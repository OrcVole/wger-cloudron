#!/bin/bash
#
# test/smoke.sh: the runtime smoke test for io.github.orcvole.wger. Builds NOTHING -- it assumes
# the image tag below already exists locally (built separately, e.g. `podman build -t
# ghcr.io/orcvole/wger-cloudron:smoke .`). Starts postgres/redis sidecars on a private network,
# runs the package image against them with CLOUDRON_* env faked, and asserts the behaviour
# described in AGENTS.md and phase-notes/phase-3.md. Every assertion is echoed PASS/FAIL; the
# script exits non-zero if any assertion failed. Cleans up all containers/network/temp data on
# exit, including on failure, via a trap.
#
# Deliberately does NOT use `set -e`: a smoke test that stops at the first failing assertion
# hides every assertion after it, which is the opposite of what an audit needs. Every check
# either records PASS or FAIL and the script continues; the final exit code reflects whether
# anything failed.
set -uo pipefail

IMAGE="${SMOKE_IMAGE:-ghcr.io/orcvole/wger-cloudron:smoke}"
CRI="$(command -v podman || command -v docker || true)"
if [[ -z "${CRI}" ]]; then
    echo "FAIL: neither podman nor docker found on PATH"
    exit 2
fi

RUN_ID="wger-smoke-$$-${RANDOM}"
NET="${RUN_ID}-net"
PG_NAME="${RUN_ID}-pg"
REDIS_NAME="${RUN_ID}-redis"
APP_NAME="${RUN_ID}-app"
DATA_DIR=""

FAIL_COUNT=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

CLEANED_UP=0
cleanup() {
    local ec=$?
    [[ "${CLEANED_UP}" == "1" ]] && return
    CLEANED_UP=1
    echo "--- cleanup ---"
    "${CRI}" rm -f "${APP_NAME}" "${PG_NAME}" "${REDIS_NAME}" >/dev/null 2>&1 || true
    "${CRI}" network rm "${NET}" >/dev/null 2>&1 || true
    # Files the container wrote into the bind mount are owned by a subuid on the host, so a
    # plain rm can fail with "Operation not permitted" under rootless podman; podman unshare
    # re-enters the user namespace where those uids are ours to delete.
    if [[ -n "${DATA_DIR}" ]]; then
        rm -rf "${DATA_DIR}" 2>/dev/null || "${CRI}" unshare rm -rf "${DATA_DIR}" 2>/dev/null || true
    fi
    exit "${ec}"
}
trap cleanup EXIT INT TERM

http_status() {
    curl -s -o /dev/null -m 5 -w '%{http_code}' "$@" 2>/dev/null || echo "000"
}

echo "=== wger Cloudron package smoke test ==="
echo "image under test: ${IMAGE}"

if ! "${CRI}" image exists "${IMAGE}" 2>/dev/null && ! "${CRI}" image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "FAIL: image ${IMAGE} is not present locally; this script does not build it (set SMOKE_IMAGE to override the tag)"
    exit 2
fi

DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${RUN_ID}.XXXXXX")"

PG_USER="wger"
PG_DB="wger"
PG_PASSWORD="$(openssl rand -hex 16)"
REDIS_PASSWORD="$(openssl rand -hex 16)"

echo "--- network + sidecars ---"
"${CRI}" network create "${NET}" >/dev/null

"${CRI}" run -d --name "${PG_NAME}" --network "${NET}" \
    -e POSTGRES_USER="${PG_USER}" -e POSTGRES_PASSWORD="${PG_PASSWORD}" -e POSTGRES_DB="${PG_DB}" \
    docker.io/postgres:16-alpine >/dev/null

"${CRI}" run -d --name "${REDIS_NAME}" --network "${NET}" \
    docker.io/redis:7-alpine redis-server --requirepass "${REDIS_PASSWORD}" >/dev/null

echo "--- waiting for sidecars ---"
pg_ready=0
for _ in $(seq 1 30); do
    if "${CRI}" exec "${PG_NAME}" pg_isready -U "${PG_USER}" >/dev/null 2>&1; then
        pg_ready=1; break
    fi
    sleep 1
done
[[ "${pg_ready}" == "1" ]] && pass "postgres sidecar ready" || fail "postgres sidecar never became ready"

