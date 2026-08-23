`<upstream>`2.6</upstream>

# wger

wger (pronounced "ˈvɛɡɐ") is a free, open source workout, fitness and nutrition manager. It
covers the whole training loop: build routines, log workouts, track body weight and
measurements, and plan meals against a searchable ingredient and nutrition database that
includes barcode scanning. A gym management mode lets a trainer administer members, assign
routines and record progress on their behalf.

A REST API ships alongside the web application and is the same API used by the official wger
mobile apps (Android and iOS), so the app installed from this package can be used from a phone
as well as a browser.

This package runs wger's own gunicorn application server together with its Celery worker and
beat scheduler under supervisor, fronted by nginx. It uses the Cloudron PostgreSQL and Redis
addons for its database and cache/queue, and the Cloudron email addon to relay outgoing mail
(password resets, notifications). Uploaded media (exercise images, custom photos) is stored in
the app's persistent data directory, not in the container image.

wger's exercise database can synchronise weekly from the public wger.de instance to pick up new
exercises, images and translations; this is on by default and configurable. Ingredient
synchronisation against wger.de is off by default, because the ingredient dataset is large and
grows the database considerably; it can be turned on if wanted.

Not included in this package version: PowerSync, the component upstream uses for offline
synchronisation in the mobile apps. Online use of the web application and the mobile apps is
expected to work fully; offline mobile sync is the one feature this package does not provide.
