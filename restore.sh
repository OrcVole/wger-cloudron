#!/bin/bash
#
# restore.sh: the manifest's restoreCommand (docs/decisions/0006). Cloudron runs it as root in a
# TEMPORARY container, after it has restored /app/data from a backup and before the app starts,
# with the /app/pgdata persistentDir mounted, no CLOUDRON_* environment, and its output discarded.
#
# On a CLONE the persistentDir is empty. On an IN-PLACE restore the platform KEEPS it, so the live
# cluster may be newer than the backup being restored. Either way this script rebuilds the database
# from the backup's dump, so a restore really does take wger back to the backup. A populated
# cluster is first moved aside (a rename inside the persistentDir, instant) and is put back if the
# rebuild fails for any reason, so a failed restore never leaves wger empty or half-loaded.
#
# Every run appends to /app/data/db/restore.log, because nothing else about this container is
# observable. The package's gates read it to prove when Cloudron does and does not call this.
# -E: the ERR trap below must also fire for failures inside the library's functions.
set -Eeuo pipefail
# shellcheck source=postgres/pg.sh
source /app/code/postgres/pg.sh

mkdir -p "${DB_DIR}"
# A restore hands files back root-owned and with modes reset (platform facts); the dump is read by
# the unprivileged server user below.
chown -R cloudron:cloudron "${DB_DIR}"
rlog() { printf '%s [restore] %s\n' "$(date -u +%FT%TZ)" "$*" >> "${RESTORE_LOG}"; }

rlog "called (dump: $([[ -s "${DUMP}" ]] && echo present || echo absent); marker: $([[ -e "${MARKER}" ]] && echo present || echo absent); cluster: $([[ -s "${PGDATA}/PG_VERSION" ]] && echo present || echo absent))"

if [[ ! -e "${MARKER}" || ! -s "${DUMP}" ]]; then
    # A backup taken before the database moved: the addon holds the data and Cloudron restores it.
    rlog "nothing to rebuild from; the cluster is left as it is"
    exit 0
fi

mkdir -p "${PGROOT}"
chown cloudron:cloudron "${PGROOT}"
chmod 0700 "${PGROOT}"
find "${PGROOT}" -xdev ! -user cloudron -exec chown cloudron:cloudron {} +

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
aside=""
build="${PGROOT}/${PG_MAJOR}.restore-tmp"
server_up=0

undo() {
    local rc=$?
    [[ ${server_up} -eq 1 ]] && pg_stop_transient "${build}"
    rm -rf "${build}"
    if [[ -n "${aside}" && -d "${aside}" && ! -e "${PGDATA}" ]]; then
        mv "${aside}" "${PGDATA}"
        rlog "FAILED (exit ${rc}); the previous cluster was put back unchanged"
    else
        rlog "FAILED (exit ${rc})"
    fi
    exit 1
}
trap undo ERR

if [[ -s "${PGDATA}/PG_VERSION" ]]; then
    # Keep only the newest set-aside copy: remove older ones before making this one.
    rm -rf "${PGROOT}"/pre-restore-*
    aside="${PGROOT}/pre-restore-${stamp}"
    rm -f "${PGDATA}/postmaster.pid"
    mv "${PGDATA}" "${aside}"
    rlog "in-place restore: moved the live cluster aside to ${aside}"
elif [[ -e "${PGDATA}" ]]; then
    rm -rf "${PGDATA}"   # an empty or half-built directory, not a cluster
fi

rm -rf "${build}"
pg_initdb "${build}"
pg_start_transient "${build}" /tmp/postgres-restore.log
server_up=1

ensure_roles
create_app_database
restore_dump_into_app_db "${DUMP}"

want="$(count_rows_in_dump "${DUMP}")"
got="$(count_rows_bundled)"
if [[ "${want}" != "${got}" ]]; then
    rlog "row counts after the rebuild differ from the dump:"
    diff <(printf '%s\n' "${want}") <(printf '%s\n' "${got}") >> "${RESTORE_LOG}" || true
    false   # triggers undo
fi
tables="$(printf '%s\n' "${got}" | grep -c .)"
rows="$(printf '%s\n' "${got}" | awk -F'|' '{ s += $2 } END { print s + 0 }')"

pg_stop_transient "${build}"
server_up=0
mv "${build}" "${PGDATA}"
trap - ERR
rlog "rebuilt from ${DUMP}: ${tables} tables, ${rows} rows, matching the dump. PowerSync resyncs from scratch on start."