redis_ready=0
for _ in $(seq 1 30); do
    if "${CRI}" exec "${REDIS_NAME}" redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
        redis_ready=1; break
    fi
    sleep 1
done
[[ "${redis_ready}" == "1" ]] && pass "redis sidecar ready" || fail "redis sidecar never became ready"

echo "--- starting app container ---"
"${CRI}" run -d --name "${APP_NAME}" --network "${NET}" \
    -p "127.0.0.1::8000" \
    -v "${DATA_DIR}:/app/data:Z" \
    -e CLOUDRON_POSTGRESQL_HOST="${PG_NAME}" \
    -e CLOUDRON_POSTGRESQL_PORT="5432" \
    -e CLOUDRON_POSTGRESQL_USERNAME="${PG_USER}" \
    -e CLOUDRON_POSTGRESQL_PASSWORD="${PG_PASSWORD}" \
    -e CLOUDRON_POSTGRESQL_DATABASE="${PG_DB}" \
    -e CLOUDRON_REDIS_HOST="${REDIS_NAME}" \
    -e CLOUDRON_REDIS_PORT="6379" \
    -e CLOUDRON_REDIS_PASSWORD="${REDIS_PASSWORD}" \
    -e CLOUDRON_APP_ORIGIN="http://localhost:8000" \
    -e CLOUDRON_MAIL_SMTP_SERVER="smtp.invalid" \
    -e CLOUDRON_MAIL_SMTP_PORT="2525" \
    -e CLOUDRON_MAIL_SMTP_USERNAME="dummy" \
    -e CLOUDRON_MAIL_SMTP_PASSWORD="dummy" \
    -e CLOUDRON_MAIL_FROM="wger@example.com" \
    "${IMAGE}" >/dev/null
CONTAINER_START_EPOCH="$(date +%s)"

HOST_PORT="$("${CRI}" port "${APP_NAME}" 8000/tcp 2>/dev/null | head -1 | sed -E 's/.*:([0-9]+)$/\1/')"
if [[ -z "${HOST_PORT}" ]]; then
    fail "could not determine the published host port for ${APP_NAME}/8000"
    echo "--- app container state and logs (most likely the container failed to start) ---"
    "${CRI}" ps -a --filter "name=${APP_NAME}" --format '{{.Status}}' || true
    "${CRI}" logs "${APP_NAME}" 2>&1 | tail -40 || true
    exit 1
fi
BASE_URL="http://127.0.0.1:${HOST_PORT}"
echo "app published at ${BASE_URL} (container port 8000)"

# --- assertion 1: /healthcheck answers 200 within 5 seconds of container start ------------
#
# This is the whole point of the immediate-health shim (AGENTS.md, phase-notes/phase-3.md):
# nginx answers it directly, without proxying to Django, specifically so it does not have to
# wait for gunicorn or the first-run bootstrap (migrations, fixtures) to finish. In this
# package's design, nginx and the one-shot bootstrap program both start as soon as supervisord
# does; gunicorn/celery only start once bootstrap.sh finishes and explicitly starts them.
healthcheck_ok_within_5s=0
deadline=$((CONTAINER_START_EPOCH + 5))
while [[ "$(date +%s)" -le "${deadline}" ]]; do
    if [[ "$(http_status "${BASE_URL}/healthcheck")" == "200" ]]; then
        healthcheck_ok_within_5s=1
        break
    fi
    sleep 0.2
done
elapsed=$(( $(date +%s) - CONTAINER_START_EPOCH ))
if [[ "${healthcheck_ok_within_5s}" == "1" ]]; then
    pass "/healthcheck returned 200 within 5s of container start (after ${elapsed}s)"
else
    fail "/healthcheck did NOT return 200 within 5s of container start"
fi

# --- assertion 2: anonymous landing page eventually returns 200 with wger content ---------
#
# This can take a while on first boot: bootstrap.sh waits for postgres/redis, runs migrations
# across every wger app, loads fixtures, then starts gunicorn. Generous bound: 180s.
# wger answers / anonymously with a REDIRECT chain, not a bare 200 (observed live 2026-08-01:
# 302 / -> /en/ -> 200 on the public features page; recon recorded the same "2xx/3xx
# anonymously"), so follow redirects (-L) and assert on the FINAL response.
login_body="$(mktemp "${DATA_DIR}.login.XXXXXX" 2>/dev/null || mktemp)"
login_ok=0
for _ in $(seq 1 90); do
    status="$(curl -sL -o "${login_body}" -m 10 -w '%{http_code}' "${BASE_URL}/" 2>/dev/null || echo 000)"
    if [[ "${status}" == "200" ]] && grep -qi 'wger' "${login_body}" 2>/dev/null; then
        login_ok=1
        break
    fi
    sleep 2
