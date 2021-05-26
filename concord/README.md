# Concord Helm Chart

This is the official Helm chart for [Concord][1]. Concord is the orchestration engine that connects different systems together using scenarios and plugins created by users.

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

[1]: https://concord.walmartlabs.com/
