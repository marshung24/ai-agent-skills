#!/usr/bin/env bash
# ask-agy.sh — 詢問 Antigravity（agy，非互動 print 模式），以明確 session_id 延續同一段對話
#
# 用途：讓呼叫端 AI 把 Antigravity 當顧問諮詢，並在同一任務內延續前文。
#
# DECISION: 未採純事後偵測，因無效 id 須在送出前零副作用攔截
# DECISION: 未採「照常輸出加警告」，因無前文回覆會被當成延續結果採信
# DECISION: 未採 status 分流到 exit 2/3，因失敗狀態未完整驗證
# DECISION: 未採可設定的安全模式，因諮詢型呼叫需免互動核可才能自動化
#
# I/O：
#   輸入  ─ prompt：由參數（優先）或 stdin 傳入
#           -r <session_id>：要延續的對話（省略則開新）
#   輸出  ─ stdout：agy 回覆純文字；最後一行 `[External Advisor agy session_id: <id>]`（供下次 -r 延續）
#   結束碼─ 0 成功；2 參數錯誤；
#           3 resume 失敗，兩種來源副作用保證不同：前置檢查擋下時 prompt 未送出（零副作用）；
#             事後比對發現另開新對話時 prompt 已執行、回覆不輸出（stderr 印新 id）；
#           1 執行失敗（CLI 非零結束、輸出非合法 JSON、status 非 SUCCESS；可能已有部分副作用）；
#           127 缺依賴
#
# 用法：
#   ask-agy.sh "問題"                      # 開新對話
#   ask-agy.sh -r <session_id> "追問"       # 延續指定對話
#   echo "很長的問題" | ask-agy.sh -r <id>  # prompt 走 stdin，免引號轉義
#   ask-agy.sh -- "-開頭的問題"             # prompt 以 - 開頭時，加 -- 結束選項解析

set -uo pipefail

# ── 自述（供 advisor-list.sh 組裝清單）──
# 必須擺在 getopts 與依賴檢查之前：getopts 不認識長選項會落入錯誤分支 exit 2，
# 而 CLI 未安裝時也該印得出自述（清單要能列出「已啟用但尚未安裝」的顧問）
# {SELF} 由 advisor-list.sh 替換為本腳本絕對路徑
if [ "${1:-}" = "--info" ]; then
  cat <<'EOF'
agy｜Antigravity
  開新：{SELF} "問題"
  延續：{SELF} -r <session_id> "追問"
EOF
  exit 0
fi

# agy 對話落地位置（版本相依，僅供 resume 前置檢查；不可用時自動降級，見下方檢查段）
BRAIN="${HOME:-}/.gemini/antigravity-cli/brain"

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v agy >/dev/null || { echo "錯誤：找不到 agy CLI，請先安裝並登入" >&2; exit 127; }
command -v jq  >/dev/null || { echo "錯誤：找不到 jq（解析 agy JSON 輸出需要）" >&2; exit 127; }

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
# 順序：prompt 檢查（exit 2）在 resume 前置驗證（exit 3）之前，與其他三支一致——
# 「缺 prompt + 失效 id」應回參數錯誤 2，而非 resume 失敗 3
PROMPT="$*"
if [ -z "$PROMPT" ] && [ ! -t 0 ]; then PROMPT="$(cat)"; fi
[ -n "$PROMPT" ] || { echo "錯誤：缺少 prompt（參數或 stdin 傳入）" >&2; exit 2; }

