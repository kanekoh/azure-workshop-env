#!/usr/bin/env bash
# Data Grid キャッシュの状態を REST API で確認する（エントリ数・サンプルキー）
# Hyperfoil が使うキー（key-0, key-1, ...）の有無も表示する
# 例: ./cache-status.sh  または  ./run.sh datagrid cache-status [--cache-name benchmark]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_NAME="${HYPERFOIL_CACHE_NAME:-benchmark}"
REST_BASE_URL="${DATAGRID_REST_URL:-}"
NAMESPACE="${DATAGRID_NAMESPACE:-datagrid}"
CLUSTER_NAME="${DATAGRID_CLUSTER_NAME:-infinispan}"
REST_USER="${DATAGRID_REST_USER:-}"
REST_PASSWORD="${DATAGRID_REST_PASSWORD:-}"
SAMPLE_KEYS="0 1 2 3 4"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rest-url)       REST_BASE_URL="$2"; shift 2 ;;
    --cache-name)     CACHE_NAME="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --rest-user)      REST_USER="$2"; shift 2 ;;
    --rest-password)  REST_PASSWORD="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--rest-url URL] [--cache-name NAME] [--namespace NS] [--rest-user USER] [--rest-password PW]"
      echo "  Data Grid キャッシュのエントリ数と、Hyperfoil が扱うキー（key-0, key-1, ...）の有無を表示します。"
      echo "  認証・証明書は未指定時は Data Grid の Secret（generated-secret, serving cert）から取得します。"
      echo "  Route が無い場合は --rest-url で port-forward 先（例: https://localhost:11222）を指定してください。"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

source "${SCRIPT_DIR}/rest-common.sh"

echo ""
echo "=== キャッシュ: ${CACHE_NAME} (${REST_BASE_URL}) ==="
echo ""

