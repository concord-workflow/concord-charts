# Concord Helm Chart

This is a Helm chart for [Concord][1]. Concord is the orchestration engine that connects different systems together using scenarios and plugins created by users.

## Usage

[Helm](https://helm.sh) must be installed to use the charts.
Please refer to Helm's [documentation](https://helm.sh/docs/) to get started.

Install a published chart from the public OCI registry (Helm 3.8 or newer):

```sh
helm install concord oci://ghcr.io/concord-workflow/concord-charts/concord --version 1.40.0
```

Chart 1.40.0 is the latest published version and selects Concord 2.13.0.
After chart 2.47.0 is published, use `--version 2.47.0` for Concord 2.47.0.
To test these changes before publication, install from this Git checkout:

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
Git tag. After the 2.47.0 tag is published:

```sh
git clone --branch 2.47.0 --depth 1 https://github.com/concord-workflow/concord-charts.git
helm upgrade --install concord concord-charts/concord -f my-values.yaml
```

[1]: https://concord.walmartlabs.com/
[2]: https://aws.amazon.com/blogs/opensource/introducing-fine-grained-iam-roles-service-accounts/
