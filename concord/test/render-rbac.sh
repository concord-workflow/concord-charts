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
def docs(name):
    return [d for d in yaml.safe_load_all((root / name).read_text()) if d]
def token(name):
    op = next(d for d in docs(name) if d['kind'] == 'Deployment' and d['metadata']['name'] == 'concord-agent-operator')
    return next(e for e in op['spec']['template']['spec']['containers'][0]['env'] if e['name'] == 'CONCORD_API_TOKEN')
assert token('external-secret.yaml') == {'name': 'CONCORD_API_TOKEN', 'valueFrom': {
    'secretKeyRef': {'name': 'my-creds', 'key': 'AGENT_TOKEN'}}}
assert not any(d['kind'] == 'Secret' for d in docs('external-secret.yaml'))
assert token('operator-secret.yaml')['valueFrom']['secretKeyRef'] == {'name': 'operator-creds', 'key': 'TOKEN'}
assert not any(d['kind'] in {'Role', 'RoleBinding', 'ClusterRole', 'ClusterRoleBinding'} for d in docs('disabled.yaml'))
for release, namespace in [('alpha', 'team-a'), ('beta', 'team-b')]:
    data = docs(release + '.yaml')
    assert not any(d['kind'] in {'ClusterRole', 'ClusterRoleBinding'} for d in data)
    role, = [d for d in data if d['kind'] == 'Role']
    binding, = [d for d in data if d['kind'] == 'RoleBinding']
    name = release + '-concord-agent-operator'
    assert role['metadata']['name'] == binding['metadata']['name'] == name
    assert role['metadata']['namespace'] == binding['metadata']['namespace'] == namespace
    assert role['rules'] == [
        {'apiGroups': [''], 'resources': ['pods'], 'verbs': ['get', 'list', 'watch', 'create', 'delete', 'patch']},
        {'apiGroups': [''], 'resources': ['configmaps'], 'verbs': ['get', 'list', 'create', 'delete']},
        {'apiGroups': ['concord.walmartlabs.com'], 'resources': ['agentpools'], 'verbs': ['get', 'list', 'watch']}]
    assert binding['roleRef'] == {'apiGroup': 'rbac.authorization.k8s.io', 'kind': 'Role', 'name': name}
    assert binding['subjects'] == [{'kind': 'ServiceAccount', 'name': name, 'namespace': namespace}]
    assert any(d['kind'] == 'ServiceAccount' and d['metadata']['name'] == name for d in data)
    op = next(d for d in data if d['kind'] == 'Deployment' and d['metadata']['name'] == 'concord-agent-operator')
    assert op['spec']['template']['spec']['serviceAccountName'] == name
print('render-rbac: OK (namespaced least privilege, release names, token fallback/override)')
PY
