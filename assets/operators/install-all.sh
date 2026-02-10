#!/usr/bin/env bash
# Data Grid Operator と Hyperfoil Operator を順にインストール
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Installing Data Grid Operator ==="
"${SCRIPT_DIR}/install-datagrid-operator.sh"

echo "=== Installing Hyperfoil Operator ==="
"${SCRIPT_DIR}/install-hyperfoil-operator.sh"

echo "=== Done ==="
