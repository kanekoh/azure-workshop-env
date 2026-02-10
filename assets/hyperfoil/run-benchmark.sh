#!/usr/bin/env bash
# Hyperfoil で Data Grid へのデータ投入・削除ベンチマークを実行する
# オプション: --records, --payload-bytes, --parallelism, --duration, --cache-name, --rest-url など
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCENARIOS_DIR="${SCRIPT_DIR}/scenarios"
if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

# デフォルト
RECORDS="${HYPERFOIL_DEFAULT_RECORDS:-10000}"
PAYLOAD_BYTES="${HYPERFOIL_DEFAULT_PAYLOAD_BYTES:-1024}"
PARALLELISM="${HYPERFOIL_DEFAULT_PARALLELISM:-4}"
DURATION="${HYPERFOIL_DEFAULT_DURATION:-30}"
CACHE_NAME="${HYPERFOIL_CACHE_NAME:-benchmark}"
REST_BASE_URL="${DATAGRID_REST_URL:-}"
MODE=""
NAMESPACE="${DATAGRID_NAMESPACE:-datagrid}"
CLUSTER_NAME="${DATAGRID_CLUSTER_NAME:-infinispan}"
# ランプアップ（秒）。負荷を直ちにかける場合は 0
RAMP_UP="${RAMP_UP:-0}"
# 出力先（生成ベンチマーク YAML を保存）
OUTPUT_DIR=""
# Hyperfoil Controller API の URL（空の場合は OpenShift の Route から自動検出を試みる）
HYPERFOIL_URL="${HYPERFOIL_URL:-}"
HYPERFOIL_NAMESPACE="${HYPERFOIL_NAMESPACE:-hyperfoil}"
# Run 終了後も Agent を止めない（ログ確認用）
KEEP_AGENTS="${KEEP_AGENTS:-}"
# Data Grid REST 認証（未指定時は Operator 生成 Secret から取得を試みる）
REST_USER="${DATAGRID_REST_USER:-}"
REST_PASSWORD="${DATAGRID_REST_PASSWORD:-}"
# HTTPS 接続時の trustManager（Agent 内の証明書パス。本番相当の性能検証では必須）
TRUST_CA_PATH="${HYPERFOIL_TRUST_CA_PATH:-}"
# 診断モード（--check 時はアップロードせず設定・生成 YAML を表示）
CHECK_MODE=""

