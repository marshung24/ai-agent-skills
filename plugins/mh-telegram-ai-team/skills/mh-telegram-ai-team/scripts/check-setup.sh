#!/usr/bin/env bash
# Telegram 串接建置檢查（僅 Claude Code 端）：唯讀偵測本機狀態，供 AI 在建置／排查開始時決定從哪一步接手
#
# 使用情境：見 setup.md〈流程總覽〉「先跑檢查」；從第一個 FAIL／ASK 的步驟接手，已 PASS 的不再詢問使用者
# 輸出：stdout 每項一行 `<狀態> <步驟> <訊息>`，依步驟編號排序；步驟編號對應〈流程總覽〉
#   PASS 已完成／FAIL 未完成或設錯／WARN 可能有問題／INFO 現況說明／ASK 本機偵測不到，須問使用者
# 結束碼：有任一 FAIL 為 1，否則 0；參數錯誤為 2
# 安全：不輸出 token、使用者或群組 ID；唯一連外動作是以 token 呼叫 getMe（只送往 api.telegram.org）
# 依賴：jq、curl；不寫入任何檔案
#
# 用法：check-setup.sh [--offline | -h]
#   --offline   跳過 getMe，token 有效性不驗證
#   -h, --help  顯示本說明
set -u

# 參數：說明文字即檔頭註解（第 2 行到 set -u 前），避免另寫一份
usage() { awk 'NR == 1 { next } /^set -u/ { exit } { sub(/^# ?/, ""); print }' "$0"; }
OFFLINE=0
case "${1:-}" in
  "") ;;
  --offline) OFFLINE=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "未知參數：$1" >&2; usage >&2; exit 2 ;;
esac

# 路徑皆為官方 telegram plugin 的固定位置；強化版沿用同一份設定與 cache 目錄
CH_DIR="$HOME/.claude/channels/telegram"
PLUGIN_KEY="telegram@claude-plugins-official"
CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
fail=0   # 1＝已有 FAIL，決定結束碼
out=""   # 暫存的結果行，finish 時才排序輸出

# 檢查順序依資料相依（jq、token 先行），與步驟順序不同；故結果先暫存，結束時依步驟編號穩定排序
# say <狀態> <步驟> <訊息>：記一行結果，FAIL 時標記結束碼
say() { out+="$(printf '%-4s %s %s' "$1" "$2" "$3")"$'\n'; [ "$1" = FAIL ] && fail=1; return 0; }
# finish：依步驟編號（第 2 欄數字）穩定排序輸出並結束；同步驟內維持檢查順序
finish() { printf '%s' "$out" | sort -s -k2,2n; exit "$fail"; }

# 步驟 4 前置工具：bun 跑 server、git 裝強化版、jq 供本檢查與 log-run.sh、curl 呼叫 getMe
for t in bun git jq curl; do
  if command -v "$t" >/dev/null 2>&1; then say PASS 4.橋接層 "$t 在 PATH"; else say FAIL 4.橋接層 "$t 不在 PATH"; fi
done
# 缺 jq 無法解析任何 JSON 設定，直接輸出已有結果結束
command -v jq >/dev/null 2>&1 || { say FAIL 4.橋接層 "缺 jq，其餘檢查無法進行"; finish; }

# 步驟 1–3 帳號與 bot：帳號本身偵測不到，以 token 能否通過 getMe 反推；無 token 才 ASK 帳號
# 取 .env 最後一筆 TELEGRAM_BOT_TOKEN（同 dotenv 後者覆蓋），去掉引號、空白與 CRLF
token=""
[ -f "$CH_DIR/.env" ] && token="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$CH_DIR/.env" | tail -n 1 | tr -d '"'"'"' \r')"
if [ -z "$token" ]; then
  say FAIL 2.建bot "$CH_DIR/.env 無 TELEGRAM_BOT_TOKEN"
  say ASK 1.帳號 "問使用者是否已有 Telegram 帳號、是否已建 bot"
else
  # 權限：GNU stat 失敗時改用 BSD（macOS）語法
  perm="$(stat -c %a "$CH_DIR/.env" 2>/dev/null || stat -f %Lp "$CH_DIR/.env")"
  if [ "$perm" = 600 ]; then say PASS 2.建bot ".env 權限 600"; else say FAIL 2.建bot ".env 權限 $perm，應為 600"; fi
  if [ "$OFFLINE" = 1 ]; then
    say INFO 2.建bot "--offline：未驗證 token"
  else
    # token 以 curl 設定檔格式經 stdin 傳入，不出現在 argv（ps 看不到）
    me="$(printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$token" | curl -sS --max-time 10 -K - 2>&1)"
    if jq -e '.ok == true' >/dev/null 2>&1 <<<"$me"; then
      say PASS 1.帳號 "token 有效，帳號與 bot 已存在"
      say PASS 2.建bot "$(jq -r '"@\(.result.username) id=\(.result.id)"' <<<"$me")"
      # can_read_all_group_messages＝true 即隱私模式已關；BotFather 改設定後須重新進群才反映
      if [ "$(jq -r '.result.can_read_all_group_messages' <<<"$me")" = true ]; then
        say INFO 3.bot參數 "隱私模式已關（收得到未 @ 的群組訊息）"
      else
        say INFO 3.bot參數 "隱私模式開啟（只收 @ 與回覆）；要收錄上下文需 /setprivacy Disable 後重新進群"
      fi
    # 401 才確定是 token 問題；其他失敗（逾時、DNS）不判 FAIL
    elif jq -e '.error_code == 401' >/dev/null 2>&1 <<<"$me"; then
      say FAIL 2.建bot "token 無效或已 /revoke"
    else
      say WARN 2.建bot "getMe 失敗（網路？）：$(jq -r '.description // empty' <<<"$me" 2>/dev/null || echo "$me" | head -c 120)"
    fi
  fi
