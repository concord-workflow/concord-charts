# Upgrade to Concord 2.47.0

The chart selects `walmartlabs/concord-server:2.47.0` and
`walmartlabs/concord-agent-operator:2.47.0`. Explicit image overrides take precedence.
Update external agents to `walmartlabs/concord-agent:2.47.0` separately.
The console and database migrations use the server image.

## Check the installation

The previous main chart declared 1.101.0, but its default images selected 2.15.0.
Read the deployed images and saved values before an upgrade.
The chart creates no AgentPool. Users must supply agents separately.

Back up the database and test restoration before the upgrade.
Preserve `SERVER_PASSWORD_BASE64`, `SECRET_STORE_SALT_BASE64`, and
`PROJECT_SECRET_SALT_BASE64`. Preserve configured initial API token values.
Changing encryption values can prevent decryption of existing secrets.

## PostgreSQL

The internal database default changes from PostgreSQL 10.6 to `library/postgres:18.6`.
This change is for new installations. It does not convert existing database files.
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
PostgreSQL 10 is unsupported. PostgreSQL 14 support ends on 2026-11-12.
See the [PostgreSQL version policy](https://www.postgresql.org/support/versioning/).

The server applies Liquibase migrations during startup. A separate operation can use
`CONCORD_COMMAND=migrateDb` with the same image and configuration.
Versions 2.46.0 and 2.47.0 add no database changelog resources after 2.45.0.
An upgrade from 2.15.0 includes migrations through 2.45.0.
An actual 1.101.0 installation also needs the earlier schema and secret association changes.
Test a restored database with its existing Liquibase checksums.
An image rollback does not reverse migrations or PostgreSQL data conversion.
Check extension privileges when the database user has restricted permissions.

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

## Validation

Run `helm lint concord/`, `concord/test/render-secure.sh`, and `concord/test/render-upgrade.sh`.
Run `concord/test/check-version.sh` with the release tag before packaging.
Test a fresh PostgreSQL 18 database and restored databases from supported source versions.
Check console configuration, agent authentication, flows, forms, logs, suspension,
resumption, Docker tasks, scaling, and enabled server plugins.
Use finite test deadlines. The legacy kind helpers contain unbounded waits and assume
an AgentPool that the chart does not create. Do not run them unattended.

STE review: sentence structure checked. Full dictionary compliance remains unverified.
