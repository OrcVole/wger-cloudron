# Gate evidence and debugging notes

Acceptance evidence for each package version, produced by the gate ladder (install and
first-run, auth, functional flows, update and restore, memory), newest version first. Every
row cites real evidence: a log line, a hash prefix, a row count, a cgroup counter. Recipes
are recorded so each gate is repeatable at the next version bump.

## Package 1.0.0 (wger 2.6)

Image under test, all gates:
`ghcr.io/orcvole/wger-cloudron@sha256:f8f79ef55d200e7b2ff561523bc4ebfb9f04d62495df07364d2338eec1d42a19`

Gate results are appended below as they resolve.

### Gate 0: install, health, first-run (PASS, 2026-08-01)

Recipe: uninstall any prior test app; `cloudron install --location <app>-test.<domain>
--image ghcr.io/orcvole/wger-cloudron@sha256:<digest>` (registry install by digest, 158 s to
green health); on the host, `docker inspect` the app container for Config.Image and its
image RepoDigests; `docker exec <cid> supervisorctl -c /app/code/supervisor/supervisord.conf
status`; `ls -ln` and `sha256sum` over `/app/data/.secrets/`; scan recent logs for
error-pattern lines and attribute each; `cloudron restart --app`, wait healthy, repeat the
hash and log-branch checks.

| Invariant | Proof | Verdict |
|---|---|---|
| digest | Config.Image and image RepoDigests both sha256:f8f79ef55d200e7b2ff561523bc4ebfb9f04d62495df07364d2338eec1d42a19, equal to the registry digest of the 2.6-1 tag | PASS |
| health | /healthcheck 200 immediately and again after restart; supervised set exactly as designed: nginx, gunicorn, celery-worker, celery-beat, fatal-exit all RUNNING, bootstrap EXITED (one-shot) | PASS |
| idle logs | 5 error-pattern lines in the last 200, every one platform-side (addon provisioning retry before the app existed, redis addon pidfile notice, task-JSON "error":null, a migration whose NAME contains "error", a restart-task 304 retry); none from the package | PASS |
| secrets | 4 files (secret-key, jwt-private, jwt-public, admin-password), mode 0600, owner 1000:1000; sha256 prefixes 71bf0a36, e331de3d, 6201f0b1, 5cb19e0a byte-identical across `cloudron restart`; second boot logs "secret material present" with no "seeding" lines | PASS |
| first-run | First boot: "database is empty ... first-run fixtures will be loaded", "Installed 3401 object(s) from 15 fixture(s)", admin password replaced (fixture-default detector), OIDC SocialApp SEEDED_CREATED; second boot: "database already has data: first-run fixtures will be skipped", SEEDED_UPDATED; landing page 200 | PASS |

Timings for the record: container start to backend serving 7 m 51 s on first run (migrations
with the faked core.0023 plus atomic fixtures, all behind the immediate-health shim); 2 m 03 s
on the restart boot (no-op migrate).
