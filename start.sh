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
        # DJANGO_DB_ENGINE is deliberately not yet set at this point in the script (infrastructure
        # is forced further down); settings/main.py's sqlite fallback branch loads fine without
        # it and this command never touches a database, so no dummy DB values are needed either.
        local jwt_out
        jwt_out="$(SECRET_KEY="$(cat "${secret_key_file}")" gosu cloudron:cloudron \
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

    log "secret material present: SECRET_KEY=yes JWT_PRIVATE_KEY=yes JWT_PUBLIC_KEY=yes (values never logged)"
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
export PYTHONPATH=/home/wger/src
export DJANGO_SETTINGS_MODULE=settings.main

export DJANGO_DB_ENGINE="django.db.backends.postgresql"
export DJANGO_DB_DATABASE="${CLOUDRON_POSTGRESQL_DATABASE}"
export DJANGO_DB_USER="${CLOUDRON_POSTGRESQL_USERNAME}"
export DJANGO_DB_PASSWORD="${CLOUDRON_POSTGRESQL_PASSWORD}"
export DJANGO_DB_HOST="${CLOUDRON_POSTGRESQL_HOST}"
export DJANGO_DB_PORT="${CLOUDRON_POSTGRESQL_PORT}"

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

export GUNICORN_WORKERS="$(compute_gunicorn_workers)"
log "gunicorn workers computed from cgroup CPU quota: ${GUNICORN_WORKERS}"

log "handing off to supervisord (tini as pid 1 for correct signal disposition)"
# NOTE: supervisord's actual CLI in this pinned base image (verified with `supervisord -h`
# against cloudron/base:5.0.0@sha256:04fd7... on 2026-08-01) only recognises -c/--configuration
# for the config file path; --configfile is not a recognised option and errors out immediately.
# AGENTS.md: "the box is the authority, not the docs" -- --configuration is used here for that
# reason, even though earlier phase notes referred to the flag as --configfile.
exec /usr/bin/tini -- /usr/bin/supervisord --nodaemon --configuration /app/code/supervisor/supervisord.conf
