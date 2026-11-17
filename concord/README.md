# Concord Helm Chart

This is a Helm chart for [Concord][1]. Concord is the orchestration engine that connects different systems together using scenarios and plugins created by users.

## Usage

[Helm](https://helm.sh) must be installed to use the charts.
Please refer to Helm's [documentation](https://helm.sh/docs/) to get started.

Install a published chart from the public OCI registry (Helm 3.8 or newer):

```sh
helm install concord oci://ghcr.io/concord-workflow/concord-charts/concord --version 2.47.0
```

Chart 2.47.0 selects Concord 2.47.0. To install from a Git checkout:

```sh
helm install concord ./concord -f my-values.yaml
```

The former `https://concord-workflow.github.io/helm-charts` Helm repository is
unavailable. Use OCI packages or Git sources instead.

## Agent Pools

The chart installs the agent operator and its CRD. It does not create an AgentPool.
Supply an AgentPool or another agent deployment before submitting processes.

The legacy `agentImageName`, `agentImageOverride`, and `dind` values have no
consumer in the chart templates. Configure agent images, tokens and DinD in your
external AgentPool. See [the upgrade instructions](UPGRADING.md) and the complete
[test/agentpool-2.47.0.yaml](test/agentpool-2.47.0.yaml) fixture. It requires
`SERVER_API_KEY` from the agent pod environment.

## Running EKS with IRSA

IAM roles for service accounts (IRSA) are a great way to control the access to AWS services for a given pod in your Kubernetes cluster. It is not uncommon for many EKS clusters to have worker nodes with roles that have wide ranging access to AWS which generally is not a good idea. It's much better to limit a specific pod to a specific role which governs that specific pod's access to AWS services.

Let's look at a simple example where your Concord installation is only running processes that need to read data from S3. First we need to create an EKS cluster with OIDC enabled where we create a service account for Concord in the EKS cluster, and create an IAM role that governs the access the Concord service account has. Below is an example of a configuration where `eksctl` is instructed to create the `concord-sa` service account in the `concord` namespace of the cluster where the created role has the well known `AmazonS3ReadOnlyAccess` attached to it.

```
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: sierra0
  region: us-east-1
  version: "1.20"

iam:
  withOIDC: true
  serviceAccounts:
  - metadata:
      name: concord-sa
      namespace: concord
    attachPolicyARNs:
    - "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"

nodeGroups:
  - name: ng-1
    instanceType: m5.large
    desiredCapacity: 10
    volumeSize: 80
    ssh:
      publicKeyPath: ~/.ssh/ec2_id_rsa.pub    
```

Note that `eksctl` will create a role in IAM that looks something like `eksctl-sierra0-addon-iamsa-concord-sa-Role1-U1Y90I1RCZWB`. If you look in IAM you will see the attached `AmazonS3ReadOnlyAccess` policy.

Alternatively, if you already have an EKS cluster and you want Concord to work with IRSA you need to setup the OIDC provider for the cluster:

```
eksctl utils associate-iam-oidc-provider \
  --cluster sierra0 \
  --approve
```               

Then you can create the mapping between the Concord service account and the IAM role that will govern the access the Concord service account will have in AWS:

```
eksctl create iamserviceaccount \
  --name concord-sa \
  --namespace concord \
  --cluster sierra0 \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --approve
```  

At this point, you now have a cluster where you can deploy (or redeploy) Concord with IRSA enabled.

Using the Concord chart, all you have to do is specify the value of the `serviceAccount.name` field in your values to be the same as the name of the service account name you specify in the `eksctl` configuration and everything will be wired up for you automatically.

## External credentials

By default, the chart renders a `concord-server-credentials` Secret from the
`database.internal.password` (or `database.external.password`),
`server.adminToken` and `server.agentToken` values.

For a hardened installation, create the Secret outside of Helm and set
`server.existingSecret` to its name. The chart then renders no Secret at all:
the server Deployment, agent operator and internal PostgreSQL all read it.
Unless `agentOperator.tokenSecretName` selects a separate Secret, the operator
uses the external server Secret's `AGENT_TOKEN` key. For a separate operator
Secret, `agentOperator.tokenSecretKey` defaults to `CONCORD_API_TOKEN`; set it to
`AGENT_TOKEN` when that is the key in your Secret. A missing key or
Secret leaves the pods unready instead of silently falling back to rendered
credentials.

Required keys:

- `DB_PASSWORD`
- `SERVER_PASSWORD_BASE64`
- `SECRET_STORE_SALT_BASE64`
- `PROJECT_SECRET_SALT_BASE64`
- `ADMIN_TOKEN`
- `AGENT_TOKEN`

Conditional keys, referenced only when the corresponding feature is enabled:

- `LDAP_SYSTEM_PASSWORD` when `ldap.enabled` is true;
- `GITHUB_SECRET` when `github.enabled` is true;
- `GIT_OAUTH` when `git.oauth` is set.

The internal PostgreSQL Deployment reads `DB_PASSWORD` from the same Secret, so
`POSTGRES_PASSWORD` is never rendered into the `postgresql-config` ConfigMap.
Set `database.internal.image.ref` to a digest-pinned image (for example
`library/postgres@sha256:...`) to pin the database image immutably;
`database.internal.image.repository`/`tag` remain supported.

## Hardening values

- `agentOperator.tokenSecretName` and `agentOperator.tokenSecretKey` (default
  `CONCORD_API_TOKEN`): select a separate operator token Secret. An empty name
  uses `server.existingSecret` with key `AGENT_TOKEN` when set, otherwise the
  literal `server.agentToken` value.
- `agentOperator.rbac.clusterWide` (default `true`): keep the historical broad
  ClusterRole. Set to `false` for a release-scoped ServiceAccount, Role and
  RoleBinding in the release namespace, with explicit verbs for pods, ConfigMaps
  and AgentPools. No cluster-wide AgentPool access, events or pods/exec is granted.
  The operator watches only its `WATCH_NAMESPACE`. Separate namespaced releases
  can coexist in different namespaces; the chart's other fixed resource names
  still require one release per namespace.
- `expose.type: clusterIP`: render a plain ClusterIP `concord-server` Service.
- `expose.debug.enabled` (default `true`): include the server debug port 5005
  in the `concord-server` Service.
- `database.internal.serviceType` (default `NodePort`): Service type for the
  internal PostgreSQL Service.
- `database.storageClass`: storage class for the `postgresql-pvc` PVC.

## Pod security

`server`, `agentOperator`, and `database.internal` each accept Kubernetes
`podSecurityContext` and container `securityContext` maps. Both default to `{}`
and are omitted when empty. `server.postgresReady.securityContext` configures
the database init container separately. Enabled plugin init containers can set
`sidecars[].securityContext`.

Use [test/restricted-values.yaml](test/restricted-values.yaml) as the recommended
Linux restricted profile for the stock images:

```sh
helm template concord concord/ -f concord/test/restricted-values.yaml
```

The example uses non-root UID/GID 456 for the server, 65532 for the operator,
and 999 for PostgreSQL, `RuntimeDefault` seccomp, no privilege escalation, and
all capabilities dropped. The database init container inherits the server UID
and has its own capability/privilege settings. Check UID/GID and writable paths
for any image override. Plugin init containers need equivalent settings too.

Ensure the server temporary volume is writable by GID 456 and the PostgreSQL
data volume by UID/GID 999. `fsGroup` helps where the storage driver supports it;
it cannot repair an existing database owned by another UID. Back up and plan
volume ownership changes before enabling non-root PostgreSQL. A read-only root
filesystem is not required by the restricted standard and is not enabled in the
example. Enabling it needs writable mounts for server GC logs, Java temporary
files and PostgreSQL sockets in addition to the existing data/tmp volumes.

The operator calls the Kubernetes API and defaults to
`agentOperator.automountServiceAccountToken=true`. PostgreSQL defaults to
`database.internal.automountServiceAccountToken=false`. The server's
`automountServiceAccountToken` defaults to `null`: the chart renders `true` when
`security.clusterAdmin` is enabled,
and `false` otherwise. Set `server.automountServiceAccountToken=true` explicitly
for API-using plugins or RBAC configured outside this chart; explicit `false`
also overrides the automatic choice. Use YAML booleans or `null`; strings such as
`"true"` (including `--set-string`) fail rendering. Secret and ConfigMap volume/env injection
does not require a pod API token. External AgentPools own their pod settings;
the test AgentPool disables token mounting. Enable it if process tasks call the API.
Cloud workload-identity projected tokens may be managed separately by admission webhooks.

`server.postgresReady.resources` defaults to requests of 10m CPU/16Mi memory and
limits of 100m CPU/64Mi memory. Override this map for your environment or use `null`
to omit it (Helm merges an empty map with the defaults).

Do not enforce baseline/restricted PSA on a namespace containing privileged DinD
agents without planning exceptions or separate namespaces. This profile covers
the chart Deployments; it does not harden externally managed agent pods.

## NetworkPolicy

Set `networkPolicy.enabled=true` to isolate ingress to the internal server and
PostgreSQL pods. It defaults to `false`; no policy is rendered when disabled.
Your cluster network must enforce Kubernetes NetworkPolicy.

The PostgreSQL policy is rendered only when both the server and database are
internal. With `server.type=external`, this chart leaves database policy to the
database owner, so it cannot block the external database client by selecting absent
server pods. Configure your own database ingress policy for that topology.

PostgreSQL accepts TCP on `database.internal.port` only from pods labelled
`app: concord-server` in the release namespace. The server accepts TCP 8001 from
its replicas, the enabled chart operator, and `networkPolicy.server.agentPeers`.
The default agent peer matches the upstream AgentPool template's
`app: agentpools.concord.walmartlabs.com` label in the release namespace.
Check your external AgentPool labels and namespaces before enabling the policy.
Replace `agentPeers` for custom agents, and include a `namespaceSelector` in each
peer for agents in other namespaces. AgentPool pods are not managed by this chart.

Add ingress controllers and monitoring clients to
`networkPolicy.server.ingressPeers`, for example:

```yaml
networkPolicy:
  enabled: true
  server:
    ingressPeers:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ingress-system
        podSelector:
          matchLabels:
            app.kubernetes.io/name: ingress-controller
```

Both selectors in one peer mean namespace AND pod labels. Separate peers mean OR.
An empty peer (`{}`) allows every source; use explicit selectors.
Only TCP 8001 is allowed to the server, including HTTP, WebSockets and metrics.
The debug port is blocked even if its Service port is enabled.
The policy does not authenticate endpoints or protect `/metrics` from allowed peers.
Policies for external servers or databases are the external owner's responsibility.

For `expose.type=nodePort` or `loadBalancer`, callers can arrive with an external
or node source address. Pod selectors may not match these connections. Add an
`ipBlock` peer for the approved client CIDR, for example (documentation range):

```yaml
networkPolicy:
  enabled: true
  server:
    ingressPeers:
      - ipBlock:
          cidr: 192.0.2.0/24
```

Whether the policy sees the original client or a translated source depends on
the CNI, load balancer and Service routing. Validate the source actually seen by
your network plugin and allow only the required CIDRs. Traffic from local node
processes or host-networked proxies can bypass pod policy isolation; an `ipBlock`
is not a substitute for perimeter access controls.

The chart does not restrict egress or select operator/agent pods for ingress
isolation. DNS, repositories, identity providers, database connections and the
Kubernetes API remain reachable unless another policy restricts them. Kubernetes
policies are additive: another allow policy can widen access. Node traffic,
host-networked proxies and Service address translation depend on the network
implementation; validate actual ingress paths in an isolated environment.

## CORS and the Server header

`server.cors.allowOrigin` optionally sets Concord 2.47.0's
`concord-server.server.cors.allowOrigin`. Its default `null` omits the setting and
preserves Concord's `*` default. To restrict browser access to a single origin:

```yaml
server:
  cors:
    allowOrigin: https://console.example.com
```

Use one origin (scheme, host, optional port), without a path or trailing slash.
Concord emits this fixed value on `/api/*` and `/forms/*`, including OPTIONS
responses; it does not parse an allow-list or reflect matching request origins.
Methods remain `*`, the allowed headers remain fixed, and credentials are not
enabled. This setting controls browser CORS checks, not server authentication or
non-browser access. Check cross-origin consoles and forms before changing it.

Concord 2.47.0 does not expose a setting for Jetty's `Server` response header.
No chart value is provided for an unsupported server feature. A core change
would add a configuration flag and pass it to `HttpConfiguration.setSendServerVersion`,
with response tests covering successful requests and errors. After that feature
is released, the chart can expose it.

Release source: [CORS configuration](https://github.com/walmartlabs/concord/blob/2.47.0/server/impl/src/main/java/com/walmartlabs/concord/server/cfg/ServerConfiguration.java),
[CORS filter](https://github.com/walmartlabs/concord/blob/2.47.0/server/impl/src/main/java/com/walmartlabs/concord/server/boot/filters/CORSFilter.java),
and [HTTP transport](https://github.com/walmartlabs/concord/blob/2.47.0/server/impl/src/main/java/com/walmartlabs/concord/server/boot/HttpServer.java).

## WebSockets

Concord 2.45.0 requires the `agentWebsocket` permission for agent WebSocket
connections (see the Concord 2.45.0 changelog). The chart renders
`websockets.requirePermission` from `server.websocketsRequirePermission`,
defaulting to `false` to preserve the pre-2.45 behavior. Set it to `true` once
your agent users were granted the `agentWebsocket` permission.

## OCI packages and Git sources

Tagged pushes build an OCI chart package in
`ghcr.io/concord-workflow/concord-charts/concord`. Public packages can be pulled
anonymously; no `helm registry login` is required. You can also use a published
Git tag:

```sh
git clone --branch 2.47.0 --depth 1 https://github.com/concord-workflow/concord-charts.git
helm upgrade --install concord concord-charts/concord -f my-values.yaml
```

[1]: https://concord.walmartlabs.com/
[2]: https://aws.amazon.com/blogs/opensource/introducing-fine-grained-iam-roles-service-accounts/