fi

# 步驟 4 橋接層：官方 plugin 已安裝、強化版已覆蓋最新版本目錄、未全域啟用
if jq -e --arg k "$PLUGIN_KEY" '.plugins | has($k)' "$HOME/.claude/plugins/installed_plugins.json" >/dev/null 2>&1; then
  say PASS 4.橋接層 "$PLUGIN_KEY 已安裝"
  # 執行的是 cache 內版本號最大的目錄；強化版安裝時會把原檔備份成 server.ts.official，以此判定已套用
  ver="$(ls "$CACHE_DIR" 2>/dev/null | sort -V | tail -n 1)"
  if [ -n "$ver" ] && [ -f "$CACHE_DIR/$ver/server.ts.official" ]; then
    say PASS 4.橋接層 "強化版已套用（$ver）"
  else
    say FAIL 4.橋接層 "強化版未套用於最新版本 ${ver:-?}（plugin 更新後須重跑 install.sh）"
  fi
else
  say FAIL 4.橋接層 "$PLUGIN_KEY 未安裝"
fi
# 應只在接 Telegram 的 session 以 --settings 啟用；全域啟用會讓每個 session 起 server
if [ "$(jq -r --arg k "$PLUGIN_KEY" '.enabledPlugins[$k] // false' "$HOME/.claude/settings.json" 2>/dev/null)" = true ]; then
  say FAIL 4.橋接層 "全域 settings.json 啟用了 telegram plugin，每個 session 都會搶 poller"
else
  say PASS 4.橋接層 "未全域啟用"
fi

# 步驟 5 群組與授權：access.json 的私訊政策、限速、admins；只輸出人數，不輸出 ID
acc="$CH_DIR/access.json"
if [ -f "$acc" ]; then
  # 未設 dmPolicy 時 server 預設為 pairing
  pol="$(jq -r '.dmPolicy // "pairing"' "$acc")"
  if [ "$pol" = allowlist ]; then say PASS 5.授權 "dmPolicy=allowlist"; else say FAIL 5.授權 "dmPolicy=$pol，配對完應切 allowlist"; fi
  say INFO 5.授權 "$(jq -r '"allowFrom \(.allowFrom // [] | length) 人、群組 \(.groups // {} | length) 個"' "$acc")"
  if jq -e '.limits | type == "object"' "$acc" >/dev/null; then
    say PASS 5.授權 "已設 limits（$(jq -r '.limits | to_entries | map("\(.key)=\(.value)") | join(" ")' "$acc")）"
  else
    say FAIL 5.授權 "未設 limits（防 AI 間迴圈）"
  fi
  # admins 不受 limits 限制；是否只有主人須人工比對，故只報人數
  if jq -e '.admins | length > 0' "$acc" >/dev/null 2>&1; then
    say INFO 5.授權 "admins $(jq '.admins | length' "$acc") 人：須只有主人"
  else
    say WARN 5.授權 "未設 admins"
  fi
else
  say FAIL 5.授權 "$acc 不存在（尚未配對）"
fi

# 步驟 7 執行期：poller 唯一、一般 shell 無 token 變數、無 MCP 失敗快取
# 以本機 bun server.ts 行程數近似 poller 數；分不出 token 與 MCP-only，多個時只警示，其他主機／容器查不到
n="$(pgrep -f 'bun.*server\.ts' 2>/dev/null | wc -l | tr -d ' ')"
case "$n" in
  0) say INFO 7.驗證 "目前無 server 執行（接 Telegram 的 session 未啟動）" ;;
  1) say PASS 7.驗證 "本機只有 1 個 server（其他主機／容器需另查）" ;;
  *) say WARN 7.驗證 "$n 個 server 同時執行；同 token 且皆非 MCP-only 會 409 Conflict，需人工確認" ;;
esac
# token 應只在 .env；export 到 shell 會被所有子行程繼承
if env | grep -q '^TELEGRAM_'; then say FAIL 7.驗證 "目前 shell 有 TELEGRAM_ 環境變數"; else say PASS 7.驗證 "shell 無 TELEGRAM_ 環境變數"; fi
# 曾連線失敗的 MCP server 會被快取，15 分鐘內同名 server 略過不啟動
if jq -e 'keys | any(test("telegram"))' "$HOME/.claude/mcp-needs-auth-cache.json" >/dev/null 2>&1; then
  say WARN 7.驗證 "MCP 失敗快取有 telegram 項，15 分鐘內會被略過"
fi

finish
