#!/bin/bash
#
# backup.sh: the manifest's backupCommand (docs/decisions/0006). Cloudron runs it as root in a
# TEMPORARY container built from this image, with /app/data and the /app/pgdata persistentDir
# mounted, no CLOUDRON_* environment, and its output discarded. It writes a consistent logical dump
# of the bundled database into /app/data, which the file backup then carries. The live cluster in
# /app/pgdata is never file-copied.
set -Eeuo pipefail
# shellcheck source=postgres/pg.sh
source /app/code/postgres/pg.sh

mkdir -p "${DB_DIR}"
chown -R cloudron:cloudron "${DB_DIR}"
BACKUP_LOG="${DB_DIR}/backup.log"
blog() { printf '%s [backup] %s\n' "$(date -u +%FT%TZ)" "$*" >> "${BACKUP_LOG}"; }
# Keep the log short: it rides every backup.
if [[ -f "${BACKUP_LOG}" ]]; then tail -n 200 "${BACKUP_LOG}" > "${BACKUP_LOG}.tmp" && mv "${BACKUP_LOG}.tmp" "${BACKUP_LOG}"; fi

# Until the marker exists the addon is authoritative, and Cloudron backs the addon up itself.
if [[ ! -e "${MARKER}" ]]; then
    blog "no ${MARKER}: the postgresql addon still holds wger's data; nothing to dump"
    exit 0
fi
if [[ ! -s "${PGDATA}/PG_VERSION" ]]; then
    blog "FAILED: ${MARKER} exists but ${PGDATA} holds no cluster"
    exit 1
fi

trap 'blog "FAILED at line ${LINENO}; the previous dump, if any, is unchanged"' ERR

started_transient=0
stop_transient() { if [[ ${started_transient} -eq 1 ]]; then pg_stop_transient "${PGDATA}"; fi; }
trap stop_transient EXIT

if pg_ready; then
    blog "live server reachable on the socket; dumping online (one consistent snapshot)"
else
    blog "no live server; starting a transient one on the data directory"
    rm -f "${PGDATA}/postmaster.pid"
    pg_start_transient "${PGDATA}" /tmp/postgres-backup.log
    started_transient=1
fi

tmp="${DUMP}.partial"
rm -f "${tmp}"
# PowerSync's bucket storage is excluded: it is rebuilt from the source after a restore.
as_pg "${PG_BIN}/pg_dump" --format=custom --exclude-schema="${PG_SYNC_SCHEMA}" \
    -h "${PG_SOCKDIR}" -p "${PG_PORT}" -U "${PG_SUPERUSER}" -d "${PG_DB}" -f "${tmp}"

# Prove the dump is readable and not hollow before it replaces the previous one.
tables="$(count_rows_in_dump "${tmp}" | grep -c .)" || tables=0
if [[ "${tables}" -lt 10 ]]; then
    blog "FAILED: the new dump lists only ${tables} tables; keeping the previous dump"
    rm -f "${tmp}"
    exit 1
fi
chmod 0600 "${tmp}"
chown cloudron:cloudron "${tmp}"
mv -f "${tmp}" "${DUMP}"
blog "wrote ${DUMP} ($(du -h "${DUMP}" | cut -f1), ${tables} tables)"
