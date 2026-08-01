# Changelog

## [1.0.0]

- Initial package, wrapping wger 2.6.
- Addons used: PostgreSQL, Redis, sendmail, localstorage.
- Processes: gunicorn, Celery worker, Celery beat and nginx under supervisor.
- Upstream default credentials and secrets (admin password, SECRET_KEY, JWT keypair)
  neutralised by the package entrypoint on first run.
- PowerSync (mobile offline sync) is not included in this package version.