done
if [[ "${login_ok}" == "1" ]]; then
    pass "anonymous landing page (/ with redirects followed) eventually returned 200 with wger content"
else
    fail "anonymous landing page (/ with redirects followed) never returned 200 with wger content within 180s"
fi

# --- assertion 3: a static asset the app actually references returns 200 ------------------
#
# collectstatic hashes filenames at build time, so nothing here is hardcoded: this pulls a real
# /static/... URL out of the page we already fetched and requests exactly that.
static_url="$(grep -oE '(href|src)="(/static/[^"]+)"' "${login_body}" 2>/dev/null | head -1 | sed -E 's/.*"(\/static\/[^"]+)"/\1/')"
if [[ -n "${static_url}" ]]; then
    static_status="$(http_status "${BASE_URL}${static_url}")"
    if [[ "${static_status}" == "200" ]]; then
        pass "static asset ${static_url} returned 200"
    else
        fail "static asset ${static_url} returned ${static_status}, expected 200"
    fi
else
    fail "could not find any /static/ reference in the login page to test"
fi
rm -f "${login_body}"

# --- assertion 4: /api/v2/ returns JSON (200 or 401 both prove gunicorn is serving DRF) ----
api_status="$(http_status "${BASE_URL}/api/v2/")"
if [[ "${api_status}" == "200" || "${api_status}" == "401" ]]; then
    api_content_type="$(curl -s -o /dev/null -m 5 -D - "${BASE_URL}/api/v2/" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}')"
    if [[ "${api_content_type}" == *json* ]]; then
        pass "/api/v2/ returned ${api_status} with JSON content-type"
    else
        fail "/api/v2/ returned ${api_status} but content-type was '${api_content_type}', not JSON"
    fi
else
    fail "/api/v2/ returned ${api_status}, expected 200 or 401"
fi

# --- assertion 5: container's application processes run as uid 1000 (cloudron) ------------
#
# Walks /proc directly instead of depending on `ps` or on exact process-title strings (gunicorn
# and celery both rename their own argv/title at runtime, which makes name-matching brittle).
# The invariant that actually matters, per AGENTS.md ("All supervisor programs run with
# user=cloudron") and the hard rule that supervisord itself is the only root process, is: no
# process other than pid 1 (tini) and supervisord itself may run as uid 0.
uid_report="$("${CRI}" exec "${APP_NAME}" sh -c '
bad=0
nonroot=0
self=$$
for d in /proc/[0-9]*; do
    [ -r "$d/status" ] || continue
    pid="${d#/proc/}"
    [ "$pid" = "1" ] && continue
    # Exclude this checker itself and its own transient children: podman exec enters the
    # container as the image default user (root, since start.sh must run as root), so without
    # this the assertion detects its own shell as a rogue root process (observed live
    # 2026-08-01: "ROOT:sh:<pid>" was this sh).
    [ "$pid" = "$self" ] && continue
    ppid="$(awk "/^PPid:/{print \$2; exit}" "$d/status" 2>/dev/null)"
    [ "$ppid" = "$self" ] && continue
    comm="$(cat "$d/comm" 2>/dev/null)"
    [ "$comm" = "supervisord" ] && continue
    uid="$(awk "/^Uid:/{print \$2; exit}" "$d/status" 2>/dev/null)"
    if [ "$uid" = "0" ]; then
        echo "ROOT:$comm:$pid"
        bad=1
    else
        nonroot=$((nonroot + 1))
    fi
done
echo "NONROOT_COUNT:$nonroot"
echo "BAD:$bad"
' 2>/dev/null)"
uid_bad="$(printf '%s\n' "${uid_report}" | sed -n 's/^BAD://p' | tail -1)"
nonroot_count="$(printf '%s\n' "${uid_report}" | sed -n 's/^NONROOT_COUNT://p' | tail -1)"
if [[ "${uid_bad}" == "0" && "${nonroot_count:-0}" -ge 3 ]]; then
    pass "all non-supervisord processes run as a non-root uid (${nonroot_count} such processes; nginx/gunicorn/celery-worker/celery-beat expected among them)"
