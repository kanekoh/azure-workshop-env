# Data Grid REST 用の共通処理（URL・認証・証明書の解決）
# 使い方: 呼び出し元で CACHE_NAME, NAMESPACE, REST_BASE_URL, REST_USER, REST_PASSWORD を必要に応じて設定してから
#         source "${SCRIPT_DIR}/rest-common.sh"
# 設定される変数: REST_BASE_URL, REST_USER, REST_PASSWORD, CURL_OPTS, CURL_AUTH, CACHE_NAME, NAMESPACE, CLUSTER_NAME
#                 (証明書を使う場合) CERT_FILE, CERT_FILE_CLEANUP, trap で EXIT 時に削除
# set -e の影響を受けないよう oc 実行箇所は set +e で囲む

_DG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DG_ASSETS_DIR="$(cd "${_DG_SCRIPT_DIR}/.." && pwd)"
[[ -f "${_DG_ASSETS_DIR}/config/defaults.env" ]] && source "${_DG_ASSETS_DIR}/config/defaults.env"

CACHE_NAME="${CACHE_NAME:-${HYPERFOIL_CACHE_NAME:-benchmark}}"
NAMESPACE="${NAMESPACE:-${DATAGRID_NAMESPACE:-datagrid}}"
CLUSTER_NAME="${CLUSTER_NAME:-${DATAGRID_CLUSTER_NAME:-infinispan}}"
REST_BASE_URL="${REST_BASE_URL:-${DATAGRID_REST_URL:-}}"
REST_USER="${REST_USER:-${DATAGRID_REST_USER:-}}"
REST_PASSWORD="${REST_PASSWORD:-${DATAGRID_REST_PASSWORD:-}}"

# --- REST URL 解決 ---
if [[ -z "${REST_BASE_URL}" ]]; then
  set +e
  ROUTE_HOST=$(oc get route -n "${NAMESPACE}" -o jsonpath='{.items[0].status.ingress[0].host}' 2>/dev/null) || true
  set -e
  if [[ -n "${ROUTE_HOST}" && "${ROUTE_HOST}" == *.* ]]; then
    REST_BASE_URL="https://${ROUTE_HOST}"
    echo "Using Data Grid REST URL from Route: ${REST_BASE_URL}"
  else
    REST_BASE_URL="https://${CLUSTER_NAME}.${NAMESPACE}.svc.cluster.local:${DATAGRID_REST_PORT:-11222}"
    echo "Using Data Grid REST URL (cluster-internal): ${REST_BASE_URL}"
    echo "  ※ Route が無いためクラスタ内 URL です。手元のマシンから実行している場合は届きません。"
    echo "    → Data Grid の Route を作成するか、port-forward して --rest-url https://localhost:11222 を指定してください。"
  fi
fi
REST_BASE_URL="${REST_BASE_URL%/}"

