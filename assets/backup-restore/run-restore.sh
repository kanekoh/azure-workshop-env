#!/usr/bin/env bash
# Data Grid リストアを実行する
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

NAMESPACE="${DATAGRID_NAMESPACE:-datagrid}"
CLUSTER_NAME="${DATAGRID_CLUSTER_NAME:-infinispan}"
BACKUP_NAME=""
RESTORE_NAME="${RESTORE_NAME:-restore-$(date +%Y%m%d-%H%M%S)}"

usage() {
  echo "Usage: $0 --backup BACKUP_CR_NAME [OPTIONS]"
  echo "  --backup NAME     Backup CR 名（必須）"
  echo "  --cluster NAME    リストア先の Infinispan CR 名"
  echo "  --namespace NS    namespace"
  echo "  --name NAME       Restore CR 名"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)        BACKUP_NAME="$2"; shift 2 ;;
    --cluster)       CLUSTER_NAME="$2"; shift 2 ;;
    --namespace)     NAMESPACE="$2"; shift 2 ;;
    --name)          RESTORE_NAME="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "${BACKUP_NAME}" ]]; then
  echo "Missing --backup BACKUP_CR_NAME"
  usage
fi

TPL="${SCRIPT_DIR}/restore.yaml.tpl"
if [[ ! -f "${TPL}" ]]; then
  echo "Template not found: ${TPL}"
  exit 1
fi

MANIFEST=$(sed -e "s/__RESTORE_NAME__/${RESTORE_NAME}/g" \
  -e "s/__BACKUP_NAME__/${BACKUP_NAME}/g" \
  -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
  -e "s/__NAMESPACE__/${NAMESPACE}/g" \
  "${TPL}")

echo "Creating Restore CR: ${RESTORE_NAME} from backup ${BACKUP_NAME} to cluster ${CLUSTER_NAME} in ${NAMESPACE}"
echo "$MANIFEST" | oc apply -f -

echo "Waiting for restore phase Succeeded (timeout 30m)..."
for i in $(seq 1 60); do
  PHASE=$(oc get restore "${RESTORE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  echo "  phase: ${PHASE}"
  case "${PHASE}" in
    Succeeded) echo "Restore succeeded."; exit 0 ;;
    Failed)    echo "Restore failed."; oc describe restore "${RESTORE_NAME}" -n "${NAMESPACE}"; exit 1 ;;
  esac
  sleep 30
done
echo "Timeout waiting for Succeeded. Check: oc get restore ${RESTORE_NAME} -n ${NAMESPACE} -o yaml"
