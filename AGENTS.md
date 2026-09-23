# AGENTS.md: wger Cloudron package working contract

The settled-decisions record for packaging **wger** (`wger`, AGPL-3.0) as a Cloudron community
app. Read this before changing anything. Do not relitigate these decisions without a concrete
reason found on a running box. **The box is the authority, not the docs.**

## What this package is

wger is a free, open source workout, fitness and nutrition manager with a REST API shared by the
official mobile apps; this package wraps the upstream 2.7 release as a thin adaptation layer,
changing only the runtime environment, never the application itself. From package 2.0.0 it also
bundles PostgreSQL 18 and PowerSync 1.26.1 so the mobile apps can sync
([ADR 0006](docs/decisions/0006-bundled-postgres-and-powersync.md)); read that ADR before touching
`start.sh`, `bootstrap.sh`, `backup.sh`, `restore.sh` or anything under `postgres/`.

Topology, one row per process, all logging to stdout:

| Process | Role | Port (localhost unless noted) |
|---|---|---|
| postgres | Bundled PostgreSQL 18, `wal_level=logical`; settings passed as flags from `postgres/pg.sh`, never read from PGDATA | 127.0.0.1:5432 and socket in `/app/pgdata` |
| nginx | Binds `httpPort`, serves `/static/` and `/media/` directly, proxies `/ps/` to PowerSync and everything else to gunicorn, answers the health check immediately | 8000 (external) |
| bootstrap | One-shot: roles, the one-time move off the addon, migrations, then starts everything below | none |
| gunicorn | Django application server | 127.0.0.1:8010 |
| celery worker | Background jobs: exercise/ingredient sync from wger.de, email, scheduled tasks | none |
| celery beat | Schedules the periodic Celery jobs | none |
| powersync | Mobile sync service (unified API + replication) | 127.0.0.1:8080, via nginx `/ps/` |
| powersync-compact | Daily `compact` of PowerSync's bucket storage | none |

State: the database is the **bundled** PostgreSQL, data in the `/app/pgdata` persistentDir.
PowerSync needs logical replication, which the Cloudron addon does not grant (`wal_level` is
`replica`, and app roles have neither superuser nor `REPLICATION`). The `postgresql` addon stays
declared only as the source of the one-time move from 1.x and as a rollback copy; nothing reads it
once `/app/data/.bundled-db` exists. Redis (cache plus Celery broker/backend) comes from the addon;
outgoing email goes through the `sendmail` addon. Uploaded media, the seeded secrets and the
database dump live under `/app/data`. Static assets are derived data baked into the image.

**Never export `PS_DATABASE_URI` outside `powersync/run.sh`.** wger's `settings/main.py` swaps
Django's whole `DATABASES` for it when it is set, so Django would silently run as the replication
role. **Test locally with `test/upgrade.sh`** (1.1.0 to 2.0.0 on real data, PowerSync end to end,
backup, in-place restore, a deliberately failed restore, clone) before any gate.

## Golden rules

1. **Conformance to the Cloudron contract first.** Adapt the application's runtime environment
   only. Never patch the application itself.
2. **Pin everything by digest**: the base image, every upstream image, every bundled service.
   Exactly one build argument per upstream version, mirrored in the manifest as
   `upstreamVersion`. Upstream's `wger/server` tags on Docker Hub are re-pushed from master on
   every push, so a tag is never trustworthy; only the resolved digest is pinned.
3. **Persisted state only in `/app/data`.** Re-assert ownership and mode on **every** boot,
   because a restore drifts them.
4. **Fail loud.** Never silently regenerate a data-loss-critical secret, and never clobber
   operator configuration. Upstream's own bootstrap resets the admin password to a known default
   on certain runs; this package never calls that path, and neutralises the default instead.
5. **Code and docs ship together.** ADRs in `docs/decisions/`. The verified-versus-assumed log
   in `docs/PACKAGING-NOTES.md`, newest first. Box-specific working notes stay in gitignored
   `phase-notes/`.
6. **`CMD`, never `ENTRYPOINT`**, because `ENTRYPOINT` breaks Cloudron debug mode. Maintain
   `.dockerignore` as carefully as `.gitignore`.
7. **Open source only.** No licence-gated upstream feature is enabled by this package.
8. **Anonymise before every push.** No box or mirror hostnames, no real emails, no tokens, no
   internal URLs in any tracked file. `example.com` is the placeholder in public docs.
   `test/secret-scan.sh` is the release gate.
9. **Git hygiene.** No AI co-authorship and no tool-attribution trailers. Commit as the
   maintainer identity, set **repo-local**, because the machine global is a placeholder.
10. **No `proxyAuth`, ever.** wger exposes a JWT REST API that the official mobile app depends
    on, and upstream's own reverse-proxy documentation warns that `/api/*` must stay reachable
    without a proxy authentication wall. A blanket `proxyAuth` addon would break the mobile app
    and is not used in this package, now or in any future version.

## Locked decisions (Phase 0, operator-confirmed 2026-08-01)

- **Manifest id:** `io.github.orcvole.wger`. The repository's `-cloudron` suffix does not enter
  the id. `author` and `packagerName` are `OrcVole`.
- **Registry:** `ghcr.io/orcvole/wger-cloudron`, pushed public so the box pulls without
  credentials. Tag scheme `2.6-<pkg-rev>`.
- **Repos:** GitHub `OrcVole/wger-cloudron` is canonical. A private mirror also exists; its URL
  is maintainer-local and deliberately not recorded in tracked files.
