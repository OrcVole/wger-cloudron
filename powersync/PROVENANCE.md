# Vendored PowerSync configuration

`upstream/powersync.yaml` and `upstream/sync_rules.yaml` are copied **unchanged** from
[wger-project/docker](https://github.com/wger-project/docker) `services/config-powersync/` at commit
`c2e67393c04774184ee1e2b02181e35484c2ba5b` (fetched 2026-09-23, current with wger server 2.7).

What the package ships:

| File | Relation to upstream |
|---|---|
| `sync_rules.yaml` | identical to `upstream/sync_rules.yaml` |
| `powersync.yaml` | upstream's, with **one** change: `telemetry.prometheus_port: 9090` removed, so no metrics port is opened inside the container |

Re-vendor at every upstream wger version bump: replace `upstream/`, re-apply the one change, and
diff. The sync rules must match the server's `powersync` publication (core migration 0027), and a
changed rules file needs a PowerSync restart to take effect.

Upstream's compose runs `journeyapps/powersync-service:latest` with no pin. This package pins
**1.26.1** by digest in the Dockerfile.