# --- Data Grid REST 認証（未指定時は Operator 生成 Secret から取得）---
CREDENTIAL_SOURCE=""
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
  if [[ -n "${AUTH_SECRET}" ]]; then
    REST_USER=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
    REST_PASSWORD=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [[ -z "${REST_USER}" || -z "${REST_PASSWORD}" ]]; then
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
        # identities.yaml 形式: credentials: / - username: ... / password: ... （行頭に - あり）
        REST_USER=$(echo "${IDENTS}" | grep -E '^[[:space:]]*(-[[:space:]]+)?username:' | head -1 | sed 's/.*username:[[:space:]]*//' | tr -d '\r')
        REST_PASSWORD=$(echo "${IDENTS}" | grep -E '^[[:space:]]*(-[[:space:]]+)?password:' | head -1 | sed 's/.*password:[[:space:]]*//' | tr -d '\r')
        if [[ -z "${REST_USER}" ]]; then
          REST_USER=$(echo "${IDENTS}" | grep -A2 'username:' | grep 'username:' | head -1 | sed 's/.*username:[[:space:]]*//' | tr -d '\r')
          REST_PASSWORD=$(echo "${IDENTS}" | grep -A2 'username:' | grep 'password:' | head -1 | sed 's/.*password:[[:space:]]*//' | tr -d '\r')
        fi
        if [[ -z "${REST_USER}" && "${IDENTS}" == *'"username"'* ]]; then
          REST_USER=$(echo "${IDENTS}" | jq -r '.credentials[0].username // empty' 2>/dev/null || true)
          REST_PASSWORD=$(echo "${IDENTS}" | jq -r '.credentials[0].password // empty' 2>/dev/null || true)
        fi
        [[ -z "${REST_USER}" ]] && REST_USER="developer"
        [[ -n "${REST_USER}" && -n "${REST_PASSWORD}" ]] && CREDENTIAL_SOURCE="Secret ${AUTH_SECRET} (key: identities.yaml or identities)"
      fi
    fi
    if [[ -z "${REST_USER}" || -z "${REST_PASSWORD}" ]]; then
      BATCH=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.identities-batch}' 2>/dev/null | base64 -d 2>/dev/null || true)
      if [[ -n "${BATCH}" ]]; then
        REST_USER=$(echo "${BATCH}" | sed -n 's/.*user create \([^ ][^ ]*\) .*/\1/p' | head -1)
        REST_PASSWORD=$(echo "${BATCH}" | sed -n 's/.* -p \([^ ][^ ]*\).*/\1/p' | head -1)
        [[ -z "${REST_USER}" ]] && REST_USER="developer"
        [[ -n "${REST_USER}" && -n "${REST_PASSWORD}" ]] && CREDENTIAL_SOURCE="Secret ${AUTH_SECRET} (key: identities-batch)"
      fi
    fi
    if [[ -z "${REST_USER}" || -z "${REST_PASSWORD}" ]]; then
      SECRET_JSON=$(oc get secret "${AUTH_SECRET}" -n "${NAMESPACE}" -o json 2>/dev/null || true)
      if [[ -n "${SECRET_JSON}" ]]; then
        KEYS=$(echo "${SECRET_JSON}" | jq -r '.data | keys[]' 2>/dev/null || true)
        for k in ${KEYS}; do
          [[ -z "$k" ]] && continue
          VAL=$(echo "${SECRET_JSON}" | jq -r --arg key "$k" '.data[$key] // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
          [[ -z "${VAL}" ]] && continue
          # YAML: "  - username: ..." / "    password: ..." にマッチするよう (-[[:space:]]+)? を許容
          U=$(echo "${VAL}" | grep -E '^[[:space:]]*(-[[:space:]]+)?username:' | head -1 | sed 's/.*username:[[:space:]]*//' | tr -d '\r')
          P=$(echo "${VAL}" | grep -E '^[[:space:]]*(-[[:space:]]+)?password:' | head -1 | sed 's/.*password:[[:space:]]*//' | tr -d '\r')
          [[ -z "$U" ]] && U=$(echo "${VAL}" | grep -A2 'username:' | grep 'username:' | head -1 | sed 's/.*username:[[:space:]]*//' | tr -d '\r')
          [[ -z "$P" ]] && P=$(echo "${VAL}" | grep -A2 'username:' | grep 'password:' | head -1 | sed 's/.*password:[[:space:]]*//' | tr -d '\r')
          if [[ -z "$U" || -z "$P" ]]; then
            U=$(echo "${VAL}" | sed -n 's/.*user create \([^ ][^ ]*\) .*/\1/p' | head -1)
            P=$(echo "${VAL}" | sed -n 's/.* -p \([^ ][^ ]*\).*/\1/p' | head -1)
          fi
          if [[ -z "$U" && "${VAL}" == *'"username"'* ]]; then
            U=$(echo "${VAL}" | jq -r '.credentials[0].username // empty' 2>/dev/null || true)
            P=$(echo "${VAL}" | jq -r '.credentials[0].password // empty' 2>/dev/null || true)
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
  set -e
fi
if [[ -n "${REST_USER}" && -n "${REST_PASSWORD}" ]]; then
  echo "Using Data Grid REST credentials (user: ${REST_USER})${CREDENTIAL_SOURCE:+ from ${CREDENTIAL_SOURCE}}"
else
  echo "WARNING: No REST credentials from Data Grid Secret. Use --rest-user / --rest-password, or check Secret in ${NAMESPACE}."
  echo "  oc get secret ${AUTH_SECRET:-${CLUSTER_NAME}-generated-secret} -n ${NAMESPACE} -o jsonpath='{.data}' | jq -r 'keys[]'"
fi

# --- OpenShift serving certificate（Data Grid の TLS 用）を Secret から取得 ---
CERT_FILE=""
CERT_FILE_CLEANUP=""
if [[ "${REST_BASE_URL}" == https://* ]]; then
  set +e
  CERT_SECRET_NAME=$(oc get infinispan "${CLUSTER_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.security.endpointEncryption.certSecretName}' 2>/dev/null || true)
  if [[ -z "${CERT_SECRET_NAME}" ]]; then
    for candidate in "${CLUSTER_NAME}-cert-secret" "infinispan-cert-secret"; do
      if oc get secret "${candidate}" -n "${NAMESPACE}" -o name &>/dev/null; then
        CERT_SECRET_NAME="${candidate}"
        break
      fi
    done
  fi
  if [[ -n "${CERT_SECRET_NAME}" ]]; then
    TLS_CRT_B64=$(oc get secret "${CERT_SECRET_NAME}" -n "${NAMESPACE}" -o go-template='{{index .data "tls.crt"}}' 2>/dev/null || true)
    if [[ -z "${TLS_CRT_B64}" ]]; then
      TLS_CRT_B64=$(oc get secret "${CERT_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
    fi
    if [[ -n "${TLS_CRT_B64}" ]]; then
      CERT_FILE=$(mktemp -t dg-cacert.XXXXXX.pem)
      CERT_FILE_CLEANUP="${CERT_FILE}"
      echo "${TLS_CRT_B64}" | base64 -d 2>/dev/null > "${CERT_FILE}" || true
      if [[ -s "${CERT_FILE}" ]]; then
        echo "Using Data Grid serving certificate from Secret ${CERT_SECRET_NAME}"
      else
        rm -f "${CERT_FILE}"
        CERT_FILE=""
        CERT_FILE_CLEANUP=""
      fi
    fi
  fi
  set -e
fi
cleanup_cert() { [[ -n "${CERT_FILE_CLEANUP}" && -f "${CERT_FILE_CLEANUP}" ]] && rm -f "${CERT_FILE_CLEANUP}"; }
trap cleanup_cert EXIT

# curl オプション
CURL_OPTS=(-s)
REST_HOST_FOR_VERIFY="${REST_BASE_URL#https://}"
REST_HOST_FOR_VERIFY="${REST_HOST_FOR_VERIFY#http://}"
REST_HOST_FOR_VERIFY="${REST_HOST_FOR_VERIFY%%:*}"
if [[ -n "${CERT_FILE}" && -f "${CERT_FILE}" && "${REST_BASE_URL}" == https://* ]]; then
  if [[ "${REST_HOST_FOR_VERIFY}" != "localhost" && "${REST_HOST_FOR_VERIFY}" != "127.0.0.1" ]]; then
    CURL_OPTS=(-s --cacert "${CERT_FILE}")
  else
    CURL_OPTS=(-s -k)
  fi
else
  CURL_OPTS=(-s -k)
fi
if [[ -n "${REST_USER}" && -n "${REST_PASSWORD}" ]]; then
  CURL_AUTH=(-u "${REST_USER}:${REST_PASSWORD}")
else
  CURL_AUTH=()
fi
