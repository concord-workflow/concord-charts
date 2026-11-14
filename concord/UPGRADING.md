# Upgrade to Concord 2.47.0

The chart selects `walmartlabs/concord-server:2.47.0` and
`walmartlabs/concord-agent-operator:2.47.0`. Explicit image overrides take precedence.
Update external agents to `walmartlabs/concord-agent:2.47.0` separately.
The console and database migrations use the server image.

## Check the installation

The latest published chart is 1.40.0, which selects Concord 2.13.0.
Unreleased main declared 1.101.0 while selecting images 2.15.0; it is not the
published starting point.
Read the deployed images and saved values before an upgrade.
The chart creates no AgentPool. Users must supply agents separately.

Back up the database and test restoration before the upgrade.
Preserve `SERVER_PASSWORD_BASE64`, `SECRET_STORE_SALT_BASE64`, and
`PROJECT_SECRET_SALT_BASE64`. Preserve configured initial API token values.
Changing encryption values can prevent decryption of existing secrets.

## Reuse saved values with new chart defaults

Do not use `helm upgrade --reuse-values` for this upgrade. It can omit newly
introduced nested defaults and fail during rendering. Export only your saved
user overrides and pass them to the new chart, so its new defaults are included:

```sh
helm get values <release> -n <namespace> -o yaml > saved-values.yaml
helm upgrade <release> ./concord -n <namespace> -f saved-values.yaml
```

Keep that file private if it includes credentials. With Helm 3.14 or newer,
`--reset-then-reuse-values` is another option. Do not combine it with
`--reuse-values` or `--reset-values`, which override that behavior.

## PostgreSQL

The internal database default remains `library/postgres:10.6` to preserve existing installations.
This preserves the chart value; it does not establish PostgreSQL 10 compatibility with Concord 2.47.0.
PostgreSQL 18.6 is an explicit opt-in through `database.internal.image.tag` or `image.ref`.
The secure test values explicitly select a PostgreSQL 18.6 digest.
Changing the image does not convert existing database files.
Do not start PostgreSQL 18 with an unconverted PostgreSQL 10 data directory.
Use a tested dump/restore or `pg_upgrade` procedure before changing the image.
Use a new volume for dump/restore. Keep the old volume for recovery.
The chart mounts `/concord/postgresql` and sets `PGDATA=/concord/postgresql/data`.
Test this explicit layout during migration.

