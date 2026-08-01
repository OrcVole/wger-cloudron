# Package-owned Django settings module for the wger Cloudron package. Imports the upstream
# image's settings unchanged, then applies the one override the platform integration needs.
# This file lives in the package's own adaptation layer (/app/code/pysettings), never in the
# application tree; DJANGO_SETTINGS_MODULE and PYTHONPATH select it (see the Dockerfile ENV
# block and start.sh).

from settings.main import *  # noqa: F401,F403

# Cloudron SSO: a user arriving through the oidc addon's callback has already authenticated
# against the Cloudron, whose own user management decides who may reach this app at all. The
# public-registration toggle (ALLOW_REGISTRATION, default False in this package) must
# therefore not close social signup: wger has no social adapter of its own, and allauth's
# default delegates signup-openness to the account adapter, which in wger returns
# ALLOW_REGISTRATION, so the first SSO login of every Cloudron user ended on allauth's
# "Sign Up Closed" page (observed live 2026-08-01). Form-based registration stays governed
# by ALLOW_REGISTRATION through wger's own account adapter.
SOCIALACCOUNT_ADAPTER = 'cloudron_adapters.CloudronSocialAccountAdapter'
