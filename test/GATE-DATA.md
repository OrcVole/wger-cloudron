# Gate data: how to put real records in, and count them

Gate 3 means the update is proven over real data: records the application stores, counted before the
update, after it, and after a restore. A health check, a sign-in page or a directory existing is not
data. Use at least three records of each kind you count; a count may grow across the update (the app
or a suite can add records), but a count that falls is data loss.

Every command names the Cloudron you are gating. `CLOUDRON_SERVER` is that Cloudron's API host (for
example `my.example.com`); `APP` is the install's location. Never rely on the CLI's default profile.

## wger

wger has no ingest suite. Run Django inside the app with the environment `start.sh` builds, putting the
exports inside the single-quoted command so values expand in the container and are never printed:

```bash
cloudron --server "$CLOUDRON_SERVER" exec --app "$APP" -- bash -c 'export PYTHONUSERBASE=/home/wger/.local PYTHONPATH=/app/code/pysettings:/home/wger/src DJANGO_SETTINGS_MODULE=cloudron_settings TIME_ZONE="${TIME_ZONE:-Etc/UTC}" DJANGO_DB_ENGINE=django.db.backends.postgresql DJANGO_DB_DATABASE="$CLOUDRON_POSTGRESQL_DATABASE" DJANGO_DB_USER="$CLOUDRON_POSTGRESQL_USERNAME" DJANGO_DB_PASSWORD="$CLOUDRON_POSTGRESQL_PASSWORD" DJANGO_DB_HOST="$CLOUDRON_POSTGRESQL_HOST" DJANGO_DB_PORT="$CLOUDRON_POSTGRESQL_PORT"; export SECRET_KEY="$(cat /app/data/.secrets/secret-key)" JWT_PRIVATE_KEY="$(cat /app/data/.secrets/jwt-private)" JWT_PUBLIC_KEY="$(cat /app/data/.secrets/jwt-public)"; cd /home/wger/src && gosu cloudron:cloudron python3 manage.py shell -c "<python>"'
```

Seed at least three body-weight entries and one workout session for a test user, then count them. From
2.7, weights live in `wger.measurements` and sessions carry `datetime_start`; compare each date after
localising to `TIME_ZONE`.

**Set `TIME_ZONE` explicitly, as above.** A `cloudron exec` shell does not inherit `start.sh`'s
environment, so without it Django falls back to upstream's `Europe/Berlin` and dates appear shifted
when they are not (measured 2026-09-14: the real upgrade keeps dates; the exec shell showed them a day
early).
