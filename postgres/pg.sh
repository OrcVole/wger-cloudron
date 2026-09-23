#!/bin/bash
#
# postgres/pg.sh: shared definitions for the bundled PostgreSQL (docs/decisions/0006). SOURCED, never
# run, by start.sh (root), bootstrap.sh (cloudron), postgres/run.sh (cloudron), backup.sh and
# restore.sh (root, in Cloudron's temporary backup/restore container, which has NO CLOUDRON_*
# environment). Everything the server needs to start is defined here, so a restored cluster can
# never carry settings of its own and every caller starts the server the same way.

PG_MAJOR=18
PG_BIN="/usr/lib/postgresql/${PG_MAJOR}/bin"
PGROOT=/app/pgdata                       # the persistentDir (manifest), excluded from file backup
PGDATA="${PGROOT}/${PG_MAJOR}"
PG_SOCKDIR="${PGROOT}"                   # socket in the persistentDir: the backup container reaches the live server through it
PG_PORT=5432
PG_SUPERUSER=cloudron                    # created by initdb; no password; socket only
PG_DB=wger
PG_APP_ROLE=wger                         # Django; owns the database; NOT a superuser
PG_SYNC_ROLE=powersync                   # PowerSync: REPLICATION BYPASSRLS, owns schema powersync
PG_SYNC_SCHEMA=powersync

SECRETS_DIR=/app/data/.secrets
DB_DIR=/app/data/db                      # backed up: the dump and the logs that describe it
DUMP="${DB_DIR}/wger.dump"
RESTORE_LOG="${DB_DIR}/restore.log"
MARKER=/app/data/.bundled-db             # present = the bundled database is authoritative (ADR 0006)

# Server settings. Absolute memory caps only, never a ratio of "available" RAM (field guide 7.7).
# max_slot_wal_keep_size bounds the WAL a stalled PowerSync slot can pin to 2 GB of the app's disk.
PG_SETTINGS=(
    "listen_addresses=127.0.0.1"
    "port=${PG_PORT}"
    "unix_socket_directories=${PG_SOCKDIR}"
    "hba_file=/app/code/postgres/pg_hba.conf"
    "max_connections=60"
    "shared_buffers=128MB"
    "work_mem=8MB"
    "maintenance_work_mem=64MB"
    "effective_cache_size=512MB"
    "wal_level=logical"
    "max_wal_senders=4"
    "max_replication_slots=4"
    "max_slot_wal_keep_size=2GB"
    "logging_collector=off"
    "log_destination=stderr"
    "log_line_prefix=[postgres] %m [%p] "
)

pg_opts_string() {  # the settings as one string, for pg_ctl -o (postgres/run.sh expands the array itself)
    local s out=""
    for s in "${PG_SETTINGS[@]}"; do out+=" -c '${s}'"; done
    printf '%s' "${out}"
}

# Run a command as the cloudron user whether the caller is root (start.sh, backup, restore) or
# already cloudron (bootstrap.sh, run.sh).
as_pg() {
    if [[ ${EUID} -eq 0 ]]; then gosu cloudron:cloudron "$@"; else "$@"; fi
}

psql_su() {  # psql as the bootstrap superuser over the socket; extra args follow
    as_pg "${PG_BIN}/psql" -X -q -v ON_ERROR_STOP=1 -h "${PG_SOCKDIR}" -p "${PG_PORT}" -U "${PG_SUPERUSER}" "$@"
}

pg_ready() {
    # -d postgres: without it the probe asks for a database named after the user, and the server
    # logs a FATAL "database does not exist" on every poll.
    as_pg "${PG_BIN}/pg_isready" -q -h "${PG_SOCKDIR}" -p "${PG_PORT}" -d postgres
}

# initdb into a temporary directory, then rename into place: an interrupted initdb must never
# leave a PGDATA that has PG_VERSION but is half-built. Same mount, so the rename is atomic.
pg_initdb() {
    local target="$1" tmp="$1.initdb-tmp"
    rm -rf "${tmp}"
    as_pg mkdir -p "${tmp}"
    chmod 0700 "${tmp}"
    as_pg "${PG_BIN}/initdb" --pgdata="${tmp}" --username="${PG_SUPERUSER}" \
        --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 --locale=en_US.UTF-8 >/dev/null
    mv "${tmp}" "${target}"
}

# A transient server for the backup and restore containers, where supervisord is not running.
pg_start_transient() {
    local datadir="$1" logfile="$2"
    as_pg "${PG_BIN}/pg_ctl" -D "${datadir}" -w -t 120 -l "${logfile}" -o "$(pg_opts_string)" start >/dev/null
}

