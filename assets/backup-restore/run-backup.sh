#!/usr/bin/env bash
# Data Grid バックアップを実行する
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

NAMESPACE="${DATAGRID_NAMESPACE:-datagrid}"
CLUSTER_NAME="${DATAGRID_CLUSTER_NAME:-infinispan}"
BACKUP_NAME="${BACKUP_NAME:-backup-$(date +%Y%m%d-%H%M%S)}"
STORAGE_SIZE="${BACKUP_STORAGE_SIZE:-2Gi}"
STORAGE_CLASS="${BACKUP_STORAGE_CLASS:-}"
# storageClassName を省略可能にする（空の場合はフィールドごと削除）
STORAGE_CLASS_FIELD=""

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "  --cluster NAME    Infinispan CR 名"
  echo "  --namespace NS    namespace"
  echo "  --name NAME        Backup CR 名"
  echo "  --storage SIZE    PVC サイズ (default: 2Gi)"
  echo "  --storage-class SC  StorageClass 名（省略可）"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)       CLUSTER_NAME="$2"; shift 2 ;;
    --namespace)     NAMESPACE="$2"; shift 2 ;;
    --name)           BACKUP_NAME="$2"; shift 2 ;;
    --storage)        STORAGE_SIZE="$2"; shift 2 ;;
    --storage-class)  STORAGE_CLASS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -n "${STORAGE_CLASS}" ]]; then
  STORAGE_CLASS_FIELD="storageClassName: ${STORAGE_CLASS}"
else
  STORAGE_CLASS_FIELD=""
fi

TPL="${SCRIPT_DIR}/backup.yaml.tpl"
if [[ ! -f "${TPL}" ]]; then
  echo "Template not found: ${TPL}"
  exit 1
fi

# storageClassName は空の場合は行ごと削除
MANIFEST=$(sed -e "s/__BACKUP_NAME__/${BACKUP_NAME}/g" \
  -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
  -e "s/__NAMESPACE__/${NAMESPACE}/g" \
  -e "s/__STORAGE_SIZE__/${STORAGE_SIZE}/g" \
  -e "s/__STORAGE_CLASS__/${STORAGE_CLASS}/g" \
  "${TPL}")

# 空の storageClassName を削除（optional のため）
if [[ -z "${STORAGE_CLASS}" ]]; then
  MANIFEST=$(echo "$MANIFEST" | sed '/storageClassName: *$/d')
fi

echo "Creating Backup CR: ${BACKUP_NAME} for cluster ${CLUSTER_NAME} in ${NAMESPACE}"
echo "$MANIFEST" | oc apply -f -

echo "Waiting for backup phase Succeeded (timeout 30m)..."
for i in $(seq 1 60); do
  PHASE=$(oc get backup "${BACKUP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  echo "  phase: ${PHASE}"
  case "${PHASE}" in
    Succeeded) echo "Backup succeeded."; exit 0 ;;
    Failed)    echo "Backup failed."; oc describe backup "${BACKUP_NAME}" -n "${NAMESPACE}"; exit 1 ;;
  esac
  sleep 30
done
echo "Timeout waiting for Succeeded. Check: oc get backup ${BACKUP_NAME} -n ${NAMESPACE} -o yaml"
