# syntax=docker/dockerfile:1
#
# Build shape per docs/decisions/0001-build-shape.md: copy the upstream wger 2.7 image's
# installed python tree and source tree, unchanged, onto the Cloudron base image. Both images
# are Ubuntu 24.04 with Python 3.12.3 and a uid/gid-1000 application user, so the copy needs no
# recompilation and no apt packages in the final stage (verified locally, see phase-notes and
# docs/PACKAGING-NOTES.md).

# ---------------------------------------------------------------------------------------------
# ARG WGER_VERSION documents which upstream release this digest was resolved from. The build is
# pinned by DIGEST, not by this ARG or by a tag: docker.io/wger/server re-pushes both `latest`
# and its version tags on every push to upstream master, so a tag alone is never trustworthy
# (docs/decisions/0001-build-shape.md, AGENTS.md golden rule 2). The digest below was resolved
# from the `2.7` tag with skopeo on 2026-09-14; the image's own Created timestamp
# matches the 2.7 release date, cross-checked in evidence/wger/prefetch/releases.md.
ARG WGER_VERSION=2.7

# Stage 1: upstream wger 2.7 image, source of /home/wger/.local (pip user-site, ~662 MiB) and
# /home/wger/src (application source, settings, node_modules for STATICFILES_DIRS, ~64 MiB).
FROM docker.io/wger/server@sha256:1c5789b93bfe5eed0b7287255782d9177027b255de2b22b59f511a693a48db04 AS upstream

# Stage 2: PowerSync, the mobile apps' sync service (docs/decisions/0006). Pinned by digest; upstream
# wger's own compose runs `:latest`. Only its Node binary and its /app tree are copied below; both were
# tested on Ubuntu 24.04 (the base's glibc 2.39 is older than this Debian 13 image's 2.41, and the
# portable Node build and the one native add-on, snappy, both load).
FROM docker.io/journeyapps/powersync-service@sha256:413a0c813e96935ebe7203b5759f8a594a7b7cd8aa42134713e63af637e0f079 AS powersync

# Stage 3: the Cloudron base image. This is the ONLY stage that ships; it must stay
# cloudron/base so platform tooling (file manager, web terminal, log viewer) keeps working.
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

ARG WGER_VERSION
LABEL org.opencontainers.image.version="${WGER_VERSION}" \
      org.opencontainers.image.source="https://github.com/OrcVole/wger-cloudron"

# Both source images are uid/gid 1000 (upstream's `wger` user, the base's `cloudron` user), so
# a plain COPY --from carries the numeric ownership across unchanged and it already matches
# `cloudron` in this stage; no --chown is needed (docs/decisions/0001-build-shape.md).
COPY --from=upstream /home/wger/.local /home/wger/.local
COPY --from=upstream /home/wger/src /home/wger/src

