<sso>

## Single sign-on

This app is connected to Cloudron user management. Anyone granted access to the app can use
the "Sign in with ..." button on the login page (it carries this Cloudron's configured name);
a wger account is created automatically on first sign-in. The administrator account below is
app-local and continues to work alongside single sign-on.

</sso>

## First login

The initial administrator account is:

- Username: `admin`
- Password: randomly generated at first start and written to
  `/app/data/.secrets/admin-password`

Read the password using the Cloudron file manager, or open the web terminal for this app and
run:

```bash
cat /app/data/.secrets/admin-password
```

Change the administrator password after first login.

## Mobile apps

The official wger apps (Android and iOS, including the F-Droid build for phones without Google
services) connect with just this app's address. They sync through PowerSync, which runs inside
this app; there is nothing to set up. Rotating the JWT keys in `/app/data/.secrets` signs every
phone out.

## Database and backups

wger's database runs inside this app rather than in the Cloudron PostgreSQL addon, because the
mobile sync needs a feature the addon does not offer. Each backup includes a consistent copy of
it, and restoring a backup (in place or as a clone) returns the database to that backup. An
install updated from a 1.x version was copied out of the addon automatically on its first start;
the addon copy is kept unchanged as a rollback copy and is no longer used.

## Registration

Self-registration of new accounts is disabled by default. To enable it, add an override to the
environment file at `/app/data/env` (see the package README for the full list of supported
overrides), then restart the app.

## Support

This package is not affiliated with the wger project. Report packaging issues at the package's
GitHub repository, and upstream application issues at the wger project itself.
