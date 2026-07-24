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
#   結束碼─ 0 成功；2 參數錯誤；3 resume 失敗；1 執行失敗且無回覆；127 缺依賴
#
# 用法：
#   ask-claude.sh "問題"                       # 開新 session
#   ask-claude.sh -r <session_id> "追問"        # 延續指定 session
#   echo "很長的問題" | ask-claude.sh -r <id>   # prompt 走 stdin，免引號轉義
#   ask-claude.sh -- "-開頭的問題"             # prompt 以 - 開頭時，加 -- 結束選項解析

# 不用 set -e：需自行分流處理各執行失敗情境，不可讓非零結束碼直接中止
set -uo pipefail

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v claude >/dev/null || { echo "錯誤：找不到 claude CLI，請先安裝並登入" >&2; exit 127; }
command -v jq     >/dev/null || { echo "錯誤：找不到 jq（解析輸出需要）" >&2; exit 127; }

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
# DECISION: 用 --output-format json（單一物件、jq 直取）而非 stream-json——
#           同步 wrapper 只需等最終結果、無 idle timeout 顧慮，無須逐 event 串流
# DECISION: 保留 --dangerously-skip-permissions——本 workspace 定位為外部沙箱環境，
#           諮詢型呼叫需免互動核可才能自動化；若移作他用，呼叫端應自行評估此預設
COMMON=(-p --output-format json --dangerously-skip-permissions)

# 暫存 stdout / stderr：stdout 供解析，stderr 供失敗診斷（不吞掉）
LOG="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$LOG" "$ERR"' EXIT

# ── 執行 Claude ──
# prompt 走 stdin，避免長字串/特殊字元的引號轉義問題
# DECISION: resume 失敗不自動改開新 session 重送——prompt 可能含有副作用指示，
#           自動重送有重複執行風險；改以 exit 3 讓呼叫端自行決定是否重送
if [ -n "$RESUME" ]; then
  printf '%s' "$PROMPT" | claude "${COMMON[@]}" --resume "$RESUME" >"$LOG" 2>"$ERR"
  if [ $? -ne 0 ]; then
    { echo "錯誤：resume 失敗（session 可能已失效）。確認無重複執行疑慮後，可不帶 -r 重送以開新對話。stderr 末幾行："
      tail -5 "$ERR"; } >&2
    exit 3
  fi
else
  printf '%s' "$PROMPT" | claude "${COMMON[@]}" >"$LOG" 2>"$ERR"
  # 開新失敗：CLI 非零即停，不信任部分輸出（可能是被中斷的殘缺回覆）
  if [ $? -ne 0 ]; then
    { echo "錯誤：claude 執行失敗。stderr 末幾行："; tail -5 "$ERR"; } >&2
    exit 1
  fi
fi

# ── 解析：--output-format json 為單一物件，回覆在 .result、id 在 .session_id ──
# jq 錯誤不重導 /dev/null——輸出非 JSON 時要讓錯誤可見（不吞錯原則）
ANSWER="$(jq -r '.result // empty' "$LOG")"
SID="$(jq -r '.session_id // empty' "$LOG")"
ISERR="$(jq -r '.is_error // false' "$LOG")"
# resume 時若輸出未帶 id，沿用傳入的 RESUME 以維持延續性（與 codex/opencode 一致）
[ -n "$RESUME" ] && [ -z "$SID" ] && SID="$RESUME"

# CLI exit 0 但回報執行錯誤（is_error=true，如 max-turns 用盡）：
# 錯誤文字不可當正常回覆輸出（呼叫端會誤信並拿 id 延續）
if [ "$ISERR" = "true" ]; then
  { echo "錯誤：Claude 回報執行錯誤（is_error=true）。回覆內容開頭："; printf '%s' "$ANSWER" | head -c 500; echo; } >&2
  exit 1
fi

# ── 輸出：回覆 + 供延續的 session id；失敗時連 stderr 一起印出供診斷 ──
if [ -z "$ANSWER" ]; then
  { echo "錯誤：Claude 無回覆。stderr 末幾行："; tail -5 "$ERR"; echo "stdout 開頭："; head -c 500 "$LOG"; } >&2
  exit 1
fi
printf '%s\n' "$ANSWER"
# 輸出契約：id 一定要有；缺失時警告呼叫端本段對話無法延續
if [ -n "$SID" ]; then
  printf '\n[External Advisor claude session_id: %s]\n' "$SID"
else
  echo "[warn] 未取得 session_id，本段對話無法延續" >&2
fi