usage() {
  echo "Usage: $0 load|delete|load-del [OPTIONS]"
  echo "  load      - データ投入のみ (PUT)"
  echo "  delete    - データ削除のみ (DELETE)。事前にキャッシュにデータがあること"
  echo "  load-del  - 投入後に削除を連続実行"
  echo ""
  echo "Options:"
  echo "  --records N          レコード数（負荷量の目安。duration と併用時は usersPerSec の算出に利用）"
  echo "  --payload-bytes N    1 レコードあたりのペイロードサイズ (bytes)"
  echo "  --parallelism N     同時セッション数（並列度）"
  echo "  --duration N         フェーズ実行時間（秒）"
  echo "  --cache-name NAME    キャッシュ名"
  echo "  --rest-url URL       Data Grid REST のベース URL (例: https://infinispan-datagrid.apps.example.com)"
  echo "  --namespace NS       Data Grid の namespace（--rest-url 未指定時に Route 検出に使用）"
  echo "  --ramp-up N          ランプアップ秒数（未使用時は 0）"
  echo "  --output-dir DIR     生成 YAML の出力先"
  echo "  --hyperfoil-url URL  Hyperfoil Controller API（未指定時は namespace ${HYPERFOIL_NAMESPACE} の Route から自動検出を試みる）"
  echo "  --hyperfoil-namespace NS  Hyperfoil がデプロイされている namespace（自動検出時に使用）"
  echo "  --rest-user USER     Data Grid REST 認証ユーザ（未指定時は Operator 生成 Secret から取得を試みる）"
  echo "  --rest-password PW   Data Grid REST 認証パスワード（--rest-user と併用）"
  echo "  --keep-agents        Run 終了後も Agent Pod を停止しない（ログ確認用: oc logs -n ${HYPERFOIL_NAMESPACE} <agent-pod>）"
  echo "  --trust-ca-path PATH Agent 内の CA/証明書ファイルパス（HTTPS で本番相当検証する場合に指定。Data Grid 証明書をマウントしたパス）"
  echo "  --check               診断のみ（URL・認証・YAML を表示し、アップロード・Run 開始は行わない）"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    load)      MODE="load"; shift ;;
    delete)    MODE="delete"; shift ;;
    load-del)  MODE="load-del"; shift ;;
    --records)        RECORDS="$2";   shift 2 ;;
    --payload-bytes)  PAYLOAD_BYTES="$2"; shift 2 ;;
    --parallelism)    PARALLELISM="$2"; shift 2 ;;
    --duration)       DURATION="$2"; shift 2 ;;
    --cache-name)     CACHE_NAME="$2"; shift 2 ;;
    --rest-url)       REST_BASE_URL="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --ramp-up)        RAMP_UP="$2"; shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
    --hyperfoil-url)       HYPERFOIL_URL="$2"; shift 2 ;;
    --hyperfoil-namespace) HYPERFOIL_NAMESPACE="$2"; shift 2 ;;
    --rest-user)           REST_USER="$2"; shift 2 ;;
    --rest-password)       REST_PASSWORD="$2"; shift 2 ;;
    --keep-agents)         KEEP_AGENTS="1"; shift ;;
    --trust-ca-path)       TRUST_CA_PATH="$2"; shift 2 ;;
    --check)               CHECK_MODE="1"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option or mode: $1"; usage ;;
  esac
done

if [[ -z "${MODE}" ]]; then
  echo "Specify mode: load, delete, or load-del"
  usage
fi

# --- Hyperfoil Controller URL ---
# 未指定時は OpenShift Route の status.ingress[0].host を取得（Route 名 "hyperfoil" で取得 → 失敗時は先頭1件）
if [[ -z "${HYPERFOIL_URL}" ]]; then
  HF_ROUTE_HOST=$(oc get route hyperfoil -n "${HYPERFOIL_NAMESPACE}" -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || true)
  if [[ -z "${HF_ROUTE_HOST}" ]]; then
    HF_ROUTE_HOST=$(oc get route -n "${HYPERFOIL_NAMESPACE}" -o jsonpath='{.items[0].status.ingress[0].host}' 2>/dev/null || true)
  fi
  if [[ -n "${HF_ROUTE_HOST}" && "${HF_ROUTE_HOST}" == *.* ]]; then
    HYPERFOIL_URL="https://${HF_ROUTE_HOST}"
    echo "Using Hyperfoil Controller URL from Route (${HYPERFOIL_NAMESPACE}): ${HYPERFOIL_URL}"
  fi
fi

# --- Data Grid REST URL ---
# 未指定時は Route の status.ingress[0].host、無ければクラスタ内 Service URL
if [[ -z "${REST_BASE_URL}" ]]; then
  ROUTE_HOST=$(oc get route -n "${NAMESPACE}" -o jsonpath='{.items[0].status.ingress[0].host}' 2>/dev/null || true)
  if [[ -n "${ROUTE_HOST}" && "${ROUTE_HOST}" == *.* ]]; then
    REST_BASE_URL="https://${ROUTE_HOST}"
    echo "Using Data Grid REST URL from Route: ${REST_BASE_URL}"
  else
    # 本番相当: クラスタ内も TLS 有効（Operator は 11222 で TLS）。性能検証は本番と同じ構成で行う
    DATAGRID_REST_PORT="${DATAGRID_REST_PORT:-11222}"
    REST_BASE_URL="https://${CLUSTER_NAME}.${NAMESPACE}.svc.cluster.local:${DATAGRID_REST_PORT}"
    echo "Using Data Grid REST URL (cluster-internal, TLS): ${REST_BASE_URL}"
  fi
