#!/bin/bash
#
# bootstrap.sh: runs as a ONE-SHOT supervisor program (supervisor/conf.d/bootstrap.conf),
# user=cloudron, autostart=true, autorestart=false, started alongside nginx. It exists to
# reconcile two doctrine requirements that are in tension if the DB-dependent work runs
# serially in start.sh before supervisord starts at all:
#
#   1. AGENTS.md / phase-notes/phase-3.md: nginx answers /healthcheck immediately, specifically
#      BECAUSE first boot (fixtures, migrations) "can be slow enough that a proxied check would
#      fail the install window" -- this requires nginx to be listening independent of how long
#      migrations take.
#   2. phase-notes/phase-3.md's first-run state machine: the random admin password must be set
#      "IMMEDIATELY, before any listener starts" after `wger bootstrap`, because upstream's own
#      bootstrap creates the admin user with a known fixture password; "the insecure window is
#      internal to start.sh with no port bound".
#
# Resolution: nginx (program priority 10, autostart=true) starts immediately when supervisord
# starts, so /healthcheck is answered within a couple of seconds of container start regardless
# of database state -- satisfying (1). gunicorn, celery-worker and celery-beat are configured
# `autostart=false` (see their supervisor/conf.d/*.conf files) and are started by THIS script,
# via supervisorctl, only once the admin password has already been reset. Until that happens,
# nginx is technically listening, but everything it would proxy to Django (the login page, the
# API, any authenticated route) 502s because gunicorn is not running -- so the actual attack
# surface the "no listener" language is protecting against (logging in with the fixture default
# password) stays closed the whole time, satisfying the intent of (2) even though the literal
# TCP accept() on :8000 happens earlier than a strictly serial reading of phase-3 implies. This
# is the single most consequential deviation from a literal reading of the spec in this package;
# see start.sh's header comment for the same note from the other side.
# -E so the ERR trap (fatal, below) also fires inside functions: without it a failure in a
# function exits this script quietly, nginx keeps answering the health check, and gunicorn never
# starts. Commands already guarded with `|| fatal` are unaffected.
set -Eeuo pipefail

log() { printf '==> [bootstrap] %s\n' "$*"; }

MANAGE="/home/wger/src/manage.py"
SUPERVISOR_CONF="/app/code/supervisor/supervisord.conf"
# shellcheck source=postgres/pg.sh
source /app/code/postgres/pg.sh

# Fail LOUD: this script is the only thing standing between "container up" and "application
# actually serving". If it fails and merely exits, nginx keeps answering /healthcheck 200 with
# nothing behind it, and the platform never restarts a running container on health alone, so
# the install would sit green and dead forever. Any fatal outcome therefore shuts supervisord
# down so the whole container exits and the failure is visible to the platform and the log.
fatal() {
    echo "==> [bootstrap] FATAL: $*" >&2
    supervisorctl -c "${SUPERVISOR_CONF}" shutdown >/dev/null 2>&1 || true
    exit 1
}
trap 'fatal "unexpected error at line ${LINENO}"' ERR

# Already running as cloudron (supervisor program `user=cloudron`), so no gosu is needed here,
# unlike start.sh which is still root at the point it seeds secrets.
manage() {
    python3 "${MANAGE}" "$@"
}

# Forwards TERM/INT to the backgrounded child and waits, so a container stop during migrate or
# the first-run bootstrap does not leave the database mid-transaction with nothing watching it.
# supervisord's own stopsignal/stopwaitsecs (see supervisor/conf.d/bootstrap.conf) delivers the
# signal to THIS script's PID; without this wrapper a child spawned with a plain `cmd &` would
# not receive it (supervisord signals only the process it directly spawned).
run_interruptible() {
    "$@" &
    local child=$!
    # shellcheck disable=SC2064  # intentional immediate expansion of $child
    trap "echo '==> [bootstrap] received TERM/INT, forwarding to pid ${child}'; kill -TERM ${child} 2>/dev/null || true" TERM INT
    local rc=0
    wait "${child}" || rc=$?
    trap - TERM INT
    return "${rc}"
}

