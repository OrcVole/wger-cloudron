#!/bin/bash
#
# test/upgrade.sh: the local proof for the bundled database and PowerSync (docs/decisions/0006).
# Builds NOTHING. Runs the previous package image against an addon-like PostgreSQL 16 sidecar, seeds
# real records, then updates to the new image on the same /app/data, the way Cloudron does, and
# checks, in order:
#
#   1. the one-time move off the addon: marker written, row counts equal, addon untouched
#   2. the app serves, and the seeded user's data is in the bundled database
#   3. PowerSync end to end: /ps/ probes, a token from wger, and the user's own measurements
#      arriving through a real sync stream (proves JWKS, replication, publication and sync rules)
#   4. a restart takes the normal path (no second move)
#   5. backupCommand, run as Cloudron runs it (temporary container, read-only, no CLOUDRON_* env)
#   6. IN-PLACE restore after newer writes: the database really goes back to the backup
#   7. a restore from a corrupted dump FAILS and puts the live cluster back (the failure path, fired
#      on purpose, per the estate's rule that a check is not trusted until it has been seen to fail)
#   8. CLONE: an empty persistentDir rebuilt from the backup
#
# Containers run with a read-only root and /app/pgdata as its own volume, as on Cloudron. Like
# smoke.sh it does not use `set -e`: every assertion reports PASS or FAIL and the exit code counts
# the failures.
#
#   OLD_IMAGE=localhost/golem/wger-cloudron:1.1.0 NEW_IMAGE=localhost/golem/wger-cloudron:2.0.0-dev test/upgrade.sh
set -uo pipefail

OLD_IMAGE="${OLD_IMAGE:-localhost/golem/wger-cloudron:1.1.0}"
NEW_IMAGE="${NEW_IMAGE:-localhost/golem/wger-cloudron:2.0.0-dev}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
CRI="$(command -v podman || true)"
[[ -n "${CRI}" ]] || { echo "FAIL: podman not found"; exit 2; }

RUN_ID="wger-up-$$-${RANDOM}"
NET="${RUN_ID}-net"
PG_NAME="${RUN_ID}-addon"
REDIS_NAME="${RUN_ID}-redis"
APP="${RUN_ID}-app"
CLONE="${RUN_ID}-clone"
VOL="${RUN_ID}-pgdata"
CLONE_VOL="${RUN_ID}-pgdata-clone"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${RUN_ID}.XXXXXX")"
DATA="${WORK}/data"
SNAP="${WORK}/data-at-backup"
CLONE_DATA="${WORK}/data-clone"
mkdir -p "${DATA}"

FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "${what}"; else fail "${what}"; fi; }

cleanup() {
    echo "--- cleanup ---"
    "${CRI}" rm -f -t 5 "${APP}" "${CLONE}" "${PG_NAME}" "${REDIS_NAME}" >/dev/null 2>&1
    "${CRI}" volume rm -f "${VOL}" "${CLONE_VOL}" >/dev/null 2>&1
    "${CRI}" network rm "${NET}" >/dev/null 2>&1
    rm -rf "${WORK}" 2>/dev/null || "${CRI}" unshare rm -rf "${WORK}" 2>/dev/null
}
trap cleanup EXIT INT TERM

ADDON_PW="$(openssl rand -hex 16)"
REDIS_PW="$(openssl rand -hex 16)"
ENV=(
    -e CLOUDRON_POSTGRESQL_HOST="${PG_NAME}" -e CLOUDRON_POSTGRESQL_PORT=5432
    -e CLOUDRON_POSTGRESQL_USERNAME=addonuser -e CLOUDRON_POSTGRESQL_PASSWORD="${ADDON_PW}"
    -e CLOUDRON_POSTGRESQL_DATABASE=addondb
    -e CLOUDRON_REDIS_HOST="${REDIS_NAME}" -e CLOUDRON_REDIS_PORT=6379 -e CLOUDRON_REDIS_PASSWORD="${REDIS_PW}"
    -e CLOUDRON_APP_ORIGIN=http://localhost:8000
    -e CLOUDRON_MAIL_SMTP_SERVER=smtp.invalid -e CLOUDRON_MAIL_SMTP_PORT=2525
    -e CLOUDRON_MAIL_SMTP_USERNAME=dummy -e CLOUDRON_MAIL_SMTP_PASSWORD=dummy -e CLOUDRON_MAIL_FROM=wger@example.com
)