# PostgreSQL 18 from the PostgreSQL project's own apt repository (PGDG), because Ubuntu 24.04 stops at
# 16 and the one-time move off the addon must dump an older-or-equal server into a newer one, never
# the reverse (docs/decisions/0006). postgresql-common would create a "main" cluster under /var/lib at
# install time; the package's cluster lives in the /app/pgdata persistentDir instead, so that
# default cluster is removed in the same layer.
RUN set -eux; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends postgresql-18 postgresql-client-18; \
    rm -rf /var/lib/postgresql/18/main /etc/postgresql/18/main; \
    rm -rf /var/lib/apt/lists/*; \
    /usr/lib/postgresql/18/bin/postgres --version; \
    locale -a | grep -qi '^en_US\.utf8$'

# PowerSync's own Node runtime and service tree, unmodified, plus its licence (FSL-1.1-ALv2).
COPY --from=powersync /usr/local/bin/node /opt/powersync/bin/node
COPY --from=powersync /app /opt/powersync/app
COPY LICENSE.powersync /opt/powersync/LICENSE

# Image environment mirrors upstream's own (verified in phase-notes/phase-2.md): PYTHONPATH
# and DJANGO_SETTINGS_MODULE are what upstream bakes in, PYTHONUSERBASE is pinned explicitly so
# pip user-site resolution never depends on HOME (Cloudron moves HOME to /app/data at runtime;
# start.sh re-exports all three on every boot too, per the phase-3 spec's env mapping table,
# which is intentionally redundant with these Dockerfile ENV values, not a substitute for them).
ENV PYTHONUSERBASE=/home/wger/.local \
    PYTHONPATH=/app/code/pysettings:/home/wger/src \
    DJANGO_SETTINGS_MODULE=cloudron_settings \
    PATH=/home/wger/.local/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

RUN mkdir -p /app/code

# The package's settings shim: imports upstream settings.main unchanged and overrides only
# SOCIALACCOUNT_ADAPTER (Cloudron SSO signup; see pysettings/cloudron_settings.py). Copied
# before the build gates so `manage.py check` and collectstatic validate the settings
# identity that actually ships, not a different one.
COPY pysettings/ /app/code/pysettings/

# --- Build gates (docs/decisions/0001-build-shape.md): fail the BUILD, not the first boot, if
# the copied tree does not import or does not pass Django's own system checks. Also bakes
# static assets at build time, per the "Static placement decision" in phase-notes/phase-3.md:
# collectstatic needs no database (verified: 11 471 files, 294 MiB, with only a placeholder
# SECRET_KEY), and shipping it read-only in the image means it is derived data that changes
# exactly when the image changes, never written to /app/data, never regenerated at boot.
# All env below is scoped to this RUN only (shell-exported, not an ENV instruction) so none of
# these placeholder values leak into the running container's environment.
RUN set -eux; \
    export \
        SECRET_KEY='build-time-placeholder-not-used-at-runtime' \
        DJANGO_DB_ENGINE='django.db.backends.sqlite3' \
        DJANGO_DB_DATABASE='/tmp/wger-build.sqlite3' \
        DJANGO_DB_USER='build' \
        DJANGO_DB_PASSWORD='build' \
        DJANGO_DB_HOST='localhost' \
        DJANGO_DB_PORT='5432' \
        DJANGO_STATIC_ROOT='/app/code/static' \
        DJANGO_MEDIA_ROOT='/tmp/wger-build-media'; \
    cd /home/wger/src; \
    python3 -c "import django, wger"; \
    python3 manage.py check; \
    python3 manage.py shell -c "from allauth.socialaccount.adapter import get_adapter; a = get_adapter(); assert type(a).__name__ == 'CloudronSocialAccountAdapter', type(a).__name__; print('social adapter gate OK')"; \
    python3 manage.py collectstatic --noinput; \
    file_count="$(find /app/code/static -type f | wc -l)"; \
    echo "==> collectstatic produced ${file_count} files"; \
    test "${file_count}" -gt 10000; \
    rm -rf /tmp/wger-build.sqlite3 /tmp/wger-build-media

# Package's own runtime adaptation layer: start.sh, bootstrap.sh, nginx, supervisor. Nothing
# here touches the application itself (AGENTS.md golden rule 1). bootstrap.sh is a supervisor
# program (supervisor/conf.d/bootstrap.conf) that runs the first-run/every-boot database work
# concurrently with nginx rather than before supervisord starts at all -- see start.sh and
# bootstrap.sh's own header comments for why.
COPY start.sh /app/code/start.sh
COPY bootstrap.sh /app/code/bootstrap.sh
COPY backup.sh restore.sh /app/code/
COPY postgres/ /app/code/postgres/
COPY powersync/powersync.yaml powersync/sync_rules.yaml powersync/run.sh powersync/compact-loop.sh /app/code/powersync/
COPY nginx/wger.conf /app/code/nginx/wger.conf
COPY supervisor/supervisord.conf /app/code/supervisor/supervisord.conf
COPY supervisor/fatal-exit-listener.py /app/code/supervisor/fatal-exit-listener.py
COPY supervisor/conf.d/ /app/code/supervisor/conf.d/

RUN set -eux; \
    chmod 0755 /app/code/start.sh /app/code/bootstrap.sh /app/code/backup.sh /app/code/restore.sh \
        /app/code/postgres/run.sh /app/code/powersync/run.sh /app/code/powersync/compact-loop.sh; \
    chmod 0644 /app/code/postgres/pg.sh /app/code/postgres/pg_hba.conf \
        /app/code/powersync/powersync.yaml /app/code/powersync/sync_rules.yaml; \
    mkdir -p /app/pgdata; \
    chown cloudron:cloudron /app/pgdata; \
    /opt/powersync/bin/node --version; \
    /opt/powersync/bin/node /opt/powersync/app/service/lib/entry.js --help > /dev/null

WORKDIR /app/code

# No ENTRYPOINT: it breaks Cloudron debug mode (AGENTS.md golden rule 6). start.sh runs as
# root to do setup (chown /app/data, seed secrets, migrate) and hands off to supervisord, which
# in turn runs every application process as `cloudron`.
CMD ["/app/code/start.sh"]
