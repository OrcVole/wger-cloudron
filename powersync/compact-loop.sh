#!/bin/bash
#
# powersync/compact-loop.sh: PowerSync has no scheduler of its own, and its bucket storage grows until
# `compact` runs (docs/decisions/0006). This supervisor program runs one pass an hour after it
# starts, then once a day. A failed pass is logged and retried the next day; it never takes the app
# down, because sync keeps working without compaction, only less efficiently.
set -uo pipefail

log() { printf '==> [powersync-compact] %s\n' "$*"; }

sleep 3600
while true; do
    log "compacting bucket storage"
    /app/code/powersync/run.sh compact
    rc=$?
    if [[ ${rc} -eq 0 ]]; then log "compaction done"; else log "compaction FAILED (exit ${rc}); next attempt in 24 h"; fi
    sleep 86400
done