Concord 2.47.0 uses open-source jOOQ 3.21. Its
[support matrix](https://www.jooq.org/download/support-matrix) lists PostgreSQL 18.
Concord source tests also use PostgreSQL 14 and 15. They do not establish a
production support range for all application queries. Test migrations and process
execution on PostgreSQL 18 before production use.
PostgreSQL 10 is unsupported. PostgreSQL 14 support ended on 2026-11-12.
See the [PostgreSQL version policy](https://www.postgresql.org/support/versioning/).

The server applies Liquibase migrations during startup. A separate operation can use
`CONCORD_COMMAND=migrateDb` with the same image and configuration.
Versions 2.46.0 and 2.47.0 add no database changelog resources after 2.45.0.
An upgrade from published chart 1.40.0 / Concord 2.13.0 includes migrations through 2.45.0.
An actual 1.101.0 installation also needs the earlier schema and secret association changes.
Test a restored database with its existing Liquibase checksums.
An image rollback does not reverse migrations or PostgreSQL data conversion.
Check extension privileges when the database user has restricted permissions.

### Internal PostgreSQL rollout strategy

The internal PostgreSQL Deployment now uses `Recreate`. During an upgrade,
Kubernetes stops the old database pod before starting its replacement, so two
PostgreSQL servers do not open the same data directory. Plan database downtime
and drain application connections before upgrading. PostgreSQL 10.6 uses a smart
shutdown on SIGTERM; active connections can outlast the pod termination grace
period and force crash recovery even with this strategy.

A release installed with Helm 4 server-side apply can reject this strategy switch:
`spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy type is 'Recreate'`.
Choose one of these one-time workarounds for the upgrade:

1. Use client-side apply for this upgrade:

   ```sh
   helm upgrade <release> ./concord -n <namespace> -f saved-values.yaml --server-side=false
   ```

2. Before upgrading, switch the existing Deployment with one JSON patch, then run
   the normal upgrade. The patch can restart PostgreSQL; use a maintenance window.

   ```sh
   kubectl -n <namespace> patch deployment postgresql --type=json \
     -p '[{"op":"remove","path":"/spec/strategy/rollingUpdate"},{"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'
   helm upgrade <release> ./concord -n <namespace> -f saved-values.yaml
   ```

Setting `rollingUpdate: null` in the chart is insufficient for this Helm 4 case.

## RBAC and operator credentials

Compared with published chart 1.40.0, this chart adds optional namespaced operator
RBAC and externally managed credentials. Set `agentOperator.rbac.clusterWide=false`
for a release-scoped ServiceAccount, Role and RoleBinding with explicit verbs.
The operator watches its release namespace only. The default cluster-wide mode
retains its historical permissions and object names.

For external credentials, see [External credentials](README.md#external-credentials).
Custom plugins that call Kubernetes must manage their own minimal RBAC separately.
Concord 2.47.0 has no built-in Kubernetes process dispatcher.

## Plugins and application configuration

Rebuild every enabled external server plugin against Concord 2.47.0.
This includes plugin sidecars such as Mica. The server uses RESTEasy 7,
Jakarta APIs, and Jetty ee10. Old `javax.validation` or `javax.annotation.Priority`
annotations can silently lose validation or ordering behavior.
Do not replace all `javax` imports: `javax.inject` and `javax.sql` remain in use.

The release images use JDK 25. Java 17 is unsupported.
Compiler release 21 supports downstream consumers; it does not validate custom Java 21 images.
Keep the release entrypoints. Preserve writable temporary files, logs, payloads,
and dependency caches for the server and agent user (UID/GID 456).
A read-only root filesystem needs writable volumes at the configured paths.

HTTP port 8001, readiness path `/api/v1/server/ping`, and WebSocket path `/websocket` remain unchanged.
The console uses `console.cfgFile=/opt/concord/console/cfg.js`.
The old `BASE_RESOURCE_PATH` setting does not configure the current console.

Keep `server.websocketsRequirePermission=false` during the initial upgrade unless
agent permissions are prepared. The application default is `true`.
Grant `agentWebsocket` to each applicable agent user before enabling the check.
The migration grants this permission to `concordAdmin`, not to every custom role.
A valid token remains necessary when the permission check is disabled.

GitHub webhooks need `github.enabled=true` and a nonempty signing secret.
Set `github.secret` for chart-managed credentials. With `server.existingSecret`,
supply its `GITHUB_SECRET` key instead.
GitHub App authentication is separate from webhook handling.
Git OAuth remains supported but deprecated. The server reads `GIT_OAUTH` from its
credentials Secret when `git.oauth` is configured.

Review the [application changelog](https://github.com/walmartlabs/concord/blob/2.47.0/CHANGELOG.md)
for earlier changes. These include plugin configuration packages, runtime APIs,
removed client1 and old endpoints, and OIDC serialization changes.
Old suspended processes with OIDC initiators can fail to resume after the 2.33.0 change.
Version 2.45.0 restricts template URI schemes and deletes earlier checkpoints when
the runtime user changes. Version 2.46.0 adds decryption and trigger access checks.
Archive limits can reject large payloads. Test representative flows before the upgrade.

## Private ingress

Set `expose.ingress.className` to select an installed Ingress controller explicitly.
For Tailscale HTTPS ingress, set `expose.type=ingress` and the class to `tailscale`.
Set `expose.ingress.host` to the service's full tailnet DNS name.
Keep `expose.tls.enabled=true`. Set `expose.tls.secretName` to an empty string
when the controller provides its own certificate.
Do not enable Tailscale Funnel for a private deployment.
The chart does not install the Tailscale operator or configure tailnet access rules.

## External AgentPools

Update each AgentPool image explicitly. Operator upgrades do not rewrite its image fields.
Supply `SERVER_API_KEY` through an agent pod `secretKeyRef`.
Use the token expected by the server. `agentOperator.tokenSecretName` supplies only
the operator token. It does not supply credentials to agent pods.
Mount GitHub App key Secrets on agent pods if their configuration uses those keys.
The chart supplies that mount only on the server.

The CRD matches Concord 2.47.0. Compared with the old main chart, it removes the
`autoScaleStrategy` schema property and changes `queueSelector` preservation.
The operator Java class still contains `autoScaleStrategy`; inspect existing resources.
Helm does not update an existing CRD during an ordinary chart upgrade.
Apply the approved CRD update before resources that require its schema.
Do not delete the CRD to force replacement; that can delete AgentPools.

Use `test/agentpool-2.47.0.yaml` only in an isolated test namespace.
Create its `concord-agent-token` Secret outside Helm with key `SERVER_API_KEY`.
The fixture uses privileged DinD and shared `/tmp` storage.
Choose and pin a DinD image before applying it. Replace `DIND_IMAGE` in the fixture.
Use the same absolute process paths in the agent and DinD containers.
The chart's legacy `dind` and agent image values remain unused.

## Optional pod hardening and token mounts

Pod and container security contexts remain empty by default. To opt in, review
[test/restricted-values.yaml](test/restricted-values.yaml), storage ownership and
any custom images or plugin init containers before setting the contexts.
Do not use namespace PSA enforcement for privileged DinD agents without exceptions.

The ordinary server and internal PostgreSQL pods now disable automatic API token
mounting. The operator retains its token. The cluster-admin option
automatically retains the server token. If an external RoleBinding or
plugin requires Kubernetes credentials, set `server.automountServiceAccountToken=true`
before upgrading. Explicit token overrides take precedence over automatic behavior.
`postgres-ready` now has small resource requests and limits; tune
`server.postgresReady.resources` if needed. See [Pod security](README.md#pod-security).

## Optional ingress isolation

NetworkPolicy is off by default. Before setting `networkPolicy.enabled=true`,
check your network plugin's enforcement and inventory every server caller.
Configure `networkPolicy.server.agentPeers` for your AgentPools and
`networkPolicy.server.ingressPeers` for ingress controllers and monitoring.
Use stable namespace and pod labels together in each cross-namespace peer.
The enabled policy allows only TCP 8001 to the server and only server pods to
internal PostgreSQL when the server is also internal. With an external server,
the chart omits the PostgreSQL policy; provide your own database ingress rules.
For NodePort/LoadBalancer exposure, configure approved source CIDRs with `ipBlock`
and verify source-address translation for your network plugin. Database administration from other pods and remote debug
connections will be blocked. Egress is unchanged. See [NetworkPolicy](README.md#networkpolicy).

## Optional CORS origin

`server.cors.allowOrigin` defaults to `null` and leaves Concord's wildcard origin
unchanged. Set a single browser origin to restrict cross-origin consoles and forms.
Test their API and OPTIONS requests before upgrading with that value.
Concord 2.47.0 cannot configure Jetty's `Server` header; suppressing it needs a core
change and a later release. See [CORS](README.md#cors-and-the-server-header).

## Validation

Install Python 3 and PyYAML (`python3 -m pip install PyYAML==6.0.3`) for structural render assertions.
Run `helm lint concord/`, `concord/test/render-secure.sh`, and `concord/test/render-upgrade.sh`.
Run `concord/test/check-version.sh` with the release tag before packaging.
The release tag must match the chart version; `appVersion` must match the default
Concord image version. Chart-only fixes can increment the chart version without
requiring a new Concord image.
Test a fresh PostgreSQL 18 database and restored databases from supported source versions.
Check console configuration, agent authentication, flows, forms, logs, suspension,
resumption, Docker tasks, scaling, and enabled server plugins.
Use finite test deadlines. The legacy kind helpers contain unbounded waits and assume
an AgentPool that the chart does not create. Do not run them unattended.