fi

# テンプレート用に host / port / protocol に分解
if [[ "${REST_BASE_URL}" == https://* ]]; then
  REST_PROTOCOL="https"
  REST_PORT="443"
  REST_HOST="${REST_BASE_URL#https://}"
  [[ "${REST_HOST}" == *:* ]] && REST_PORT="${REST_HOST##*:}" && REST_HOST="${REST_HOST%%:*}"
  if [[ -z "${TRUST_CA_PATH}" ]]; then
    echo "WARNING: HTTPS で接続しますが --trust-ca-path が未指定です。Agent で証明書検証に失敗する場合は、Data Grid の CA/証明書を Agent にマウントし --trust-ca-path でそのパスを指定してください（本番相当の性能検証では必須）。"
  fi
elif [[ "${REST_BASE_URL}" == http://* ]]; then
  REST_PROTOCOL="http"
  REST_HOST="${REST_BASE_URL#http://}"
  if [[ "${REST_HOST}" == *:* ]]; then
    REST_PORT="${REST_HOST##*:}"
    REST_HOST="${REST_HOST%%:*}"
  else
    REST_PORT="${DATAGRID_REST_PORT:-11222}"
  fi
else
  REST_PROTOCOL="https"
  REST_PORT="443"
  REST_HOST="${REST_BASE_URL}"
fi

# --- Data Grid REST 認証（未指定時は Operator 生成 Secret から取得）---
# Operator の Secret はバージョンにより .data.username/.password のほか、
# identities.yaml / identities / identities-batch などの形式がある
# 認証取得中の oc/jq 失敗で set -e に落ちないよう一時的に無効化
if [[ -z "${REST_USER}" || -z "${REST_PASSWORD}" ]]; then
  set +e
  AUTH_SECRET=""
  AUTH_SECRET=$(oc get infinispan "${CLUSTER_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.security.endpointSecretName}' 2>/dev/null || true)
  if [[ -z "${AUTH_SECRET}" ]]; then
    for candidate in "${CLUSTER_NAME}-generated-secret" "infinispan-generated-secret"; do
      if oc get secret "${candidate}" -n "${NAMESPACE}" -o name &>/dev/null; then
        AUTH_SECRET="${candidate}"
        break
      fi
    done
  fi
  CREDENTIAL_SOURCE=""
  if [[ -n "${AUTH_SECRET}" ]]; then
    # 1) 平の username / password キー
    REST_USER=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
    REST_PASSWORD=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [[ -z "${REST_USER}" || -z "${REST_PASSWORD}" ]]; then
      # 2) identities.yaml（キー名にドットがある場合は go-template で取得）
      IDENTS=""
      for key in "identities.yaml" "identities"; do
        if [[ "$key" == "identities.yaml" ]]; then
          IDENTS=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o go-template='{{index .data "identities.yaml"}}' 2>/dev/null | base64 -d 2>/dev/null || true)
        else
          IDENTS=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
        fi
        [[ -n "${IDENTS}" ]] && break
      done
      if [[ -n "${IDENTS}" ]]; then
        REST_USER=$(echo "${IDENTS}" | grep -E '^[[:space:]]*username:' | head -1 | sed 's/.*username:[[:space:]]*//' | tr -d '\r')
        REST_PASSWORD=$(echo "${IDENTS}" | grep -E '^[[:space:]]*password:' | head -1 | sed 's/.*password:[[:space:]]*//' | tr -d '\r')
        if [[ -z "${REST_USER}" ]]; then
          REST_USER=$(echo "${IDENTS}" | grep -A2 'username:' | grep 'username:' | head -1 | sed 's/.*username:[[:space:]]*//' | tr -d '\r')
          REST_PASSWORD=$(echo "${IDENTS}" | grep -A2 'username:' | grep 'password:' | head -1 | sed 's/.*password:[[:space:]]*//' | tr -d '\r')
        fi
        [[ -z "${REST_USER}" ]] && REST_USER="developer"
        [[ -n "${REST_USER}" && -n "${REST_PASSWORD}" ]] && CREDENTIAL_SOURCE="Secret ${AUTH_SECRET} (key: identities.yaml or identities)"
      fi
    fi
    if [[ -z "${REST_USER}" || -z "${REST_PASSWORD}" ]]; then
      # 3) identities-batch（CLI 形式: "user create <name> -p <password>"）
      BATCH=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.identities-batch}' 2>/dev/null | base64 -d 2>/dev/null || true)
      if [[ -n "${BATCH}" ]]; then
        REST_USER=$(echo "${BATCH}" | sed -n 's/.*user create \([^ ][^ ]*\) .*/\1/p' | head -1)
        REST_PASSWORD=$(echo "${BATCH}" | sed -n 's/.* -p \([^ ][^ ]*\).*/\1/p' | head -1)
        [[ -z "${REST_USER}" ]] && REST_USER="developer"
        [[ -n "${REST_USER}" && -n "${REST_PASSWORD}" ]] && CREDENTIAL_SOURCE="Secret ${AUTH_SECRET} (key: identities-batch)"
      fi
    fi
    # 4) キー名に依存しない: Secret の全 data キーをデコードし、YAML/CLI 形式なら認証を抽出
    if [[ -z "${REST_USER}" || -z "${REST_PASSWORD}" ]]; then
      SECRET_JSON=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o json 2>/dev/null || true)
      if [[ -n "${SECRET_JSON}" ]]; then
        KEYS=$(echo "${SECRET_JSON}" | jq -r '.data | keys[]' 2>/dev/null || true)
        for k in ${KEYS}; do
          [[ -z "$k" ]] && continue
          VAL=$(echo "${SECRET_JSON}" | jq -r --arg key "$k" '.data[$key] // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
          [[ -z "${VAL}" ]] && continue
          # YAML 形式 (username: / password:)
          U=$(echo "${VAL}" | grep -E '^[[:space:]]*username:' | head -1 | sed 's/.*username:[[:space:]]*//' | tr -d '\r')
          P=$(echo "${VAL}" | grep -E '^[[:space:]]*password:' | head -1 | sed 's/.*password:[[:space:]]*//' | tr -d '\r')
          [[ -z "$U" ]] && U=$(echo "${VAL}" | grep -A2 'username:' | grep 'username:' | head -1 | sed 's/.*username:[[:space:]]*//' | tr -d '\r')
          [[ -z "$P" ]] && P=$(echo "${VAL}" | grep -A2 'username:' | grep 'password:' | head -1 | sed 's/.*password:[[:space:]]*//' | tr -d '\r')
          if [[ -z "$U" || -z "$P" ]]; then
            # identities-batch 形式
            U=$(echo "${VAL}" | sed -n 's/.*user create \([^ ][^ ]*\) .*/\1/p' | head -1)
            P=$(echo "${VAL}" | sed -n 's/.* -p \([^ ][^ ]*\).*/\1/p' | head -1)
          fi
          [[ -z "$U" ]] && U="developer"
          if [[ -n "$U" && -n "$P" ]]; then
            REST_USER="$U"
            REST_PASSWORD="$P"
            CREDENTIAL_SOURCE="Secret ${AUTH_SECRET} (key: ${k})"
            break
          fi
        done
      fi
    fi
    [[ -n "${REST_USER}" && -n "${REST_PASSWORD}" && -z "${CREDENTIAL_SOURCE}" ]] && CREDENTIAL_SOURCE="Secret ${AUTH_SECRET} (key: username/password)"
  fi
fi
if [[ -n "${REST_USER}" && -n "${REST_PASSWORD}" ]]; then
  REST_BASE64_AUTH=$(echo -n "${REST_USER}:${REST_PASSWORD}" | base64 | tr -d '\n')
  REST_AUTH_HEADERS_YAML="                headers:__NL__                  authorization: \"Basic ${REST_BASE64_AUTH}\""
  echo "Using Data Grid REST credentials (user: ${REST_USER})${CREDENTIAL_SOURCE:+ from ${CREDENTIAL_SOURCE}}"
else
  REST_AUTH_HEADERS_YAML=""
  echo "WARNING: No REST credentials. Data Grid with endpoint auth returns 401 Unauthorized."
  echo "  Use --rest-user / --rest-password, or ensure Secret (e.g. ${CLUSTER_NAME}-generated-secret) in ${NAMESPACE} has username/password, identities.yaml, identities, or identities-batch."
  echo "  Inspect Secret keys: oc get secret ${AUTH_SECRET:-${CLUSTER_NAME}-generated-secret} -n ${NAMESPACE} -o jsonpath='{.data}' | jq -r 'keys[]'"
  echo "  Check generated YAML with --output-dir to confirm Authorization header is present."
fi
set -e

# usersPerSec: レコード数と時間から概算（duration 中に records に近いリクエストを出す）
if [[ "${DURATION}" -gt 0 ]]; then
  USERS_PER_SEC=$(( (RECORDS + DURATION - 1) / DURATION ))
else
  USERS_PER_SEC="${PARALLELISM}"
fi
# 少なくとも 1 は必要
USERS_PER_SEC=$(( USERS_PER_SEC > 0 ? USERS_PER_SEC : 1 ))

# 接続プール数（Pool depleted を防ぐ。並列度の 4 倍、最低 16）
SHARED_CONNECTIONS=$(( PARALLELISM * 4 ))
[[ "${SHARED_CONNECTIONS}" -lt 16 ]] && SHARED_CONNECTIONS=16

# ペイロード文字列（YAML に埋め込む用）。大きい場合は注意
PAYLOAD_PLACEHOLDER=""
if [[ "${PAYLOAD_BYTES}" -gt 0 ]]; then
  if [[ "${PAYLOAD_BYTES}" -gt 8192 ]]; then
    PAYLOAD_PLACEHOLDER="(payload ${PAYLOAD_BYTES} bytes - reduce for inline YAML or use bodyFile)"
  else
    # 英小文字のみで指定バイト数（YAML でエスケープしやすい）
    PAYLOAD_PLACEHOLDER=$(python3 -c "print('a' * ${PAYLOAD_BYTES})" 2>/dev/null) || \
      PAYLOAD_PLACEHOLDER=$(printf 'a%.0s' $(seq 1 "${PAYLOAD_BYTES}" 2>/dev/null) || echo "a")
  fi
fi

apply_sed() {
  local f="$1"
  sed -e "s|__CACHE_NAME__|${CACHE_NAME}|g" \
      -e "s|__USERS_PER_SEC__|${USERS_PER_SEC}|g" \
      -e "s|__PARALLELISM__|${PARALLELISM}|g" \
      -e "s|__DURATION__|${DURATION}|g" \
      -e "s|__REST_BASE_URL__|${REST_BASE_URL}|g" \
      -e "s|__REST_HOST__|${REST_HOST}|g" \
      -e "s|__REST_PORT__|${REST_PORT}|g" \
      -e "s|__REST_PROTOCOL__|${REST_PROTOCOL}|g" \
      -e "s|__PAYLOAD_BYTES__|${PAYLOAD_BYTES}|g" \
      -e "s|__RECORDS__|${RECORDS}|g" \
      -e "s|__PAYLOAD_PLACEHOLDER__|${PAYLOAD_PLACEHOLDER}|g" \
      -e "s|__SHARED_CONNECTIONS__|${SHARED_CONNECTIONS}|g" \
      "$f"
}

# 認証ヘッダブロックを YAML に挿入（プレースホルダ行を置換。__NL__ を改行に）
inject_auth_headers() {
  local file="$1"
  if [[ -n "${REST_AUTH_HEADERS_YAML}" ]]; then
    awk -v block="${REST_AUTH_HEADERS_YAML}" '
      BEGIN { n = split(block, a, "__NL__"); for (i = 1; i <= n; i++) lines[i] = a[i] }
      /__REST_AUTH_HEADERS_YAML__/ { for (i = 1; i <= n; i++) print lines[i]; next }
      { print }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  else
    grep -v '__REST_AUTH_HEADERS_YAML__' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  fi
}

# --keep-agents 時: agent-one に stop: false を追加（Run 終了後も Pod を残してログ確認可能に）
inject_keep_agents() {
  local file="$1"
  if [[ -n "${KEEP_AGENTS}" ]]; then
    awk '/agent-one: \{\}/ { print "  agent-one:"; print "    stop: false"; next } { print }' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  fi
}

# HTTPS 時: trustManager を注入（__TRUST_MANAGER_YAML__ を置換）。未指定なら行を削除
inject_trust_manager() {
  local file="$1"
  if [[ -n "${TRUST_CA_PATH}" ]]; then
    # YAML インデント: http の直下なので 2 スペース
    awk -v path="${TRUST_CA_PATH}" '
      /__TRUST_MANAGER_YAML__/ {
        print "  trustManager:"
        print "    certFile: \"" path "\""
        next
      }
      { print }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  else
    grep -v '__TRUST_MANAGER_YAML__' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  fi
}

case "${MODE}" in
  load)
    TPL="${SCENARIOS_DIR}/load.yaml.tpl"
    ;;
  delete)
    TPL="${SCENARIOS_DIR}/delete.yaml.tpl"
    ;;
  load-del)
    TPL="${SCENARIOS_DIR}/load-and-delete.yaml.tpl"
    ;;
  *)
    echo "Invalid mode: ${MODE}"
    exit 1
    ;;
