#!/usr/bin/env bash
# Hyperfoil Operator をインストールし、続けて Hyperfoil コントローラー用インスタンス（CR）をデプロイする。
# Data Grid と同様、Operator インストール時に構築まで行い、そのままベンチマーク実行可能にする。
# マニュアルインストール（InstallPlan 手動承認）のため、勝手にアップグレードされない。
# 何度でも実行可能。既にインストール済みの場合は Operator はスキップし、インスタンスは apply で更新。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

HYPERFOIL_OPERATOR_NAMESPACE="${HYPERFOIL_OPERATOR_NAMESPACE:-openshift-operators}"
SUBSCRIPTION_NAME="${HYPERFOIL_OPERATOR_SUBSCRIPTION_NAME:-hyperfoil-operator}"
HYPERFOIL_NAMESPACE="${HYPERFOIL_NAMESPACE:-hyperfoil}"
HYPERFOIL_INSTANCE_YAML="${ASSETS_DIR}/hyperfoil/hyperfoil-instance.yaml"

echo "Hyperfoil Operator (latest, Manual approval) in namespace=${HYPERFOIL_OPERATOR_NAMESPACE}"

# --- 1. Operator のインストール（Subscription が無い場合のみ）---
if ! oc get subscription "${SUBSCRIPTION_NAME}" -n "${HYPERFOIL_OPERATOR_NAMESPACE}" &>/dev/null; then
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION_NAME}
  namespace: ${HYPERFOIL_OPERATOR_NAMESPACE}
spec:
  channel: alpha
  name: hyperfoil-bundle
  source: community-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
EOF

  echo "Waiting for InstallPlan..."
  until oc get installplan -n "${HYPERFOIL_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep -q .; do
    echo "  ..."
    sleep 5
  done

  for ip in $(oc get installplan -n "${HYPERFOIL_OPERATOR_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}'); do
    if oc get installplan "$ip" -n "${HYPERFOIL_OPERATOR_NAMESPACE}" -o jsonpath='{.spec.approved}' 2>/dev/null | grep -q false; then
      oc patch installplan "$ip" -n "${HYPERFOIL_OPERATOR_NAMESPACE}" --type merge -p '{"spec":{"approved":true}}'
      echo "Approved InstallPlan: $ip"
    fi
  done

  echo "Waiting for Hyperfoil CSV to be Succeeded..."
  sleep 5
  for i in $(seq 1 60); do
    CSV=$(oc get csv -n "${HYPERFOIL_OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.metadata.name contains "hyperfoil")].metadata.name}' 2>/dev/null | head -1)
    if [[ -n "${CSV}" ]]; then
      oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${CSV}" -n "${HYPERFOIL_OPERATOR_NAMESPACE}" --timeout=300s 2>/dev/null || true
      break
    fi
    echo "Waiting for CSV... ($i/60)"
    sleep 5
  done
  oc get csv -n "${HYPERFOIL_OPERATOR_NAMESPACE}" | grep -E 'NAME|hyperfoil' || true
  echo "Hyperfoil Operator installed."
else
  echo "Subscription ${SUBSCRIPTION_NAME} already exists. Skipping Operator install."
fi

# --- 2. Hyperfoil コントローラー用インスタンス（CR）のデプロイ ---
if [[ ! -f "${HYPERFOIL_INSTANCE_YAML}" ]]; then
  echo "Instance template not found: ${HYPERFOIL_INSTANCE_YAML}. Skipping instance deploy."
  exit 0
fi

if ! oc get namespace "${HYPERFOIL_NAMESPACE}" &>/dev/null; then
  oc create namespace "${HYPERFOIL_NAMESPACE}"
  echo "Created namespace: ${HYPERFOIL_NAMESPACE}"
fi

echo "Deploying Hyperfoil controller instance (Hyperfoil CR)..."
oc apply -f "${HYPERFOIL_INSTANCE_YAML}"

echo "Hyperfoil instance deployed. Controller and Route may take a moment to be ready."
echo "  Check: oc get hf -n ${HYPERFOIL_NAMESPACE}  &&  oc get route -n ${HYPERFOIL_NAMESPACE}"
echo "Done (Operator + instance; ready for run-benchmark.sh)."