pg_stop_transient() {
    local datadir="$1"
    as_pg "${PG_BIN}/pg_ctl" -D "${datadir}" -w -t 120 -m fast stop >/dev/null 2>&1 || true
}

secret_value() {  # prints a secret file's value; fails if absent
    local f="${SECRETS_DIR}/$1"
    [[ -s "${f}" ]] || { echo "missing secret ${f}" >&2; return 1; }
    cat "${f}"
}

# Roles are rebuilt from /app/data/.secrets on every boot and every restore, never restored from a
# dump, so their passwords always match the secrets the rest of the package reads (ADR 0006).
ensure_roles() {
    local app_pw sync_pw
    app_pw="$(secret_value db-wger)"
    sync_pw="$(secret_value db-powersync)"
    psql_su -d postgres \
        -v app_role="${PG_APP_ROLE}" -v app_pw="${app_pw}" \
        -v sync_role="${PG_SYNC_ROLE}" -v sync_pw="${sync_pw}" <<'SQL'
SELECT format('CREATE ROLE %I', :'app_role') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_role') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEROLE NOREPLICATION PASSWORD %L', :'app_role', :'app_pw') \gexec
SELECT format('CREATE ROLE %I', :'sync_role') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'sync_role') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEROLE REPLICATION BYPASSRLS PASSWORD %L', :'sync_role', :'sync_pw') \gexec
SQL
}

database_exists() {  # database_exists <name>
    [[ "$(psql_su -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$1'")" == "1" ]]
}

create_app_database() {
    psql_su -d postgres -c "CREATE DATABASE ${PG_DB} OWNER ${PG_APP_ROLE} ENCODING 'UTF8' TEMPLATE template0"
}

# Inactive logical slots on a database block DROP DATABASE and pin WAL. Only ever called while
# PowerSync is not running (bootstrap before it starts, restore in its own container).
drop_slots_for() {
    psql_su -d postgres -Atc "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE database = '$1' AND NOT active" >/dev/null
}

# Exact row count of every table in public, one "table|count" line each.
count_rows_sql="SELECT table_name, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1"

count_rows_bundled() {  # sorted bytewise: the two servers may collate table names differently
    psql_su -d "${PG_DB}" -At -F '|' -c "${count_rows_sql}" | LC_ALL=C sort
}

# The same "table|count" list, read out of a custom-format dump rather than a database. COPY text
# format escapes newlines inside values, so one line between "COPY" and "\." is one row. pg_dump
# writes a COPY block for every table, empty ones included, so the two lists are comparable.
count_rows_in_dump() {
    as_pg "${PG_BIN}/pg_restore" --data-only --schema=public -f - "$1" | awk '
        /^COPY /   { t = $2; sub(/^public\./, "", t); gsub(/"/, "", t); n = 0; inb = 1; next }
        inb && $0 == "\\." { print t "|" n; inb = 0; next }
        inb        { n++ }
    ' | LC_ALL=C sort
}

# Load a custom-format dump into an EMPTY database owned by the app role. Extensions are created by
# the superuser first and their TOC entries (and comments on them) skipped, because the app role
# cannot own an extension's comment. Everything else is restored AS the app role, so it owns every
# object, including the powersync publication. --exit-on-error: a partial load is a failure.
restore_dump_into_app_db() {
    local dumpfile="$1" list ext
    list="$(mktemp /tmp/wger-toc.XXXXXX)"
    as_pg "${PG_BIN}/pg_restore" -l "${dumpfile}" > "${list}"
    while read -r ext; do
        [[ -n "${ext}" ]] || continue
        psql_su -d "${PG_DB}" -c "CREATE EXTENSION IF NOT EXISTS \"${ext}\" WITH SCHEMA public"
    done < <(awk '$4 == "EXTENSION" { print $6 }' "${list}")
    sed -i -E 's/^([0-9]+; [0-9]+ [0-9]+ (EXTENSION|COMMENT - EXTENSION) )/;\1/' "${list}"
    chmod 0644 "${list}"
    as_pg "${PG_BIN}/pg_restore" --exit-on-error --no-owner --no-privileges --role="${PG_APP_ROLE}" \
        -L "${list}" -h "${PG_SOCKDIR}" -p "${PG_PORT}" -U "${PG_SUPERUSER}" -d "${PG_DB}" "${dumpfile}"
    rm -f "${list}"
}

write_marker() {  # write_marker <born: fresh|addon|restore> <tables> <rows>
    python3 - "$@" <<'PY'
import json, os, sys, datetime
born, tables, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
path = "/app/data/.bundled-db"
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump({"born": born,
               "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
               "postgres_major": 18, "tables": tables, "rows": rows}, f)
    f.write("\n")
os.replace(tmp, path)
PY
}
