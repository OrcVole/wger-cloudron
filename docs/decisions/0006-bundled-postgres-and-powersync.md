# ADR 0006: bundle PostgreSQL and PowerSync so the mobile apps work

Status: accepted, 2026-09-23. Package 2.0.0. Moves the database off the `postgresql` addon, which
ADRs 0001 to 0005 assumed throughout; their other decisions stand.

## Context

Since app 2.0.0 (2026-06-16) the wger mobile apps are offline-first and sync only through
[PowerSync](https://www.powersync.com/). After sign-in the app fetches `/api/v2/powersync-token`,
probes the advertised URL and then `<server>/ps/`, and if neither answers it shows a screen whose
only buttons are Logout, Docs and Retry. There is no online-only mode, and the server refuses app
versions older than its `MIN_APP_VERSION` (2.1.0 on server 2.7), so no older app is a workaround.

PowerSync replicates from PostgreSQL with **logical replication**: `wal_level=logical`, a role with
`REPLICATION` and `BYPASSRLS`, and a publication. The Cloudron addon runs `wal_level=replica` and its
app roles are `NOSUPERUSER NOCREATEROLE` without `REPLICATION` (verified on a 9.x box, 2026-09-22).
No manifest option changes either. Every alternative sync engine, and every route that feeds a
replica from the addon, hits the same wall. The full option table is in the workspace recce,
`phase-notes/powersync-recce-2026-09-22.md` §4.

## Decision

Bundle **PostgreSQL 18** and the **PowerSync service** in the app container, following the
estate's bundled-Postgres pattern (field guide §7.7, the Windmill package's ADR 0003), with the
changes below.

### PostgreSQL

- **Server:** `postgresql-18` from the PostgreSQL project's apt repository (PGDG) on
  `cloudron/base:5.0.0` (Ubuntu 24.04, whose own archive stops at 16). **18, not the addon's 16,
  deliberately:** dumping an older server and loading into a newer one is the direction PostgreSQL
  supports. The reverse is not safe: `pg_dump` 16 refuses a newer server, and from 17 on `pg_dump`
  writes `SET transaction_timeout`, which a 16 server rejects. Cloudron's development branch already
  ships 18 in the addon, so a 16 bundle would break the migration for anyone whose addon moves first.
  18 also spares us a 16 to 17 to 18 upgrade path later. Windmill bundles Ubuntu's 16, so the two
  packages differ here on purpose.
- **Data:** `PGDATA=/app/pgdata/18` on a **`persistentDirs`** entry, so the live cluster is never
  file-copied by the backup walk. `minBoxVersion` stays 9.1.0, which already covers it.
