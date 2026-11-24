#!/usr/bin/env bash
# Claude／Codex 訂閱額度剩餘查詢：唯讀，走各 CLI 官方的非互動額度介面，不啟動對話、不消耗額度
#
# 使用情境：祕書回答「還剩多少額度」、承接任務前評估餘量；log-run.sh 以 --json 取額度快照
# 輸出：預設每個額度窗一行 `<ai> <窗口>：剩 N%（重置 <時間>）`；--json 為 {"claude":[…],"codex":[…]}
#   每窗 {window, remain_pct, resets}；查不到的 AI 值為 null。只有剩餘百分比，無法換算成剩餘 token 數
# 結束碼：至少一支查得為 0，全數查不到為 1；參數錯誤為 2；缺 jq／timeout 為 127
# 依賴：jq、GNU timeout（macOS 為 gtimeout）；各 AI 需其 CLI 已登入，未安裝者略過
#
# 用法：quota.sh [--json] [claude] [codex]   未指定 AI 時查全部
#   --json      機器可讀輸出
#   -h, --help  顯示本說明
set -uo pipefail

usage() { awk 'NR == 1 { next } /^set -u/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

# 參數：--json 與 AI 名稱可任意順序；同名只查一次
JSON=0; TARGETS=()
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    -h|--help) usage; exit 0 ;;
    claude|codex) [[ " ${TARGETS[*]:-} " == *" $a "* ]] || TARGETS+=("$a") ;;
    *) echo "未知參數：$a" >&2; usage >&2; exit 2 ;;
  esac
done
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(claude codex)

command -v jq >/dev/null || { echo "缺 jq" >&2; exit 127; }
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout)" || { echo "缺 timeout（GNU coreutils）" >&2; exit 127; }
TIMEOUT=30   # 額度查詢不含模型推論，逾此視為 CLI 卡住

# quota_claude：stdout 印窗口 JSON 陣列，失敗回非 0
# print 模式跑內建 /usage；num_turns 非 0 表示被當 prompt 送進模型，回覆是模型編的、不可採信
quota_claude() {
  local q
  q="$("$TIMEOUT_BIN" "$TIMEOUT" claude -p --output-format json '/usage' 2>/dev/null)" || return 1
  jq -e '.is_error == false and .num_turns == 0' >/dev/null 2>&1 <<<"$q" || return 1
  # 報告行形如「Current session: 23% used · resets Sep 1, 7:49pm (Asia/Taipei)」，整行錨定以免誤抓其他百分比
  jq -ce '[ .result | split("\n")[]
      | capture("^(?<window>[^:]+):\\s+(?<used>[0-9]{1,3})% used(\\s+·\\s+resets\\s+(?<resets>.+))?$")?
      | select((.used | tonumber) <= 100)
      | {window, remain_pct: (100 - (.used | tonumber)), resets} ]
    | if length == 0 then empty else . end' <<<"$q"
}

# quota_codex：stdout 印窗口 JSON 陣列，失敗回非 0
# app-server 的 JSON-RPC account/rateLimits/read；stdin EOF 時 server 會在回應前結束，故用 FIFO 保持連線
# DECISION: 未採 coproc，因 macOS 內建 bash 3.2 不支援
quota_codex() {
  local line resp="" pid dir
  dir="$(mktemp -d)" || return 1
  mkfifo "$dir/in" "$dir/out" || { rm -rf "$dir"; return 1; }
  "$TIMEOUT_BIN" --kill-after=5s "$TIMEOUT" codex app-server <"$dir/in" >"$dir/out" 2>/dev/null &
  pid=$!
  # 兩端依序開啟才不互等；開啟後即可刪檔，連線不受影響
  exec 3>"$dir/in" 4<"$dir/out"
  rm -rf "$dir"
  # server 提早結束時 SIGPIPE 只結束子 shell，不中斷查詢流程
  ( printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"mh_telegram_ai_team","title":"mh-telegram-ai-team","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}' >&3 ) 2>/dev/null
  # 以 JSON 的 .id 認回應（通知不帶 id）；收到即關 stdin 讓 server 自行結束
  while IFS= read -r line <&4; do
    if jq -e 'type == "object" and .id == 2' >/dev/null 2>&1 <<<"$line"; then resp="$line"; break; fi
  done
  exec 3>&- 4<&-
  wait "$pid" 2>/dev/null
  [ -n "$resp" ] || return 1
  # usedPercent 驗 0–100 再換算；windowDurationMins 300／10080 即 5 小時窗／7 天窗，resetsAt 為 epoch 秒
  jq -ce '[ .result.rateLimits | (.primary, .secondary) | select(. != null)
      | select((.usedPercent | type) == "number" and .usedPercent >= 0 and .usedPercent <= 100)
      | { window: ({"300": "5h", "10080": "7d"}[(.windowDurationMins | tostring)] // "\(.windowDurationMins)m"),
          remain_pct: ((100 - .usedPercent) | round),
          resets: (if .resetsAt then (.resetsAt | strflocaltime("%Y-%m-%d %H:%M %z")) else null end) } ]
    | if length == 0 then empty else . end' <<<"$resp"
}

# 主流程：逐支查詢，未安裝或失敗記 null 並警告，不中斷其餘
result='{}'; ok=0
for ai in "${TARGETS[@]}"; do
  w=""
  if ! command -v "$ai" >/dev/null; then
    echo "[warn] $ai CLI 不在 PATH，略過" >&2
  elif w="$("quota_$ai")" && [ -n "$w" ]; then
    ok=1
  else
    w=""; echo "[warn] $ai 額度查詢失敗" >&2
  fi
  result="$(jq -c --arg k "$ai" --argjson v "${w:-null}" '. + {($k): $v}' <<<"$result")"
done

if [ "$JSON" = 1 ]; then
  printf '%s\n' "$result"
else
  jq -r 'to_entries[] | .key as $ai
    | if .value == null then "\($ai) 查不到"
      else .value[] | "\($ai) \(.window)：剩 \(.remain_pct)%" + (if .resets then "（重置 \(.resets)）" else "" end) end' <<<"$result"
fi
[ "$ok" = 1 ]