- **memoryLimit:** measure, do not guess. Install the test instance with a generous limit so that
  an OOM never masks behaviour, measure warmup peak and steady state, then set the shipped floor
  from the gate ladder's memory gate. Provisionally 3 GiB (`3221225472`) from 2.0.0, because
  PostgreSQL and PowerSync now share the limit; **not yet measured**: the memory gate, with a
  phone syncing, sets it.
- **Health:** `healthCheckPath = /healthcheck`, served immediately by nginx rather than proxied
  to Django, because upstream has no dedicated health endpoint, `/` answers anonymously with
  2xx/3xx only once the application is fully up, and first boot (fixtures, `collectstatic`,
  migrations) can be slow enough that a proxied check would fail the install window.
- **Auth topology:** app-native accounts by default, no `proxyAuth`, `optionalSso` not enabled
  until the allauth `openid_connect` route through `WGER_SOCIAL_PROVIDERS` is proven against a
  Cloudron `oidc` addon (an open experiment, not a given). Self-registration (`ALLOW_REGISTRATION`)
  defaults off in this package regardless of the SSO outcome.

## Pinned upstream

- `cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c`
- wger `2.6` (tagged 2026-06-17), image `docker.io/wger/server`, digest resolved and pinned at
  build time (tags float), AGPL-3.0.
- Each bundled service, with its digest and the reason for that exact version: recorded in
  `docs/decisions/` as each is added.

## Build shape

To be settled in an ADR before the Dockerfile is written. Candidate shape (from recon): a
multi-stage build with `docker.io/wger/server@sha256:<2.6 digest>` as a source stage and
`cloudron/base:5.0.0` as the final stage, copying the installed Python tree and application
source across, since both images are Ubuntu 24.04, Python 3.12 and uid/gid 1000. Fallback if the
copy does not hold up under a build gate: install wger 2.6 from source onto the base image
directly, which needs a Node toolchain for the static asset pipeline. Neither shape is built yet;
this section is filled in once the ADR lands.

## Secrets

First-run only, idempotent, under `/app/data`, mode 0600, re-asserted on every boot.

| Secret | Shape | Criticality | Notes |
|---|---|---|---|
| `SECRET_KEY` | Django secret key, random string | data-loss-critical | Rotation invalidates sessions and password reset tokens; does not orphan stored data. Never regenerated once seeded. |
| JWT keypair | RS256 private/public key pair (JWK) | data-loss-critical | Used for the mobile JWT API and served as the JWKS that PowerSync validates every app token against. Rotation signs every mobile app out; does not orphan stored data. Never regenerated once seeded. |
| `db-wger`, `db-powersync` | Hex passwords for the bundled database's two login roles | data-loss-critical | Roles are re-created from these on every boot and restore, never restored from the dump. Never regenerated once seeded. |
| Admin password | Random string | seed-once | Set on first boot in place of upstream's insecure default, written to `/app/data/.secrets/admin-password` for the operator to read once. |

Data-loss-critical secrets must be proven byte-identical, by sha256, across both an update and a
restore. Never record the value itself, in any file, ever. The digest is the invariant.

## Environment mapping

Translate on every boot. Verified against the upstream compose file and source (see
`docs/PACKAGING-NOTES.md` for the evidence trail); the mapping table itself is filled in once
the start.sh phase is under way.

| Application variable | Source or value | Notes |
|---|---|---|
| `DJANGO_DB_*` | bundled server: socket `/app/pgdata`, database and role `wger`, password `db-wger` | `CLOUDRON_POSTGRESQL_*` are read only by the one-time move |
| `PS_DATABASE_URI`, `PS_STORAGE_PG_URI`, `PS_JWKS_URL`, `PS_PORT` | set in `powersync/run.sh` only | see the warning under State |
| `DJANGO_CACHE_LOCATION` | `CLOUDRON_REDIS_URL`, db index 1 | |
| Celery broker/backend | `CLOUDRON_REDIS_URL`, db index 2 | |
| `EMAIL_*`, `FROM_EMAIL` | `CLOUDRON_MAIL_SMTP_*`, `CLOUDRON_MAIL_FROM` | `ENABLE_EMAIL=True` |
| `CSRF_TRUSTED_ORIGINS`, site URL | `CLOUDRON_APP_ORIGIN` | |
| `ALLOWED_HOSTS` | hardcoded `['*']` upstream | host validation is the proxy's job |

## Backup and restore

`/app/pgdata` is a `persistentDirs` entry, so the live cluster is never file-copied. The
`backupCommand` (`backup.sh`) writes `pg_dump -Fc` of `wger`, excluding the `powersync` schema,
to `/app/data/db/wger.dump`; the `restoreCommand` (`restore.sh`) rebuilds from it and checks
every table's row count against the dump. On an **in-place** restore Cloudron keeps the
persistentDir, so `restore.sh` moves the live cluster aside to `/app/pgdata/pre-restore-<time>`
first and puts it back if anything fails: this package's restores really restore, unlike the
Windmill and Langfuse packages. Both hooks run with no `CLOUDRON_*` environment and discarded
output; they log to `/app/data/db/{backup,restore}.log`. Redis state is disposable.
**Open:** proving on a real box that Cloudron never calls `restoreCommand` on update or restart.

## Future compatibility

The single bump point for a version upgrade is the upstream image digest (and the
`upstreamVersion` manifest field, kept in step). Django migrations and the wger fixture bootstrap
run automatically on boot against an existing database. Deliberately out of scope for this
package version: any SSO claim beyond what the allauth experiment proves. At every upstream bump,
re-vendor `powersync/` (see its `PROVENANCE.md`): the sync rules must match the server's
`powersync` publication. PostgreSQL stays at 18 until a release ships `pg_upgrade`.
