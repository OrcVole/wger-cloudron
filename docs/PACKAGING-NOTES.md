# Packaging notes (verified-versus-assumed log, newest first)

Anonymised. Box-specific detail lives in the maintainer's local notes, not here.

---

## 2026-08-01: runtime smoke, first platform install, SSO experiment

Everything below was found by RUNNING the package, first under the local smoke harness, then
on a real Cloudron installation. None of it was caught by static review, and two items cannot
be caught locally at all.

**Verified (each one cost a live failure):**

- **Django management output must be sentinel-extracted.** Django's app-ready logging (for
  example django-axes' startup banner) writes to stdout, so any value captured from
  `manage.py shell` by command substitution carries log noise. The package's database probe
  misread a fresh database as populated because of this; every captured value now uses a
  sentinel-prefixed line extracted with `sed`, never a comparison of the whole captured blob.
- **supervisord does not reset HOME when dropping privileges.** A program with
  `user=cloudron` inherits root's `HOME=/root`. The `wger` CLI is invoke-based, and invoke
  opens `$HOME/.invoke.yaml` at startup, which dies with EACCES as an unprivileged user. The
  entrypoint exports `HOME=/app/data` before supervisord starts.
- **wger 2.6's `core.0023_create_publication` requires a database superuser**
  (`CREATE PUBLICATION powersync FOR ALL TABLES`). The Cloudron PostgreSQL addon user is not
  one, so the migration kills the first migrate with
  `psycopg.errors.InsufficientPrivilege`. A local postgres sidecar cannot reproduce this
  (its bootstrap user IS a superuser). The package fakes exactly this migration; see
  ADR 0005.
- **`wger bootstrap` gates itself on table existence**, so a half-initialised database
  (tables, zero users, the state a failed first migrate leaves behind) makes it a silent
  no-op and wedges the install permanently. The package now runs the equivalent steps
  explicitly and idempotently; see ADR 0005.
- **wger mounts django-allauth at `/account` (singular).** The OIDC callback is
  `/account/oidc/<provider_id>/login/callback/`. Guessing the conventional plural
  `/accounts/...` produces a redirect URI registration that can never match; the live
  redirect was captured from the running application before the manifest value was trusted.
- **The anonymous front page is a redirect chain, not a bare 200**: `/` answers 302 to a
  locale path and lands on the public features page. Health probes and smoke assertions must
  follow redirects; upstream's own healthcheck accepts 2xx/3xx for the same reason.

**Assumed, then corrected:**

- The smoke test's process-audit originally detected its own `podman exec` shell as a rogue
  root process (the image's default user is root, so the checker enters as root). Assertion
  shells that walk `/proc` must exclude their own process tree.
- First-run recovery was assumed delegable to upstream's bootstrap task; the wedge above
  disproved that. Recovery logic has to own every step it is responsible for resuming.

## 2026-08-01: recon and repository scaffold

Recon confirmed no existing Cloudron package of wger anywhere (official store, community store,
`git.cloudron.io`, GitHub), so this package starts from a clean slate rather than a fork or a
contribution to an existing effort. This entry summarises the recon findings that this repository
scaffold is built on.

**Validated (decisions that held up):**

- **No duplicate package exists.** Checked the official store index, `ca.cloudron.io`'s roughly
  61-app listing, `git.cloudron.io` project search, and GitHub, all returning no wger Cloudron
  package. One forum wishlist thread (opened 2019, revived 2024) is the only prior interest, and
  no reply on it ever claimed the work.
- **Upstream architecture matches the standard multi-process shape.** The real docker-compose
  file lists gunicorn, nginx, postgres, redis, a Celery worker and Celery beat as the core
  services, which maps directly onto the package's supervisor-managed process set plus the
  `postgresql`, `redis`, `sendmail` and `localstorage` addons.
- **`proxyAuth` is wrong for this app.** Upstream's own reverse-proxy documentation states that
  `/api/*` must be reachable without a proxy authentication wall, because the official mobile
  app authenticates against it directly with JWT. This rules out a blanket `proxyAuth` addon for
  the lifetime of the package.

**Surfaced (things that were wrong or missing, and are now fixed):**

- **Postgres major version fit: verified, resolved.** Upstream's compose file ships PostgreSQL
  15 and Django 6.0 (wger 2.6's Django version) states "Django supports PostgreSQL 14 and
  higher" in its own database documentation. The target box's `postgresql` addon serves a
  running PostgreSQL 16 cluster (verified directly: the cluster's `PG_VERSION` file reads 16,
  `pg_config` reports 16.13). The addon clears the floor comfortably and the package uses it;
  no bundled-Postgres escalation is needed.
- **Static files are baked at build time.** `manage.py collectstatic` against the pinned 2.6
  image produced 11 471 files, 294 MiB, and needs no database connection (verified by running
  it with only a placeholder SECRET_KEY). That size rules out both a tmpfs location (the pages
  would be charged to the container's memory limit) and the backed-up data directory
  (collectstatic rewrites mtimes, and Cloudron's backup syncer diffs by mtime and size, so
  every backup would re-upload the whole 294 MiB). The Dockerfile therefore runs collectstatic
  at build time and ships the result read-only in the image; static output changes exactly when
  the image changes.
- **Upstream Docker Hub tags float.** `docker.io/wger/server` re-pushes both `latest` and its
  version tags on every push to master, confirmed from the upstream build workflow, so a tag
  reference alone is not a stable pin; the Dockerfile phase resolves and records the digest for
  the `2.6` tag at the moment it is built, not the tag itself.

**Still open:**

- Whether Cloudron SSO can be wired through django-allauth's generic `openid_connect` provider,
  exposed by wger's `WGER_SOCIAL_PROVIDERS` setting, against the Cloudron `oidc` addon. No
  evidence either way yet; this is an explicit experiment for a later phase, with app-native
  accounts as the documented fallback if it does not work.
- (Resolved since first drafted, kept for the record.) `create_or_reset_admin` is reached by
  upstream's bootstrap only when the database is empty, verified by reading `wger/tasks.py`
  inside the pinned image: `bootstrap` calls it inside an `if not database_exists()` branch.
  Called directly it would reset an existing admin's password to the insecure default, so the
  package's entrypoint never calls it outside first run, and on first run immediately replaces
  the fixture password with a randomly generated one.
- The default posture for the wger.de ingredient sync job (large, multi-gigabyte growth
  potential) versus the exercise sync job (small, weekly) has not been written up as an ADR yet;
  the working assumption carried into this scaffold is exercise sync on, ingredient sync off,
  both operator-configurable.

---

## Conventions for this file

- Newest first, so the top of the file is always the current state of knowledge.
- Every claim carries its evidence. "It works" is not an entry; "a 4 MiB upload returned 200 and
  the downloaded bytes were sha256-identical" is.
- Distinguish verified from assumed explicitly. An assumption written as a fact is the single
  most expensive thing this document can contain.
- Anything that generalises beyond this application gets harvested into the private field guide
  at the end of the round. This file is the application's record; the field guide is the
  doctrine.
- Gate ladder evidence tables live in `docs/DEBUGGING.md` or the relevant ADR. This file records
  what the gates taught, not the raw runs.
