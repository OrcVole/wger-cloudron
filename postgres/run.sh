#!/bin/bash
#
# postgres/run.sh: the supervisor program for the bundled PostgreSQL (docs/decisions/0006). Runs as
# cloudron. start.sh has already created or checked PGDATA before supervisord started.
set -euo pipefail
# shellcheck source=postgres/pg.sh
source /app/code/postgres/pg.sh

# A container killed without a clean shutdown leaves postmaster.pid behind, and in a fresh
# container its PID can belong to an unrelated process, so postgres may refuse to start. Remove it
# only when nothing answers on the socket: a backup container's transient server on the same data
# directory would answer, and must not be disturbed.
if [[ -e "${PGDATA}/postmaster.pid" ]] && ! pg_ready; then
    echo "==> [postgres] removing stale postmaster.pid (nothing answering on the socket)"
    rm -f "${PGDATA}/postmaster.pid"
fi

args=()
for s in "${PG_SETTINGS[@]}"; do args+=(-c "${s}"); done
exec "${PG_BIN}/postgres" -D "${PGDATA}" "${args[@]}"
