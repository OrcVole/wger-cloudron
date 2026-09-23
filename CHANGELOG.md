# Changelog

[2.0.0]

- The wger mobile apps (Android and iOS, app version 2.0 and later) now work with this package. They need a sync service called PowerSync, which the package now includes and serves at `/ps/` on the app's own address. Nothing needs configuring on the phone beyond the server address.
- This includes Android without Google services (for example LineageOS or GrapheneOS), using the app from F-Droid.
- **The database moves into the app.** PowerSync needs logical replication, which the Cloudron PostgreSQL addon does not offer, so the package now runs its own PostgreSQL 18.
- The first start after this update copies all data from the addon database into the app's own database and checks that every table has the same number of rows before the app starts. **This first start takes longer than usual**, in proportion to the amount of data. If the check fails, the app stops with a clear error and the addon database is left untouched.
- The addon database is kept, unchanged, as a rollback copy. It is no longer used or updated, and a later version will remove it.
- To go back to 1.1.0, restore the backup taken before this update.
- Backups now contain a consistent dump of the app's database. Restoring a backup, including an in-place restore, returns the database to the backup's contents. The database it replaces is kept aside inside the app until the next restore.
- After a restore, the mobile apps download their data from the server again automatically.
- Memory limit raised from 2 GB to 3 GB for PostgreSQL and PowerSync.
- PowerSync 1.26.1 is included under the Functional Source License (FSL-1.1-ALv2, which becomes Apache 2.0 after two years); its licence text ships with the package.
- The workaround that skipped one upstream database migration is no longer needed and has been removed.
- Correction to 1.1.0: that version did not support the mobile apps, and its changelog should have said so.

[1.1.0]

- Upstream wger 2.6 to 2.7.
- Set TIME_ZONE in `/app/data/env` to your own timezone before applying this update if you are not on UTC, because the migration converts past session dates using this zone and cannot be re-run afterwards.
- Workout sessions now use datetime fields instead of separate date and time fields; past session data is backfilled automatically using the instance timezone.
- WeightEntry table migrated into the measurements system; the `/api/v2/weightentry/` endpoint remains functional but is deprecated.
- New configuration options: `WGER_MAX_SESSION_LENGTH_HOURS`, `WGER_SHOW_APP_STORE_LINKS`, `USE_X_FORWARDED_HOST`.
- Measurement categories now support health sync.
- Timezone-aware streaks and trophies.

[1.0.0]

- Initial package, wrapping wger 2.6.
- Cloudron single sign-on through the oidc addon: the login page offers sign-in with the
  Cloudron's own name, and accounts are provisioned automatically on first sign-in.
  Optional; installs without user management use local accounts only.
- Addons used: PostgreSQL, Redis, sendmail, localstorage, oidc.
- Processes: gunicorn, Celery worker, Celery beat and nginx under supervisor.
- Upstream default credentials and secrets (admin password, SECRET_KEY, JWT keypair)
  neutralised by the package entrypoint on first run.
- PowerSync (mobile offline sync) is not included in this package version.