run_app() {  # run_app <name> <image> <datadir> [pgdata volume]
    local name="$1" image="$2" data="$3" vol="${4:-}"
    local mounts=(-v "${data}:/app/data:Z")
    [[ -n "${vol}" ]] && mounts+=(-v "${vol}:/app/pgdata")
    "${CRI}" run -d --name "${name}" --network "${NET}" --read-only -p 127.0.0.1::8000 \
        "${mounts[@]}" "${ENV[@]}" "${image}" >/dev/null
}

# The temporary container Cloudron uses for backupCommand/restoreCommand: same image, read-only,
# /app/data and the persistentDir mounted, and NO CLOUDRON_* environment.
run_hook() {  # run_hook <script> <datadir> <volume>
    "${CRI}" run --rm --network "${NET}" --read-only -v "$2:/app/data:Z" -v "$3:/app/pgdata" "${NEW_IMAGE}" "$1"
}

boots() { "${CRI}" logs "$1" 2>&1 | grep -c 'bootstrap sequence complete'; }

# wait_booted <container> [boots already seen]: until bootstrap reports one more completion than
# before. podman keeps a container's earlier logs across stop/start, so an old line must not count.
wait_booted() {
    local c="$1" seen="${2:-0}" t=0
    while (( t < BOOT_TIMEOUT )); do
        if (( $(boots "${c}") > seen )); then return 0; fi
        if [[ "$("${CRI}" inspect -f '{{.State.Running}}' "${c}" 2>/dev/null)" != "true" ]]; then
            echo "--- ${c} exited during boot; last log lines ---"; "${CRI}" logs "${c}" 2>&1 | tail -30
            return 1
        fi
        sleep 5; t=$((t + 5))
    done
    echo "--- ${c} did not finish booting in ${BOOT_TIMEOUT}s ---"; "${CRI}" logs "${c}" 2>&1 | tail -30
    return 1
}

base_url() { echo "http://127.0.0.1:$("${CRI}" port "$1" 8000/tcp | head -1 | sed -E 's/.*:([0-9]+)$/\1/')"; }

# Django shell inside a running container, with the environment start.sh would build. $2 = old|new.
django() {  # django <container> <old|new> <python>
    local db
    if [[ "$2" == old ]]; then
        db='DJANGO_DB_DATABASE="$CLOUDRON_POSTGRESQL_DATABASE" DJANGO_DB_USER="$CLOUDRON_POSTGRESQL_USERNAME" DJANGO_DB_PASSWORD="$CLOUDRON_POSTGRESQL_PASSWORD" DJANGO_DB_HOST="$CLOUDRON_POSTGRESQL_HOST" DJANGO_DB_PORT="$CLOUDRON_POSTGRESQL_PORT"'
    else
        db='DJANGO_DB_DATABASE=wger DJANGO_DB_USER=wger DJANGO_DB_PASSWORD="$(cat /app/data/.secrets/db-wger)" DJANGO_DB_HOST=/app/pgdata DJANGO_DB_PORT=5432'
    fi
    "${CRI}" exec -u cloudron -e HOME=/app/data "$1" bash -c "export PYTHONUSERBASE=/home/wger/.local PYTHONPATH=/app/code/pysettings:/home/wger/src DJANGO_SETTINGS_MODULE=cloudron_settings TIME_ZONE=Etc/UTC DJANGO_DB_ENGINE=django.db.backends.postgresql ${db}; export SECRET_KEY=\"\$(cat /app/data/.secrets/secret-key)\" JWT_PRIVATE_KEY=\"\$(cat /app/data/.secrets/jwt-private)\" JWT_PUBLIC_KEY=\"\$(cat /app/data/.secrets/jwt-public)\"; cd /home/wger/src && python3 manage.py shell -c '$3'" 2>/dev/null
}

