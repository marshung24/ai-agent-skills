#!/usr/bin/env bash
# advisor-throttle.sh — 外部顧問呼叫的漏桶節流（查詢水位、取用額度、重置）
#
# 用途：為自主模式的顧問呼叫提供**不依賴呼叫端自律**的速率上限。實際扣桶由
#       ask-*.sh 在送出 prompt 前內部完成；本腳本另供使用者查看與重置。
#
# I/O：
#   輸入  ─ 子命令 status / consume / reset，搭配 --scope 與 --advisor
#   輸出  ─ stdout：consume 與 status 印機器可讀 JSON；reset 印確認訊息
#           stderr：警告與人類可讀診斷，一律 [warn] 前綴
#   結束碼─ 0 成功（consume＝放行）；1 執行失敗（身分／鎖／狀態，prompt 未送出）；
#           2 參數錯誤；5 桶滿（consume）；127 缺依賴
#
# 用法：
#   advisor-throttle.sh status [--advisor <ai>] [--scope <scope>]
#   advisor-throttle.sh consume --advisor <ai> --scope <scope>
#   advisor-throttle.sh reset --advisor <ai> --scope <scope> | --all
#
# ⚠️ reset 是使用者的管理操作：它會清空硬性節流的水位。🚫 不得由自主流程呼叫——
#    被擋下後自行 reset 等於節流不存在。

# 不用 set -e：桶滿與失敗都是要分流處理的正常分支
set -uo pipefail

SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null || { echo "錯誤：找不到 jq（讀寫桶狀態需要）" >&2; exit 127; }

# shellcheck source=lib/enabled-io.sh
. "$SCRIPTS_DIR/lib/enabled-io.sh"
# shellcheck source=lib/throttle-io.sh
. "$SCRIPTS_DIR/lib/throttle-io.sh"

usage() {
  echo "用法: $0 <status|consume|reset> [選項]"
  echo "  status  [--advisor <ai>] [--scope <scope>]   查看水位（唯讀，不改狀態）"
  echo "  consume --advisor <ai> --scope <scope>       取用一次額度"
  echo "  reset   --advisor <ai> --scope <scope>|--all 重置水位（使用者管理操作）"
  echo
  echo "  scope: $THROTTLE_SCOPES"
}

CMD="${1:-}"
case "$CMD" in
  status|consume|reset) shift ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) echo "錯誤：未知的子命令「$CMD」" >&2; usage >&2; exit 2 ;;
esac

AI=""; SCOPE=""; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --advisor) AI="${2:-}"; shift 2 || { echo "錯誤：--advisor 缺值" >&2; exit 2; } ;;
    --scope)   SCOPE="${2:-}"; shift 2 || { echo "錯誤：--scope 缺值" >&2; exit 2; } ;;
    --all)     ALL=1; shift ;;
    *) echo "錯誤：未知選項「$1」" >&2; usage >&2; exit 2 ;;
  esac
done

scan_supported
# 顧問名同時是桶檔名的一部分：不驗字元集會讓 ../ 逃出狀態目錄
if [ -n "$AI" ]; then
  if ! valid_name "$AI" || ! is_supported "$AI"; then
    echo "錯誤：不支援的顧問名「${AI}」（支援：$(join_names "${SUPPORTED[@]:-}")）" >&2
    exit 2
  fi
fi
if [ -n "$SCOPE" ] && ! valid_scope "$SCOPE"; then
  echo "錯誤：未知的 scope「${SCOPE}」（可用：${THROTTLE_SCOPES}）" >&2
  exit 2
fi

load_throttle_config

# 狀態目錄由會寫入的子命令建立：GC 與記錄都早於 bucket_take，不能依賴它順手建立。
# status 宣稱唯讀，🚫 不得在此建目錄
if [ "$CMD" != "status" ]; then
  mkdir -p "$THROTTLE_STATE_DIR" 2>/dev/null || { echo "錯誤：無法建立狀態目錄 $THROTTLE_STATE_DIR" >&2; exit 1; }
fi

# 本進程的 lstart 供鎖的 owner metadata 使用（回收時據以判斷 owner 是否還活著）
SELF_LSTART="$(ps -o lstart= -p $$ 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"

# 身分取不到一律 fail closed：fail open 會讓環境差異直接成為繞過節流的途徑
if ! resolve_principal; then
  echo "[warn] 無法辨識呼叫端 AI Agent（祖先鏈中找不到非 shell 程序）" >&2
  echo "錯誤：節流身分解析失敗，未取用額度" >&2
  exit 1
fi
AGENT_LABEL="${PRINCIPAL_COMM:-agent}"

case "$CMD" in
  consume)
    [ -n "$AI" ] && [ -n "$SCOPE" ] || { echo "錯誤：consume 需要 --advisor 與 --scope" >&2; exit 2; }
    throttle_gc
    out="$(bucket_take "$AI" "$SCOPE" take)"; rc=$?
    printf '%s\n' "$out"
    case "$rc" in
      0) usage_log "$AI/$SCOPE  allow  $(printf '%s' "$out" | jq -r '"remaining=\(.remaining)/\(.capacity) refill=\(.refill_seconds)s"' 2>/dev/null)"
         exit 0 ;;
      1) usage_log "$AI/$SCOPE  deny   $(printf '%s' "$out" | jq -r '"remaining=\(.remaining)/\(.capacity) retry_after=\(.retry_after_seconds)s"' 2>/dev/null)"
         echo "[warn] ${AI}/${SCOPE} 額度用盡，$(printf '%s' "$out" | jq -r '.retry_after_seconds')秒後可再取用" >&2
         exit 5 ;;
      *) echo "錯誤：取用額度失敗（桶狀態或鎖），prompt 未送出" >&2; exit 1 ;;
    esac
    ;;
  status)
    # 未指定就列出本 agent 的全部桶；無桶時輸出空陣列而非報錯
    printf '['
    first=1
    for a in "${SUPPORTED[@]:-}"; do
      [ -n "$AI" ] && [ "$a" != "$AI" ] && continue
      for s in $THROTTLE_SCOPES; do
        [ -n "$SCOPE" ] && [ "$s" != "$SCOPE" ] && continue
        [ -f "$(bucket_path "$a" "$s")" ] || continue
        out="$(bucket_take "$a" "$s" peek)"
        [ "$first" -eq 1 ] || printf ','
        printf '%s' "$out"
        first=0
      done
    done
    printf ']\n'
    exit 0
    ;;
  reset)
    if [ "$ALL" -eq 1 ]; then
      failed=""
      for a in "${SUPPORTED[@]:-}"; do
        for s in $THROTTLE_SCOPES; do bucket_reset "$a" "$s" || failed="$failed $a/$s"; done
      done
      # 部分失敗仍回 0 會讓使用者以為水位已清，實際還在節流
      if [ -n "$failed" ]; then
        usage_log "*/*  reset  partial（失敗：${failed# }）"
        echo "錯誤：下列桶重置失敗（可能被其他程序持鎖）：${failed# }" >&2
        exit 1
      fi
      usage_log "*/*  reset  all"
      echo "已重置本 agent 的所有桶"
      exit 0
    fi
    [ -n "$AI" ] && [ -n "$SCOPE" ] || { echo "錯誤：reset 需要 --advisor 與 --scope（或 --all）" >&2; exit 2; }
    bucket_reset "$AI" "$SCOPE" || { echo "錯誤：重置失敗（鎖逾時）" >&2; exit 1; }
    usage_log "$AI/$SCOPE  reset"
    echo "已重置 ${AI}/${SCOPE}"
    exit 0
    ;;
esac
