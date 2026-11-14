#!/usr/bin/env bash
# Structural assertions require Python 3 and PyYAML.
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
helm template alpha "${CHART_DIR}" -n team-a --set agentOperator.rbac.clusterWide=false > "${WORK_DIR}/alpha.yaml"
helm template beta "${CHART_DIR}" -n team-b --set agentOperator.rbac.clusterWide=false > "${WORK_DIR}/beta.yaml"
helm template concord "${CHART_DIR}" --set server.existingSecret=my-creds > "${WORK_DIR}/external-secret.yaml"
helm template concord "${CHART_DIR}" --set server.existingSecret=my-creds \
  --set agentOperator.tokenSecretName=operator-creds --set agentOperator.tokenSecretKey=TOKEN > "${WORK_DIR}/operator-secret.yaml"
helm template concord "${CHART_DIR}" --set agentOperator.enabled=false > "${WORK_DIR}/disabled.yaml"
python3 - "${WORK_DIR}" <<'PY'
import sys
from pathlib import Path
import yaml
root = Path(sys.argv[1])

def expect(condition, message):
    if not condition:
        sys.exit('render-rbac: FAIL: ' + message)

def one(items, message):
    expect(len(items) == 1, message)
    return items[0]

def docs(name):
    return [d for d in yaml.safe_load_all((root / name).read_text()) if d]

def operator(data, context):
    return one([d for d in data if d.get('kind') == 'Deployment'
                and d.get('metadata', {}).get('name') == 'concord-agent-operator'],
               context + ': expected one operator Deployment')

def token(name):
    op = operator(docs(name), name)
    containers = op.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])
    container = one(containers, name + ': expected one operator container')
    return one([e for e in container.get('env', []) if e.get('name') == 'CONCORD_API_TOKEN'],
               name + ': expected one CONCORD_API_TOKEN environment entry')

expect(token('external-secret.yaml') == {'name': 'CONCORD_API_TOKEN', 'valueFrom': {
    'secretKeyRef': {'name': 'my-creds', 'key': 'AGENT_TOKEN'}}},
    'operator must inherit the external server Secret and AGENT_TOKEN key')
expect(not any(d.get('kind') == 'Secret' for d in docs('external-secret.yaml')),
       'external credentials must not render a chart-managed Secret')
expect(token('operator-secret.yaml').get('valueFrom', {}).get('secretKeyRef') == {'name': 'operator-creds', 'key': 'TOKEN'},
       'explicit operator Secret and key must override the server Secret')
expect(not any(d.get('kind') in {'Role', 'RoleBinding', 'ClusterRole', 'ClusterRoleBinding'} for d in docs('disabled.yaml')),
       'disabled operator must not render operator RBAC')
for release, namespace in [('alpha', 'team-a'), ('beta', 'team-b')]:
    data = docs(release + '.yaml')
    expect(not any(d.get('kind') in {'ClusterRole', 'ClusterRoleBinding'} for d in data),
           release + ': namespaced mode must not render cluster-wide RBAC')
    role = one([d for d in data if d.get('kind') == 'Role'], release + ': expected one operator Role')
    binding = one([d for d in data if d.get('kind') == 'RoleBinding'], release + ': expected one operator RoleBinding')
    name = release + '-concord-agent-operator'
    expect(role.get('metadata', {}).get('name') == binding.get('metadata', {}).get('name') == name,
           release + ': operator Role and RoleBinding names must be release-scoped')
    expect(role.get('metadata', {}).get('namespace') == binding.get('metadata', {}).get('namespace') == namespace,
           release + ': operator Role and RoleBinding must use the release namespace')
    expect(role.get('rules') == [
        {'apiGroups': [''], 'resources': ['pods'], 'verbs': ['get', 'list', 'watch', 'create', 'delete', 'patch']},
        {'apiGroups': [''], 'resources': ['configmaps'], 'verbs': ['get', 'list', 'create', 'delete']},
        {'apiGroups': ['concord.walmartlabs.com'], 'resources': ['agentpools'], 'verbs': ['get', 'list', 'watch']}],
        release + ': operator Role must contain only the expected least-privilege rules')
    expect(binding.get('roleRef') == {'apiGroup': 'rbac.authorization.k8s.io', 'kind': 'Role', 'name': name},
           release + ': operator RoleBinding must reference the release-scoped Role')
    expect(binding.get('subjects') == [{'kind': 'ServiceAccount', 'name': name, 'namespace': namespace}],
           release + ': operator RoleBinding must target the release-scoped ServiceAccount')
    expect(any(d.get('kind') == 'ServiceAccount' and d.get('metadata', {}).get('name') == name for d in data),
           release + ': release-scoped operator ServiceAccount is missing')
    op = operator(data, release)
    expect(op.get('spec', {}).get('template', {}).get('spec', {}).get('serviceAccountName') == name,
           release + ': operator Deployment must use the release-scoped ServiceAccount')
print('render-rbac: OK (namespaced least privilege, release names, token fallback/override)')
PY
