#!/usr/bin/env bash
# Renders the chart in default and secure modes and asserts the externally
# managed security contract. Exits non-zero on the first violated expectation.
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

helm template concord "${CHART_DIR}" > "${WORK_DIR}/default.yaml"
helm template concord "${CHART_DIR}" \
  -f "${CHART_DIR}/test/secure-values.yaml" > "${WORK_DIR}/secure.yaml"

fail() {
  echo "render-secure: FAIL: $1" >&2
  exit 1
}

# Number of YAML documents in which each given ERE matches at least one line.
count_docs() {
  local file="$1"
  shift
  local -a envs=()
  local idx=0 s
  for s in "$@"; do
    envs+=("D${idx}=${s}")
    idx=$((idx + 1))
  done
  env "${envs[@]}" awk '
    function flushdoc(    i, ok) {
      ok = 1
      for (i in want) {
        if (!(i in matched)) { ok = 0; break }
      }
      if (ok) cnt++
    }
    BEGIN {
      cnt = 0
      for (i = 0; (s = ENVIRON["D" i]) != ""; i++) want[i] = s
    }
    /^---/ { flushdoc(); delete matched; next }
    {
      for (i in want) {
        if (!(i in matched) && $0 ~ want[i]) matched[i] = 1
      }
    }
    END { flushdoc(); print cnt + 0 }
  ' "$file"
}

secure="${WORK_DIR}/secure.yaml"
default="${WORK_DIR}/default.yaml"

# --- secure mode ---------------------------------------------------------------

[ "$(grep -c '^  name: concord-server-credentials$' "${secure}")" -eq 0 ] ||
  fail "secure: chart-managed concord-server-credentials Secret must not render"

[ "$(grep -c 'value: auBy4eDWrKWsyhiDp3AQiwXX' "${secure}")" -eq 0 ] ||
  fail "secure: literal server.agentToken must not render"

grep -q 'name: concord-server-credentials-external' "${secure}" ||
  fail "secure: external Secret must be referenced"

grep -q 'key: AGENT_TOKEN' "${secure}" ||
  fail "secure: operator must read CONCORD_API_TOKEN with key AGENT_TOKEN"

[ "$(count_docs "${secure}" "^kind: Deployment\$" "name: concord-server-credentials-external")" -eq 3 ] ||
  fail "secure: server, operator and PostgreSQL Deployments must reference the external Secret"

[ "$(grep -c '^  POSTGRES_PASSWORD:' "${secure}")" -eq 0 ] ||
  fail "secure: postgresql-config ConfigMap must not contain POSTGRES_PASSWORD"

[ "$(grep -cE 'port: 5005|name: debug' "${secure}")" -eq 0 ] ||
  fail "secure: debug port must be absent"

[ "$(count_docs "${secure}" "^kind: Service\$")" -eq 2 ] ||
  fail "secure: expected exactly two Services"

[ "$(count_docs "${secure}" "^kind: Service\$" "^  type: ClusterIP\$")" -eq 2 ] ||
  fail "secure: both Services must be ClusterIP"
[ "$(count_docs "${secure}" "^kind: ClusterRole\$" "^  name: concord-agent-operator\$")" -eq 0 ] ||
  fail "secure: broad concord-agent-operator ClusterRole must not render"

[ "$(count_docs "${secure}" "^kind: Role\$")" -ge 2 ] ||
  fail "secure: namespaced concord-agent-operator and concord-k8s-dispatcher Roles must render"

[ "$(count_docs "${secure}" "^kind: ClusterRole\$" "agentpool-watch")" -eq 1 ] ||
  fail "secure: agentpool-watch ClusterRole must render"
[ "$(count_docs "${secure}" "^kind: ClusterRole\$" "agentpool-watch" "'\*'")" -eq 0 ] ||
  fail "secure: agentpool-watch ClusterRole must not use wildcard verbs"

grep -q 'image: library/postgres@sha256:7958605b474b3d264a969cb3a123d6aa00ad1e1fe9da8a69984dabb704d93317' "${secure}" ||
  fail "secure: PostgreSQL image must be the digest pin from database.internal.image.ref"

grep -q 'websockets.requirePermission = false' "${secure}" ||
  fail "secure: server.conf must contain websockets.requirePermission = false"

# --- default mode --------------------------------------------------------------

grep -q '^  name: concord-server-credentials$' "${default}" ||
  fail "default: chart-managed concord-server-credentials Secret must render"

grep -A1 'name: CONCORD_API_TOKEN' "${default}" | grep -q 'value:' ||
  fail "default: operator must use the literal server.agentToken"

[ "$(count_docs "${default}" "^kind: ClusterRole\$" "^  name: concord-agent-operator\$")" -eq 1 ] ||
  fail "default: broad concord-agent-operator ClusterRole must render"

[ "$(count_docs "${default}" "^kind: Service\$" "^  name: postgresql\$")" -eq 1 ] ||
  fail "default: PostgreSQL Service must render"

grep -q 'type: NodePort' "${default}" ||
  fail "default: PostgreSQL Service must default to NodePort"

grep -q 'port: 5005' "${default}" ||
  fail "default: debug port must render by default"

grep -q 'image: library/postgres:10.6' "${default}" ||
  fail "default: PostgreSQL image must default to repository:tag"

grep -q 'websockets.requirePermission = false' "${default}" ||
  fail "default: server.conf must contain websockets.requirePermission = false"

echo "render-secure: OK (default and secure contracts hold)"
