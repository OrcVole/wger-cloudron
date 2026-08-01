# ADR 0002: auth topology, app-native accounts, no proxyAuth, SSO as a tested option

Status: accepted, 2026-08-01.

## Context

wger serves two kinds of traffic on one origin: the human web application, and a JWT-secured
REST API (`/api/v2/`, plus `/allauth/` headless auth) that the official Android and iOS apps
depend on for their entire login flow. Upstream's own reverse-proxy authentication
documentation states that `/api/*` must remain reachable without a proxy authentication wall,
or API clients and the mobile apps break. wger has no native OIDC or LDAP integration, but it
ships django-allauth with the socialaccount framework, and its `WGER_SOCIAL_PROVIDERS`
environment variable adds arbitrary allauth provider applications, including in principle the
generic `openid_connect` provider.

## Decision

1. No `proxyAuth`, ever, at any path scope. The application's own session, token and JWT
   mechanisms protect every surface; unauthenticated API calls receive the application's own
   401, not a login redirect. This is a lifetime commitment of the package because `proxyAuth`
   cannot be retrofitted meaningfully onto an API the mobile app must reach.
2. Accounts are application-native. Self-registration and guest accounts are disabled by
   default by the package (operator-overridable), so a fresh install exposes a login page and
   nothing else. The administrator account is created at first run with a randomly generated
   password (ADR 0003).
3. Cloudron single sign-on is attempted as a bounded experiment: the `oidc` addon mapped into
   allauth's `openid_connect` provider, seeded idempotently at boot as a SocialApp
   configuration. It ships only if it passes the auth gate on a real install; otherwise the
   package documents plainly that Cloudron SSO is not available and why. The experiment's
   outcome, either way, is recorded in the packaging notes and offered upstream.

## Consequences

Operators manage users in wger, not in the Cloudron directory, unless the SSO experiment
lands. Brute-force protection relies on the application's django-axes defaults (enabled). The
health check path is served by the package nginx and needs no session. Nothing in this
topology blocks the mobile apps, integrations, or future upstream auth work.

## Amendment (2026-08-01): the SSO experiment landed

Verified end to end on a live installation (authorize, callback, automatic provisioning, a
logged-in session), so the manifest now declares the `oidc` addon with
`loginRedirectUri: /account/oidc/cloudron/login/callback/` (the application's REAL allauth
mount point, read from its URL resolver and confirmed against the live redirect; wger mounts
allauth at `/account`, singular) and `optionalSso: true`.

Two decisions the experiment forced, both recorded here because they are auth topology:

1. **SSO signup is open while form registration stays closed.** wger routes allauth's social
   signup-openness through the same toggle as public form registration
   (`ALLOW_REGISTRATION`, default off in this package), which blocked the first sign-in of
   every Cloudron user. The package ships a settings shim (`pysettings/cloudron_settings.py`,
   selected via `DJANGO_SETTINGS_MODULE`, importing upstream settings unchanged) whose only
   override is a social account adapter that accepts identities the platform has already
   authenticated. The platform's own user and group access control is the actual gate;
   public self-registration remains off independently.
2. **The login button carries the Cloudron's own display name**, because the SocialApp row is
   reconciled on every boot with `name` taken from `CLOUDRON_OIDC_PROVIDER_NAME`. Packages
   that hardcode a vendor name lose the operator's branding; this one follows the platform.

The reconciliation is bidirectional: installed without SSO (`optionalSso`), any previously
seeded SocialApp row is deleted so no dead login button survives a topology change.
