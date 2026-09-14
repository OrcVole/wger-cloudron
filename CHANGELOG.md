# Changelog

[1.1.0]

- Upstream wger 2.6 to 2.7.
- Set TIME_ZONE in `/app/data/env` to your own timezone before applying this update if you are not on UTC, because the migration converts past session dates using this zone and cannot be re-run afterwards.
- Workout sessions now use datetime fields instead of separate date and time fields; past session data is backfilled automatically using the instance timezone.
- WeightEntry table migrated into the measurements system; the `/api/v2/weightentry/` endpoint remains functional but is deprecated.
- New configuration options: `WGER_MAX_SESSION_LENGTH_HOURS`, `WGER_SHOW_APP_STORE_LINKS`, `USE_X_FORWARDED_HOST`.
- Measurement categories now support health sync.
- Timezone-aware streaks and trophies.

## [1.0.0]

- Initial package, wrapping wger 2.6.
- Cloudron single sign-on through the oidc addon: the login page offers sign-in with the
  Cloudron's own name, and accounts are provisioned automatically on first sign-in.
  Optional; installs without user management use local accounts only.
- Addons used: PostgreSQL, Redis, sendmail, localstorage, oidc.
- Processes: gunicorn, Celery worker, Celery beat and nginx under supervisor.
- Upstream default credentials and secrets (admin password, SECRET_KEY, JWT keypair)
  neutralised by the package entrypoint on first run.
- PowerSync (mobile offline sync) is not included in this package version.
