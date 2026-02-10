#!/usr/bin/env bash
# DataGrid インスタンスをデプロイする
# パラメタ: version, replicas（デフォルト 8.5.3-2, 3）。将来: 認証の有無など拡張可能
# 何度でも実行可能。同じ Infinispan CR に oc apply するため、バージョンやレプリカ数を変えて再実行すると設定が更新される。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

# デフォルト値
VERSION="${DATAGRID_CLUSTER_VERSION:-8.5.3-2}"
REPLICAS="${DATAGRID_REPLICAS:-3}"
NAMESPACE="${DATAGRID_NAMESPACE:-datagrid}"
CLUSTER_NAME="${DATAGRID_CLUSTER_NAME:-infinispan}"
# 認証: true / false（将来拡張用）
ENDPOINT_AUTH="${DATAGRID_ENDPOINT_AUTH:-true}"
# エンドポイント TLS: 未設定時は Operator が Service CA で自動有効化。--no-tls で無効（開発/ワークショップ用）
ENDPOINT_ENCRYPTION_BLOCK=""

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "  --version VERSION    Data Grid サーバーバージョン (default: ${VERSION})"
  echo "  --replicas N         レプリカ数 (default: ${REPLICAS})"
  echo "  --namespace NS       デプロイ先 namespace (default: ${NAMESPACE})"
  echo "  --cluster-name NAME  Infinispan CR 名 (default: ${CLUSTER_NAME})"
  echo "  --no-auth            エンドポイント認証を無効にする"
  echo "  --no-tls             エンドポイント TLS を無効にする（開発用。REST が http で通るようになる）"
  echo "  --dry-run            適用せずに生成 YAML を表示"
  exit 0
}

DRY_RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)      VERSION="$2";  shift 2 ;;
    --replicas)     REPLICAS="$2"; shift 2 ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --no-auth)      ENDPOINT_AUTH="false"; shift ;;
    --no-tls)       ENDPOINT_ENCRYPTION_BLOCK="    endpointEncryption:__NL__      type: None"; shift ;;
    --dry-run)      DRY_RUN="1"; shift ;;
    -h|--help)      usage ;;
    *)              echo "Unknown option: $1"; usage ;;
  esac
done

BASE_YAML="${SCRIPT_DIR}/infinispan-base.yaml"
if [[ ! -f "${BASE_YAML}" ]]; then
  echo "Not found: ${BASE_YAML}"
  exit 1
fi

# 名前空間が無ければ作成
if ! oc get namespace "${NAMESPACE}" 2>/dev/null; then
  oc create namespace "${NAMESPACE}"
fi

# プレースホルダ置換して適用（__ENDPOINT_ENCRYPTION_BLOCK__ は改行を含むため別処理）
MANIFEST=$(sed -e "s/__DATAGRID_VERSION__/${VERSION}/g" \
  -e "s/__REPLICAS__/${REPLICAS}/g" \
  -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
  -e "s/__NAMESPACE__/${NAMESPACE}/g" \
  -e "s/__ENDPOINT_AUTH__/${ENDPOINT_AUTH}/g" \
  "${BASE_YAML}")
# 空でない場合のみ置換（空の場合はプレースホルダ行を削除。__NL__ を改行に）
if [[ -n "${ENDPOINT_ENCRYPTION_BLOCK}" ]]; then
  MANIFEST=$(echo "${MANIFEST}" | awk -v block="${ENDPOINT_ENCRYPTION_BLOCK}" '
    BEGIN { n = split(block, a, "__NL__"); for (i = 1; i <= n; i++) lines[i] = a[i] }
    /__ENDPOINT_ENCRYPTION_BLOCK__/ { for (i = 1; i <= n; i++) print lines[i]; next }
    { print }
  ')
else
  MANIFEST=$(echo "${MANIFEST}" | grep -v '__ENDPOINT_ENCRYPTION_BLOCK__')
fi

if [[ -n "${DRY_RUN}" ]]; then
  echo "$MANIFEST"
  exit 0
fi

echo "Deploying Data Grid: version=${VERSION}, replicas=${REPLICAS}, namespace=${NAMESPACE}, cluster=${CLUSTER_NAME}, endpointAuth=${ENDPOINT_AUTH}, endpointTLS=$([ -n "${ENDPOINT_ENCRYPTION_BLOCK}" ] && echo 'disabled' || echo 'default')"
echo "$MANIFEST" | oc apply -f -

echo "Waiting for Infinispan to be ready..."
oc wait --for=condition=WellFormed infinispan/"${CLUSTER_NAME}" -n "${NAMESPACE}" --timeout=600s 2>/dev/null || true
oc get infinispan -n "${NAMESPACE}"
echo "Done. Pods: oc get pods -n ${NAMESPACE}"