# Bounded TCP reachability wait. Upstream's own database_exists() (mirrored below) treats ANY
# DatabaseError -- including "connection refused" -- as "empty", so waiting for a real TCP
# handshake first stops a merely-not-up-yet addon container from being mistaken for a fresh
# install and re-triggering fixtures against what is actually just a slow-starting database.
wait_for_tcp() {
    local name="$1" host="$2" port="$3" attempt
    for attempt in $(seq 1 30); do
        if python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
except OSError:
    sys.exit(1)
s.close()
' "${host}" "${port}"; then
            log "${name} reachable at ${host}:${port}"
            return 0
        fi
        log "waiting for ${name} at ${host}:${port} (attempt ${attempt}/30)"
        sleep 2
    done
    fatal "${name} at ${host}:${port} did not become reachable after 60s"
}

# Based on wger/tasks.py's own database_exists() (verified against the pinned image's source on
# 2026-08-01; replicated rather than reused because it is reached through the `wger` invoke
# CLI's bootstrap task, not exposed as its own manage.py command), with two deliberate
# hardenings, both bought by a live smoke failure on 2026-08-01:
#
#   1. The verdict is a sentinel LINE extracted from the output, never a comparison of the
#      whole captured blob: Django's app-ready logging writes INFO noise to stdout (django-axes
#      prints an "AXES: BEGIN" banner), and that noise rode along in the command substitution,
#      made the blob != "EMPTY", and silently skipped first-run bootstrap on a genuinely fresh
#      database (observed live: fresh sidecar, "database already has data", then migrations
#      applying 0001_initial from scratch, then a fixtureless site answering 500).
#   2. A reachable schema with ZERO users also counts as empty, which is STRONGER than
#      upstream's table-existence test: a first run interrupted between migrate and the
#      fixtures (a real possibility when the platform restarts a container during a slow first
#      install) leaves tables but no users, and under upstream semantics that state would skip
#      bootstrap forever. Zero users provably means zero user-owned data, so re-running the
#      fixture bootstrap there is safe and self-healing.
database_is_empty() {
    local out state
    out="$(manage shell -c '
from django.contrib.auth.models import User
from django.db import DatabaseError
try:
    n = User.objects.count()
except DatabaseError:
    print("WGER_DB_STATE=EMPTY")
else:
    print("WGER_DB_STATE=EMPTY" if n == 0 else "WGER_DB_STATE=HAS_DATA")
' 2>/dev/null)" || fatal "could not probe database emptiness"
    state="$(printf '%s\n' "${out}" | sed -n 's/^WGER_DB_STATE=//p' | tail -1)"
    [[ -n "${state}" ]] || fatal "database emptiness probe produced no verdict"
    [[ "${state}" == "EMPTY" ]]
}

# Admin password handling, STATE-driven rather than first-run-flag-driven: the fixture set
# (users.json) creates exactly one user, admin, with the known default password 'adminadmin'.
# Whatever boot this is, if the admin user currently carries that default it is replaced with
# a random password before gunicorn ever starts. That heals every interruption window (killed
# between fixtures and reset, killed mid-reset) without ever touching a password the operator
# has since changed, and it never resets anything on a restored or long-running install.
# Sentinel-prefixed extraction throughout, same reason as database_is_empty(): Django log
# noise on stdout would otherwise be captured into the values.
ensure_admin_password() {
    local admin_pw_file="${SECRETS_DIR}/admin-password"
    local out verdict
    out="$(manage shell -c '
import secrets
from django.contrib.auth.models import User
try:
    u = User.objects.get(username="admin")
except User.DoesNotExist:
    print("WGER_ADMIN=ABSENT")
else:
    if u.check_password("adminadmin"):
        pw = secrets.token_urlsafe(24)
        u.set_password(pw)
        u.save()
        print("WGER_ADMIN_PW=" + pw)
        print("WGER_ADMIN=RESET")
    else:
        print("WGER_ADMIN=PRESENT_CUSTOM")
' 2>/dev/null)" || fatal "could not inspect the admin user"
    verdict="$(printf '%s\n' "${out}" | sed -n 's/^WGER_ADMIN=//p' | tail -1)"
    case "${verdict}" in
    RESET)
        local admin_pw
        admin_pw="$(printf '%s\n' "${out}" | sed -n 's/^WGER_ADMIN_PW=//p' | tail -1)"
        [[ -n "${admin_pw}" ]] || fatal "admin password reset produced no value"
        ( umask 077; printf '%s' "${admin_pw}" > "${admin_pw_file}" )
        chmod 0600 "${admin_pw_file}"
        log "admin password was the fixture default; replaced with a random one, written to ${admin_pw_file} (0600, value never logged)"
        ;;
    PRESENT_CUSTOM)
        if [[ ! -s "${admin_pw_file}" ]]; then
            log "note: admin password is operator-managed and ${admin_pw_file} is absent; leaving it untouched"
        fi
        ;;
    ABSENT)
        if [[ "${FIRST_RUN}" == "1" ]]; then
            fatal "admin user missing immediately after first-run fixtures"
        fi
        log "note: no admin user exists (operator-managed?); nothing to do"
        ;;
    *)
        fatal "admin probe produced no verdict"
        ;;
    esac
    unset out
}

