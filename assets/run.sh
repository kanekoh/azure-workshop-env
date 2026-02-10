#!/usr/bin/env bash
# assets の統一エントリポイント（どこからでも実行可能）
# 例: ./assets/run.sh datagrid deploy --replicas 5
#     ./assets/run.sh operators install-datagrid
set -euo pipefail

# このスクリプトの場所を基準に assets ディレクトリを決定（どこから実行しても同じように動作）
ASSETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${ASSETS_DIR}/config/defaults.env" ]]; then
  source "${ASSETS_DIR}/config/defaults.env"
fi

usage() {
  echo "Usage: $0 <command> [subcommand] [OPTIONS...]"
  echo ""
  echo "Commands:"
  echo "  operators install-all            Data Grid + Hyperfoil Operator をインストール"
  echo "  operators install-datagrid      Data Grid Operator をインストール（再実行でバージョン変更可）"
  echo "  operators install-hyperfoil     Hyperfoil Operator をインストール（再実行可）"
  echo "  datagrid deploy [OPTIONS...]      DataGrid インスタンスをデプロイ（再実行で設定変更可）"
  echo "  datagrid cache-status [OPTIONS...]  キャッシュのエントリ数と Hyperfoil 用キーの有無を表示"
  echo "  datagrid clear-cache [OPTIONS...]  キャッシュを全件クリア（REST action=clear、Hyperfoil 不要）"
  echo "  datagrid delete-cache [OPTIONS...] キャッシュ定義を削除（REST DELETE）。Operator が CR の template で再作成"
  echo "  hyperfoil load [OPTIONS...]      データ投入ベンチマーク"
  echo "  hyperfoil delete [OPTIONS...]    データ削除ベンチマーク"
  echo "  hyperfoil load-del [OPTIONS...]  投入＋削除ベンチマーク"
  echo "  hyperfoil test [OPTIONS...]      短時間テスト（5s・低負荷）"
  echo "  hyperfoil status [--run-id ID] [-o FILE]  登録ベンチマークと Run 状態の確認（-o でファイルにも出力）"
  echo "  backup [OPTIONS...]              バックアップ実行"
  echo "  restore [OPTIONS...]            リストア実行（--backup 必須）"
  echo "  metrics [OPTIONS...]            メトリクス収集"
  echo ""
  echo "Examples:"
  echo "  $0 operators install-all"
  echo "  DATAGRID_OPERATOR_VERSION=8.5.6 $0 operators install-datagrid"
  echo "  $0 datagrid deploy --version 8.5.4-1 --replicas 5"
  echo "  $0 hyperfoil load --records 100000 --parallelism 4"
  echo "  $0 backup --cluster infinispan --storage 2Gi"
  echo "  $0 restore --backup backup-20250209-120000 --cluster infinispan"
  echo "  $0 metrics --output-dir ./my-metrics"
  exit 0
}

if [[ $# -lt 1 ]]; then
  usage
fi

CMD="$1"
shift || true

case "${CMD}" in
  operators)
    if [[ $# -lt 1 ]]; then
      echo "Subcommand required: install-all | install-datagrid | install-hyperfoil"
      exit 1
    fi
    SUB="$1"
    shift || true
    case "${SUB}" in
      install-all)
        cd "${ASSETS_DIR}/operators" && exec ./install-all.sh
        ;;
      install-datagrid)
        cd "${ASSETS_DIR}/operators" && exec ./install-datagrid-operator.sh "$@"
        ;;
      install-hyperfoil)
        cd "${ASSETS_DIR}/operators" && exec ./install-hyperfoil-operator.sh "$@"
        ;;
      *)
        echo "Unknown: operators ${SUB}. Use install-all | install-datagrid | install-hyperfoil"
        exit 1
        ;;
    esac
    ;;
  datagrid)
    if [[ $# -lt 1 ]]; then
      echo "Subcommand required: deploy | cache-status | clear-cache | delete-cache"
      exit 1
    fi
    SUB="$1"
    shift || true
    case "${SUB}" in
      deploy)
        cd "${ASSETS_DIR}/datagrid" && exec ./deploy-datagrid.sh "$@"
        ;;
      cache-status)
        cd "${ASSETS_DIR}/datagrid" && exec ./cache-status.sh "$@"
        ;;
      clear-cache)
        cd "${ASSETS_DIR}/datagrid" && exec ./clear-cache.sh "$@"
        ;;
      delete-cache)
        cd "${ASSETS_DIR}/datagrid" && exec ./delete-cache.sh "$@"
        ;;
      *)
        echo "Unknown: datagrid ${SUB}. Use deploy | cache-status | clear-cache | delete-cache"
        exit 1
        ;;
    esac
    ;;
  hyperfoil)
    if [[ $# -lt 1 ]]; then
      echo "Subcommand required: load | delete | load-del | test | status"
      exit 1
    fi
    SUB="$1"
    shift || true
    case "${SUB}" in
      load|delete|load-del)
        cd "${ASSETS_DIR}/hyperfoil" && exec ./run-benchmark.sh "${SUB}" "$@"
        ;;
      test)
        cd "${ASSETS_DIR}/hyperfoil" && exec ./test-benchmark.sh "$@"
        ;;
      status)
        cd "${ASSETS_DIR}/hyperfoil" && exec ./status.sh "$@"
        ;;
      *)
        echo "Unknown: hyperfoil ${SUB}. Use load | delete | load-del | test | status"
        exit 1
        ;;
    esac
    ;;
  backup)
    cd "${ASSETS_DIR}/backup-restore" && exec ./run-backup.sh "$@"
    ;;
  restore)
    cd "${ASSETS_DIR}/backup-restore" && exec ./run-restore.sh "$@"
    ;;
  metrics)
    cd "${ASSETS_DIR}/metrics" && exec ./collect-metrics.sh "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: ${CMD}"
    usage
    ;;
esac
