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
set -euo pipefail

log() { printf '==> [bootstrap] %s\n' "$*"; }

MANAGE="/home/wger/src/manage.py"
SECRETS_DIR="/app/data/.secrets"
SUPERVISOR_CONF="/app/code/supervisor/supervisord.conf"

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

# --- main ------------------------------------------------------------------------------------

log "starting (nginx is already up and answering /healthcheck; gunicorn/celery are not started yet)"

wait_for_tcp postgresql "${DJANGO_DB_HOST}" "${DJANGO_DB_PORT}"
wait_for_tcp redis "${CLOUDRON_REDIS_HOST}" "${CLOUDRON_REDIS_PORT}"

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
# core.0023_create_publication runs CREATE PUBLICATION powersync FOR ALL TABLES, which
# PostgreSQL allows only to superusers; the Cloudron postgresql addon user is not one, and the
# migration killed the first install (psycopg.errors.InsufficientPrivilege, observed live
# 2026-08-01). PowerSync is not part of this package (mobile offline sync is documented as
# unavailable), so that one migration is FAKED: core is migrated for real up to 0022, 0023 is
# then recorded as applied without running, and the full migrate afterwards continues normally
# (core.0024 and later run for real). All three commands are idempotent no-ops once applied.
# Revisit at every upstream version bump: a new superuser-requiring migration would fail the
# update loudly, which is the intended fail-loud behaviour.
log "applying core migrations to 0022, then faking the PowerSync publication migration (core.0023)"
run_interruptible python3 "${MANAGE}" migrate --noinput core 0022
run_interruptible python3 "${MANAGE}" migrate --noinput --fake core 0023

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

log "starting gunicorn, celery-worker and celery-beat"
supervisorctl -c "${SUPERVISOR_CONF}" start gunicorn celery-worker celery-beat

log "first-run/every-boot bootstrap sequence complete"
