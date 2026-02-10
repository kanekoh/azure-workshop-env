#!/usr/bin/env bash
# Hyperfoil の登録ベンチマークと Run の状態を API で確認する
# 例: ./status.sh  または  ./run.sh hyperfoil status [--run-id 0000]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

HYPERFOIL_URL="${HYPERFOIL_URL:-}"
HYPERFOIL_NAMESPACE="${HYPERFOIL_NAMESPACE:-hyperfoil}"
RUN_ID=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hyperfoil-url)   HYPERFOIL_URL="$2"; shift 2 ;;
    --run-id)          RUN_ID="$2"; shift 2 ;;
    -o|--output)       OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--hyperfoil-url URL] [--run-id RUN_ID] [-o|--output FILE]"
      echo "  -o, --output FILE  結果をファイルにも出力する（標準出力と同時に書き出す）"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ファイル出力オプション: 標準出力を tee でファイルにも書き出す
if [[ -n "${OUTPUT_FILE}" ]]; then
  exec > >(tee "${OUTPUT_FILE}")
fi

# Controller URL を解決（oc 未使用・未ログイン・Route 無しでも set -e で落ちないよう set +e）
if [[ -z "${HYPERFOIL_URL}" ]]; then
  set +e
  HF_ROUTE_HOST=$(oc get route hyperfoil -n "${HYPERFOIL_NAMESPACE}" -o jsonpath='{.status.ingress[0].host}' 2>/dev/null) || true
  if [[ -z "${HF_ROUTE_HOST}" ]]; then
    HF_ROUTE_HOST=$(oc get route -n "${HYPERFOIL_NAMESPACE}" -o jsonpath='{.items[0].status.ingress[0].host}' 2>/dev/null) || true
  fi
  set -e
  if [[ -n "${HF_ROUTE_HOST}" && "${HF_ROUTE_HOST}" == *.* ]]; then
    HYPERFOIL_URL="https://${HF_ROUTE_HOST}"
  fi
fi

if [[ -z "${HYPERFOIL_URL}" ]]; then
  echo "Hyperfoil Controller URL が取得できません。"
  echo "  oc でクラスタに接続していない場合（例: Mac から接続なし）は --hyperfoil-url で URL を指定してください。"
  echo "  例: ./run.sh hyperfoil status --hyperfoil-url https://hyperfoil-hyperfoil.apps.<cluster>/ --run-id 0007"
  echo "  oc を使う場合: oc get route -n ${HYPERFOIL_NAMESPACE} で Route を確認してください。"
  exit 1
fi

HYPERFOIL_URL="${HYPERFOIL_URL%/}"
CURL_OPTS=(-s -k)

echo "=== Hyperfoil Controller: ${HYPERFOIL_URL} ==="
echo ""

# 登録ベンチマーク一覧
echo "--- 登録ベンチマーク (GET /benchmark) ---"
BENCHMARKS=$(curl "${CURL_OPTS[@]}" "${HYPERFOIL_URL}/benchmark" 2>/dev/null || echo "[]")
if [[ "${BENCHMARKS}" == "[]" || -z "${BENCHMARKS}" ]]; then
  echo "  (なし)"
else
  echo "${BENCHMARKS}" | python3 -c "
import sys, json
try:
    names = json.load(sys.stdin)
    for n in (names if isinstance(names, list) else [names]):
        print(f'  - {n}')
except Exception:
    print(sys.stdin.read())
" 2>/dev/null || echo "  ${BENCHMARKS}"
fi
echo ""

# Run 一覧（詳細付き）
echo "--- Run 一覧 (GET /run?details=true) ---"
RUNS_JSON=$(curl "${CURL_OPTS[@]}" "${HYPERFOIL_URL}/run?details=true" 2>/dev/null || echo "[]")
if [[ "${RUNS_JSON}" == "[]" || -z "${RUNS_JSON}" ]]; then
  echo "  (なし)"
else
  echo "${RUNS_JSON}" | python3 -c "
