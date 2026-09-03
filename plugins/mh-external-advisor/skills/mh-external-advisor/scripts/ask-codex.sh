#!/usr/bin/env bash
# ask-codex.sh — 詢問 Codex（非互動），以明確 session_id 延續同一段對話
#
# 用途：讓呼叫端 AI（Claude/其他）把 Codex 當顧問諮詢，並在同一任務內延續前文。
#       採「明確 session_id」而非 `resume --last`：id 由呼叫端保存在自身對話脈絡中，
#       天然綁定「這個任務」，不會誤接到同目錄其他無關 session。
#
# I/O：
#   輸入  ─ prompt：由參數（優先）或 stdin 傳入
#           -r <session_id>：要延續的對話（省略則開新對話）
#   輸出  ─ stdout：Codex 回覆文字；最後一行 `[External Advisor codex session_id: <id>]`（供下次 -r 延續）
#   結束碼─ 0 成功；2 參數錯誤；3 resume 失敗；1 執行失敗（無回覆或回覆不可採信，
#           可能已有部分副作用）；5 節流擋下（prompt 未送出）；127 缺依賴
#
# 用法：
#   ask-codex.sh --scope explore "問題"                      # 開新對話
#   ask-codex.sh --scope unblock -r <session_id> "追問"        # 延續指定對話
#   echo "很長的問題" | ask-codex.sh --scope unblock -r <id>  # prompt 走 stdin，免引號轉義
#   ask-codex.sh --scope explore -- "-開頭的問題"             # prompt 以 - 開頭時，加 -- 結束選項解析

# 不用 set -e：需自行分流處理各執行失敗情境，不可讓非零結束碼直接中止
set -uo pipefail

# ── 自述（供 advisor-list.sh 組裝清單）──
# 必須擺在 getopts 與依賴檢查之前：getopts 不認識長選項會落入錯誤分支 exit 2，
# 而 CLI 未安裝時也該印得出自述（清單要能列出「已啟用但尚未安裝」的顧問）
# {SELF} 由 advisor-list.sh 替換為本腳本絕對路徑
if [ "${1:-}" = "--info" ]; then
  cat <<'EOF'
codex｜Codex
  開新：{SELF} --scope <explore|unblock|review> "問題"
  延續：{SELF} --scope <explore|unblock|review> -r <session_id> "追問"
EOF
  exit 0
fi

# 路徑自解析：以腳本自身位置為準，不信任 cwd
SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v codex >/dev/null || { echo "錯誤：找不到 codex CLI，請先安裝並登入" >&2; exit 127; }
command -v jq    >/dev/null || { echo "錯誤：找不到 jq（解析輸出需要）" >&2; exit 127; }

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
THROTTLE_OUT="$("$SCRIPTS_DIR/advisor-throttle.sh" consume --advisor codex --scope "$SCOPE")"
case $? in
  0) ;;
  5) printf '%s\n' "$THROTTLE_OUT"
     # 呼叫端最需要知道的是「要不要重送」——訊息不講，它得去翻文件才敢判斷
     echo "錯誤：節流額度用盡，prompt 未送出（可安全重試）" >&2; exit 5 ;;
  *) echo "錯誤：節流檢查失敗，prompt 未送出" >&2; exit 1 ;;
esac

# ── 共用旗標 ──
# DECISION: 未採預設安全模式，因諮詢型呼叫需免互動核可才能自動化
COMMON=(--json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check)

# 暫存 stdout / stderr：stdout 供解析，stderr 供失敗診斷（不吞掉）
LOG="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$LOG" "$ERR"' EXIT