esac

if [[ ! -f "${TPL}" ]]; then
  echo "Template not found: ${TPL}"
  exit 1
fi

BENCH_YAML=$(mktemp -t hyperfoil-bench-XXXXXX.yaml)
trap "rm -f ${BENCH_YAML} ${BENCH_YAML}.tmp ${BENCH_YAML}.bak" EXIT
apply_sed "${TPL}" > "${BENCH_YAML}"
inject_auth_headers "${BENCH_YAML}"
inject_trust_manager "${BENCH_YAML}"
inject_keep_agents "${BENCH_YAML}"

if [[ -n "${OUTPUT_DIR}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
  cp "${BENCH_YAML}" "${OUTPUT_DIR}/benchmark-${MODE}.yaml"
  echo "Saved: ${OUTPUT_DIR}/benchmark-${MODE}.yaml"
fi

echo "Generated benchmark: mode=${MODE}, records≈${RECORDS}, payload=${PAYLOAD_BYTES}B, parallelism=${PARALLELISM}, duration=${DURATION}s, usersPerSec=${USERS_PER_SEC}, sharedConnections=${SHARED_CONNECTIONS}"
echo "--- Generated YAML (first 40 lines) ---"
head -n 40 "${BENCH_YAML}"
echo "..."

if [[ -n "${CHECK_MODE}" ]]; then
  echo ""
  echo "========== 診断レポート (--check) =========="
  echo "Data Grid REST URL: ${REST_BASE_URL}"
  echo "認証: $([ -n "${REST_USER}" ] && echo "取得済み (user: ${REST_USER})${CREDENTIAL_SOURCE:+ from ${CREDENTIAL_SOURCE}}" || echo "未取得 (401 の原因になり得る)")"
  echo "trust-ca-path: ${TRUST_CA_PATH:-未指定}"
  echo "sharedConnections: ${SHARED_CONNECTIONS} (プール本数。0や未設定だと実質1本になり Pool depleted の原因)"
  echo "Hyperfoil Controller: ${HYPERFOIL_URL:-未検出}"
  echo ""
  echo "--- 生成 YAML の http と最初のリクエスト部分 ---"
  sed -n '/^http:/,/^phases:/p' "${BENCH_YAML}" | sed '$d'
  sed -n '/scenario:/,/metric:/p' "${BENCH_YAML}" | head -20
  echo ""
  echo "--- 原因追求のためのログ確認コマンド ---"
  echo "Agent ログ (直近): oc logs -n ${HYPERFOIL_NAMESPACE} -l app.kubernetes.io/name=hyperfoil-agent -c agent --tail=100"
  echo "Controller ログ:   oc logs -n ${HYPERFOIL_NAMESPACE} -l app=hyperfoil -c controller --tail=100"
  echo "Secret のキー一覧: oc get secret ${AUTH_SECRET:-${CLUSTER_NAME}-generated-secret} -n ${NAMESPACE} -o jsonpath='{.data}' | jq -r 'keys[]'"
  echo "=========================================="
  exit 0
fi

if [[ -n "${HYPERFOIL_URL}" ]]; then
  HYPERFOIL_URL="${HYPERFOIL_URL%/}"
  # Hyperfoil API: (1) POST /benchmark で YAML を登録 → 204, (2) GET /benchmark/{name}/start で実行開始 → 202 と Run JSON
  BENCHMARK_NAME="datagrid-load"
  [[ "${MODE}" == "delete" ]] && BENCHMARK_NAME="datagrid-delete"
  [[ "${MODE}" == "load-del" ]] && BENCHMARK_NAME="datagrid-load-and-delete"

  echo "Uploading benchmark to Hyperfoil at ${HYPERFOIL_URL}..."
  UPLOAD_RESP=$(mktemp -t hyperfoil-upload-XXXXXX)
  HTTP_CODE=$(curl -s -k -w "%{http_code}" -o "${UPLOAD_RESP}" -X POST -H "Content-Type: text/vnd.yaml" --data-binary "@${BENCH_YAML}" "${HYPERFOIL_URL}/benchmark")
  if [[ "${HTTP_CODE}" != "204" && "${HTTP_CODE}" != "200" ]]; then
    echo "Upload failed (HTTP ${HTTP_CODE}). Response:"
    cat "${UPLOAD_RESP}" 2>/dev/null || true
    rm -f "${UPLOAD_RESP}"
    exit 1
  fi
  rm -f "${UPLOAD_RESP}"

  echo "Starting run for benchmark '${BENCHMARK_NAME}'..."
  RUN_JSON=$(curl -s -k -X GET "${HYPERFOIL_URL}/benchmark/${BENCHMARK_NAME}/start")
  RUN_ID=$(echo "${RUN_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
  if [[ -z "${RUN_ID}" ]]; then
    RUN_ID=$(echo "${RUN_JSON}" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
  fi
  if [[ -z "${RUN_ID}" ]]; then
    echo "Start failed. Response: ${RUN_JSON}"
    exit 1
  fi
  echo "Run ID: ${RUN_ID}. Status: ${HYPERFOIL_URL}/run/${RUN_ID}"
  if [[ -n "${KEEP_AGENTS}" ]]; then
    echo "Agent は Run 終了後も停止しません。ログ確認: oc get pods -n ${HYPERFOIL_NAMESPACE} で Agent Pod を確認し、oc logs <pod名> -n ${HYPERFOIL_NAMESPACE} で表示できます。"
  fi
else
  echo "Hyperfoil Controller URL could not be determined."
  SUGGEST_HOST=$(oc get route hyperfoil -n "${HYPERFOIL_NAMESPACE}" -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || oc get route -n "${HYPERFOIL_NAMESPACE}" -o jsonpath='{.items[0].status.ingress[0].host}' 2>/dev/null || true)
  if [[ -n "${SUGGEST_HOST}" && "${SUGGEST_HOST}" == *.* ]]; then
    echo "  Route のホストは取得できました。次で再実行: --hyperfoil-url https://${SUGGEST_HOST}"
  else
    echo "  oc get route -n ${HYPERFOIL_NAMESPACE} で HOST を確認し、--hyperfoil-url https://<HOST> を付けて再実行してください。"
  fi
fi