seed() {  # seed <container> <old|new> <n> <day offset>: n measurements for user "gate"
    django "$1" "$2" "
import datetime
from django.utils import timezone
from django.contrib.auth.models import User
from rest_framework.authtoken.models import Token
from wger.measurements.models import Category, Measurement
u, _ = User.objects.get_or_create(username=\"gate\", defaults={\"email\": \"gate@example.com\"})
u.set_password(\"gate-pass-123\"); u.save()
c, _ = Category.objects.get_or_create(user=u, name=\"Gate weight\", defaults={\"unit\": \"kg\"})
for i in range($3):
    Measurement.objects.create(category=c, date=timezone.now() - datetime.timedelta(days=$4 + i), value=80 + i)
t, _ = Token.objects.get_or_create(user=u)
print(\"GATE_TOKEN=\" + t.key)
print(\"GATE_COUNT=%d\" % Measurement.objects.filter(category__user=u).count())
" | sed -n 's/^GATE_//p'
}

gate_count() {  # gate_count <container> <old|new>
    django "$1" "$2" "
from wger.measurements.models import Measurement
print(\"GATE_COUNT=%d\" % Measurement.objects.filter(category__user__username=\"gate\").count())
" | sed -n 's/^GATE_COUNT=//p'
}

psql_in() {  # psql_in <container> <sql>: as the bundled superuser, database wger
    "${CRI}" exec -u cloudron "$1" /usr/lib/postgresql/18/bin/psql -X -h /app/pgdata -U cloudron -d wger -Atc "$2" 2>/dev/null
}

addon_counts() {
    "${CRI}" exec -e PGPASSWORD="${ADDON_PW}" "${PG_NAME}" psql -X -U addonuser -d addondb -At -F '|' -c \
        "SELECT table_name, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" | LC_ALL=C sort
}

copy_data() { "${CRI}" unshare bash -c "rm -rf '$2' && cp -a '$1' '$2'"; }

echo "=== wger upgrade proof: ${OLD_IMAGE} -> ${NEW_IMAGE} ==="
"${CRI}" network create "${NET}" >/dev/null
# The addon stand-in: PostgreSQL 16, default wal_level (replica), a non-superuser owner, like Cloudron's.
"${CRI}" run -d --name "${PG_NAME}" --network "${NET}" -e POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
    docker.io/postgres:16-alpine >/dev/null
"${CRI}" run -d --name "${REDIS_NAME}" --network "${NET}" docker.io/redis:7-alpine redis-server --requirepass "${REDIS_PW}" >/dev/null
for _ in $(seq 1 30); do "${CRI}" exec "${PG_NAME}" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
"${CRI}" exec "${PG_NAME}" psql -U postgres -qc "CREATE ROLE addonuser LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${ADDON_PW}'" \
    -c "CREATE DATABASE addondb OWNER addonuser" >/dev/null
"${CRI}" volume create "${VOL}" >/dev/null
"${CRI}" volume create "${CLONE_VOL}" >/dev/null

echo "--- 0. the previous version, on the addon ---"
run_app "${APP}" "${OLD_IMAGE}" "${DATA}"
check "previous version boots on the addon" wait_booted "${APP}"
out="$(seed "${APP}" old 5 0)"
seeded="$(printf '%s\n' "${out}" | sed -n 's/^COUNT=//p')"
check "seeded 5 measurements for user gate (got ${seeded:-none})" test "${seeded:-0}" = 5
before="$(addon_counts)"
"${CRI}" stop -t 30 "${APP}" >/dev/null; "${CRI}" rm "${APP}" >/dev/null

echo "--- 1. update to the new version on the same /app/data ---"
run_app "${APP}" "${NEW_IMAGE}" "${DATA}" "${VOL}"
check "new version boots" wait_booted "${APP}"
logs="$("${CRI}" logs "${APP}" 2>&1)"
check "the log reports a verified move off the addon" grep -q 'database moved and verified' <<< "${logs}"
check "marker written with born=addon" grep -q '"born": "addon"' "${DATA}/.bundled-db"
check "addon is untouched by the move" test "$(addon_counts)" = "${before}"
check "the seeded measurements are in the bundled database" test "$(gate_count "${APP}" new)" = 5
check "Django is connected to the bundled server, not the addon" \
    test "$(psql_in "${APP}" "SELECT count(*) FROM pg_stat_activity WHERE usename = 'wger'")" -ge 1

echo "--- 2. the app serves ---"
BASE="$(base_url "${APP}")"
check "the site answers 200 (following redirects)" test "$(curl -s -L -o /dev/null -w '%{http_code}' -m 20 "${BASE}/")" = 200

echo "--- 3. PowerSync end to end ---"
check "powersync is RUNNING under supervisor" \
    bash -c "'${CRI}' exec '${APP}' supervisorctl -c /app/code/supervisor/supervisord.conf status powersync | grep -q RUNNING"
ok=0; for _ in $(seq 1 30); do [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "${BASE}/ps/probes/liveness")" == 200 ]] && { ok=1; break; }; sleep 2; done
check "/ps/probes/liveness answers 200 through nginx" test "${ok}" = 1
check "a logical replication slot exists" test -n "$(psql_in "${APP}" "SELECT slot_name FROM pg_replication_slots WHERE slot_type = 'logical'")"
token="$(printf '%s\n' "${out}" | sed -n 's/^TOKEN=//p')"
ps_json="$(curl -s -L -m 10 -H "Authorization: Token ${token}" "${BASE}/api/v2/powersync-token")"
jwt="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' <<< "${ps_json}" 2>/dev/null)"
ps_url="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["powersync_url"])' <<< "${ps_json}" 2>/dev/null)"
check "wger issues a PowerSync token" test -n "${jwt}"
check "the advertised PowerSync URL is <site>/ps/ (got ${ps_url:-none})" test "${ps_url}" = "http://localhost:8000/ps/"
stream="$(curl -s -N -m 20 -X POST -H "Authorization: Token ${jwt}" -H 'Content-Type: application/json' \
    -d '{"raw_data": true, "include_checksum": true}' "${BASE}/ps/sync/stream" 2>/dev/null)"
check "the sync stream opens with a checkpoint" grep -q checkpoint <<< "${stream}"
check "the user's measurements arrive through the sync stream" grep -q 'measurements_measurement' <<< "${stream}"
unauth="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H 'Content-Type: application/json' -d '{}' "${BASE}/ps/sync/stream")"
check "the sync stream refuses a request with no token (got ${unauth})" test "${unauth}" = 401

echo "--- 4. restart takes the normal path ---"
n="$(boots "${APP}")"
"${CRI}" restart -t 30 "${APP}" >/dev/null
check "boots again after a restart" wait_booted "${APP}" "${n}"
check "the move ran exactly once across both boots" test "$("${CRI}" logs "${APP}" 2>&1 | grep -c 'MOVING THE DATABASE')" = 1

echo "--- 5. backupCommand, as Cloudron runs it, with the app live ---"
run_hook /app/code/backup.sh "${DATA}" "${VOL}"; rc=$?
check "backup.sh exits 0" test "${rc}" = 0
check "a dump was written" test -s "${DATA}/db/wger.dump"
copy_data "${DATA}" "${SNAP}"

echo "--- 6. in-place restore after newer writes ---"
seed "${APP}" new 3 100 >/dev/null
check "3 newer measurements written after the backup (now 8)" test "$(gate_count "${APP}" new)" = 8
"${CRI}" stop -t 30 "${APP}" >/dev/null
copy_data "${SNAP}" "${DATA}"      # Cloudron restores /app/data; the persistentDir is KEPT
run_hook /app/code/restore.sh "${DATA}" "${VOL}"; rc=$?
check "restore.sh exits 0" test "${rc}" = 0
check "restore.log records a rebuild" grep -q 'rebuilt from' "${DATA}/db/restore.log"
n="$(boots "${APP}")"
"${CRI}" start "${APP}" >/dev/null
check "boots after the in-place restore" wait_booted "${APP}" "${n}"
check "the database went back to the backup: 5 measurements, not 8" test "$(gate_count "${APP}" new)" = 5
check "the replaced cluster was kept aside" \
    bash -c "'${CRI}' exec '${APP}' sh -c 'ls -d /app/pgdata/pre-restore-*' >/dev/null 2>&1"

echo "--- 7. a restore from a corrupted dump fails and changes nothing ---"
seed "${APP}" new 2 200 >/dev/null     # live state now differs from the dump: 7
"${CRI}" stop -t 30 "${APP}" >/dev/null
"${CRI}" unshare bash -c "truncate -s \$(( \$(stat -c %s '${DATA}/db/wger.dump') / 2 )) '${DATA}/db/wger.dump'"
run_hook /app/code/restore.sh "${DATA}" "${VOL}"; rc=$?
check "restore.sh FAILS on a corrupted dump (exit ${rc})" test "${rc}" != 0
check "restore.log records the cluster being put back" grep -q 'put back unchanged' "${DATA}/db/restore.log"
"${CRI}" unshare cp "${SNAP}/db/wger.dump" "${DATA}/db/wger.dump"   # put the good dump back
n="$(boots "${APP}")"
"${CRI}" start "${APP}" >/dev/null
check "boots on the put-back cluster" wait_booted "${APP}" "${n}"
check "the put-back cluster is the live one: 7 measurements" test "$(gate_count "${APP}" new)" = 7

echo "--- 8. clone: an empty persistentDir rebuilt from the backup ---"
copy_data "${SNAP}" "${CLONE_DATA}"
run_hook /app/code/restore.sh "${CLONE_DATA}" "${CLONE_VOL}"; rc=$?
check "restore.sh on an empty persistentDir exits 0" test "${rc}" = 0
run_app "${CLONE}" "${NEW_IMAGE}" "${CLONE_DATA}" "${CLONE_VOL}"
check "the clone boots" wait_booted "${CLONE}"
check "the clone has the backup's 5 measurements" test "$(gate_count "${CLONE}" new)" = 5

echo
if (( FAILS == 0 )); then echo "=== ALL PASSED ==="; else echo "=== ${FAILS} FAILED ==="; fi
exit $(( FAILS > 0 ))
