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
[[ $(grep -c 'image: library/postgres:18.6$' "${WORK_DIR}/default.yaml") == 2 ]] || fail 'database and init images'
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
echo 'render-upgrade: OK'
