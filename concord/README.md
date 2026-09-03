# Concord Helm Chart

This is a Helm chart for [Concord][1]. Concord is the orchestration engine that connects different systems together using scenarios and plugins created by users.

## Usage

[Helm](https://helm.sh) must be installed to use the charts.
Please refer to Helm's [documentation](https://helm.sh/docs/) to get started.

Once Helm is set up properly, add the repo as follows:

```sh
helm repo add concord https://concord-workflow.github.io/helm-charts
```

To install a release named concord, run:

```sh
helm install concord concord/concord
```

## Agent Pools

For reasonable, out of the box utility, an autoscaling agent pool is enabled by default with a minimum size of one, and a maximum size of 10. The number of agents autoscale based on the number of processes waiting in the queue.

The default autoscaling agent pool will likely cover most use cases, but you are free to create as many agent pools as you wish, each with different configurations and capabilities.

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
the server Deployment, the agent operator Deployment (when
`agentOperator.tokenSecretName` points at the same Secret) and the internal
PostgreSQL Deployment all read their credentials from it. A missing key or
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
  `CONCORD_API_TOKEN`): read the operator's API token from a Secret instead of
  the literal `server.agentToken` value.
- `agentOperator.rbac.clusterWide` (default `true`): keep the historical broad
  ClusterRole. Set to `false` to render a namespaced `concord-agent-operator`
  Role (pods, events, ConfigMaps, pods/exec and AgentPools) plus a cluster-wide
  `concord-agent-operator-agentpool-watch` ClusterRole limited to get, list and
  watch on AgentPools.
- `server.kubernetesDispatcherRbac.enabled` (default `false`): render a
  namespaced `concord-k8s-dispatcher` Role/RoleBinding allowing the server
  ServiceAccount to manage Secrets and Jobs for the Kubernetes process
  dispatcher.

## WebSockets

Concord 2.45.0 requires the `agentWebsocket` permission for agent WebSocket
connections (see the Concord 2.45.0 changelog). The chart renders
`websockets.requirePermission` from `server.websocketsRequirePermission`,
defaulting to `false` to preserve the pre-2.45 behavior. Set it to `true` once
your agent users were granted the `agentWebsocket` permission.

[1]: https://concord.walmartlabs.com/
[2]: https://aws.amazon.com/blogs/opensource/introducing-fine-grained-iam-roles-service-accounts/
