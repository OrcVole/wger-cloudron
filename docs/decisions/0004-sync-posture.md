# ADR 0004: wger.de synchronisation posture

Status: accepted, 2026-08-01.

## Context

wger can synchronise content from the public wger.de instance: the exercise database with its
images and videos (modest, curated), and the ingredient database (very large; upstream removed
its own sync-on-startup path because a full run "needs several hours", and a synchronised
ingredient set grows the database by gigabytes). Sync runs as weekly Celery tasks when
enabled. Live ingredient lookups by barcode (`DOWNLOAD_INGREDIENTS_FROM=WGER`) fetch single
items on demand through Celery and do not bulk-download.

## Decision

Package defaults, each operator-overridable through `/app/data/env`:

- Exercise, exercise image and exercise video sync: ON (weekly). A fitness app with an empty
  or stale exercise catalogue is not useful, and the dataset is modest.
- Bulk ingredient sync: OFF. The cost lands in the PostgreSQL addon and in every backup of it,
  and the on-demand barcode path covers the common need.
- On-demand ingredient lookups from wger.de: ON.

The defaults, the reasoning, and the override names are documented in the README; the
description text mentions the outbound weekly connection to wger.de so an operator learns of
the phone-home-shaped (but content-only) traffic before installing.

## Consequences

Fresh installs get a full exercise catalogue within the first weekly cycle (and the base
fixtures immediately). Operators who want the full offline ingredient database opt in
knowingly, with the size warning in front of them. No telemetry is involved either way; the
traffic is content synchronisation from a public instance, and disabling every sync leaves a
fully functional, self-contained application.
