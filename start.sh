#!/bin/bash
#
# start.sh: the wger Cloudron package entrypoint. Runs as root (CMD, never ENTRYPOINT -- see
# AGENTS.md golden rule 6) to do FAST setup only, then hands off to supervisord as PID 1's child
# via tini. Every package log line is prefixed "==> ".
#
# Deliberately does NOT run the database probe, first-run bootstrap, migrate or set-site-url:
# those are slow (Django migrations across ~15 apps against a cold database can run well past
# the few seconds Cloudron's install/update health-check window allows) and AGENTS.md's own
# rationale for the immediate-health shim is specifically that nginx must answer /healthcheck
# without waiting on them. bootstrap.sh (see supervisor/conf.d/bootstrap.conf) runs that work AS
# A SUPERVISOR PROGRAM, in parallel with nginx, and only starts gunicorn/celery-worker/
# celery-beat (autostart=false below) once it finishes -- so the actual Django backend, and
# therefore any working login page, only comes up after the first-run admin password has already
# been reset. See bootstrap.sh's own header comment for the full reasoning and the doctrine text
# this reconciles. This is the single most consequential deviation from a literal reading of
# phase-notes/phase-3.md's start.sh sequence; it preserves every behavioural guarantee that text
# describes (chown-before-anything-else, seed-if-absent secrets, `:=` defaults before sourcing
# operator overrides, forced infrastructure after sourcing, no boot-time collectstatic) while
# moving only the DB-dependent steps to run concurrently with nginx instead of before it.
set -euo pipefail
umask 022

log() { printf '==> %s\n' "$*"; }

SECRETS_DIR=/app/data/.secrets
MANAGE="/home/wger/src/manage.py"
# shellcheck source=postgres/pg.sh
source /app/code/postgres/pg.sh

