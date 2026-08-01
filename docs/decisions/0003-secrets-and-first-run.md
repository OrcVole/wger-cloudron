# ADR 0003: secrets and first-run initialisation

Status: accepted, 2026-08-01.

## Context

wger needs three secrets: the Django `SECRET_KEY` (signs sessions and password-reset tokens),
an RS256 JWK keypair for the mobile API's JWTs, and an administrator password. Upstream ships
insecure defaults for all three (a known `SECRET_KEY`, a known JWK pair whose hashes the
application itself blacklists with a warning, and the fixture password `adminadmin`), and only
warns when they are used. Rotating `SECRET_KEY` logs every browser session out and voids
outstanding password-reset links; rotating the JWK pair logs every mobile session out. Neither
orphans stored data, but both are disruptive, so the seed-once rule applies in full.

## Decision

- All three live under `/app/data/.secrets/` (directory 0700, files 0600, ownership and mode
  re-asserted every boot because a restore drifts them).
- `SECRET_KEY`: generated once (`openssl rand`), only if absent, never reseeded.
- JWK pair: generated once at first run with upstream's own `generate-jwt-keys` mechanism so
  the format always matches what the application expects, stored as two files, exported into
  the environment at every boot, never logged.
- Administrator password: first run executes upstream's `wger bootstrap --no-process-static`
  against the empty database (migrations, fixtures, and the fixture admin account), then
  replaces the fixture password with a random one and writes it to
  `/app/data/.secrets/admin-password`, before the application server is started. Amended
  2026-08-01 at implementation review: the original wording said "before any listener exists",
  but the immediate-health shim requires nginx to bind within seconds of container start,
  ahead of first-run bootstrap (measured at roughly 17 seconds against a fresh database). The
  guarantee that matters survives intact in a weaker premise: nginx listens, but gunicorn is
  held down (supervisor `autostart=false`) until the bootstrap one-shot has already reset the
  password, so no request can reach a login surface while the fixture password exists; nginx
  returns 502 for everything except the health path during that window. The insecure value is
  therefore still never reachable over the network. A failed bootstrap shuts supervisord down
  (fail loud) rather than leaving nginx answering a green health check in front of a dead
  application. The file is the operator's read-once artefact, surfaced in the
  post-install message; changing the password in the application does not update the file, and
  the file is never re-written on later boots.
- First-run detection asks the database itself (a user count that treats a missing table as
  empty), not a marker file in `/app/data`, because the database lives in the addon and can be
  reset independently of the data directory; a marker file would then skip bootstrap against
  an empty database and the application would crash-loop on missing tables.
- Update and restore must both leave every secrets file byte-identical (sha256 compared), and
  the entrypoint must take the "existing secrets found" path. This is a standing gate.

## Consequences

A restore of `/app/data` alongside an intact addon database reproduces the working install
exactly. A restore of `/app/data` against an emptied addon database re-bootstraps the schema
and fixtures while keeping the old secrets, which is the correct direction: sessions survive
where possible, and nothing regenerates silently.