# 失敗診斷：只印事件型別序列與 stderr，不倒 stdout 原文——NDJSON 一則事件即一行，
# 而 agent_message 事件內含完整回覆，以「行」設限等於不設限，回覆會滲進呼叫端的錯誤日誌。
# 型別序列本身不含內容，卻能看出執行走到哪一步（實測成功序列：thread.started → turn.started
# → item.completed → turn.completed；resume 失效時 stdout 全空、錯誤只在 stderr）
DIAG_BYTES=800
DIAG_EVENTS=20
diag() {
  local types
  types="$(jq -Rrs --argjson n "$DIAG_EVENTS" 'split("\n") | map(fromjson? // empty)
    | map(.type // empty) | (if length > $n then ["…"] + .[-$n:] else . end)
    | join(" → ")' "$LOG" 2>/dev/null)"
  if [ -n "$types" ]; then
    echo "codex 事件序列：$types"
  else
    echo "codex stdout 末 ${DIAG_BYTES} bytes（非 NDJSON 或全空）："; tail -c "$DIAG_BYTES" "$LOG"; echo
  fi
  echo "codex stderr 末 ${DIAG_BYTES} bytes："; tail -c "$DIAG_BYTES" "$ERR"
}

# ── 執行 Codex ──
# prompt 走 stdin（`-`），避免長字串/特殊字元的引號轉義問題
# DECISION: 未採失敗自動開新重送，因 prompt 含副作用指示時會重複執行
if [ -n "$RESUME" ]; then
  printf '%s' "$PROMPT" | codex exec resume "${COMMON[@]}" "$RESUME" - >"$LOG" 2>"$ERR"
  if [ $? -ne 0 ]; then
    { echo "錯誤：resume 失敗（對話可能已失效）。確認無重複執行疑慮後，可不帶 -r 重送以開新對話。"
      diag; } >&2
    exit 3
  fi
else
  printf '%s' "$PROMPT" | codex exec "${COMMON[@]}" - >"$LOG" 2>"$ERR"
  # 開新失敗：CLI 非零即停，不信任部分輸出（可能是被中斷的殘缺回覆）
  if [ $? -ne 0 ]; then
    { echo "錯誤：codex 執行失敗。"; diag; } >&2
    exit 1
  fi
fi

# ── 解析 NDJSON（slurp 整檔，多行文字安全）──
# 回覆：取最後一則 agent_message 的完整 text（在 jq 內取 last，不可對輸出行 tail）
ANSWER="$(jq -Rrs 'split("\n") | map(fromjson? // empty)
  | map(select(.type=="item.completed") | .item
        | select(.type=="agent_message") | .text // empty)
  | last // empty' "$LOG")"
# thread_id：取 thread.started 事件的第一個 thread_id
TID="$(jq -Rrs 'split("\n") | map(fromjson? // empty)
  | map(select(.type=="thread.started") | .thread_id // empty)
  | first // empty' "$LOG")"
# 輸出契約防護：id 必須是單行可見字元，否則末行標記會被撐成多行或被偽造
# DECISION: 未採 agy 的嚴格字元集，因此處 id 不觸及檔案系統，過嚴會誤殺
if [ -n "$TID" ] && ! [[ "$TID" =~ ^[[:graph:]]+$ ]]; then TID=""; fi
# resume 時若事件未重印 id（或重印的不合格），沿用傳入的 RESUME 以維持延續性
# DECISION: 未採先沿用後驗證，因壞格式的新 id 會擋掉本來有效的 RESUME
if [ -n "$RESUME" ] && [ -z "$TID" ] && [[ "$RESUME" =~ ^[[:graph:]]+$ ]]; then TID="$RESUME"; fi

# ── 輸出：回覆 + 供延續的 session id；失敗時連 stderr 一起印出供診斷 ──
if [ -z "$ANSWER" ]; then
  { echo "錯誤：Codex 無回覆。"; diag; } >&2
  exit 1
fi
printf '%s\n' "$ANSWER"
# 輸出契約：id 一定要有；缺失時警告呼叫端本段對話無法延續
if [ -n "$TID" ]; then
  printf '\n[External Advisor codex session_id: %s]\n' "$TID"
else
  echo "[warn] 未取得 session_id，本段對話無法延續" >&2
fi