- **Settings live in the image, not in PGDATA.** `postgres/run.sh` starts the server with every
  setting as a `-c` flag and `hba_file` pointing into `/app/code`, so an update can change them and
  a restored cluster cannot carry stale ones. Key values: `wal_level=logical`,
  `max_wal_senders=4`, `max_replication_slots=4`, **`max_slot_wal_keep_size=2GB`** (a stalled
  PowerSync slot must not fill the app's disk), `listen_addresses=127.0.0.1`,
  `unix_socket_directories=/app/pgdata`, and absolute memory caps (`shared_buffers=128MB`,
  `work_mem=8MB`, `maintenance_work_mem=64MB`), never a ratio (field guide §7.7).
- **The socket sits in the persistentDir** so the backup's temporary container can reach the live
  server through the shared mount (Windmill's technique).
- **Authentication:** `local` trust (only this container's processes reach the socket), `host`
  scram-sha-256 on `127.0.0.1` only, including `replication`.
- **Major-version guard:** if `PGDATA/PG_VERSION` is not `18`, `start.sh` refuses to start and says
  why. It never initialises a new cluster over an old one.

### Roles, created idempotently by `bootstrap.sh` on every boot

| Role | Attributes | Used by |
|---|---|---|
| `cloudron` | superuser, created by `initdb`, no password, socket only | package scripts only |
| `wger` | `LOGIN`, owns database `wger`, **not** superuser | Django, over the socket |
| `powersync` | `LOGIN REPLICATION BYPASSRLS`, `SELECT` on `public`, owns schema `powersync` | PowerSync, over TCP loopback |

Passwords are seeded once into `/app/data/.secrets/` (`db-wger`, `db-powersync`) and re-asserted
with `ALTER ROLE` on every boot. Roles are therefore rebuilt from the secrets, not restored from a
dump. That keeps the backup to a single database and makes a restored cluster's passwords match the
restored secrets by construction.

The package runs this setup as SQL itself rather than through wger's `setup-powersync-storage`
command, because that command issues `CREATE ROLE` through Django's connection, which is the
non-superuser `wger`. The effect is the same: a `powersync` role owning a `powersync` schema in
database `wger`. PowerSync uses one role for both the replication source and its bucket storage.

**`PS_DATABASE_URI` is set only in the PowerSync program's environment.** wger's
`settings/main.py` replaces Django's whole `DATABASES` with `PS_DATABASE_URI` when that variable
exists, so exporting it globally would silently move Django onto the replication role.

### Moving an existing install off the addon (first boot of 2.0.0)

The addon stays declared in 2.0.0. It is the source of this migration and the rollback copy.

`bootstrap.sh` decides with a marker, `/app/data/.bundled-db` (JSON: how the bundled database was
born, when, and the row counts it was verified against). The marker lives in `/app/data`, so it
rides every backup together with the dump it describes.

| State at boot | Action |
|---|---|
| Marker present | Normal boot. The bundled database is authoritative. |
| No marker, addon has no `django_migrations` table | Fresh install. Create an empty `wger` database and write the marker (`"born": "fresh"`) before Django migrates. |
| No marker, addon has wger tables | **Migrate.** Clear the way (next paragraph), `pg_dump -Fc` from the addon (its discrete `CLOUDRON_POSTGRESQL_*` variables), `pg_restore --exit-on-error --no-owner --role=wger`, then compare `count(*)` for every table in `public` on both sides. Write the marker only if every count matches. Otherwise stop loudly, leaving the addon untouched. The next boot starts the migration over. |

**Clearing the way** when no marker exists but the bundled cluster already has a `wger` database.
A flag file, `/app/pgdata/.bundled-db-in-progress`, is written before bootstrap creates the database
and removed after the marker. If the flag is present, the database is bootstrap's own unfinished
attempt and is dropped. If it is absent and the database holds tables, it is **not ours to drop**: the
realistic case is an install rolled back to 1.1.0 and then updated again, where the platform re-mounts
the old persistentDir with its now-stale data. That database is renamed to `wger_orphaned_<time>`
(only the newest is kept) and a line in the log says so. The fresh copy then comes from the addon,
which is the current data. Inactive replication slots on the database are dropped first, since they
block both operations.

Django never connects to the bundled database before the marker exists, so an interrupted
migration can always be redone from the addon. The addon is never written to again. The publication
created by core migration 0027 comes across in the dump. The faked `core 0023` from ADR 0005 is
no longer needed: in 2.7 that migration is a no-op, and existing installs already record it as
applied.

### Backup and restore

- **`backupCommand` (`backup.sh`):** `pg_dump -Fc --exclude-schema=powersync wger` to
  `/app/data/db/wger.dump`, through the live socket if the app is running, otherwise through a
  transient server. The dump is written to a temporary name, checked to be readable, and then
  renamed. It is skipped, with a log line, while no marker exists, because until then the addon is
  authoritative and Cloudron backs it up itself. PowerSync's bucket storage is excluded on purpose:
  PowerSync rebuilds it from the source.
- **Row counts come from the dump itself.** COPY text format escapes newlines, so the lines between
  a table's `COPY` and `\.` are its rows, and `pg_dump` writes a block for every table, empty ones
  included. A count query run beside a live backup would read a different snapshot from the dump; the
  dump cannot disagree with itself.
- **`restoreCommand` (`restore.sh`):** Cloudron runs it before the app starts on a **clone** (the
  persistentDir starts empty) and on an **in-place restore**, where the platform *keeps* the
  persistentDir (platform facts, verified on OpenBao and Meilisearch).
  - **This package makes an in-place restore actually restore the database.** The Windmill and
    Langfuse packages leave the live database in place and document "clone instead". For a fitness
    log, "I restored last week's backup and nothing changed" is the worse surprise. So `restore.sh`
    moves a populated `PGDATA` aside to `/app/pgdata/pre-restore-<UTC time>` (a rename within one
    mount, so it is instant) and rebuilds from the dump. It keeps only the newest aside copy.
  - It rebuilds with `initdb`, roles from the restored secrets, `pg_restore --exit-on-error`, then
    compares the restored row counts with the counts read out of the dump. **On any failure it puts the aside copy back and
    exits non-zero**, so the restore task fails visibly instead of leaving an empty or half-loaded
    database.
  - With no dump present, it changes nothing and says so.
  - **Unverified, and a gate item:** that Cloudron runs `restoreCommand` only on restore and clone,
    never on update or restart. The container's stdout is discarded, so `restore.sh` appends one line
    per run to `/app/data/db/restore.log` to make this observable. If it ever runs on an update, the
    rebuild uses the dump from the backup Cloudron takes just before the update, and the aside copy
    keeps everything newer.
- **After a restore, PowerSync starts from nothing.** It gets a new cluster, no slot and an empty
  `powersync` schema, so it re-replicates in full. Apps see new checkpoints and resync. Their queued
  offline edits upload again through wger's own upload endpoint.
- **If `PGDATA` is empty, the marker is present and there is no dump**, `start.sh` refuses to start
  rather than serve an empty database.

### PowerSync

- **Pinned by digest:** `journeyapps/powersync-service:1.26.1`
  (`sha256:413a0c813e96935ebe7203b5759f8a594a7b7cd8aa42134713e63af637e0f079`). Upstream wger's own
  compose file runs `:latest`. Its Node 24.18.1 binary and `/app` tree are copied to
  `/opt/powersync`. Tested on Ubuntu 24.04: it starts, and its one native add-on (snappy) loads.
- **Config:** upstream's `powersync.yaml` and `sync_rules.yaml`, vendored unchanged in `powersync/`
  with a provenance note. Environment: `PS_DATABASE_URI` and `PS_STORAGE_PG_URI` (the `powersync`
  role over `127.0.0.1:5432`, database `wger`), `PS_PORT=8080`, and
  `PS_JWKS_URL=http://127.0.0.1:8010/api/v2/powersync-keys`, which reaches gunicorn directly.
  wger's `ALLOWED_HOSTS` is `*`, so the loopback Host header is accepted.
- **Served at `/ps/`** on the app's own domain by the package nginx: prefix stripped, buffering
  off, HTTP/1.1 with `Upgrade` and `Connection` passed through, one-hour read timeout. The app
  already falls back to `<server>/ps/`, and the token endpoint advertises exactly that by default,
  so no URL setting is needed.
- **Process order under supervisor:** `postgres` first, then `bootstrap` (the migration or
  migrations, then role setup), then `gunicorn`, the Celery processes and `powersync`, all started by
  `bootstrap` when it finishes. A `powersync-compact` loop runs `compact` once a day.
- **Read-only root:** PowerSync writes file probes to `<app>/.probes`, which is a symlink into
  `/run`.
- **Licence:** PowerSync is FSL-1.1-ALv2 (converts to Apache 2.0 after two years). Redistribution
  is allowed outside "Competing Use", which a free self-hosted fitness-app package is not (our
  reading, not legal advice). Its licence text ships as `LICENSE.powersync`, and the README credits
  it.

### Memory

Postgres, PowerSync, gunicorn and Celery now share one `memoryLimit`. It is provisionally raised
from 2 GiB to 3 GiB, and PowerSync's Node heap is capped with `--max-old-space-size=512`. The real
number comes from the idle-versus-production gate with a phone syncing, including a resync after a
restore.

## Consequences

- **The mobile apps work.** They are gated on real phones: LineageOS and GrapheneOS without Google
  services, using the F-Droid build.
- The first start of 2.0.0 copies the database and takes longer in proportion to its size. The
  changelog says so.
- The addon copy goes stale the moment the migration finishes, but it is still backed up by
  Cloudron and still shown by the dashboard's database tools. The README says it is a frozen
  rollback copy. A later version removes the addon, once a gate has shown whether removing an addon
  on update deletes its database.
- **Rollback to 1.1.0** is a restore of the pre-update backup. It brings the manifest back to the
  addon, whose data is restored from that same backup. The persistentDir is then orphaned (not
  mounted, not deleted), per platform facts.
- **We now own Postgres upgrades.** A move past 18 must ship `pg_upgrade` or a dump-and-reload.
- The image grows by about 350 MB (PowerSync tree plus Node) and by the Postgres packages.
- ADR 0005's faked migration and its re-audit rule are retired.

## Alternatives rejected

Addon plus an in-container replica, operator-enabled `wal_level=logical` on the shared addon,
another sync engine, a non-Postgres PowerSync source, and a separate sync app. Each is dead for a
reason recorded in the recce (§4). The two asks that could later let us return to the addon are a
Cloudron manifest option for logical replication and an upstream "no sync" flag. Both are drafted
in the workspace.
