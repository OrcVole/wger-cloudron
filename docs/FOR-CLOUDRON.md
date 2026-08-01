# For the Cloudron project

Notes and findings from packaging wger that are relevant to the Cloudron platform or packaging
process itself, rather than to the wger application. All observed on Cloudron 9.2.0 with
CLI 8.3.1 during 2026-08.

## Adding an SSO addon to an existing `optionalSso` app does not provision it

An app first installed from a manifest without SSO fields keeps its install-time "no SSO"
state across `cloudron update`, even when the updated manifest adds the `oidc` addon: the
update succeeds but no `CLOUDRON_OIDC_*` variables are injected. The CLI offers `--no-sso`
at install time only; there is no update-time flag to opt in. A packager iterating on a test
install has to uninstall and reinstall to turn SSO on. An update-time flag (or a documented
dashboard path called out in the packaging docs) would save that cycle.

## `cloudron repair` cannot recover a source-built install whose upload was cleaned

An install that failed late (after "Building image", during DNS propagation) left the app in
`error (pending_install)`. `cloudron repair --app` then failed with ENOENT on the platform's
own copy of `source.tar.gz`, apparently cleaned up after the failed attempt, and `repair`
accepts no fresh source upload (only `--image`). The only recovery was uninstall and
reinstall. Either retaining the uploaded source while an app is in an error state, or letting
`repair` accept a source directory the way `update` does, would make failed installs
recoverable in place.

## Trailing-dot hosts: the proxy normalises Host but only the proxy could canonicalise

A browser session on the absolute-FQDN form of an app domain (`https://app.example.com.`,
trailing dot) breaks any cookie-dependent flow in Chromium-family browsers, which refuse to
store cookies for trailing-dot hosts; in a Django app this surfaces as a CSRF 403 on the
first POST (the Origin header keeps the dot while the Host header arrives normalised). The
platform's front proxy strips the trailing dot from Host before the app sees it, which means
the app CANNOT detect and canonical-redirect the dotted navigation itself (an in-container
nginx rule fires only for direct requests, verified live). The proxy is the one component
that still sees the dotted authority, so a 301 to the canonical host at the proxy would
spare every packaged app the failure mode. Low priority, but the failure is confusing when a
user lands on a dotted URL.

## Install-time dependency on `ipv6.api.cloudron.io`

The DNS propagation step of an install failed outright with "Unable to detect ipv6. API
server (ipv6.api.cloudron.io) unreachable" during what looked like a brief outage of that
endpoint. The identical install succeeded minutes later. A retry (or treating the ipv6 probe
as best-effort when the domain has no AAAA record) would keep a transient reachability blip
from failing an otherwise-finished install.