# Cloudron SSO (experiment E4): reconcile the allauth SocialApp row for the oidc addon on
# EVERY boot. Addon present: create or update the row from CLOUDRON_OIDC_* (values can change
# across restarts, golden rule for addon env). Addon absent: delete any previously seeded row,
# so a stale login button never points at a dead issuer. allauth.socialaccount is always in
# INSTALLED_APPS in wger's settings (only the per-provider apps are env-gated), so the model
# is importable in both branches. The callback URL follows allauth's provider-id pattern
# under wger's SINGULAR mount point: /account/oidc/<provider_id>/login/callback/ with
# provider_id "cloudron" (verified live on the rig 2026-08-01: allauth sent exactly
# redirect_uri=https://<app>/account/oidc/cloudron/login/callback/; doctrine gotcha #48's
# warning about guessing this path was earned, the plural /accounts/ guess was wrong).
reconcile_oidc_socialapp() {
    local out
    out="$(manage shell -c '
import os
from allauth.socialaccount.models import SocialApp
from django.contrib.sites.models import Site

issuer = os.environ.get("CLOUDRON_OIDC_ISSUER", "")
if issuer:
    app, created = SocialApp.objects.update_or_create(
        provider="openid_connect",
        provider_id="cloudron",
        defaults={
            "name": os.environ.get("CLOUDRON_OIDC_PROVIDER_NAME", "Cloudron"),
            "client_id": os.environ["CLOUDRON_OIDC_CLIENT_ID"],
            "secret": os.environ["CLOUDRON_OIDC_CLIENT_SECRET"],
            "settings": {"server_url": issuer},
        },
    )
    app.sites.set(Site.objects.all())
    print("WGER_OIDC=SEEDED_CREATED" if created else "WGER_OIDC=SEEDED_UPDATED")
else:
    n, _ = SocialApp.objects.filter(provider="openid_connect", provider_id="cloudron").delete()
    print("WGER_OIDC=REMOVED" if n else "WGER_OIDC=ABSENT")
' 2>/dev/null | sed -n 's/^WGER_OIDC=//p' | tail -1)" || fatal "could not reconcile the Cloudron OIDC SocialApp"
    log "Cloudron OIDC SocialApp state: ${out:-unknown}"
}

# --- the bundled database (docs/decisions/0006) ------------------------------------------------

# Written before bootstrap creates the bundled wger database, removed once the marker exists. Its
# presence at boot means any wger database in the bundled cluster is our own unfinished attempt.
IN_PROGRESS="${PGROOT}/.bundled-db-in-progress"
ADDON_DUMP="${DB_DIR}/.addon-migration.dump"

wait_for_postgres() {
    local attempt
    for attempt in $(seq 1 60); do
        if pg_ready; then
            log "bundled PostgreSQL is accepting connections"
            return 0
        fi
        log "waiting for the bundled PostgreSQL (attempt ${attempt}/60)"
        sleep 2
    done
    fatal "the bundled PostgreSQL did not accept connections after 120s"
}

# The addon, reached through the discrete CLOUDRON_POSTGRESQL_* variables (the ones 1.x used) as
# libpq's own PG* environment: no URL to build or percent-encode, and nothing depends on
# CLOUDRON_POSTGRESQL_URL being present.
addon() {
    PGHOST="${CLOUDRON_POSTGRESQL_HOST}" PGPORT="${CLOUDRON_POSTGRESQL_PORT}" \
    PGUSER="${CLOUDRON_POSTGRESQL_USERNAME}" PGPASSWORD="${CLOUDRON_POSTGRESQL_PASSWORD}" \
    PGDATABASE="${CLOUDRON_POSTGRESQL_DATABASE}" "$@"
}

