#!/usr/bin/env bash
# 短時間・低負荷でベンチマークが通るかテストする
# 例: ./test-benchmark.sh  または  ./run.sh hyperfoil test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

echo "Running short load benchmark (5s, low rate) to verify setup..."
exec "${SCRIPT_DIR}/run-benchmark.sh" load \
  --duration 5 \
  --records 100 \
  --payload-bytes 64 \
  --parallelism 2 \
  "$@"
