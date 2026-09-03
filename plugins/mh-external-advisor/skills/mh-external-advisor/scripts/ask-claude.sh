#!/usr/bin/env bash
# ask-claude.sh — 詢問 Claude（非互動 print 模式），以 session_id 明確延續同一段對話
#
# 用途：讓呼叫端 AI（Codex/其他）把 Claude 當顧問諮詢，並在同一任務內延續前文。
#       採「明確 session_id」而非 `--continue`：id 由呼叫端保存在自身對話脈絡中，
#       天然綁定「這個任務」，不會誤接到最近一段無關對話。
#
# I/O：
#   輸入  ─ prompt：由參數（優先）或 stdin 傳入
#           -r <session_id>：要延續的 Claude session（省略則開新對話）
#   輸出  ─ stdout：Claude 回覆文字；最後一行 `[External Advisor claude session_id: <id>]`（供下次 -r 延續）
#   結束碼─ 0 成功；2 參數錯誤；3 resume 失敗；1 執行失敗（無回覆，或 is_error=true
#           的錯誤文字不當回覆輸出；可能已有部分副作用）；5 節流擋下（prompt 未送出）；127 缺依賴
#
# 用法：
#   ask-claude.sh --scope explore "問題"                       # 開新 session
#   ask-claude.sh --scope unblock -r <session_id> "追問"        # 延續指定 session
#   echo "很長的問題" | ask-claude.sh --scope unblock -r <id>   # prompt 走 stdin，免引號轉義
#   ask-claude.sh --scope explore -- "-開頭的問題"             # prompt 以 - 開頭時，加 -- 結束選項解析

# 不用 set -e：需自行分流處理各執行失敗情境，不可讓非零結束碼直接中止
set -uo pipefail

# ── 自述（供 advisor-list.sh 組裝清單）──
# 必須擺在 getopts 與依賴檢查之前：getopts 不認識長選項會落入錯誤分支 exit 2，
# 而 CLI 未安裝時也該印得出自述（清單要能列出「已啟用但尚未安裝」的顧問）
# {SELF} 由 advisor-list.sh 替換為本腳本絕對路徑
if [ "${1:-}" = "--info" ]; then
  cat <<'EOF'
claude｜Claude
  開新：{SELF} --scope <explore|unblock|review> "問題"
  延續：{SELF} --scope <explore|unblock|review> -r <session_id> "追問"
EOF
  exit 0
fi

# 路徑自解析：以腳本自身位置為準，不信任 cwd
SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v claude >/dev/null || { echo "錯誤：找不到 claude CLI，請先安裝並登入" >&2; exit 127; }
command -v jq     >/dev/null || { echo "錯誤：找不到 jq（解析輸出需要）" >&2; exit 127; }

# ── 參數解析：-r <session_id> 為可選的延續目標 ──
RESUME=""
# ── --scope：節流用，必填。getopts 不認長選項，先摘出來 ──
SCOPE=""
_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --) while [ $# -gt 0 ]; do _ARGS+=("$1"); shift; done; break ;;
    --scope) SCOPE="${2:-}"
             [ -n "$SCOPE" ] || { echo "錯誤：--scope 缺值（explore|unblock|review）" >&2; exit 2; }
             shift 2 ;;
    *) _ARGS+=("$1"); shift ;;
  esac
done
# 空陣列用 "${arr[@]:-}" 會展開成一個空字串參數，改用 + 形式
set -- ${_ARGS[@]+"${_ARGS[@]}"}

while getopts "r:" opt; do
  case "$opt" in
    r) RESUME="$OPTARG"
       # 空字串 id 必擋：呼叫端最常見寫法是 -r "$id"，id 擷取失敗時 $id 為空——
       # 若放行會靜默改走「開新對話」路徑重送 prompt，繞過 resume 失敗防線（重複執行風險）
       [ -n "$RESUME" ] || { echo "錯誤：-r 的 id 不可為空（上一輪 id 擷取可能失敗，請先檢查）" >&2; exit 2; } ;;
    *) echo "用法: $0 [-r <session_id>] [--] \"<prompt>\"" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# ── 取得 prompt：命令列參數優先；無參數時僅在 stdin 非 TTY 才讀（避免互動誤用時掛住）──
PROMPT="$*"
if [ -z "$PROMPT" ] && [ ! -t 0 ]; then PROMPT="$(cat)"; fi
[ -n "$PROMPT" ] || { echo "錯誤：缺少 prompt（參數或 stdin 傳入）" >&2; exit 2; }

