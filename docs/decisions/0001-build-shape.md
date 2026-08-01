# ADR 0001: build shape, copy the upstream tree onto the Cloudron base

Status: accepted, 2026-08-01.

## Context

wger 2.6 ships an official image, `docker.io/wger/server`, whose version tags are re-pushed on
every push to upstream's master branch, so only a digest reference is stable. The image is built
on ubuntu:24.04 with Python 3.12.3 and a `wger` user at uid 1000. The Cloudron base image is
also Ubuntu 24.04, with Python 3.12.3 and the `cloudron` user at uid 1000. The application
lives in two trees: `/home/wger/.local` (the pip user-site with all dependencies and console
scripts, about 662 MiB) and `/home/wger/src` (source, settings and node_modules, about 64 MiB).
Runtime paths that matter (media root, static root, database) are all overridable through
environment variables, and the image environment pins `PYTHONPATH=/home/wger/src` and
`DJANGO_SETTINGS_MODULE=settings.main`.

Building wger from source onto the base instead would repeat upstream's Node and sass static
pipeline inside our Dockerfile for no behavioural gain, and would build an artefact upstream
has never tested.

## Decision

Multi-stage Dockerfile. Stage one is `docker.io/wger/server` pinned by the digest resolved from
the 2.6 tag at packaging time (recorded in the Dockerfile beside the ARG). The final stage is
`cloudron/base:5.0.0` at the doctrine-pinned digest, copying `/home/wger/.local` and
`/home/wger/src` unchanged, at the same paths. The interpreter minors match exactly, the uid
matches, and glibc forward compatibility is not even needed. The base already provides libpq5,
the en_US.utf8 locale, gettext, tini and gosu (verified locally), so the runtime stage installs
no apt packages.

`manage.py collectstatic` runs at BUILD time (it needs no database, verified) into
`/app/code/static`, shipped read-only; the entrypoint sets `DJANGO_STATIC_ROOT` there and never
runs collectstatic at boot. Rationale, with measurements, in the packaging notes: 294 MiB of
derived files that change exactly when the image changes.

`PYTHONUSERBASE=/home/wger/.local` is exported at runtime so the user-site resolves regardless
of HOME, which Cloudron moves to the data directory.

Build gates in the Dockerfile: `python3 -c "import django, wger"` under the runtime
environment, and a `manage.py check` invocation with placeholder settings, so an incompatible
copy fails the build rather than the first boot.

## Consequences

The package inherits upstream's exact dependency set and its security posture; a package
revision is a digest bump plus rebuild. The `/home/wger` path survives in the image (it is
baked into console-script shebangs and the image environment); the Cloudron filesystem contract
is untouched because both trees are read-only at runtime. If a future upstream image moves the
trees or changes the Python minor away from the base's, this ADR is the first thing to revisit,
and the fallback is a from-source install onto the base (upstream's build steps are public).