addon_psql() {
    addon "${PG_BIN}/psql" -X -q -v ON_ERROR_STOP=1 "$@"
}

addon_has_wger() {
    local v
    v="$(addon_psql -Atc "SELECT to_regclass('public.django_migrations') IS NOT NULL")" \
        || fatal "could not query the postgresql addon"
    [[ "${v}" == "t" ]]
}

# See ADR 0006, "Clearing the way". Called only when no marker exists.
clear_bundled_database() {
    database_exists "${PG_DB}" || return 0
    drop_slots_for "${PG_DB}"
    local has_tables
    has_tables="$(psql_su -d "${PG_DB}" -Atc "SELECT to_regclass('public.django_migrations') IS NOT NULL")"
    if [[ -e "${IN_PROGRESS}" || "${has_tables}" != "t" ]]; then
        log "dropping an unfinished bundled database from an earlier attempt"
        psql_su -d postgres -c "DROP DATABASE ${PG_DB}"
        return 0
    fi
    local keep old
    keep="${PG_DB}_orphaned_$(date -u +%Y%m%d%H%M%S)"
    for old in $(psql_su -d postgres -Atc "SELECT datname FROM pg_database WHERE datname LIKE '${PG_DB}\_orphaned\_%'"); do
        drop_slots_for "${old}"
        psql_su -d postgres -c "DROP DATABASE \"${old}\""
    done
    log "WARNING: the bundled cluster holds a wger database with data but no marker says it is current"
    log "WARNING: (usually: this app was rolled back to a pre-2.0.0 backup and then updated again)."
    log "WARNING: keeping it as ${keep} and copying the current data from the addon instead"
    psql_su -d postgres -c "ALTER DATABASE ${PG_DB} RENAME TO \"${keep}\""
}

migrate_from_addon() {
    log "MOVING THE DATABASE: copying wger's data from the postgresql addon into the bundled server (one time)"
    rm -f "${ADDON_DUMP}"
    log "dumping the addon database"
    run_interruptible addon "${PG_BIN}/pg_dump" --format=custom --no-owner --no-privileges \
        --file="${ADDON_DUMP}"
    log "dump written ($(du -h "${ADDON_DUMP}" | cut -f1)); loading it into the bundled server"
    run_interruptible restore_dump_into_app_db "${ADDON_DUMP}"

    log "verifying: exact row counts of every table, addon against bundled"
    local want got
    want="$(addon_psql -At -F '|' -c "${count_rows_sql}" | LC_ALL=C sort)" || fatal "could not count rows in the addon"
    got="$(count_rows_bundled)" || fatal "could not count rows in the bundled database"
    if [[ "${want}" != "${got}" ]]; then
        diff <(printf '%s\n' "${want}") <(printf '%s\n' "${got}") | sed 's/^/==> [bootstrap]   /' >&2 || true
        fatal "row counts differ between the addon and the bundled copy (above: < addon, > bundled). The addon is untouched and the move will be retried on the next start."
    fi
    local tables rows
    tables="$(printf '%s\n' "${got}" | grep -c .)"
    rows="$(printf '%s\n' "${got}" | awk -F'|' '{ s += $2 } END { print s + 0 }')"
    write_marker addon "${tables}" "${rows}"
    rm -f "${ADDON_DUMP}"
    log "database moved and verified: ${tables} tables, ${rows} rows, all matching the addon. The addon copy is kept, unchanged, as the rollback copy."
}

