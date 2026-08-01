# For the wger project

Notes and findings from packaging wger that are relevant to the upstream wger project, such as
deployment or configuration gaps discovered while adapting it to a constrained container
platform. Offered gratefully; wger 2.6 packaged cleanly overall, and the items below are the
few places where a managed-hosting environment differs from the reference docker-compose one.

## Migration `core.0023_create_publication` requires a database superuser

The migration executes `CREATE PUBLICATION powersync FOR ALL TABLES`, which PostgreSQL
restricts to superusers. Managed platforms (Cloudron addons, most DBaaS products) hand
applications a non-superuser role, so the migration fails with
`psycopg.errors.InsufficientPrivilege: must be superuser to create FOR ALL TABLES publication`
and aborts the whole first migrate. The reference compose file does not hit this because the
official postgres image's bootstrap user is a superuser.

Suggestion: catch `InsufficientPrivilege` inside `add_publication` and log a warning (the
publication only matters when PowerSync is actually deployed), or gate the operation on a
setting so deployments without PowerSync skip it cleanly. This package currently records that
one migration as applied without running it (`migrate --fake core 0023`), which works but has
to be re-audited at every release.

## `wger bootstrap` treats a half-initialised database as initialised

`database_exists()` in `wger/tasks.py` answers "does the users table exist", so a first run
that dies between migrate and the fixture load (for example on the migration above) leaves a
database that `wger bootstrap` refuses to finish: tables exist, so it skips migrate, fixtures
and admin creation entirely and returns success. Anything that wraps the entrypoint then loops
forever with no admin account. A `User.objects.count() == 0` check alongside the
DatabaseError branch would make bootstrap resumable after an interrupted first run.

## A toggle to hide the app-store badges would serve privacy-minded self-hosters

The base template's footer and the public features page hardcode Google Play, Apple App
Store and Flathub badges. The badge images are served locally (no third-party request
happens on page load), so the privacy exposure is limited to deliberate clicks, but some
self-hosting operators prefer their instances not to advertise or link out to the big app
stores at all. A single boolean setting in the `WGER_SETTINGS` family (for example
`SHOW_APP_STORE_LINKS`, default on) wrapped around those template blocks would cover the
preference cleanly; today the only options are template overrides or reverse-proxy content
filtering, both of which age badly across releases.

## The `wger` CLI depends on a readable HOME

The CLI is invoke-based, and invoke opens `$HOME/.invoke.yaml` during startup. Under process
supervisors that do not reset HOME on privilege drop (supervisord among them), the inherited
`HOME=/root` makes the CLI die with `PermissionError` before argument parsing. Trivially fixed
deployment-side by exporting HOME, but a `load_user=False` invoke configuration (or catching
the PermissionError) would remove the trap for everyone.