# ── 節流：扣桶成功才送出 ──
# 嵌在 adapter 內部而非交由呼叫端自行呼叫——由呼叫端決定要不要節流，等於沒有節流。
# 任何失敗一律不送出：fail open 會讓環境差異成為繞過節流的途徑
[ -n "$SCOPE" ] || { echo "錯誤：缺少 --scope（explore|unblock|review）" >&2; exit 2; }
THROTTLE_OUT="$("$SCRIPTS_DIR/advisor-throttle.sh" consume --advisor claude --scope "$SCOPE")"
case $? in
  0) ;;
  5) printf '%s\n' "$THROTTLE_OUT"
     # 呼叫端最需要知道的是「要不要重送」——訊息不講，它得去翻文件才敢判斷
     echo "錯誤：節流額度用盡，prompt 未送出（可安全重試）" >&2; exit 5 ;;
  *) echo "錯誤：節流檢查失敗，prompt 未送出" >&2; exit 1 ;;
esac

# ── 共用旗標 ──
# DECISION: 未採 stream-json，因同步 wrapper 只需等最終結果
# DECISION: 未採預設安全模式，因諮詢型呼叫需免互動核可才能自動化
COMMON=(-p --output-format json --dangerously-skip-permissions)

# 暫存 stdout / stderr：stdout 供解析，stderr 供失敗診斷（不吞掉）
LOG="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$LOG" "$ERR"' EXIT

# 診斷輸出一律以 byte 設限：claude 的回覆在 stdout 單一 JSON 物件的 .result，
# 整份輸出只有一行，以「行」設限等於不設限（回覆會滲進呼叫端的錯誤日誌）
DIAG_BYTES=800

# ── 執行 Claude ──
# prompt 走 stdin，避免長字串/特殊字元的引號轉義問題
# DECISION: 未採失敗自動開新重送，因 prompt 含副作用指示時會重複執行
if [ -n "$RESUME" ]; then
  printf '%s' "$PROMPT" | claude "${COMMON[@]}" --resume "$RESUME" >"$LOG" 2>"$ERR"
  if [ $? -ne 0 ]; then
    { echo "錯誤：resume 失敗（session 可能已失效）。確認無重複執行疑慮後，可不帶 -r 重送以開新對話。"
      echo "claude stderr 末 ${DIAG_BYTES} bytes："; tail -c "$DIAG_BYTES" "$ERR"; } >&2
    exit 3
  fi
else
  printf '%s' "$PROMPT" | claude "${COMMON[@]}" >"$LOG" 2>"$ERR"
  # 開新失敗：CLI 非零即停，不信任部分輸出（可能是被中斷的殘缺回覆）
  if [ $? -ne 0 ]; then
    { echo "錯誤：claude 執行失敗。claude stderr 末 ${DIAG_BYTES} bytes："; tail -c "$DIAG_BYTES" "$ERR"; } >&2
    exit 1
  fi
fi

# ── 解析：--output-format json 為單一物件，回覆在 .result、id 在 .session_id ──
# jq 錯誤不重導 /dev/null——輸出非 JSON 時要讓錯誤可見（不吞錯原則）
ANSWER="$(jq -r '.result // empty' "$LOG")"
SID="$(jq -r '.session_id // empty' "$LOG")"
ISERR="$(jq -r '.is_error // false' "$LOG")"
# 輸出契約防護：id 必須是單行可見字元，否則末行標記會被撐成多行或被偽造
# DECISION: 未採嚴格字元集與先沿用後驗證，因理由同 ask-codex.sh
if [ -n "$SID" ] && ! [[ "$SID" =~ ^[[:graph:]]+$ ]]; then SID=""; fi
# resume 時若輸出未帶合格 id，沿用傳入的 RESUME 以維持延續性（與 codex/opencode 一致）
if [ -n "$RESUME" ] && [ -z "$SID" ] && [[ "$RESUME" =~ ^[[:graph:]]+$ ]]; then SID="$RESUME"; fi

# CLI exit 0 但回報執行錯誤（is_error=true，如 max-turns 用盡）：
# 錯誤文字不可當正常回覆輸出（呼叫端會誤信並拿 id 延續）
if [ "$ISERR" = "true" ]; then
  { echo "錯誤：Claude 回報執行錯誤（is_error=true）。錯誤文字首 ${DIAG_BYTES} bytes："
    printf '%s' "$ANSWER" | head -c "$DIAG_BYTES"; echo; } >&2
  exit 1
fi

# ── 輸出：回覆 + 供延續的 session id；失敗時連 stderr 一起印出供診斷 ──
if [ -z "$ANSWER" ]; then
  { echo "錯誤：Claude 無回覆。claude stderr 末 ${DIAG_BYTES} bytes："; tail -c "$DIAG_BYTES" "$ERR"
    echo "claude stdout 首 ${DIAG_BYTES} bytes（此分支 .result 已為空）："; head -c "$DIAG_BYTES" "$LOG"; echo; } >&2
  exit 1
fi
printf '%s\n' "$ANSWER"
# 輸出契約：id 一定要有；缺失時警告呼叫端本段對話無法延續
if [ -n "$SID" ]; then
  printf '\n[External Advisor claude session_id: %s]\n' "$SID"
else
  echo "[warn] 未取得 session_id，本段對話無法延續" >&2
fi
