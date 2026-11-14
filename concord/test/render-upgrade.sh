#!/usr/bin/env bash
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
fail() { echo "render-upgrade: FAIL: $1" >&2; exit 1; }
"${CHART_DIR}/test/check-version.sh"
helm template concord "${CHART_DIR}" > "${WORK_DIR}/default.yaml"
grep -q 'image: walmartlabs/concord-server:2.47.0$' "${WORK_DIR}/default.yaml" || fail 'server image'
grep -q 'image: walmartlabs/concord-agent-operator:2.47.0$' "${WORK_DIR}/default.yaml" || fail 'operator image'
[[ $(grep -c 'image: library/postgres:10.6$' "${WORK_DIR}/default.yaml") == 2 ]] || fail 'database and init images'
# A database major upgrade must be an explicit values change.
helm template concord "${CHART_DIR}" --set-string database.internal.image.tag=18.6 > "${WORK_DIR}/postgres18.yaml"
[[ $(grep -c 'image: library/postgres:18.6$' "${WORK_DIR}/postgres18.yaml") == 2 ]] || fail 'explicit database upgrade'
# Regression: credential and server-config helpers must not replace each other.
helm template concord "${CHART_DIR}" --show-only templates/server/config-map.yaml > "${WORK_DIR}/config.yaml"
grep -Fq 'jdbc:postgresql://postgresql:5432/postgres' "${WORK_DIR}/config.yaml" || fail 'database configuration missing'
grep -Fq 'appPassword = ${DB_PASSWORD}' "${WORK_DIR}/config.yaml" || fail 'database password substitution missing'
! grep -q 'DB_PASSWORD:' "${WORK_DIR}/config.yaml" || fail 'credentials rendered as server configuration'
# CRD schema metadata is not an AgentPool instance.
! grep -q '^kind: AgentPool$' "${WORK_DIR}/default.yaml" || fail 'unexpected managed AgentPool'
for permission in true false; do
  helm template concord "${CHART_DIR}" --set server.websocketsRequirePermission="${permission}" > "${WORK_DIR}/permission.yaml"
  [[ $(grep -c 'requirePermission' "${WORK_DIR}/permission.yaml") == 1 ]] || fail 'duplicate permission assignment'
  grep -q "websockets.requirePermission = ${permission}$" "${WORK_DIR}/permission.yaml" || fail 'permission override'
done
helm template concord "${CHART_DIR}" --set serverImageOverride=example.invalid/server:test \
  --set agentOperatorImageOverride=example.invalid/operator:test > "${WORK_DIR}/overrides.yaml"
grep -q 'image: example.invalid/server:test$' "${WORK_DIR}/overrides.yaml" || fail 'server image override'
grep -q 'image: example.invalid/operator:test$' "${WORK_DIR}/overrides.yaml" || fail 'operator image override'
helm template concord "${CHART_DIR}" --set database.type=external --set agentOperator.enabled=false > "${WORK_DIR}/external.yaml"
! grep -q 'image: library/postgres:' "${WORK_DIR}/external.yaml" || fail 'internal database with external values'
! grep -q 'image: walmartlabs/concord-agent-operator:' "${WORK_DIR}/external.yaml" || fail 'disabled operator'
helm template concord "${CHART_DIR}" --set git.oauth=test-token > "${WORK_DIR}/oauth.yaml"
grep -Fq 'oauth = ${GIT_OAUTH}' "${WORK_DIR}/oauth.yaml" || fail 'OAuth environment reference'
if helm template concord "${CHART_DIR}" --set github.enabled=true > /dev/null 2>&1; then
  fail 'empty webhook secret accepted'
fi
helm template concord "${CHART_DIR}" --set github.enabled=true --set github.secret=test-webhook-secret > "${WORK_DIR}/github.yaml"
grep -Fq 'secret = ${GITHUB_SECRET}' "${WORK_DIR}/github.yaml" || fail 'webhook secret reference'
helm template concord "${CHART_DIR}" --set github.enabled=true \
  --set server.existingSecret=external-credentials > "${WORK_DIR}/github-external.yaml"
grep -Fq 'secret = ${GITHUB_SECRET}' "${WORK_DIR}/github-external.yaml" || fail 'external webhook secret'
helm template concord "${CHART_DIR}" --show-only templates/server/ingress.yaml \
  --set expose.ingress.className=tailscale --set-string expose.tls.secretName= > "${WORK_DIR}/tailscale.yaml"
