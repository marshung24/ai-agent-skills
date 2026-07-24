#!/usr/bin/env bash
# ask-opencode.sh — 詢問 Opencode（非互動），以 session_id 明確延續同一段對話
#
# 用途：讓呼叫端 AI 把 Opencode 當顧問諮詢，並在同一任務內延續前文。
#       採「明確 session_id」而非 `--continue`：id 由呼叫端保存在自身對話脈絡中，
#       天然綁定「這個任務」，不會誤接到最近一段無關 session。
#
# I/O：
#   輸入  ─ prompt：由參數（優先）或 stdin 傳入
#           -r <session_id>：要延續的 Opencode session（省略則開新對話）
#   輸出  ─ stdout：Opencode 回覆文字；最後一行 `[External Advisor opencode session_id: <id>]`（供下次 -r 延續）
#   結束碼─ 0 成功；2 參數錯誤；3 resume 失敗；1 執行失敗且無回覆；
#           127 缺依賴（CLI/jq 未安裝，或偵測不到免互動旗標）
#
# 用法：
#   ask-opencode.sh "問題"                      # 開新 session
#   ask-opencode.sh -r <session_id> "追問"       # 延續指定 session
#   echo "很長的問題" | ask-opencode.sh -r <id>  # prompt 走 stdin，免引號轉義
#   ask-opencode.sh -- "-開頭的問題"             # prompt 以 - 開頭時，加 -- 結束選項解析

# 不用 set -e：需自行分流處理各執行失敗情境，不可讓非零結束碼直接中止
set -uo pipefail

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v opencode >/dev/null || { echo "錯誤：找不到 opencode CLI，請先安裝並登入" >&2; exit 127; }
command -v jq       >/dev/null || { echo "錯誤：找不到 jq（解析輸出需要）" >&2; exit 127; }

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

# ── 共用旗標：自動核可權限（本環境定位為外部沙箱）、輸出 NDJSON 事件流 ──
# DECISION: 免互動旗標以 --help 動態偵測公開旗標名，不 hardcode——
#           公開名依版本而異：1.17.10 為 --dangerously-skip-permissions，約 1.17.12 起
#           更名 --auto、舊名轉 hidden 相容別名（仍有效但不列 help，上游可能隨時移除）；
#           且 opencode 對未知旗標不報錯（非嚴格解析，實測），別名一旦移除即靜默失去
#           免互動核可、無從偵測——故一律跟隨 help 中的公開名，兩者皆無才明確報錯
RUN_HELP="$(opencode run --help 2>&1)"
if grep -q -e '--dangerously-skip-permissions' <<<"$RUN_HELP"; then
  AUTO_FLAG="--dangerously-skip-permissions"
elif grep -qE -- '(^|[[:space:]])--auto([[:space:]=,]|$)' <<<"$RUN_HELP"; then
  # --auto 用邊界比對：子字串比對會誤中 --autoupdate 之類旗標，
  # 配上「未知旗標不報錯」的特性，誤中即靜默失去免互動核可
  AUTO_FLAG="--auto"
else
  echo "錯誤：偵測不到 opencode 的免互動核可旗標（--dangerously-skip-permissions / --auto），版本可能又更名，請以 opencode run --help 確認" >&2
  exit 127
fi
COMMON=(run "$AUTO_FLAG" --format json)

# 暫存 stdout / stderr：stdout 供解析，stderr 供失敗診斷（不吞掉）
LOG="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$LOG" "$ERR"' EXIT

# ── 執行 Opencode ──
# opencode 的 prompt 走命令列引數（其 run 子命令非以 stdin 收 prompt）；
# prompt 前加 `--` 分隔符，防止以 `-` 開頭的 prompt 被誤解析為旗標（實測支援）
# DECISION: resume 失敗不自動改開新 session 重送——prompt 可能含有副作用指示，
#           自動重送有重複執行風險；改以 exit 3 讓呼叫端自行決定是否重送
if [ -n "$RESUME" ]; then
  opencode "${COMMON[@]}" --session "$RESUME" -- "$PROMPT" >"$LOG" 2>"$ERR"
  if [ $? -ne 0 ]; then
    { echo "錯誤：resume 失敗（session 可能已失效）。確認無重複執行疑慮後，可不帶 -r 重送以開新對話。stderr 末幾行："
      tail -5 "$ERR"; } >&2
    exit 3
  fi
else
  opencode "${COMMON[@]}" -- "$PROMPT" >"$LOG" 2>"$ERR"
  # 開新失敗：CLI 非零即停，不信任部分輸出（可能是被中斷的殘缺回覆）
  if [ $? -ne 0 ]; then
    { echo "錯誤：opencode 執行失敗。stderr 末幾行："; tail -5 "$ERR"; } >&2
    exit 1
  fi
fi

# ── 解析 NDJSON（slurp 整檔，多行文字安全）──
# 回覆：串接所有 text 事件的 part.text（多段輸出時依序合併）
ANSWER="$(jq -Rrs 'split("\n") | map(fromjson? // empty)
  | map(select(.type=="text") | .part.text // empty) | join("")' "$LOG")"
# session id：取第一個帶 sessionID 的事件
SID="$(jq -Rrs 'split("\n") | map(fromjson? // empty)
  | map(.sessionID // empty) | map(select(. != "")) | first // empty' "$LOG")"
# resume 時若事件未帶 id，沿用傳入的 RESUME 以維持延續性
[ -n "$RESUME" ] && [ -z "$SID" ] && SID="$RESUME"

# ── 輸出：回覆 + 供延續的 session id；失敗時連 stderr 一起印出供診斷 ──
if [ -z "$ANSWER" ]; then
  { echo "錯誤：Opencode 無回覆。stderr 末幾行："; tail -5 "$ERR"; echo "stdout 末幾行："; tail -5 "$LOG"; } >&2
  exit 1
fi
printf '%s\n' "$ANSWER"
# 輸出契約：id 一定要有；缺失時警告呼叫端本段對話無法延續
if [ -n "$SID" ]; then
  printf '\n[External Advisor opencode session_id: %s]\n' "$SID"
else
  echo "[warn] 未取得 session_id，本段對話無法延續" >&2
fi
