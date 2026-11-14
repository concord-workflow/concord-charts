#!/usr/bin/env bash
# Requires Python 3 and PyYAML, also used by CI.
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
helm template concord "${CHART_DIR}" > "${WORK_DIR}/disabled.yaml"
helm template concord "${CHART_DIR}" --set networkPolicy.enabled=true > "${WORK_DIR}/enabled.yaml"
cat > "${WORK_DIR}/peers.yaml" <<'YAML'
networkPolicy:
  enabled: true
  server:
    agentPeers:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: workers
        podSelector:
          matchLabels:
            app: custom-agent
    ingressPeers:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ingress-system
        podSelector:
          matchLabels:
            app.kubernetes.io/name: ingress-controller
YAML
helm template concord "${CHART_DIR}" -f "${WORK_DIR}/peers.yaml" \
  --set expose.port=8080 --set commonLabels.owner=platform > "${WORK_DIR}/peers.yaml.out"
helm template concord "${CHART_DIR}" --set networkPolicy.enabled=true \
  --set database.type=external --set agentOperator.enabled=false > "${WORK_DIR}/external-db.yaml"
helm template concord "${CHART_DIR}" --set networkPolicy.enabled=true \
  --set server.type=external --set server.apiBaseUrl=https://concord.example.com > "${WORK_DIR}/external-server.yaml"
helm template concord "${CHART_DIR}" --set networkPolicy.enabled=true \
  --set database.type=external --set server.type=external \
  --set server.apiBaseUrl=https://concord.example.com > "${WORK_DIR}/external-both.yaml"
python3 - "${WORK_DIR}" <<'PY'
import sys
from pathlib import Path
import yaml
root = Path(sys.argv[1])
def policies(name):
    return {d['metadata']['name']: d for d in yaml.safe_load_all((root / name).read_text())
            if d and d['kind'] == 'NetworkPolicy'}
def pod(key, value):
    return {'podSelector': {'matchLabels': {key: value}}}
assert not policies('disabled.yaml')
p = policies('enabled.yaml')
assert set(p) == {'concord-server', 'postgresql'}
for name, label in [('concord-server', 'concord-server'), ('postgresql', 'postgresql')]:
    spec = p[name]['spec']
    assert spec['podSelector'] == {'matchLabels': {'app': label}}
    assert spec['policyTypes'] == ['Ingress'] and 'egress' not in spec
assert p['postgresql']['spec']['ingress'] == [{
    'ports': [{'protocol': 'TCP', 'port': 5432}],
    'from': [pod('app', 'concord-server')]}]
rule = p['concord-server']['spec']['ingress']
assert len(rule) == 1 and rule[0]['ports'] == [{'protocol': 'TCP', 'port': 8001}]
assert rule[0]['from'] == [pod('app', 'concord-server'), pod('name', 'concord-agent-operator'),
                            pod('app', 'agentpools.concord.walmartlabs.com')]
p = policies('peers.yaml.out')
values = yaml.safe_load((root / 'peers.yaml').read_text())['networkPolicy']['server']
assert p['concord-server']['spec']['ingress'][0]['from'] == [
    pod('app', 'concord-server'), pod('name', 'concord-agent-operator'),
    *values['agentPeers'], *values['ingressPeers']]
# The Service port is configurable; the server's target port stays 8001.
assert p['concord-server']['spec']['ingress'][0]['ports'] == [{'protocol': 'TCP', 'port': 8001}]
assert all(d['metadata']['labels']['owner'] == 'platform' for d in p.values())
p = policies('external-db.yaml')
assert set(p) == {'concord-server'}
assert pod('name', 'concord-agent-operator') not in p['concord-server']['spec']['ingress'][0]['from']
assert not policies('external-server.yaml')
assert not policies('external-both.yaml')
print('render-network-policy: OK (disabled, enabled, peers, external components)')
PY
