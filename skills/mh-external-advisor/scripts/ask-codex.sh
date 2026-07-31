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
#           可能已有部分副作用）；127 缺依賴
#
# 用法：
#   ask-codex.sh "問題"                      # 開新對話
#   ask-codex.sh -r <session_id> "追問"        # 延續指定對話
#   echo "很長的問題" | ask-codex.sh -r <id>  # prompt 走 stdin，免引號轉義
#   ask-codex.sh -- "-開頭的問題"             # prompt 以 - 開頭時，加 -- 結束選項解析

# 不用 set -e：需自行分流處理各執行失敗情境，不可讓非零結束碼直接中止
set -uo pipefail

# ── 自述（供 advisor-list.sh 組裝清單）──
# 必須擺在 getopts 與依賴檢查之前：getopts 不認識長選項會落入錯誤分支 exit 2，
# 而 CLI 未安裝時也該印得出自述（清單要能列出「已啟用但尚未安裝」的顧問）
# {SELF} 由 advisor-list.sh 替換為本腳本絕對路徑
if [ "${1:-}" = "--info" ]; then
  cat <<'EOF'
codex｜Codex
  開新：{SELF} "問題"
  延續：{SELF} -r <session_id> "追問"
EOF
  exit 0
fi

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v codex >/dev/null || { echo "錯誤：找不到 codex CLI，請先安裝並登入" >&2; exit 127; }
command -v jq    >/dev/null || { echo "錯誤：找不到 jq（解析輸出需要）" >&2; exit 127; }

# ── 參數解析：-r <session_id> 為可選的延續目標 ──
RESUME=""
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

# ── 共用旗標 ──
# DECISION: 保留 --dangerously-bypass-approvals-and-sandbox——本 workspace 定位為
#           外部沙箱環境（容器/受控主機），諮詢型呼叫需免互動核可才能自動化；
#           若移作他用，呼叫端應自行評估此預設
COMMON=(--json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check)

# 暫存 stdout / stderr：stdout 供解析，stderr 供失敗診斷（不吞掉）
LOG="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$LOG" "$ERR"' EXIT

# ── 執行 Codex ──
# prompt 走 stdin（`-`），避免長字串/特殊字元的引號轉義問題
# DECISION: resume 失敗不自動改開新對話重送——prompt 可能含有副作用指示，
#           自動重送有重複執行風險；改以 exit 3 讓呼叫端自行決定是否重送
if [ -n "$RESUME" ]; then
  printf '%s' "$PROMPT" | codex exec resume "${COMMON[@]}" "$RESUME" - >"$LOG" 2>"$ERR"
  if [ $? -ne 0 ]; then
    { echo "錯誤：resume 失敗（對話可能已失效）。確認無重複執行疑慮後，可不帶 -r 重送以開新對話。stderr 末幾行："
      tail -5 "$ERR"; } >&2
    exit 3
  fi
else
  printf '%s' "$PROMPT" | codex exec "${COMMON[@]}" - >"$LOG" 2>"$ERR"
  # 開新失敗：CLI 非零即停，不信任部分輸出（可能是被中斷的殘缺回覆）
  if [ $? -ne 0 ]; then
    { echo "錯誤：codex 執行失敗。stderr 末幾行："; tail -5 "$ERR"; } >&2
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
# DECISION: 不比照 agy 的 ^[A-Za-z0-9-]+$ 嚴格字元集——agy 的 id 是自行推測的目錄名需防污損，
#           此處 id 由 CLI 自己的 JSON 欄位給出，過嚴會在上游改格式時誤殺
if [ -n "$TID" ] && ! [[ "$TID" =~ ^[[:graph:]]+$ ]]; then TID=""; fi
# resume 時若事件未重印 id（或重印的不合格），沿用傳入的 RESUME 以維持延續性
# DECISION: 驗證擺在沿用之前——反過來的話，一個格式壞掉的新 id 會佔住 TID 而擋掉
#           本來有效的 RESUME，讓一段還活著的對話被誤報為不可延續
if [ -n "$RESUME" ] && [ -z "$TID" ] && [[ "$RESUME" =~ ^[[:graph:]]+$ ]]; then TID="$RESUME"; fi

# ── 輸出：回覆 + 供延續的 session id；失敗時連 stderr 一起印出供診斷 ──
if [ -z "$ANSWER" ]; then
  { echo "錯誤：Codex 無回覆。stderr 末幾行："; tail -5 "$ERR"; echo "stdout 末幾行："; tail -5 "$LOG"; } >&2
  exit 1
fi
printf '%s\n' "$ANSWER"
# 輸出契約：id 一定要有；缺失時警告呼叫端本段對話無法延續
if [ -n "$TID" ]; then
  printf '\n[External Advisor codex session_id: %s]\n' "$TID"
else
  echo "[warn] 未取得 session_id，本段對話無法延續" >&2
fi
