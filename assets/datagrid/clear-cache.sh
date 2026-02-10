#!/usr/bin/env bash
# Data Grid キャッシュを REST API で全件クリアする（Hyperfoil に依存しない確実な方法）
# POST /rest/v2/caches/{cacheName}?action=clear → 204 で全エントリ削除
# 例: ./clear-cache.sh  または  ./run.sh datagrid clear-cache [--cache-name benchmark]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_NAME="${HYPERFOIL_CACHE_NAME:-benchmark}"
REST_BASE_URL="${DATAGRID_REST_URL:-}"
NAMESPACE="${DATAGRID_NAMESPACE:-datagrid}"
CLUSTER_NAME="${DATAGRID_CLUSTER_NAME:-infinispan}"
REST_USER="${DATAGRID_REST_USER:-}"
REST_PASSWORD="${DATAGRID_REST_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rest-url)       REST_BASE_URL="$2"; shift 2 ;;
    --cache-name)     CACHE_NAME="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --rest-user)      REST_USER="$2"; shift 2 ;;
    --rest-password)  REST_PASSWORD="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--rest-url URL] [--cache-name NAME] [--namespace NS] [--rest-user USER] [--rest-password PW]"
      echo "  指定キャッシュの全エントリを Data Grid REST API (action=clear) で削除します。"
      echo "  認証は未指定時は Data Grid の Secret から取得。Route が無い場合は --rest-url で port-forward 先を指定。"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

source "${SCRIPT_DIR}/rest-common.sh"

echo "キャッシュ '${CACHE_NAME}' を全件クリアします (POST ${REST_BASE_URL}/rest/v2/caches/${CACHE_NAME}?action=clear)"
CODE=$(curl "${CURL_OPTS[@]}" "${CURL_AUTH[@]}" -o /dev/null -w "%{http_code}" -X POST "${REST_BASE_URL}/rest/v2/caches/${CACHE_NAME}?action=clear" 2>/dev/null || echo "000")
if [[ "${CODE}" == "204" ]]; then
  echo "完了しました (HTTP 204 No Content)。キャッシュ内の全エントリが削除されました。"
  echo "確認: ./run.sh datagrid cache-status --cache-name ${CACHE_NAME}"
else
  echo "失敗しました (HTTP ${CODE})。URL・認証・キャッシュ名を確認してください。"
  exit 1
fi
