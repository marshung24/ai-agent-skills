#!/usr/bin/env bash
# ask-agy.sh — 詢問 Antigravity（agy，非互動 print 模式），以 conversation id 明確延續同一段對話
#
# 用途：讓呼叫端 AI 把 Antigravity 當顧問諮詢，並在同一任務內延續前文。
#
# DECISION: id 取得走「磁碟偵測」——實測本版 agy headless 下：
#           (1) 自產 UUID 帶 --conversation 無效（靜默開新、不落地）
#           (2) agy 自建的 conversation id 帶 --conversation 可正確延續
#           (3) headless 不印 resume 指令（Auto-Save Resume 僅互動模式）
#           主路徑：查 cache/last_conversations.json 的「cwd → 最後 conversation id」
#           對照表，並以 brain/<id> mtime 驗證確為本次執行建立（防讀到同 cwd 舊 id）；
#           fallback：掃 brain/ 比 marker 新的目錄。皆依賴 agy 的儲存位置
#           （~/.gemini/antigravity-cli/），版本更換時需重驗。
#
# DECISION: -r 的 id 先驗 brain 目錄存在，不存在即 exit 3——agy 對無效 id 會靜默
#           開新對話（無法以結束碼偵測），前置檢查補回「resume 失敗」語意。
#
# I/O：
#   輸入  ─ prompt：由參數（優先）或 stdin 傳入
#           -r <conversation_id>：要延續的對話（省略則開新）
#   輸出  ─ stdout：agy 回覆純文字；最後一行 `[External Advisor agy session_id: <id>]`（供下次 -r 延續）
#   結束碼─ 0 成功；2 參數錯誤；3 resume id 不存在；1 執行失敗且無回覆；127 缺依賴
#
# 用法：
#   ask-agy.sh "問題"                      # 開新對話（id 由磁碟偵測取得）
#   ask-agy.sh -r <conversation_id> "追問"  # 延續指定對話
#   echo "很長的問題" | ask-agy.sh -r <id>  # prompt 走 stdin，免引號轉義
#   ask-agy.sh -- "-開頭的問題"             # prompt 以 - 開頭時，加 -- 結束選項解析

set -uo pipefail

# agy 對話儲存位置（版本相依，見檔頭 DECISION）
BRAIN="$HOME/.gemini/antigravity-cli/brain"
LASTMAP="$HOME/.gemini/antigravity-cli/cache/last_conversations.json"

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v agy >/dev/null || { echo "錯誤：找不到 agy CLI，請先安裝並登入" >&2; exit 127; }
command -v jq  >/dev/null || { echo "錯誤：找不到 jq（解析 last_conversations.json 需要）" >&2; exit 127; }

# ── 參數解析：-r <conversation_id> 為可選的延續目標 ──
RESUME=""
while getopts "r:" opt; do
  case "$opt" in
    r) RESUME="$OPTARG"
       # 空字串 id 必擋：呼叫端最常見寫法是 -r "$id"，id 擷取失敗時 $id 為空——
       # 若放行會靜默改走「開新對話」路徑重送 prompt，繞過 resume 失敗防線（重複執行風險）
       [ -n "$RESUME" ] || { echo "錯誤：-r 的 id 不可為空（上一輪 id 擷取可能失敗，請先檢查）" >&2; exit 2; } ;;
    *) echo "用法: $0 [-r <conversation_id>] [--] \"<prompt>\"" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# ── 取得 prompt：命令列參數優先；無參數時僅在 stdin 非 TTY 才讀（避免互動誤用時掛住）──
# 順序：prompt 檢查（exit 2）在 resume 前置驗證（exit 3）之前，與其他三支一致——
# 「缺 prompt + 失效 id」應回參數錯誤 2，而非 resume 失敗 3
PROMPT="$*"
if [ -z "$PROMPT" ] && [ ! -t 0 ]; then PROMPT="$(cat)"; fi
[ -n "$PROMPT" ] || { echo "錯誤：缺少 prompt（參數或 stdin 傳入）" >&2; exit 2; }