urlencode() {
    python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

compute_gunicorn_workers() {
    local quota period cpus
    if [[ -r /sys/fs/cgroup/cpu.max ]]; then
        read -r quota period < /sys/fs/cgroup/cpu.max
        if [[ "${quota}" == "max" ]]; then
            cpus="$(nproc)"
        else
            cpus=$(( (quota + period - 1) / period ))
        fi
    else
        cpus="$(nproc)"
    fi
    (( cpus < 1 )) && cpus=1
    (( cpus > 3 )) && cpus=3
    echo "${cpus}"
}

# Seeds SECRET_KEY and the JWT RS256 keypair the first time they are absent. Idempotent: does
# nothing once the files exist. Never regenerated after that (AGENTS.md: both are
# data-loss-critical; rotation only invalidates sessions / logs mobile apps out, but "never
# regenerated once seeded" is the contract). Runs here, pre-exec, rather than in bootstrap.sh,
# because the files it produces are read back into this script's own exported environment
# (SECRET_KEY, JWT_PRIVATE_KEY, JWT_PUBLIC_KEY, below) before supervisord and every program it
# runs inherit that environment.
seed_secrets() {
    local secret_key_file="${SECRETS_DIR}/secret-key"
    local jwt_private_file="${SECRETS_DIR}/jwt-private"
    local jwt_public_file="${SECRETS_DIR}/jwt-public"

    if [[ ! -s "${secret_key_file}" ]]; then
        log "seeding SECRET_KEY (first boot)"
        ( umask 077; openssl rand -hex 50 > "${secret_key_file}" )
        chmod 0600 "${secret_key_file}"
        chown cloudron:cloudron "${secret_key_file}"
    fi

    if [[ ! -s "${jwt_private_file}" || ! -s "${jwt_public_file}" ]]; then
        log "seeding JWT RS256 keypair (first boot, via manage.py generate-jwt-keys)"
        # generate-jwt-keys (wger/core/management/commands/generate-jwt-keys.py, read from the
        # pinned image on 2026-08-01) writes ONLY to stdout (all warnings and Django's system
        # check output go to stderr, verified separately by running it with split streams):
        #   # Paste these into your environment file (e.g. docker/config/prod.env).
        #   # Keep JWT_PRIVATE_KEY secret, never commit it to a public repo.
        #   <blank line>
        #   JWT_PRIVATE_KEY=<base64url-encoded JSON JWK, RSA private, kid=wger, no padding>
        #   JWT_PUBLIC_KEY=<base64url-encoded JSON JWK, RSA public, kid=wger, no padding>
        # settings/main.py decodes these itself (jwk_b64_to_pem) at import time, so the files
        # below store the values exactly as printed -- still base64-JWK-encoded, not decoded --
        # and are re-exported verbatim as JWT_PRIVATE_KEY/JWT_PUBLIC_KEY on every boot.
          # wger 2.7 requires DJANGO_DB_ENGINE to be set even for generate-jwt-keys (settings/main.py
          # no longer has a safe sqlite fallback when the env var is absent). Dummy values suffice
          # because this command never touches a database -- it only generates key material.
        local jwt_out
        jwt_out="$(SECRET_KEY="$(cat "${secret_key_file}")" \
            DJANGO_DB_ENGINE='django.db.backends.sqlite3' \
            DJANGO_DB_DATABASE='/tmp/wger-build.sqlite3' \
            DJANGO_DB_USER='build' \
            DJANGO_DB_PASSWORD='build' \
            DJANGO_DB_HOST='localhost' \
            DJANGO_DB_PORT='5432' \
            gosu cloudron:cloudron \
            python3 "${MANAGE}" generate-jwt-keys 2>/dev/null)" || { echo "==> FATAL: generate-jwt-keys failed" >&2; exit 1; }
        local priv pub
        priv="$(printf '%s\n' "${jwt_out}" | sed -n 's/^JWT_PRIVATE_KEY=//p')"
        pub="$(printf '%s\n' "${jwt_out}" | sed -n 's/^JWT_PUBLIC_KEY=//p')"
        if [[ -z "${priv}" || -z "${pub}" ]]; then
            echo "==> FATAL: generate-jwt-keys did not produce JWT_PRIVATE_KEY/JWT_PUBLIC_KEY" >&2
            exit 1
        fi
        ( umask 077; printf '%s' "${priv}" > "${jwt_private_file}" )
        ( umask 077; printf '%s' "${pub}"  > "${jwt_public_file}" )
        chmod 0600 "${jwt_private_file}" "${jwt_public_file}"
        chown cloudron:cloudron "${jwt_private_file}" "${jwt_public_file}"
        unset jwt_out priv pub
    fi

    # Passwords for the bundled PostgreSQL's two login roles (docs/decisions/0006). Hex, so they
    # never need quoting in a connection URI. bootstrap.sh and restore.sh re-assert them on the
    # roles every time, so the files are the single source of truth.
    local name
    for name in db-wger db-powersync; do
        if [[ ! -s "${SECRETS_DIR}/${name}" ]]; then
            log "seeding ${name} password (first boot of the bundled database)"
            ( umask 077; openssl rand -hex 24 > "${SECRETS_DIR}/${name}" )
        fi
    done

    log "secret material present: SECRET_KEY=yes JWT_PRIVATE_KEY=yes JWT_PUBLIC_KEY=yes db-wger=yes db-powersync=yes (values never logged)"
}

# The bundled PostgreSQL's data directory (docs/decisions/0006). Fast by design, so it stays in
# start.sh: at most one initdb of an empty cluster (a second or two). The slow, database-dependent
# work (the one-time move off the addon, migrations) is bootstrap.sh's, after nginx is up.
prepare_postgres() {
    mkdir -p "${PGROOT}" "${DB_DIR}" /run/powersync
    chown cloudron:cloudron "${PGROOT}" "${DB_DIR}" /run/powersync
    chmod 0700 "${PGROOT}"
    # A restore or the backup container (which runs as root) can leave files root-owned. Walk only
    # what is wrong rather than chown -R an entire cluster on every boot.
    find "${PGROOT}" -xdev ! -user cloudron -exec chown cloudron:cloudron {} +

    if [[ -s "${PGDATA}/PG_VERSION" ]]; then
        local have
        have="$(cat "${PGDATA}/PG_VERSION")"
        if [[ "${have}" != "${PG_MAJOR}" ]]; then
            echo "==> FATAL: ${PGDATA} holds a PostgreSQL ${have} cluster but this package runs PostgreSQL ${PG_MAJOR}." >&2
            echo "==> FATAL: refusing to start rather than create a new cluster beside it. Restore a backup taken by this package version, or ask the packager for an upgrade path." >&2
            exit 1
        fi
        log "bundled PostgreSQL ${PG_MAJOR} cluster present"
    elif [[ -e "${MARKER}" ]]; then
        # The marker says the bundled database is authoritative, yet the cluster is gone. On a
        # clone Cloudron's restoreCommand rebuilds it before this script ever runs, so reaching
        # here means there was nothing to rebuild from. Starting empty would look like data loss.
        echo "==> FATAL: ${MARKER} says wger's data lives in the bundled database, but ${PGDATA} is empty." >&2
        echo "==> FATAL: restore this app from a backup. To deliberately start over with an empty database, delete ${MARKER} first." >&2
        exit 1
    else
        log "initialising an empty PostgreSQL ${PG_MAJOR} cluster in ${PGDATA}"
        pg_initdb "${PGDATA}"
    fi
}

# --- main ------------------------------------------------------------------------------------

log "wger Cloudron package starting"

# Persisted state only in /app/data; ownership and mode are re-asserted on EVERY boot because a
# restore drifts them (AGENTS.md golden rule 3). This is the first action, before anything else.
mkdir -p /app/data
chown -R cloudron:cloudron /app/data

# Runtime HOME for this script and, through the supervisord exec below, for every program it
# runs. supervisord does NOT reset HOME when dropping a program to user=cloudron, so without
# this every child inherits root's HOME=/root; the `wger` CLI is invoke-based, invoke opens
# $HOME/.invoke.yaml at startup, and as uid cloudron that open fails EACCES and kills first-run
# bootstrap (observed live 2026-08-01). /app/data is the doctrine home for runtime HOME: it
# exists, it is owned by cloudron, and stray dotfiles land somewhere harmless and backed up.
export HOME=/app/data

mkdir -p "${SECRETS_DIR}"
chmod 0700 "${SECRETS_DIR}"
chown cloudron:cloudron "${SECRETS_DIR}"

mkdir -p /app/data/media
chown cloudron:cloudron /app/data/media

# /run does not persist across restarts, so its subtrees are (re)created every boot, before
# supervisord (and therefore nginx/bootstrap/celery-beat) starts.
mkdir -p /run/nginx /run/wger /run/supervisor
chown -R cloudron:cloudron /run/nginx /run/wger
chmod 0755 /run/nginx /run/wger
# root:cloudron, group-writable: supervisord (root) owns the control socket it creates here, but
# bootstrap.sh runs as cloudron and needs to reach it via supervisorctl once first-run bootstrap
# finishes, to start gunicorn/celery-worker/celery-beat (see supervisor/supervisord.conf's
# unix_http_server section, which sets chown/chmod on the actual socket file to match).
chown root:cloudron /run/supervisor
chmod 0750 /run/supervisor

seed_secrets

# Re-assert ownership and mode on every secret file on every boot, outside the seed-once branch
# above: a restore can reset permissions on files that already existed (AGENTS.md golden rule 3).
find "${SECRETS_DIR}" -maxdepth 1 -type f -exec chmod 0600 {} + -exec chown cloudron:cloudron {} +

prepare_postgres

# Operator-tunable defaults, set with the `:=` pattern so an operator override in /app/data/env
# (sourced next) can replace them. Package-forced infrastructure values are exported further
# below, AFTER sourcing, so they always win regardless of what the operator file contains.
: "${ALLOW_REGISTRATION:=False}"
: "${ALLOW_GUEST_USERS:=False}"
: "${SYNC_EXERCISES_CELERY:=True}"
: "${SYNC_EXERCISE_IMAGES_CELERY:=True}"
: "${SYNC_EXERCISE_VIDEOS_CELERY:=True}"
: "${SYNC_INGREDIENTS_CELERY:=False}"
: "${CELERY_WORKER_CONCURRENCY:=2}"
: "${GUNICORN_EXTRA_ARGS:=}"
: "${LOG_LEVEL_PYTHON:=INFO}"
default_tz="UTC"
[[ -r /etc/timezone ]] && default_tz="$(cat /etc/timezone)"
: "${TIME_ZONE:=${default_tz}}"
unset default_tz
export ALLOW_REGISTRATION ALLOW_GUEST_USERS SYNC_EXERCISES_CELERY SYNC_EXERCISE_IMAGES_CELERY \
       SYNC_EXERCISE_VIDEOS_CELERY SYNC_INGREDIENTS_CELERY CELERY_WORKER_CONCURRENCY \
       GUNICORN_EXTRA_ARGS LOG_LEVEL_PYTHON TIME_ZONE

if [[ -f /app/data/env ]]; then
    log "sourcing operator overrides from /app/data/env"
    # shellcheck disable=SC1091
    source /app/data/env
fi

log "forcing package infrastructure environment (always wins over operator overrides)"

export PYTHONUSERBASE=/home/wger/.local
export PYTHONPATH=/app/code/pysettings:/home/wger/src
export DJANGO_SETTINGS_MODULE=cloudron_settings

# Django uses the BUNDLED PostgreSQL over its Unix socket, as the non-superuser owner role
# (docs/decisions/0006). The postgresql addon stays declared only as the source of the one-time
# move and as the rollback copy; bootstrap.sh reads it through the CLOUDRON_POSTGRESQL_* variables
# and nothing else touches it. Never export PS_DATABASE_URI here: see powersync/run.sh.
export DJANGO_DB_ENGINE="django.db.backends.postgresql"
export DJANGO_DB_DATABASE="${PG_DB}"
export DJANGO_DB_USER="${PG_APP_ROLE}"
export DJANGO_DB_PASSWORD="$(cat "${SECRETS_DIR}/db-wger")"
export DJANGO_DB_HOST="${PG_SOCKDIR}"
export DJANGO_DB_PORT="${PG_PORT}"

redis_pw_enc="$(urlencode "${CLOUDRON_REDIS_PASSWORD}")"
export DJANGO_CACHE_BACKEND="django_redis.cache.RedisCache"
export DJANGO_CACHE_LOCATION="redis://:${redis_pw_enc}@${CLOUDRON_REDIS_HOST}:${CLOUDRON_REDIS_PORT}/0"
export DJANGO_CACHE_CLIENT_PASSWORD="${CLOUDRON_REDIS_PASSWORD}"
export DJANGO_CACHE_CLIENT_CLASS="django_redis.client.DefaultClient"
export CELERY_BROKER="redis://:${redis_pw_enc}@${CLOUDRON_REDIS_HOST}:${CLOUDRON_REDIS_PORT}/1"
export CELERY_BACKEND="redis://:${redis_pw_enc}@${CLOUDRON_REDIS_HOST}:${CLOUDRON_REDIS_PORT}/1"
unset redis_pw_enc
export USE_CELERY="True"

export SECRET_KEY="$(cat "${SECRETS_DIR}/secret-key")"
export JWT_PRIVATE_KEY="$(cat "${SECRETS_DIR}/jwt-private")"
export JWT_PUBLIC_KEY="$(cat "${SECRETS_DIR}/jwt-public")"

export SITE_URL="${CLOUDRON_APP_ORIGIN}"
export CSRF_TRUSTED_ORIGINS="${CLOUDRON_APP_ORIGIN}"
export X_FORWARDED_PROTO_HEADER_SET="True"
export NUMBER_OF_PROXIES="2"

export DJANGO_MEDIA_ROOT="/app/data/media"
export DJANGO_STATIC_ROOT="/app/code/static"

export ENABLE_EMAIL="True"
export EMAIL_HOST="${CLOUDRON_MAIL_SMTP_SERVER}"
export EMAIL_PORT="${CLOUDRON_MAIL_SMTP_PORT}"
export EMAIL_HOST_USER="${CLOUDRON_MAIL_SMTP_USERNAME}"
export EMAIL_HOST_PASSWORD="${CLOUDRON_MAIL_SMTP_PASSWORD}"
# CLOUDRON_MAIL_SMTP_PORT has STARTTLS disabled by the platform (addon docs); the relay is plain
# on that port, internal to the Cloudron network, so EMAIL_USE_TLS must stay False.
export EMAIL_USE_TLS="False"
export FROM_EMAIL="${CLOUDRON_MAIL_FROM}"

export DOWNLOAD_INGREDIENTS_FROM="WGER"
export DJANGO_DEBUG="False"

# Cloudron SSO (experiment E4): when the oidc addon is present, its CLOUDRON_OIDC_* values
# are in the environment; enable allauth's generic openid_connect provider then. Forced after
# the operator override sourcing like the rest of the infrastructure block. The SocialApp row
# carrying the actual issuer/client configuration is reconciled by bootstrap.sh once the
# database is migrated. With the addon absent the variable stays unset and the provider app is
# simply not loaded.
if [[ -n "${CLOUDRON_OIDC_ISSUER:-}" ]]; then
    export WGER_SOCIAL_PROVIDERS="openid_connect"
fi

export GUNICORN_WORKERS="$(compute_gunicorn_workers)"
log "gunicorn workers computed from cgroup CPU quota: ${GUNICORN_WORKERS}"

log "handing off to supervisord (tini as pid 1 for correct signal disposition)"
# NOTE: supervisord's actual CLI in this pinned base image (verified with `supervisord -h`
# against cloudron/base:5.0.0@sha256:04fd7... on 2026-08-01) only recognises -c/--configuration
# for the config file path; --configfile is not a recognised option and errors out immediately.
# AGENTS.md: "the box is the authority, not the docs" -- --configuration is used here for that
# reason, even though earlier phase notes referred to the flag as --configfile.
exec /usr/bin/tini -- /usr/bin/supervisord --nodaemon --configuration /app/code/supervisor/supervisord.conf