grep -q 'ingressClassName: "tailscale"' "${WORK_DIR}/tailscale.yaml" || fail 'ingress class selection'
! grep -q 'secretName:' "${WORK_DIR}/tailscale.yaml" || fail 'unwanted TLS Secret for managed certificates'
# Never roll two PostgreSQL instances against the same volume.
python3 - "${WORK_DIR}/default.yaml" <<'PY'
import sys, yaml

def fail(message):
    sys.exit('render-upgrade: FAIL: ' + message)

with open(sys.argv[1]) as manifest:
    postgres = [d for d in yaml.safe_load_all(manifest)
                if d and d.get('kind') == 'Deployment' and d.get('metadata', {}).get('name') == 'postgresql']
if len(postgres) != 1:
    fail('expected exactly one internal PostgreSQL Deployment')
spec = postgres[0].get('spec', {})
if spec.get('replicas') != 1:
    fail('PostgreSQL Deployment must have one replica')
if spec.get('strategy') != {'type': 'Recreate'}:
    fail('PostgreSQL Deployment strategy must be Recreate without rollingUpdate')
PY
for exposure in ingress nodePort loadBalancer clusterIP; do
  helm template concord "${CHART_DIR}" --set expose.type="${exposure}" > "${WORK_DIR}/exposure.yaml"
  python3 - "${WORK_DIR}/exposure.yaml" "${exposure}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as manifest:
    services = [d for d in yaml.safe_load_all(manifest)
                if d and d.get('kind') == 'Service' and d.get('metadata', {}).get('name') == 'concord-server']
if len(services) != 1:
    sys.exit('render-upgrade: FAIL: expected one server Service for ' + sys.argv[2])
expected = {'ingress': 'ClusterIP', 'clusterIP': 'ClusterIP', 'nodePort': 'NodePort', 'loadBalancer': 'LoadBalancer'}
if services[0].get('spec', {}).get('type') != expected[sys.argv[2]]:
    sys.exit('render-upgrade: FAIL: incorrect server Service type for ' + sys.argv[2])
PY
done
for invalid in ClusterIP typo; do
  if helm template concord "${CHART_DIR}" --set expose.type="${invalid}" > /dev/null 2>&1; then
    fail "invalid expose.type accepted: ${invalid}"
  fi
done
# External servers do not consume expose.type, including legacy values.
helm template concord "${CHART_DIR}" --set server.type=external \
  --set server.apiBaseUrl=https://concord.example.com --set expose.type=none > "${WORK_DIR}/external-server.yaml"
python3 - "${WORK_DIR}/external-server.yaml" <<'PY'
import sys, yaml
with open(sys.argv[1]) as manifest:
    for doc in yaml.safe_load_all(manifest):
        if doc and (doc.get('kind') == 'Ingress' or
                    (doc.get('kind') == 'Service' and doc.get('metadata', {}).get('name') == 'concord-server')):
            sys.exit('render-upgrade: FAIL: external server must not render a server Service or Ingress')
PY
# A chart-only release must work without a new Concord image.
cp -R "${CHART_DIR}" "${WORK_DIR}/chart"
sed -i 's/^version: .*/version: 2.47.1/' "${WORK_DIR}/chart/Chart.yaml"
"${WORK_DIR}/chart/test/check-version.sh" 2.47.1
if "${WORK_DIR}/chart/test/check-version.sh" 2.47.0 > /dev/null 2>&1; then
  fail 'mismatched chart release tag accepted'
fi
sed -i 's/^appVersion: .*/appVersion: "2.47.1"/' "${WORK_DIR}/chart/Chart.yaml"
if "${WORK_DIR}/chart/test/check-version.sh" > /dev/null 2>&1; then
  fail 'mismatched application/image version accepted'
fi
# The removed agent template must not be shipped in the chart package.
helm package "${CHART_DIR}" -d "${WORK_DIR}" > /dev/null
if tar -tzf "${WORK_DIR}"/concord-*.tgz | grep -q 'files/agent/agent.conf'; then
  fail 'unused agent template packaged'
fi
echo 'render-upgrade: OK (upgrade and review regressions)'