# ── resume 前置驗證 ──
# id 格式限制：僅允許 UUID 字元集，防 `../` 之類路徑蒙混過目錄存在檢查
if [ -n "$RESUME" ] && ! [[ "$RESUME" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "錯誤：conversation id 格式不合法（僅允許英數與連字號）" >&2
  exit 2
fi
# id 對應的對話不存在即停（agy 對無效 id 會靜默開新，須在此擋下）
if [ -n "$RESUME" ] && [ ! -d "$BRAIN/$RESUME" ]; then
  # 注意：${RESUME} 必須帶大括號——後面緊接全形字時，bash 會把多位元組字元
  # 的首位元組黏進變數名（set -u 下報 unbound variable）
  echo "錯誤：resume 失敗（conversation id 不存在：${RESUME}）。確認無重複執行疑慮後，可不帶 -r 重送以開新對話。" >&2
  exit 3
fi

# ── 共用旗標 ──
# DECISION: 保留 --dangerously-skip-permissions——本 workspace 定位為外部沙箱環境，
#           諮詢型呼叫需免互動核可才能自動化；若移作他用，呼叫端應自行評估此預設
# 注意：agy 的 -p 是「吃值」旗標（prompt 即其值），必須排在最後、prompt 緊跟其後
COMMON=(--dangerously-skip-permissions)
[ -n "$RESUME" ] && COMMON+=(--conversation "$RESUME")

# 暫存 stdout / stderr：agy 輸出即純文字回覆，stderr 供失敗診斷（不吞掉）
LOG="$(mktemp)"; ERR="$(mktemp)"; MARK="$(mktemp)"
trap 'rm -f "$LOG" "$ERR" "$MARK"' EXIT

# ── 執行 agy：prompt 作為 -p 的值傳入（MARK 在執行前建立，供事後偵測新增對話目錄）──
agy "${COMMON[@]}" -p "$PROMPT" >"$LOG" 2>"$ERR"
RC=$?

# ── 取得 conversation id ──
if [ -n "$RESUME" ]; then
  # 延續：沿用傳入的 id
  CID="$RESUME"
else
  # 開新（主路徑）：查「cwd → 最後 conversation id」對照表，
  # 並以 brain/<id> 比 MARK 新驗證確為本次執行建立（防讀到同 cwd 的舊 id）
  CID="$(jq -r --arg d "$PWD" '.[$d] // empty' "$LASTMAP" 2>/dev/null)"
  if [ -z "$CID" ] || [ ! -d "$BRAIN/$CID" ] || [ -z "$(find "$BRAIN/$CID" -maxdepth 0 -newer "$MARK" 2>/dev/null)" ]; then
    # fallback：偵測 brain/ 下比 MARK 新的目錄（本次執行建立的對話）
    # -mindepth 1 排除 brain 根目錄本身（子目錄建立會更新父目錄 mtime）；
    # -exec ls -td {} +：無匹配時不執行（免空跑產生垃圾）、有匹配時依 mtime 新→舊排序，
    # macOS/Linux 皆可攜（不用 stat——旗標兩平台不相容；不用 xargs——空輸入行為兩平台不一致）
    CID="$(find "$BRAIN" -mindepth 1 -maxdepth 1 -type d -newer "$MARK" -exec ls -td {} + 2>/dev/null \
      | head -1 | sed 's|.*/||')"
  fi
  # 偵測結果套用與 -r 相同的字元集驗證：來源異常（對照表污損等）時寧缺勿錯，
  # 清空並由下方輸出段印 [warn]，不輸出不可 resume 的假 id
  if [ -n "$CID" ] && ! [[ "$CID" =~ ^[A-Za-z0-9-]+$ ]]; then
    CID=""
  fi
fi

# ── 輸出：回覆 + 供延續的 session id；失敗時連 stderr 一起印出供診斷 ──
ANSWER="$(cat "$LOG")"
if [ "$RC" -ne 0 ] || [ -z "$ANSWER" ]; then
  { echo "錯誤：agy 無回覆（exit $RC）。stderr 末幾行："; tail -5 "$ERR"; echo "stdout 末幾行："; tail -5 "$LOG"; } >&2
  exit 1
fi
printf '%s\n' "$ANSWER"
# 輸出契約：id 一定要有；缺失時警告呼叫端本段對話無法延續
if [ -n "$CID" ]; then
  printf '\n[External Advisor agy session_id: %s]\n' "$CID"
else
  echo "[warn] 未取得 conversation id（brain 目錄偵測失敗），本段對話無法延續" >&2
fi