# Decide where wger's data comes from on this boot (ADR 0006, the state table).
prepare_database() {
    ensure_roles || fatal "could not create or update the database roles"
    if [[ -e "${MARKER}" ]]; then
        database_exists "${PG_DB}" || fatal "${MARKER} says the bundled database is authoritative, but it has no ${PG_DB} database. Restore this app from a backup."
        log "bundled database is authoritative ($(cat "${MARKER}"))"
        return 0
    fi
    # The addon decides fresh-versus-move, so wait for it: a slow addon must not read as "empty".
    wait_for_tcp "postgresql addon" "${CLOUDRON_POSTGRESQL_HOST}" "${CLOUDRON_POSTGRESQL_PORT}"
    clear_bundled_database
    touch "${IN_PROGRESS}"
    create_app_database
    if addon_has_wger; then
        migrate_from_addon
    else
        log "fresh install: the addon holds no wger data, so the bundled database starts empty"
        write_marker fresh 0 0
    fi
    rm -f "${IN_PROGRESS}"
}

# PowerSync's access, re-asserted every boot after migrations (new tables need the grant too;
# the default-privileges rule covers tables created later by wger's own migrations).
ensure_powersync_access() {
    psql_su -d "${PG_DB}" -v sync_role="${PG_SYNC_ROLE}" -v app_role="${PG_APP_ROLE}" -v schema="${PG_SYNC_SCHEMA}" <<'SQL' \
        || fatal "could not grant PowerSync its access"
SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', :'schema', :'sync_role') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'sync_role') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'sync_role') \gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'sync_role') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON TABLES TO %I', :'app_role', :'sync_role') \gexec
SQL
    local pub
    pub="$(psql_su -d "${PG_DB}" -Atc "SELECT count(*) FROM pg_publication_tables WHERE pubname = 'powersync'")"
    [[ "${pub}" -gt 0 ]] || fatal "the powersync publication is missing or empty after migrations (core migration 0027 should have created it)"
    log "PowerSync access in place: schema ${PG_SYNC_SCHEMA}, read access to public, publication covers ${pub} tables"
}

# --- main ------------------------------------------------------------------------------------

log "starting (nginx is already up and answering /healthcheck; gunicorn/celery are not started yet)"

wait_for_postgres
wait_for_tcp redis "${CLOUDRON_REDIS_HOST}" "${CLOUDRON_REDIS_PORT}"
prepare_database

log "probing database emptiness"
FIRST_RUN=0
if database_is_empty; then
    FIRST_RUN=1
    log "database is empty (no tables, or tables with zero users): first-run fixtures will be loaded"
else
    log "database already has data: first-run fixtures will be skipped"
fi

# The first-run work is deliberately NOT delegated to upstream's `wger bootstrap` any more:
# that task gates itself on table-existence, so in the migrated-but-unfixtured state a real
# interrupted install leaves behind (observed live on the rig, 2026-08-01) it returns success
# in seconds having done nothing, and the install wedges. The equivalent steps run here
# explicitly (same commands, same fixture list and order as wger/tasks.py bootstrap), each one
# idempotent, so any interruption at any point heals on the next boot.
#
# ADR 0005 faked core.0023 here because the addon role could not create a FOR ALL TABLES
# publication. In wger 2.7 that migration is a no-op and 0027 creates the publication from an
# explicit table list, which the owning role may do; existing installs already record 0023 as
# applied. So migrations now run unmodified (docs/decisions/0006).
log "running database migrations"
run_interruptible python3 "${MANAGE}" migrate --noinput

if [[ "${FIRST_RUN}" == "1" ]]; then
    # Upstream loads these one loaddata call each; a single call keeps the exact list and
    # order but makes the whole fixture load ONE transaction, so an interruption rolls back
    # cleanly to "zero users" and the next boot simply retries first run. Upstream loads
    # gym.json twice (its list, verbatim); once suffices in a single atomic call.
    log "loading initial fixtures (single atomic loaddata, upstream bootstrap's list and order)"
    run_interruptible python3 "${MANAGE}" loaddata \
        gym.json languages.json groups.json users.json licenses.json \
        setting_repetition_units.json setting_weight_units.json gym_config.json \
        equipment.json muscles.json categories.json exercise-base-data.json \
        translations.json gym-config.json gym-adminconfig.json
fi

ensure_admin_password

log "setting the site URL from SITE_URL"
manage set-site-url

reconcile_oidc_socialapp

ensure_powersync_access

log "starting gunicorn, celery-worker, celery-beat, powersync and its daily compaction"
supervisorctl -c "${SUPERVISOR_CONF}" start gunicorn celery-worker celery-beat powersync powersync-compact

log "first-run/every-boot bootstrap sequence complete"
