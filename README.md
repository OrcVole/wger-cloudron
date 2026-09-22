# wger for Cloudron

A Cloudron package for [wger](https://github.com/wger-project/wger), a free, open source
workout, fitness and nutrition manager. Documentation for the upstream application is at
[wger.readthedocs.io](https://wger.readthedocs.io).

This repository is not affiliated with the wger project. It packages the upstream application
for the Cloudron platform; application behaviour, features and bugs belong upstream.

## Licence

The wger application is licensed AGPL-3.0. This package mirrors that licence in `LICENSE`
(fetched verbatim from the upstream repository at the pinned tag). The packaging code in this
repository (Dockerfile, start scripts, configuration) is offered under the same terms unless
stated otherwise.

## Installing

```bash
cloudron install --appstore-id io.github.orcvole.wger
```

Once this package is published, it will be available through the versions-url channel used by
this repository. Installation details (channel URL, `cloudron install` invocation) will be added
here once the package has a published version.

## Architecture

The package runs several processes under supervisor, all logging to stdout:

| Process | Role |
|---|---|
| nginx | Binds the app's HTTP port, serves `/static/` and `/media/` directly, proxies everything else to gunicorn, answers the health check immediately |
| gunicorn | The Django application server |
| celery worker | Background jobs: exercise/ingredient sync, email, scheduled tasks |
| celery beat | Schedules the periodic Celery jobs |

State and services:

- PostgreSQL, Redis (cache and Celery broker/backend) and outgoing email are provided by
  Cloudron addons, not bundled in the image.
- Uploaded media lives under `/app/data/media` and is backed up with the rest of `/app/data`.
- Static assets are derived data, baked into the image by `collectstatic` at build time and
  served read-only; they change exactly when the image changes and are deliberately not
  persisted or backed up.

## Single sign-on

The package integrates Cloudron user management through the `oidc` addon and wger's bundled
django-allauth. The login page offers a "Sign in with ..." button carrying the Cloudron's
configured display name, and a wger account is provisioned automatically on first sign-in.
Public self-registration stays disabled independently of this: the Cloudron's own user and
group access control decides who can reach the app. Installing without user management is
supported (`optionalSso`); the app then uses purely local accounts, and no stale login button
is left behind.

## What is deliberately not included

PowerSync, the synchronisation service used by the official mobile apps, is not part of this
package. **The mobile apps require it from version 2.0 onward**: that release made the app
offline-first, and against a server without PowerSync it stops after sign-in and reports that the
sync service is unreachable. The wger versions this package ships refuse app versions older than
2.0, so an older app is not a workaround.

Until this package includes PowerSync, use the web application, which works in a phone's
browser, or the REST API. The web application and API are not affected.

PowerSync needs PostgreSQL logical replication, which the Cloudron PostgreSQL addon does not
provide to apps, so adding it is a larger change than adding a process. It is being worked on.

## Backup and restore

All persistent application state lives either in a Cloudron addon (PostgreSQL, Redis) or under
`/app/data` (uploaded media, seeded secrets, the operator environment override file). Cloudron's
standard backup, covering the addons and `/app/data` together, is sufficient; there is no
additional external state to capture.

## Further documentation

- [docs/PACKAGING-NOTES.md](docs/PACKAGING-NOTES.md): the verified-versus-assumed log for this
  package, newest entry first.
- [docs/FOR-CLOUDRON.md](docs/FOR-CLOUDRON.md): notes intended for the Cloudron project.
- [docs/FOR-UPSTREAM.md](docs/FOR-UPSTREAM.md): notes intended for the wger project.
- [AGENTS.md](AGENTS.md): the settled-decisions working contract for this package.
- [docs/decisions/](docs/decisions/): architecture decision records.
