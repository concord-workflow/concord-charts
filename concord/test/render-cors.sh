#!/usr/bin/env bash
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
helm template concord "${CHART_DIR}" > "${WORK_DIR}/default.yaml"
helm template concord "${CHART_DIR}" --set server.cors.allowOrigin=https://console.example.com > "${WORK_DIR}/origin.yaml"
helm template concord "${CHART_DIR}" --set-string server.cors.allowOrigin='*' > "${WORK_DIR}/wildcard.yaml"
cat > "${WORK_DIR}/escaped-values.yaml" <<'YAML'
server:
  cors:
    allowOrigin: 'quote"backslash\value'
YAML
helm template concord "${CHART_DIR}" -f "${WORK_DIR}/escaped-values.yaml" > "${WORK_DIR}/escaped.yaml"
for invalid in true 123 ''; do
  if helm template concord "${CHART_DIR}" --set server.cors.allowOrigin="${invalid}" > /dev/null 2>&1; then
    echo "render-cors: FAIL: invalid allowOrigin accepted: ${invalid}" >&2
    exit 1
  fi
done
python3 - "${WORK_DIR}" <<'PY'
import json
from pathlib import Path
import sys
import yaml
root = Path(sys.argv[1])
def config(file):
    return next(d['data']['server.conf'] for d in yaml.safe_load_all((root / file).read_text())
                if d and d['kind'] == 'ConfigMap' and d['metadata']['name'] == 'server-cfg')
assert 'cors.allowOrigin' not in config('default.yaml')
for file, value in [('origin.yaml', 'https://console.example.com'), ('wildcard.yaml', '*'),
                     ('escaped.yaml', 'quote"backslash\\value')]:
    conf = config(file)
    assert conf.count('cors.allowOrigin') == 1
    line = next(l.strip() for l in conf.splitlines() if 'cors.allowOrigin' in l)
    assert line == 'cors.allowOrigin = ' + json.dumps(value)
    assert 'sendServerVersion' not in conf
print('render-cors: OK (inherited default, explicit origin/wildcard, escaping, invalid types)')
PY