import sys, json
try:
    runs = json.load(sys.stdin)
    if not isinstance(runs, list): runs = [runs]
    for r in runs:
        rid = r.get('id', '')
        bench = r.get('benchmark', '')
        started = r.get('started', '')
        term = r.get('terminated', '') or '(実行中)'
        completed = r.get('completed', False)
        status = 'TERMINATED' if term != '(実行中)' else 'RUNNING'
        print(f'  Run {rid}: benchmark={bench} started={started} terminated={term} status={status}')
except Exception as e:
    print('  (parse error)', e)
    print(sys.stdin.read()[:500])
" 2>/dev/null || echo "  ${RUNS_JSON:0:500}"
fi
echo ""

# 指定 Run または先頭 Run の詳細
TARGET_RUN_ID="${RUN_ID}"
if [[ -z "${TARGET_RUN_ID}" ]]; then
  TARGET_RUN_ID=$(echo "${RUNS_JSON}" | python3 -c "
import sys, json
try:
    runs = json.load(sys.stdin)
    if isinstance(runs, list) and runs:
        print(runs[0].get('id', ''))
except Exception: pass
" 2>/dev/null)
fi

if [[ -n "${TARGET_RUN_ID}" ]]; then
  echo "--- Run ${TARGET_RUN_ID} の詳細 (GET /run/${TARGET_RUN_ID}) ---"
  RUN_DETAIL=$(curl "${CURL_OPTS[@]}" "${HYPERFOIL_URL}/run/${TARGET_RUN_ID}" 2>/dev/null || echo "")
  if [[ -z "${RUN_DETAIL}" ]]; then
    echo "  取得失敗"
  else
    echo "${RUN_DETAIL}" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    print(f\"  id: {r.get('id')}\")
    print(f\"  benchmark: {r.get('benchmark')}\")
    print(f\"  started: {r.get('started')}\")
    print(f\"  terminated: {r.get('terminated', '(実行中)')}\")
    print(f\"  completed: {r.get('completed')}\")
    print(f\"  cancelled: {r.get('cancelled')}\")
    phases = r.get('phases', [])
    if phases:
        print('  phases:')
        for p in phases:
            print(f\"    - {p.get('name')}: status={p.get('status')} type={p.get('type')} started={p.get('started')} completed={p.get('completed')}\")
    errs = r.get('errors', [])
    if errs:
        print('  errors:', errs)
except Exception as e:
    print('  (parse error)', e)
    print(sys.stdin.read()[:800])
" 2>/dev/null || echo "${RUN_DETAIL}"
  fi

  # 終了済みなら統計を表示
  TERMINATED=$(echo "${RUN_DETAIL}" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    print('yes' if r.get('terminated') else '')
except Exception: pass
" 2>/dev/null)
  if [[ -n "${TERMINATED}" ]]; then
    echo ""
    echo "--- Run ${TARGET_RUN_ID} 統計 (GET /run/${TARGET_RUN_ID}/stats/total) ---"
    STATS=$(curl "${CURL_OPTS[@]}" "${HYPERFOIL_URL}/run/${TARGET_RUN_ID}/stats/total" 2>/dev/null || echo "")
    if [[ -n "${STATS}" ]]; then
      echo "${STATS}" | python3 -c "
import sys, json
def us_to_ms(v):
    return round((v or 0) / 1000.0, 2) if v is not None else '-'
try:
    d = json.load(sys.stdin)
    run_status = d.get('status', '')
    stats = d.get('statistics', [])
    for s in stats:
        ph = s.get('phase', '')
        mid = s.get('metric', '')
        summary = s.get('summary', {}) or {}
        req = summary.get('requestCount', 0)
        resp = summary.get('responseCount', 0)
        # HTTP ステータス: 実 API は summary.extensions.http に status_2xx 等で返す
        ext_http = (summary.get('extensions') or {}).get('http') or {}
        counts = summary.get('responseCounts', {}) or {}
        ok = ext_http.get('status_2xx') or counts.get('2xx', 0) or 0
        c3 = ext_http.get('status_3xx') or counts.get('3xx', 0) or 0
        c4 = ext_http.get('status_4xx') or counts.get('4xx', 0) or 0
        c5 = ext_http.get('status_5xx') or counts.get('5xx', 0) or 0
        other = ext_http.get('status_other', 0) or 0
        err = summary.get('errors') or (summary.get('invalid', 0) + summary.get('connectionErrors', 0) + summary.get('internalErrors', 0)) or 0
        blocked = summary.get('blockedTime', 0) or 0
        timeouts = summary.get('requestTimeouts') or summary.get('timeouts', 0) or 0
        rest = {k: v for k, v in counts.items() if k not in ('2xx','3xx','4xx','5xx')}
        if other: rest['other'] = other
        extra = (' ' + str(rest)) if rest else ''
        print(f\"  phase={ph} metric={mid}: run_status={run_status} requestCount={req} responseCount={resp}\")
        print(f\"    2xx={ok} 3xx={c3} 4xx={c4} 5xx={c5} errors={err} timeouts={timeouts} blockedTime={blocked}ms{extra}\")
        # 応答時間 (API はマイクロ秒)
        min_rt = summary.get('minResponseTime')
        max_rt = summary.get('maxResponseTime')
        mean_rt = summary.get('meanResponseTime')
        std_rt = summary.get('stdDevResponseTime')
        if min_rt is not None or mean_rt is not None or max_rt is not None:
            print(f\"    responseTime(us): min={min_rt or '-'} mean={mean_rt or '-'} max={max_rt or '-'} stdDev={std_rt or '-'}\")
            print(f\"    responseTime(ms): min={us_to_ms(min_rt)} mean={us_to_ms(mean_rt)} max={us_to_ms(max_rt)} stdDev={us_to_ms(std_rt)}\")
        pr = summary.get('percentileResponseTime') or {}
        if pr:
            p50 = pr.get('50.0'); p90 = pr.get('90.0'); p99 = pr.get('99.0'); p999 = pr.get('99.9'); p9999 = pr.get('99.99')
            print(f\"    percentiles(us): p50={p50 or '-'} p90={p90 or '-'} p99={p99 or '-'} p99.9={p999 or '-'} p99.99={p9999 or '-'}\")
            print(f\"    percentiles(ms): p50={us_to_ms(p50)} p90={us_to_ms(p90)} p99={us_to_ms(p99)} p99.9={us_to_ms(p999)} p99.99={us_to_ms(p9999)}\")
        cache_hits = ext_http.get('cacheHits')
        if cache_hits is not None:
            print(f\"    cacheHits={cache_hits}\")
        is_warmup = s.get('isWarmup')
        if is_warmup is not None:
            print(f\"    isWarmup={is_warmup}\")
        failed_slas = s.get('failedSLAs') or []
        if failed_slas:
            print(f\"    failedSLAs: {failed_slas}\")
            if any('session limit' in str(x) for x in failed_slas):
                print(f\"    -> セッション数が上限に達した。parallelism を下げるか、constantRate の maxSessions を確認。\")
        if mid == 'delete' and c4 > 0 and ok == 0:
            print(f\"    -> delete で 4xx のみ: 削除対象 key-0,1,... が無かった(404) の可能性。先に load を実行してから delete または load-del を実行。\")
        if req > 0 and ok + c3 + c4 + c5 + err == 0 and not rest:
            print(f\"    -> レスポンス未カウント: 接続が返ってこない/タイムアウト/不正応答の可能性。Agent ログや Data Grid ログを確認。\")
except Exception as e:
    print('  (parse error)', e)
    print(sys.stdin.read()[:600])
" 2>/dev/null || echo "${STATS}"
    echo ""
    echo "  (全メトリクスは生 JSON で確認: curl -s -k ${HYPERFOIL_URL}/run/${TARGET_RUN_ID}/stats/total | jq .)"
    else
      echo "  (取得失敗)"
    fi
  fi
else
  echo "Run がまだありません。'hyperfoil test' または 'hyperfoil load' で実行してください。"
fi
