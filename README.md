# wger for Cloudron

A Cloudron package for [wger](https://github.com/wger-project/wger), a free, open source
workout, fitness and nutrition manager. Documentation for the upstream application is at
[wger.readthedocs.io](https://wger.readthedocs.io).

This repository is not affiliated with the wger project. It packages the upstream application
for the Cloudron platform; application behaviour, features and bugs belong upstream.

## Licence

The wger application is licensed AGPL-3.0. This package mirrors that licence in `LICENSE`
(fetched verbatim from the upstream repository at the pinned tag). The packaging code in this
repository (Dockerfile, start scripts, configuration) is offered under the same terms unless
stated otherwise. The image also contains PowerSync, under the Functional Source License (FSL-1.1-ALv2,
which becomes Apache 2.0 two years after each release); its text is
[`LICENSE.powersync`](LICENSE.powersync).

## Installing

```bash
cloudron install --appstore-id io.github.orcvole.wger
```

Once this package is published, it will be available through the versions-url channel used by
this repository. Installation details (channel URL, `cloudron install` invocation) will be added
here once the package has a published version.

## Architecture

The package runs several processes under supervisor, all logging to stdout:

| Process | Role |
|---|---|
| postgres | wger's PostgreSQL 18 database, inside the app (see below for why) |
| nginx | Binds the app's HTTP port, serves `/static/` and `/media/` directly, proxies `/ps/` to PowerSync and everything else to gunicorn, answers the health check immediately |
| bootstrap | One-shot at every start: the one-time move off the addon, migrations, roles, then starts the rest |
| gunicorn | The Django application server |
| celery worker | Background jobs: exercise/ingredient sync, email, scheduled tasks |
| celery beat | Schedules the periodic Celery jobs |
| powersync | The mobile apps' sync service, at `/ps/` on the app's own domain |
| powersync-compact | Compacts PowerSync's storage once a day |

State and services:

- **The database is bundled**: PostgreSQL 18 runs inside the app with its data in `/app/pgdata`, a
  `persistentDirs` entry (kept across updates, never file-copied by the backup). PowerSync needs
  logical replication, which the Cloudron PostgreSQL addon does not provide. The `postgresql`
  addon stays declared only as the source of the one-time move from 1.x and as a rollback copy.
- Redis (cache and Celery broker/backend) and outgoing email come from Cloudron addons.
- Uploaded media lives under `/app/data/media` and is backed up with the rest of `/app/data`.
- Static assets are derived data, baked into the image by `collectstatic` at build time and
  served read-only; they change exactly when the image changes and are deliberately not
  persisted or backed up.

## Single sign-on

The package integrates Cloudron user management through the `oidc` addon and wger's bundled
django-allauth. The login page offers a "Sign in with ..." button carrying the Cloudron's
configured display name, and a wger account is provisioned automatically on first sign-in.
Public self-registration stays disabled independently of this: the Cloudron's own user and
group access control decides who can reach the app. Installing without user management is
supported (`optionalSso`); the app then uses purely local accounts, and no stale login button
is left behind.

## Mobile apps (PowerSync)

The official mobile apps (Android and iOS, 2.0 and later) are offline-first and sync only through
PowerSync. This package includes PowerSync 1.26.1, pinned by digest, and serves it at `/ps/` on
the app's own domain, which is where the apps look by default: a phone needs only the server
address. Android without Google services (LineageOS, GrapheneOS) works with the F-Droid build.

PowerSync checks the apps' tokens against wger's JWT keypair in `/app/data/.secrets`, so rotating
that keypair signs every phone out. Its configuration and sync rules are upstream's, vendored in
[`powersync/`](powersync/) with their provenance. The full design, including why the database had
to move, is [ADR 0006](docs/decisions/0006-bundled-postgres-and-powersync.md).

## Backup and restore

Persistent state is the bundled database in `/app/pgdata` and everything under `/app/data`
(uploaded media, seeded secrets, the operator environment override file). Redis holds only cache
and queue state.

- **Backup:** the manifest's `backupCommand` writes a consistent `pg_dump` of the database to
  `/app/data/db/wger.dump`, and Cloudron's normal backup carries it. The live data directory is
  never file-copied.
- **Restore, in place or as a clone:** the `restoreCommand` rebuilds the database from that dump
  and checks every table's row count against it. An in-place restore therefore really does return
  the database to the backup. The database it replaces is kept aside in
  `/app/pgdata/pre-restore-<time>` until the next restore, and if the rebuild fails the previous
  database is put back and the restore reports failure. PowerSync resyncs from scratch afterwards.
- **Updating from 1.x:** the first start of 2.0.0 copies the addon database into the bundled one,
  checks every table's row count, and only then starts the app. The addon copy is left untouched.
  To go back to 1.1.0, restore the backup Cloudron took before the update.

## Further documentation

- [docs/PACKAGING-NOTES.md](docs/PACKAGING-NOTES.md): the verified-versus-assumed log for this
  package, newest entry first.
- [docs/FOR-CLOUDRON.md](docs/FOR-CLOUDRON.md): notes intended for the Cloudron project.
- [docs/FOR-UPSTREAM.md](docs/FOR-UPSTREAM.md): notes intended for the wger project.
- [AGENTS.md](AGENTS.md): the settled-decisions working contract for this package.
- [docs/decisions/](docs/decisions/): architecture decision records;
  [0006](docs/decisions/0006-bundled-postgres-and-powersync.md) covers the bundled database and
  PowerSync.
