#!/usr/bin/env bash
# キャッシュ定義を REST API で削除する（DELETE /rest/v2/caches/{cacheName}）
# 用途: 統計有効な template で作り直すため。削除後は Operator が Cache CR に従いキャッシュを再作成する。
# 例: ./delete-cache.sh  または  ./run.sh datagrid delete-cache [--rest-url https://localhost:11222]
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
      echo "  指定キャッシュを REST API で削除します（定義ごと削除。中身の clear ではない）。"
      echo "  Operator が Cache CR に従い同じ名前のキャッシュを template で再作成します。"
      echo "  統計を有効にしたい場合: 本コマンド実行後、cache-status でエントリ数が数値になるか確認。"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

source "${SCRIPT_DIR}/rest-common.sh"

echo "キャッシュ '${CACHE_NAME}' を削除します (DELETE ${REST_BASE_URL}/rest/v2/caches/${CACHE_NAME})"
CODE=$(curl "${CURL_OPTS[@]}" "${CURL_AUTH[@]}" -o /dev/null -w "%{http_code}" -X DELETE "${REST_BASE_URL}/rest/v2/caches/${CACHE_NAME}" 2>/dev/null || echo "000")
if [[ "${CODE}" == "200" || "${CODE}" == "204" ]]; then
  echo "完了しました (HTTP ${CODE})。Operator が Cache CR に従いキャッシュを再作成します。"
  echo "数十秒後: ./run.sh datagrid cache-status --rest-url ${REST_BASE_URL}"
else
  echo "失敗しました (HTTP ${CODE})。URL・認証・キャッシュ名を確認してください。"
  exit 1
fi
