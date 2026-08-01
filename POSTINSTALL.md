## First login

The initial administrator account is:

- Username: `admin`
- Password: randomly generated at first start and written to
  `/app/data/.secrets/admin-password`

Read the password using the Cloudron file manager, or open the web terminal for this app and
run:

```
cat /app/data/.secrets/admin-password
```

Change the administrator password after first login.

## Registration

Self-registration of new accounts is disabled by default. To enable it, add an override to the
environment file at `/app/data/env` (see the package README for the full list of supported
overrides), then restart the app.

## Support

This package is not affiliated with the wger project. Report packaging issues at the package's
GitHub repository, and upstream application issues at the wger project itself.
