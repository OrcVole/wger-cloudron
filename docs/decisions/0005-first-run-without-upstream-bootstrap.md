# ADR 0005: first-run initialisation without upstream's bootstrap task

Status: accepted, 2026-08-01. Amends the first-run mechanics of ADR 0003; the secrets rules
there stand unchanged.

## Context

ADR 0003 originally delegated first-run database initialisation to upstream's own
`wger bootstrap --no-process-static` task. Two defects surfaced the first time the package ran
against a real Cloudron PostgreSQL addon rather than a local test database:

1. wger 2.6's migration `core.0023_create_publication` executes
   `CREATE PUBLICATION powersync FOR ALL TABLES`. PostgreSQL permits FOR ALL TABLES
   publications only to superusers. The addon database user is deliberately not a superuser,
   so the first migrate died with `psycopg.errors.InsufficientPrivilege` roughly four minutes
   in. A local sidecar database cannot reproduce this: the stock postgres container's
   bootstrap user is a superuser, so every local test passes.
2. The failed migrate left a half-initialised database: tables up to the failed migration,
   zero users, no fixtures. `wger bootstrap` gates itself on TABLE existence
   (`database_exists()` in `wger/tasks.py`), so on the next boot it returned success in
   seconds having done nothing, the admin account never appeared, and the install wedged in a
   fail-loud restart loop. Delegating recovery to a task with its own hidden gate made the
   wedge permanent.

## Decision

`bootstrap.sh` performs the first-run steps explicitly, each one idempotent, and does not call
`wger bootstrap` at all:

- **Emptiness probe**: the database counts as empty when the users table is missing OR
  contains zero rows. The zero-rows clause is deliberately stronger than upstream's
  table-existence test: a first run interrupted between migrate and fixtures leaves tables and
  zero users, and zero users provably means zero user-owned data, so retrying the fixture load
  there is safe and self-healing.
- **PowerSync publication migration is faked**: `manage.py migrate core 0022` (real), then
  `manage.py migrate --fake core 0023`, then the ordinary full `manage.py migrate`. PowerSync
  is not part of this package (mobile offline sync is documented as unavailable), and the
  publication cannot be created without superuser rights, so recording the migration as
  applied is the honest representation of the deployed state. All three commands are no-ops
  once applied, so they run on every boot.
- **Fixtures load in ONE atomic `loaddata` call**, using upstream's exact fixture list and
  order from `wger/tasks.py`. A single call is a single transaction: an interruption rolls the
  database back to zero users and the next boot simply retries first run.
- **Admin password by state detection, not by first-run flag**: the fixture set creates
  exactly one user, `admin`, with the known password `adminadmin`. On every boot, if the admin
  user currently carries that fixture default, it is replaced with a random password written
  to `/app/data/.secrets/admin-password` (0600). This heals every interruption window and
  never touches a password the operator has since changed. All output captured from Django is
  sentinel-prefixed and extracted line-wise, because Django's app-ready logging writes to
  stdout and otherwise rides along in command substitution.

## Consequences

- A fresh install, an interrupted install at any point, and the specific wedge state observed
  live all converge to a healthy application without manual database surgery (verified live:
  the wedged installation healed on update with this design).
- The fake must be revisited at every upstream version bump. A future superuser-requiring
  migration will fail the update loudly, which is the intended behaviour; the fix is another
  explicit, documented fake or an upstream patch.
- The package no longer depends on the behaviour of upstream's invoke-based CLI at boot time
  (which also required a HOME the runtime user can read; see PACKAGING-NOTES).
