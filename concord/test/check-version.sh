#!/usr/bin/env bash
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scalar() { sed -n "s/^$2: *//p" "$1" | tr -d '\"\047'; }
chart_version=$(scalar "${CHART_DIR}/Chart.yaml" version)
app_version=$(scalar "${CHART_DIR}/Chart.yaml" appVersion)
image_version=$(scalar "${CHART_DIR}/values.yaml" version)
[[ "${app_version}" == "${image_version}" ]] || {
  echo 'Application and default image versions must agree' >&2; exit 1;
}
if [[ $# -gt 0 && "$1" != "${chart_version}" ]]; then
  echo 'Release tag must equal the chart version' >&2; exit 1
fi
echo "check-version: OK (chart ${chart_version}, application ${app_version})"
