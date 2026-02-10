#!/usr/bin/env bash
# Data Grid およびバックアップ・リストア分析用のメトリクスを収集する
# 収集内容: Backup/Restore CR の状態・所要時間、Pod リソース、PVC、Data Grid 関連メトリクス
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

NAMESPACE="${DATAGRID_NAMESPACE:-datagrid}"
CLUSTER_NAME="${DATAGRID_CLUSTER_NAME:-infinispan}"
OUTPUT_DIR="${OUTPUT_DIR:-./metrics-$(date +%Y%m%d-%H%M%S)}"
# 収集間隔（秒）。バックアップ/リストア中の経過を見る場合は短くする
INTERVAL="${METRICS_INTERVAL:-30}"
# 収集回数（0 の場合は 1 回だけ）
ITERATIONS="${METRICS_ITERATIONS:-1}"

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "  --output-dir DIR   出力ディレクトリ"
  echo "  --namespace NS      Data Grid の namespace"
  echo "  --cluster NAME      Infinispan CR 名"
  echo "  --interval SEC      収集間隔（複数回収集時）"
  echo "  --iterations N      収集回数（0=1回のみ）"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --cluster)      CLUSTER_NAME="$2"; shift 2 ;;
    --interval)     INTERVAL="$2"; shift 2 ;;
    --iterations)   ITERATIONS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

mkdir -p "${OUTPUT_DIR}"
echo "Collecting metrics to ${OUTPUT_DIR}"

collect_once() {
  local suffix="${1:-}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # 1. Backup / Restore CR の status（あれば）
  oc get backup,restore -n "${NAMESPACE}" -o json 2>/dev/null > "${OUTPUT_DIR}/backup-restore-crs${suffix}.json" || true

  # 2. Infinispan CR の status
  oc get infinispan "${CLUSTER_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null > "${OUTPUT_DIR}/infinispan-cr${suffix}.json" || true

  # 3. Pod のリソース使用量（oc adm top pods）
  oc adm top pods -n "${NAMESPACE}" --containers 2>/dev/null > "${OUTPUT_DIR}/pod-metrics${suffix}.txt" || true

  # 4. PVC 一覧（バックアップサイズの目安）
  oc get pvc -n "${NAMESPACE}" -o wide 2>/dev/null > "${OUTPUT_DIR}/pvc${suffix}.txt" || true

  # 5. Pod 一覧と状態
  oc get pods -n "${NAMESPACE}" -o wide 2>/dev/null > "${OUTPUT_DIR}/pods${suffix}.txt" || true

  # 6. タイムスタンプ付きサマリ
  {
    echo "collected_at: ${ts}"
    echo "namespace: ${NAMESPACE}"
    echo "cluster: ${CLUSTER_NAME}"
    echo "---"
    echo "Backup CRs:"
    oc get backup -n "${NAMESPACE}" -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' 2>/dev/null || true
    echo "Restore CRs:"
    oc get restore -n "${NAMESPACE}" -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' 2>/dev/null || true
    echo "Pods:"
    oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || true
  } > "${OUTPUT_DIR}/summary${suffix}.txt"

  echo "[${ts}] Collected ${suffix:-once}"
}

if [[ "${ITERATIONS}" -le 0 ]]; then
  ITERATIONS=1
fi

for i in $(seq 1 "${ITERATIONS}"); do
  if [[ "${ITERATIONS}" -gt 1 ]]; then
    collect_once "-${i}"
    [[ $i -lt "${ITERATIONS}" ]] && sleep "${INTERVAL}"
  else
    collect_once ""
  fi
done

# バックアップ・リストアの所要時間分析用: Backup/Restore の phase 履歴は CR の status に含まれる
echo "Done. For backup/restore duration analysis, check:"
echo "  - ${OUTPUT_DIR}/backup-restore-crs*.json  (status.phase, status.conditions)"
echo "  - ${OUTPUT_DIR}/pod-metrics*.txt          (CPU/Memory during operation)"
echo "  - ${OUTPUT_DIR}/summary*.txt              (timestamps and phase)"