else
    fail "found a process other than tini/supervisord running as root, or too few non-root processes (report: $(printf '%s' "${uid_report}" | tr '\n' ' '))"
fi

# --- assertion 6: admin password secret exists, mode 0600 ---------------------------------
admin_pw_mode="$("${CRI}" exec "${APP_NAME}" stat -c '%a' /app/data/.secrets/admin-password 2>/dev/null || echo "")"
if [[ "${admin_pw_mode}" == "600" ]]; then
    pass "/app/data/.secrets/admin-password exists, mode 0600"
else
    fail "/app/data/.secrets/admin-password missing or wrong mode (got '${admin_pw_mode}', expected 600)"
fi

# --- assertion 7: SECRET_KEY and admin password values never appear in the logs -----------
secret_key_val="$("${CRI}" exec "${APP_NAME}" cat /app/data/.secrets/secret-key 2>/dev/null || echo "")"
admin_pw_val="$("${CRI}" exec "${APP_NAME}" cat /app/data/.secrets/admin-password 2>/dev/null || echo "")"
jwt_priv_val="$("${CRI}" exec "${APP_NAME}" cat /app/data/.secrets/jwt-private 2>/dev/null || echo "")"
logs="$("${CRI}" logs "${APP_NAME}" 2>&1 || true)"
secret_leak=0
if [[ -n "${secret_key_val}" ]] && printf '%s' "${logs}" | grep -qF "${secret_key_val}"; then
    fail "SECRET_KEY value appears in container logs"
    secret_leak=1
fi
if [[ -n "${admin_pw_val}" ]] && printf '%s' "${logs}" | grep -qF "${admin_pw_val}"; then
    fail "admin password value appears in container logs"
    secret_leak=1
fi
if [[ -n "${jwt_priv_val}" ]] && printf '%s' "${logs}" | grep -qF "${jwt_priv_val}"; then
    fail "JWT private key value appears in container logs"
    secret_leak=1
fi
if [[ "${secret_leak}" == "0" && -n "${secret_key_val}" && -n "${admin_pw_val}" ]]; then
    pass "SECRET_KEY and admin password values do not appear in container logs"
elif [[ -z "${secret_key_val}" || -z "${admin_pw_val}" ]]; then
    fail "could not read back secret values to test for a log leak (secrets not seeded yet?)"
fi
unset secret_key_val admin_pw_val jwt_priv_val logs

# --- assertion 8: idempotent secret seeding across a restart ------------------------------
hash_secrets() {
    "${CRI}" exec "${APP_NAME}" sh -c '
    for f in secret-key jwt-private jwt-public admin-password; do
        sha256sum "/app/data/.secrets/$f" 2>/dev/null
    done' 2>/dev/null
}
hashes_before="$(hash_secrets)"
echo "--- restarting app container to test idempotent secret seeding ---"
"${CRI}" restart "${APP_NAME}" >/dev/null 2>&1
restart_epoch="$(date +%s)"
restart_healthy=0
for _ in $(seq 1 30); do
    if [[ "$(http_status "${BASE_URL}/healthcheck")" == "200" ]]; then
        restart_healthy=1
        break
    fi
    sleep 1
done
if [[ "${restart_healthy}" != "1" ]]; then
    fail "app did not answer /healthcheck again after restart"
else
    pass "app answered /healthcheck again after restart ($(( $(date +%s) - restart_epoch ))s)"
fi
hashes_after="$(hash_secrets)"
if [[ -n "${hashes_before}" && "${hashes_before}" == "${hashes_after}" ]]; then
    pass "secret file sha256 hashes unchanged across a restart (idempotent seeding)"
else
    fail "secret file sha256 hashes CHANGED across a restart (seeding is not idempotent)"
    echo "  before: ${hashes_before}"
    echo "  after:  ${hashes_after}"
fi

echo "==================================================="
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    echo "smoke test FAILED: ${FAIL_COUNT} assertion(s) did not pass"
    exit 1
fi
echo "smoke test OK: all assertions passed"
exit 0