# ── resume 前置驗證 ──
# id 字元集限制比其他三支嚴：此 id 會拼進 brain/<id> 路徑，須防 `../` 之類蒙混過目錄存在檢查
if [ -n "$RESUME" ] && ! [[ "$RESUME" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "錯誤：session_id 格式不合法（僅允許英數與連字號）" >&2
  exit 2
fi
# 前置檢查只在「能證明 id 不存在」時才擋，判準是 brain/ 第一層**全部**為 UUID 目錄：
# 只要出現一個非 UUID 目錄就代表布局可能已改（分層或混合），此時無法由「brain/<id> 不存在」
# 推出「id 不存在」，一律回報不可驗證讓上層放行。逐項比對十六進位字元集，不用 ? glob
# （? 匹配任意字元，分層目錄名恰好合長度就會漏網）；顯式列舉 .*/ 並跳過 . 與 ..，
# 使結果不受呼叫端經 BASHOPTS 帶進來的 dotglob 影響
brain_flat_layout() {
  [ -n "${HOME:-}" ] && [ -d "$BRAIN" ] || return 1
  local entry name hit=0
  for entry in "$BRAIN"/*/ "$BRAIN"/.*/; do
    [ -d "$entry" ] || continue
    name="${entry%/}"; name="${name##*/}"
    case "$name" in .|..) continue ;; esac
    [[ "$name" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
    hit=1
  done
  [ "$hit" -eq 1 ]
}
if [ -n "$RESUME" ]; then
  if brain_flat_layout; then
    # id 對應的對話不存在即停（agy 對無效 id 會靜默開新，須在送出前擋下）
    # 注意：${RESUME} 必須帶大括號——後面緊接全形字時，bash 會把多位元組字元
    # 的首位元組黏進變數名（set -u 下報 unbound variable）
    [ -d "$BRAIN/$RESUME" ] || {
      echo "錯誤：resume 失敗（對應的對話不存在：${RESUME}）。prompt 未送出。確認無重複執行疑慮後，可不帶 -r 重送以開新對話。" >&2
      exit 3
    }
  else
    # 無法證明 id 不存在時放行，改由事後比對攔截——代價是失效 id 會多花一次呼叫且 prompt 已執行，
    # 但反過來擋下會在 agy 改動儲存結構後讓所有 resume 失效。此時 exit 3 不再保證零副作用（見檔頭結束碼）
    # 前綴用 [note] 而非 [warn]：呼叫端把 stderr 的 [warn] 視為「id 不可用」，此處不影響 id 有效性
    echo "[note] 無法驗證 agy 儲存結構，resume 前置檢查略過；本次若 resume 失敗，prompt 已送出並執行" >&2
  fi
fi

# ── 共用旗標 ──
# 注意：agy 的 -p 是「吃值」旗標（prompt 即其值），必須排在最後、prompt 緊跟其後
COMMON=(--dangerously-skip-permissions --output-format json)
[ -n "$RESUME" ] && COMMON+=(--conversation "$RESUME")

# 暫存 stdout / stderr：stdout 為單行 JSON，stderr 供失敗診斷（不吞掉）
OUT="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR"' EXIT

# ── 執行 agy：prompt 作為 -p 的值傳入 ──
agy "${COMMON[@]}" -p "$PROMPT" >"$OUT" 2>"$ERR"
RC=$?

# 診斷輸出：失敗分支共用，避免各分支各寫一份
# agy 的失敗訊息在 stdout 的 .error，stderr 常為全空（實測逾時與 SIGTERM 皆如此）。
# stdout 為合法 JSON 時只抽 .status/.error——整份 JSON 含 .response，直接倒出會把回覆內容寫進
# 呼叫端的錯誤日誌（且 agy 的 JSON 是單行，以「行」設限等於不設限，故非 JSON 時改用 byte 上限）
DIAG_BYTES=800
dump_diag() {
  local status err
  {
    echo "$1"
    if status="$(jq -r '.status // empty' "$OUT" 2>/dev/null)" && [ -n "$status" ]; then
      err="$(jq -r '.error // empty' "$OUT" 2>/dev/null)"
      echo "agy status：$status${err:+（$err）}"
    else
      echo "agy stdout 末 ${DIAG_BYTES} bytes（非預期格式）："; tail -c "$DIAG_BYTES" "$OUT"; echo
    fi
    echo "agy stderr 末 ${DIAG_BYTES} bytes："; tail -c "$DIAG_BYTES" "$ERR"
  } >&2
}

# ── 失敗判定（fail closed：任一項不成立即 exit 1，不輸出殘缺回覆）──
# CLI 結束碼優先於 JSON 內容：非零時即使 stdout 恰為合法 JSON 也不採信
[ "$RC" -eq 0 ] || { dump_diag "錯誤：agy 執行失敗（exit $RC）。"; exit 1; }
# 必要欄位存在且型別正確——不可用 tostring 之類偷偷轉型，型別變動應以失敗呈現
jq -e 'type == "object"
  and (.conversation_id | type == "string" and length > 0)
  and (.status          | type == "string")
  and (.response        | type == "string")' "$OUT" >/dev/null 2>&1 \
  || { dump_diag "錯誤：agy 輸出非預期的 JSON（欄位缺漏或型別不符）。"; exit 1; }
STATUS="$(jq -r '.status' "$OUT")"
[ "$STATUS" = "SUCCESS" ] || { dump_diag "錯誤：agy 回報 status=${STATUS}。"; exit 1; }

# ── 取得 conversation id ──
CID="$(jq -r '.conversation_id' "$OUT")"
# resume 未接上：agy 對無效 id 會靜默開新且結束碼仍為 0，只能靠回傳 id 比對辨識。
# 回覆不輸出——它來自一段無前文的新對話，輸出會被呼叫端當成延續結果採信
if [ -n "$RESUME" ] && [ "$CID" != "$RESUME" ]; then
  echo "[warn] resume 失敗：agy 另開了新對話（新 id: ${CID}），回覆未輸出。確認無重複執行疑慮後，可不帶 -r 重送以開新對話。" >&2
  exit 3
fi
# 套用與 -r 相同的字元集驗證：來源異常時寧缺勿錯，清空並由下方輸出段印 [warn]，不輸出不可 resume 的假 id
if ! [[ "$CID" =~ ^[A-Za-z0-9-]+$ ]]; then CID=""; fi

# 無回覆即失敗，與其他三支一致（其 CLI 解析不到回覆時亦為 exit 1）——
# 只取長度不取內容，避免把回覆讀進變數（command substitution 會吃掉尾端換行）
if [ "$(jq -r '.response | length' "$OUT" 2>/dev/null)" = "0" ]; then
  dump_diag "錯誤：agy 回報成功但無回覆內容。"
  exit 1
fi

# ── 輸出：回覆 + 供延續的 session id ──
# jq -j 直接輸出解碼後的字串（跳脫字元正確還原）；不可用 $(jq -r …)——command substitution
# 會吃掉尾端換行，之後無法還原。條件式只在回覆本身沒有結尾換行時補一個，確保末行標記獨占一行
jq -j '.response, (if (.response | endswith("\n")) then "" else "\n" end)' "$OUT"
# 輸出契約：id 一定要有；缺失時警告呼叫端本段對話無法延續
if [ -n "$CID" ]; then
  printf '\n[External Advisor agy session_id: %s]\n' "$CID"
else
  echo "[warn] 未取得 session_id（agy 回傳的 conversation_id 格式不合法），本段對話無法延續" >&2
fi
