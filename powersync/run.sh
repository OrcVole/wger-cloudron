#!/bin/bash
#
# powersync/run.sh: runs the PowerSync service (docs/decisions/0006) as cloudron.
#
#   run.sh start      the supervisor program: API server and replication worker in one process
#   run.sh compact    one compaction pass (powersync/compact-loop.sh calls this daily)
#
# PS_DATABASE_URI is exported HERE and nowhere else. wger's settings/main.py replaces Django's whole
# DATABASES setting with PS_DATABASE_URI whenever that variable exists, so if start.sh exported it,
# gunicorn and Celery would silently connect as the replication role instead of as wger.
set -euo pipefail

mode="${1:-start}"
sync_pw="$(cat /app/data/.secrets/db-powersync)"
uri="postgresql://powersync:${sync_pw}@127.0.0.1:5432/wger"
unset sync_pw

export PS_DATABASE_URI="${uri}"
export PS_STORAGE_PG_URI="${uri}"
export PS_PORT=8080
# Straight to gunicorn, not through nginx: wger's ALLOWED_HOSTS is '*', so the loopback Host
# header is accepted, and PowerSync does not depend on nginx being up to validate a token.
export PS_JWKS_URL="http://127.0.0.1:8010/api/v2/powersync-keys"
export NODE_ENV=production

# PowerSync writes its file probes to <working directory>/.probes; /run is writable, /opt is not.
cd /run/powersync

node=(/opt/powersync/bin/node --max-old-space-size=512 /opt/powersync/app/service/lib/entry.js)
case "${mode}" in
start)   exec "${node[@]}" start -r unified -c /app/code/powersync/powersync.yaml ;;
compact) exec "${node[@]}" compact -c /app/code/powersync/powersync.yaml ;;
*)       echo "usage: $0 start|compact" >&2; exit 2 ;;
esac
