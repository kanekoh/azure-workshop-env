#!/usr/bin/env bash
# Data Grid Operator をインストールする（バージョン指定可能、デフォルト 8.5.7）
# マニュアルインストール（InstallPlan 手動承認）のため、勝手にアップグレードされない。
# 何度でも実行可能。既にインストール済みの場合はバージョン変更時のみ Subscription を更新する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

DATAGRID_OPERATOR_VERSION="${DATAGRID_OPERATOR_VERSION:-8.5.7}"
DATAGRID_OPERATOR_CHANNEL="${DATAGRID_OPERATOR_CHANNEL:-stable}"
DATAGRID_OPERATOR_NAMESPACE="${DATAGRID_OPERATOR_NAMESPACE:-openshift-operators}"
SUBSCRIPTION_NAME="${DATAGRID_OPERATOR_SUBSCRIPTION_NAME:-datagrid-operator}"

# startingCSV は Operator の CSV 名（datagrid-operator.vX.Y.Z）
STARTING_CSV="datagrid-operator.v${DATAGRID_OPERATOR_VERSION}"

echo "Data Grid Operator: channel=${DATAGRID_OPERATOR_CHANNEL}, startingCSV=${STARTING_CSV}, namespace=${DATAGRID_OPERATOR_NAMESPACE}"

# 既存の Subscription がある場合
if oc get subscription "${SUBSCRIPTION_NAME}" -n "${DATAGRID_OPERATOR_NAMESPACE}" &>/dev/null; then
  CURRENT_CSV=$(oc get subscription "${SUBSCRIPTION_NAME}" -n "${DATAGRID_OPERATOR_NAMESPACE}" -o jsonpath='{.spec.startingCSV}' 2>/dev/null || echo "")
  CURRENT_CHANNEL=$(oc get subscription "${SUBSCRIPTION_NAME}" -n "${DATAGRID_OPERATOR_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
  if [[ "${CURRENT_CSV}" == "${STARTING_CSV}" && "${CURRENT_CHANNEL}" == "${DATAGRID_OPERATOR_CHANNEL}" ]]; then
    echo "Subscription ${SUBSCRIPTION_NAME} already exists with same version (${STARTING_CSV}). Nothing to do."
    oc get csv -n "${DATAGRID_OPERATOR_NAMESPACE}" -l operators.coreos.com/datagrid-operator.openshift-operators= 2>/dev/null || true
    exit 0
  fi
  echo "Updating existing subscription to startingCSV=${STARTING_CSV}, channel=${DATAGRID_OPERATOR_CHANNEL} (keeping Manual approval)"
  oc patch subscription "${SUBSCRIPTION_NAME}" -n "${DATAGRID_OPERATOR_NAMESPACE}" --type merge -p "{\"spec\":{\"channel\":\"${DATAGRID_OPERATOR_CHANNEL}\",\"startingCSV\":\"${STARTING_CSV}\",\"installPlanApproval\":\"Manual\"}}"
  echo "Waiting for InstallPlan (if any)..."
  sleep 5
  for ip in $(oc get installplan -n "${DATAGRID_OPERATOR_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    if oc get installplan "$ip" -n "${DATAGRID_OPERATOR_NAMESPACE}" -o jsonpath='{.spec.approved}' 2>/dev/null | grep -q false; then
      oc patch installplan "$ip" -n "${DATAGRID_OPERATOR_NAMESPACE}" --type merge -p '{"spec":{"approved":true}}'
      echo "Approved InstallPlan: $ip"
    fi
  done
  echo "Waiting for CSV ${STARTING_CSV} to be Succeeded..."
  oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/"${STARTING_CSV}" -n "${DATAGRID_OPERATOR_NAMESPACE}" --timeout=600s 2>/dev/null || true
  oc get csv -n "${DATAGRID_OPERATOR_NAMESPACE}" -l operators.coreos.com/datagrid-operator.openshift-operators= 2>/dev/null || true
  echo "Data Grid Operator update done."
  exit 0
fi

# 新規インストール: OperatorGroup（必要な場合）
if [[ "${DATAGRID_OPERATOR_NAMESPACE}" != "openshift-operators" ]]; then
  if ! oc get operatorgroup -n "${DATAGRID_OPERATOR_NAMESPACE}" 2>/dev/null | grep -q .; then
    oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: datagrid-operator-group
  namespace: ${DATAGRID_OPERATOR_NAMESPACE}
spec:
  targetNamespaces: []
EOF
  fi
fi

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION_NAME}
  namespace: ${DATAGRID_OPERATOR_NAMESPACE}
spec:
  channel: ${DATAGRID_OPERATOR_CHANNEL}
  name: datagrid
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
  startingCSV: ${STARTING_CSV}
EOF

echo "Subscription created. Approving InstallPlan..."
until oc get installplan -n "${DATAGRID_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep -q .; do
  echo "Waiting for InstallPlan..."
  sleep 5
done

for ip in $(oc get installplan -n "${DATAGRID_OPERATOR_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}'); do
  if oc get installplan "$ip" -n "${DATAGRID_OPERATOR_NAMESPACE}" -o jsonpath='{.spec.approved}' | grep -q false; then
    oc patch installplan "$ip" -n "${DATAGRID_OPERATOR_NAMESPACE}" --type merge -p '{"spec":{"approved":true}}'
    echo "Approved InstallPlan: $ip"
  fi
done

echo "Waiting for Data Grid Operator CSV to be Succeeded..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/"${STARTING_CSV}" -n "${DATAGRID_OPERATOR_NAMESPACE}" --timeout=300s 2>/dev/null || true
oc get csv -n "${DATAGRID_OPERATOR_NAMESPACE}" -l operators.coreos.com/datagrid-operator.openshift-operators=
echo "Data Grid Operator install done."
