# Changelog

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
