<upstream>2.7</upstream>

# wger

wger (pronounced "ˈvɛɡɐ") is a free, open source workout, fitness and nutrition manager. It
covers the whole training loop: build routines, log workouts, track body weight and
measurements, and plan meals against a searchable ingredient and nutrition database that
includes barcode scanning. A gym management mode lets a trainer administer members, assign
routines and record progress on their behalf.

The official wger mobile apps (Android and iOS) work with this package, including Android
without Google services, such as LineageOS or GrapheneOS, using the app from F-Droid. The apps
sync through PowerSync, which the package includes and serves on the app's own address, so a
phone needs only the server address. A REST API ships alongside the web application.

This package runs wger's own gunicorn application server together with its Celery worker and
beat scheduler under supervisor, fronted by nginx. Its database is a PostgreSQL server inside the
app, because the mobile apps' sync needs a database feature (logical replication) that the
Cloudron PostgreSQL addon does not offer. Backups carry a consistent copy of that database, and
restoring a backup returns it to the backup's contents. It uses the Cloudron Redis addon for its
cache and queue, and the Cloudron email addon to relay outgoing mail (password resets,
notifications). Uploaded media (exercise images, custom photos) is stored in the app's persistent
data directory, not in the container image.

wger's exercise database can synchronise weekly from the public wger.de instance to pick up new
exercises, images and translations; this is on by default and configurable. Ingredient
synchronisation against wger.de is off by default, because the ingredient dataset is large and
grows the database considerably; it can be turned on if wanted.

PowerSync is licensed under the Functional Source License (FSL-1.1-ALv2), which becomes Apache
2.0 two years after each release; wger itself is AGPL-3.0.