# 認証付きで実行できる curl の例（実際の確認用にそのままコピーして実行可能）
echo "--- 認証付き curl の例（コピーして実行可）---"
if [[ ${#CURL_AUTH[@]} -gt 0 ]]; then
  CURL_AUTH_PART="-u \"${REST_USER}:${REST_PASSWORD}\""
else
  CURL_AUTH_PART=""
fi
CURL_OPTS_PART="${CURL_OPTS[*]}"
echo "  # キャッシュ一覧"
echo "  curl ${CURL_OPTS_PART} ${CURL_AUTH_PART} \"${REST_BASE_URL}/rest/v2/caches\""
echo "  # 統計 (action=stats)"
echo "  curl ${CURL_OPTS_PART} ${CURL_AUTH_PART} \"${REST_BASE_URL}/rest/v2/caches/${CACHE_NAME}?action=stats\""
echo "  # キー一覧 (action=keys)。実在キーはここで確認（個別 GET が 400 でも一覧は取得可能）"
echo "  curl ${CURL_OPTS_PART} ${CURL_AUTH_PART} \"${REST_BASE_URL}/rest/v2/caches/${CACHE_NAME}?action=keys&limit=500\""
echo "  # キー取得例 (key-0)。キャッシュが protostream の場合は 400 になることがある"
echo "  curl ${CURL_OPTS_PART} ${CURL_AUTH_PART} -H 'Key-Content-Type: application/x-java-object;type=java.lang.String' \"${REST_BASE_URL}/rest/v2/caches/${CACHE_NAME}/key-0\""
echo ""

# キャッシュ一覧に存在するか
CACHES=$(curl "${CURL_OPTS[@]}" "${CURL_AUTH[@]}" -w "\n%{http_code}" "${REST_BASE_URL}/rest/v2/caches" 2>/dev/null || true)
HTTP_CODE=""
if [[ -n "${CACHES}" ]]; then
  HTTP_CODE=$(echo "${CACHES}" | tail -n1)
  CACHES=$(echo "${CACHES}" | sed '$d')
fi
if [[ -z "${CACHES}" ]]; then
  echo "REST API に接続できません。URL と認証を確認してください。"
  if [[ -n "${HTTP_CODE}" && "${HTTP_CODE}" != "000" ]]; then
    echo "  HTTP ステータス: ${HTTP_CODE}"
  else
    echo "  接続確認のため curl を再実行します（エラー内容を表示）:"
    if [[ ${#CURL_AUTH[@]} -gt 0 ]]; then
      curl -s -k "${CURL_AUTH[@]}" "${REST_BASE_URL}/rest/v2/caches" 2>&1 || true
    else
      curl -s -k "${REST_BASE_URL}/rest/v2/caches" 2>&1 || true
    fi
  fi
  echo "  ※ port-forward の場合は別ターミナルで: oc port-forward svc/infinispan -n ${NAMESPACE} 11222:11222"
  exit 1
fi
# 一覧は JSON 配列 ["cache1","cache2"] または文字列の可能性
if ! echo "${CACHES}" | grep -qE "\"${CACHE_NAME}\"|${CACHE_NAME}"; then
  echo "キャッシュ '${CACHE_NAME}' は一覧にありません。"
  echo "  (一覧: $(echo "${CACHES}" | tr -d '[]' | head -c 200))"
  exit 1
fi

# 統計
STATS=$(curl "${CURL_OPTS[@]}" "${CURL_AUTH[@]}" "${REST_BASE_URL}/rest/v2/caches/${CACHE_NAME}?action=stats" 2>/dev/null || echo "")
echo "--- 統計 (GET /rest/v2/caches/${CACHE_NAME}?action=stats) ---"
if [[ -z "${STATS}" ]]; then
  echo "  (取得失敗)"
else
  # JSON の current_number_of_entries / number_of_entries または XML の current_number_of_entries
  ENTRIES=$(echo "${STATS}" | jq -r '.current_number_of_entries // .number_of_entries // .["current-number-of-entries"] // empty' 2>/dev/null || true)
  if [[ -z "${ENTRIES}" ]]; then
    ENTRIES=$(echo "${STATS}" | grep -oE 'current_number_of_entries|number_of_entries|current-number-of-entries>[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
    if [[ -z "${ENTRIES}" ]]; then
      # XML 例: <current_number_of_entries>123</current_number_of_entries>
      ENTRIES=$(echo "${STATS}" | sed -n 's/.*current_number_of_entries>\([0-9]*\)<.*/\1/p' | head -1 || true)
    fi
  fi
  if [[ -n "${ENTRIES}" ]]; then
    if [[ "${ENTRIES}" == "-1" ]]; then
      echo "  エントリ数: 不明 (API が -1 を返しています。キャッシュで statistics が無効の可能性)"
    else
      echo "  エントリ数: ${ENTRIES}"
    fi
  fi
  if command -v jq &>/dev/null && echo "${STATS}" | jq -e . &>/dev/null; then
    echo "${STATS}" | jq -r '
      if .hits != null then "  ヒット数: \(.hits)" else empty end,
      if .misses != null then "  ミス数: \(.misses)" else empty end,
      if .hits != null and .misses != null and ((.hits + .misses) > 0) then "  ヒット率: \((.hits * 100 / (.hits + .misses)) | floor)%" else empty end
    ' 2>/dev/null || true
  fi
  # 生レスポンスが短ければ表示
  if [[ -z "${ENTRIES}" && ${#STATS} -lt 600 ]]; then
    echo "  (生レスポンス: ${STATS})"
  fi
fi

# キー一覧（action=keys）。個別 GET は protostream 等で 400 になることがあるため、一覧で実在キーを確認する
KEYS_JSON=$(curl "${CURL_OPTS[@]}" "${CURL_AUTH[@]}" -s "${REST_BASE_URL}/rest/v2/caches/${CACHE_NAME}?action=keys&limit=500" 2>/dev/null || echo "[]")
echo ""
echo "--- キー一覧 (GET /rest/v2/caches/${CACHE_NAME}?action=keys) ---"
if [[ -z "${KEYS_JSON}" || "${KEYS_JSON}" == "[]" ]]; then
  echo "  (キーなし、または取得失敗)"
else
  KEY_COUNT=$(echo "${KEYS_JSON}" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || echo "0")
  echo "  キー数: ${KEY_COUNT}"
  if [[ "${KEY_COUNT}" -gt 0 ]]; then
    # 最大20件まで表示。key-0, key-1 等があれば先頭に、それ以外は先頭数件
    echo "  サンプル: $(echo "${KEYS_JSON}" | jq -r 'if type == "array" then .[0:20] | join(", ") else . end' 2>/dev/null | head -c 200)"
    if [[ "${KEY_COUNT}" -gt 20 ]]; then
      echo "  (先頭20件のみ表示。全件は ?action=keys&limit=-1 で取得)"
    fi
  fi
fi

echo ""
echo "--- Hyperfoil が扱うキー ---"
echo "  load:  PUT  /rest/v2/caches/${CACHE_NAME}/key-\${hyperfoil.session.id}  → key-0, key-1, key-2, ..."
echo "  delete: DELETE 同上。キーの有無は上記「キー一覧」で確認（個別 GET は encoding により 400 になることがあります）。"

echo ""
echo "--- 見方 ---"
echo "  • エントリ数: キャッシュ内のキー数。-1 はキャッシュで statistics が無効のため不明。Cache に statistics: \"true\" を付けると表示される（例: datagrid/cache-benchmark.yaml）。clear すると 0 になる（statistics 有効時）。"
echo "  • キー一覧: action=keys で取得。実在するキーはここで確認できる（個別 GET が 400 でも一覧は取得可能）。"
echo "  • ヒット/ミス: GET の累積統計。clear してもリセットされない（Data Grid の仕様）。"
echo ""
echo "  ※ エントリ数を増やす: ./run.sh hyperfoil load --cache-name ${CACHE_NAME}"
echo "  ※ 同じキーを削除:     ./run.sh hyperfoil delete --cache-name ${CACHE_NAME}  （load 後に実行するか load-del で投入→削除）"
