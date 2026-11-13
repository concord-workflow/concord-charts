#!/usr/bin/env bash
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
helm template concord "${CHART_DIR}" > "${WORK_DIR}/default.yaml"
helm template concord "${CHART_DIR}" -f "${CHART_DIR}/test/restricted-values.yaml" > "${WORK_DIR}/restricted.yaml"
helm template concord "${CHART_DIR}" --set security.clusterAdmin=true > "${WORK_DIR}/admin.yaml"
helm template concord "${CHART_DIR}" --set server.automountServiceAccountToken=true \
  --set database.internal.automountServiceAccountToken=true > "${WORK_DIR}/token.yaml"
helm template concord "${CHART_DIR}" --set security.clusterAdmin=true \
  --set server.automountServiceAccountToken=false > "${WORK_DIR}/no-token.yaml"
helm template concord "${CHART_DIR}" --set database.type=external --set agentOperator.enabled=false > "${WORK_DIR}/external.yaml"
helm template concord "${CHART_DIR}" --set server.postgresReady.resources.requests.cpu=25m \
  --set server.postgresReady.resources.limits.memory=128Mi > "${WORK_DIR}/resources.yaml"
helm template concord "${CHART_DIR}" --set server.postgresReady.resources=null > "${WORK_DIR}/no-resources.yaml"
# Reject string booleans instead of silently choosing the automatic default.
for invalid in true false 1 ''; do
  if helm template concord "${CHART_DIR}" --set-string server.automountServiceAccountToken="${invalid}" > /dev/null 2>&1; then
    echo "render-pod-security: FAIL: non-boolean token setting accepted: ${invalid}" >&2
    exit 1
  fi
done
helm template concord "${CHART_DIR}" --set server.automountServiceAccountToken=1 > "${WORK_DIR}/invalid-token.yaml" 2> "${WORK_DIR}/invalid-token.log" && {
  echo 'render-pod-security: FAIL: numeric token setting accepted' >&2
  exit 1
}
python3 - "${WORK_DIR}" "${CHART_DIR}" <<'PY'
import sys
from pathlib import Path
import yaml
root, chart = map(Path, sys.argv[1:])
def deployments(file):
    return {d['metadata']['name']: d['spec']['template']['spec']
            for d in yaml.safe_load_all((root / file).read_text()) if d and d['kind'] == 'Deployment'}
def server(file):
    return deployments(file)['concord-server']
def containers(spec):
    return spec['containers'] + (spec.get('initContainers') or [])
pods = deployments('default.yaml')
assert set(pods) == {'concord-server', 'postgresql', 'concord-agent-operator'}
for name, spec in pods.items():
    assert spec['automountServiceAccountToken'] == (name == 'concord-agent-operator')
    assert 'securityContext' not in spec
    assert all('securityContext' not in c for c in containers(spec))
assert server('admin.yaml')['automountServiceAccountToken'] is True
assert server('token.yaml')['automountServiceAccountToken'] is True
assert deployments('token.yaml')['postgresql']['automountServiceAccountToken'] is True
assert server('no-token.yaml')['automountServiceAccountToken'] is False
assert set(deployments('external.yaml')) == {'concord-server'}
assert not server('external.yaml').get('initContainers')
example = yaml.safe_load((chart / 'test/restricted-values.yaml').read_text())
for name, values in [('concord-server', example['server']), ('postgresql', example['database']['internal']),
                     ('concord-agent-operator', example['agentOperator'])]:
    spec = deployments('restricted.yaml')[name]
    assert spec['securityContext'] == values['podSecurityContext']
    assert spec['containers'][0]['securityContext'] == values['securityContext']
    assert spec['securityContext']['runAsNonRoot'] is True
    assert spec['securityContext']['runAsUser'] > 0
    assert spec['securityContext']['seccompProfile']['type'] == 'RuntimeDefault'
    for c in containers(spec):
        assert c['securityContext']['allowPrivilegeEscalation'] is False
        assert c['securityContext']['capabilities']['drop'] == ['ALL']
init = server('default.yaml')['initContainers'][0]
assert init['name'] == 'postgres-ready'
assert init['env'] == [{'name': 'PGUSER', 'value': 'postgres'}]
assert init['resources'] == {'requests': {'cpu': '10m', 'memory': '16Mi'},
                            'limits': {'cpu': '100m', 'memory': '64Mi'}}
assert 'resources' not in server('no-resources.yaml')['initContainers'][0]
init = server('resources.yaml')['initContainers'][0]
assert init['resources']['requests']['cpu'] == '25m'
assert init['resources']['limits']['memory'] == '128Mi'
print('render-pod-security: OK (empty contexts, restricted profile, tokens, init resources)')
PY
