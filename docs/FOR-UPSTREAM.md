# For the wger project

Notes and findings from packaging wger that are relevant to the upstream wger project, such as
deployment or configuration gaps discovered while adapting it to a constrained container
platform. Offered gratefully: wger packages cleanly, and the items below are the few places where
a managed-hosting environment differs from the reference docker-compose one.

## Resolved upstream in 2.7: thank you

Every item filed from the 2.6 packaging round was addressed in wger 2.7:

| Filed against 2.6 | Resolved in 2.7 by |
|---|---|
| Migration `core.0023_create_publication` needed a database superuser (`FOR ALL TABLES`) | 0023 is now a no-op; `core.0027_powersync_publication` creates the publication from an explicit table list, which needs only table ownership |
| `wger bootstrap` treated a half-initialised database as initialised | `database_exists()` now answers `User.objects.exists()`, so an interrupted first run resumes |
| No way to hide the app-store badges | `WGER_SHOW_APP_STORE_LINKS` |
| The `wger` CLI died when `HOME` was unreadable | `WgerConfig.load_user` ignores the per-user invoke config |

This package's workarounds for the first and last (a faked `core 0023`, an exported `HOME`) are
now redundant and will be removed in the next package version.

## Open: the mobile apps and PowerSync on managed databases

Since app 2.0.0 the mobile apps need PowerSync. PowerSync needs PostgreSQL logical replication,
and managed database platforms do not grant it. On Cloudron, the PostgreSQL addon runs with
`wal_level=replica`, and the application's role has neither `REPLICATION` nor `CREATEROLE`. The
same wall stops the YunoHost and Home Assistant packages. This package will bundle its own
PostgreSQL to get past it, so nothing below is a blocker. These are the changes that would help
most, cheapest first.

1. **Tell the app plainly when a server has no sync.** Today a server without PowerSync looks the
   same as a broken one ("check if the PowerSync service is running correctly"), so users report
   packages as broken after every update. A `POWERSYNC_ENABLED` setting that makes
   `/api/v2/powersync-token` answer 404 with `"code": "powersync_disabled"` would let the app,
   which already calls that endpoint at first login, say "this server does not provide mobile sync;
   use the web interface" instead. Older apps see a failed token request, as they do today.
2. **Ship the PowerSync sync rules and service config with each server release**, and name the
   PowerSync service version each wger release is tested with. Today they live on the `master`
   branch of `wger-project/docker`. A packager building a given wger tag has to guess which
   revision matches that tag's schema. A `powersync/` directory in the server repository, or a
   release asset, would keep the two in lockstep.
3. **Document the `/ps/` fallback as a stable contract.** `findLivePowerSyncUrl()` tries
   `<server>/ps/` after the advertised URL. Packages that serve PowerSync on the same origin will
   rely on that path, so it is worth saying in the docs that it stays.
4. **Let `setup-powersync-storage` use an existing role.** It always runs `CREATE ROLE`, which
   managed roles cannot. An option to place the bucket-storage schema under an existing role (for
   example when `PS_STORAGE_PG_URI` names the Django user) would make it usable wherever logical
   replication *is* granted but role creation is not.
5. **Say what to do with PowerSync after a database restore.** A restore that recreates the cluster
   changes its system identifier and orphans the replication slot and bucket state. A documented
   procedure (or a management command) to reset bucket storage and resync would help every
   deployment that restores from a dump, not only packaged ones.
6. **Give the PowerSync URL settings global defaults.** `POWERSYNC_URL` and `POWERSYNC_URL_PATH`
   are defined only in `settings/main.py`, so under any settings module built on
   `settings_global` (the CI settings among them) `/api/v2/powersync-token` raises
   `AttributeError`. That is also why the endpoint has no test. Two lines in `settings_global.py`
   fix it; they are part of the patch for item 1.
7. **The larger one: an online-only mode in the app** when the server declares no sync (item 1).
   Writes already go through `/api/v2/upload-powersync-data`, a plain Django endpoint. The missing
   half is downloading the synced tables over REST. This is the most work of any item here, and it
   is the only one that would make the mobile apps work on *every* managed platform without a
   bundled database.

Suggested patches for items 1 to 6, each against the current `master` branch of the repository it
touches, tested with that repository's own suite and linters, are kept by the package maintainer
and offered as pull requests. Item 7 is a design question for the app and has no patch.

This package will add PowerSync by bundling PostgreSQL. When that version ships, we will send a
pull request updating `docs/installation/cloudron.rst`.
