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
SEC_DIR="${MH_TG_SECRETARY_DIR:-$HOME/secretary}"
CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
fail=0   # 1＝已有 FAIL，決定結束碼
out=""   # 暫存的結果行，finish 時才排序輸出

# 檢查順序依資料相依（jq、token 先行），與步驟順序不同；故結果先暫存，結束時依步驟編號穩定排序
# say <狀態> <步驟> <訊息>：記一行結果，FAIL 時標記結束碼
say() { out+="$(printf '%-4s %s %s' "$1" "$2" "$3")"$'\n'; [ "$1" = FAIL ] && fail=1; return 0; }
# reg_missing <internal.md>：列出未填的必要欄位（bot username、負責人 user ID／username）
# 解析模版的表格形狀：〈祕書〉為「欄位｜值」、〈負責人〉為「user ID｜username｜暱稱」；值不是帳號格式即未填，每位負責人都要有 username
reg_missing() {
  awk -F'|' '
    /^## / { sec = $0; next }
    sec ~ /^## 祕書/ && NF >= 3 {
      k = $2; v = $3; gsub(/^ +| +$/, "", k); gsub(/^ +| +$/, "", v)
      if (k == "bot username" && v ~ /^@?[A-Za-z0-9_]+/) bot = 1
    }
    sec ~ /^## 負責人/ && $2 ~ /^ *[0-9]+ *$/ { owner = 1; u = $3; gsub(/ /, "", u); if (u !~ /^@[A-Za-z0-9_]+$/) no_u = 1 }
    END {
      out = ""
      if (!bot) out = out "bot username "
      if (!owner) out = out "負責人 user ID "
      else if (no_u) out = out "負責人 username "
      sub(/ $/, "", out); print out
    }' "$1"
}
# finish：依步驟編號（第 2 欄數字）穩定排序輸出並結束；同步驟內維持檢查順序
finish() { printf '%s' "$out" | sort -s -k2,2n; exit "$fail"; }

# 步驟 4 前置工具：bun 跑 server、git 裝強化版、jq 供本檢查與 log-run.sh、curl 呼叫 getMe
for t in bun git jq curl; do
  if command -v "$t" >/dev/null 2>&1; then say PASS 4.橋接層 "$t 在 PATH"; else say FAIL 4.橋接層 "$t 不在 PATH"; fi
done
# macOS 的 PATH 上 bash 低於 4（系統內建 3.2）時建議改裝 Homebrew bash；非必要故只 WARN
if [ "$(uname)" = Darwin ]; then
  bash_ver="$(bash -c 'echo "${BASH_VERSION%%[!0-9.]*}"' 2>/dev/null)"
  if [ "${bash_ver%%.*}" -ge 4 ] 2>/dev/null; then say PASS 4.橋接層 "PATH 上 bash ${bash_ver}"
  else say WARN 4.橋接層 "PATH 上 bash ${bash_ver:-未知}，建議 brew install bash（macOS 內建 3.2 過舊）"; fi
fi
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
  if [ "$perm" = 600 ]; then say PASS 2.建bot ".env 權限 600"; else say FAIL 2.建bot ".env 權限 ${perm}，應為 600"; fi
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
    say PASS 4.橋接層 "強化版已套用（${ver}）"
    # 歷史保存上限：強化版寫死於 prune()，plugin 更新或重裝會蓋回原值，數值與目標不符時提示改法
    tune="$(dirname "$0")/tune-history.sh"
    tune_out="$("$tune" --check --file "$CACHE_DIR/$ver/server.ts" 2>&1)"
    case $? in
      0) say PASS 4.橋接層 "歷史保存上限符合目標（5000 則／140 天；超過 500MB 縮到 2000 則）" ;;
      1) say WARN 4.橋接層 "歷史保存上限不符（$(grep -E '目前=' <<<"$tune_out" | awk '{print $1 $2}' | paste -sd ' ' -)）：跑 $tune --apply 後重開接 Telegram 的 session" ;;
      *) say WARN 4.橋接層 "無法判讀歷史保存上限：$(tail -n 1 <<<"$tune_out")" ;;
    esac
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

# 步驟 5 群組與授權：access.json 的私訊政策、限速、admins、觸發字；只輸出人數，不輸出 ID
acc="$CH_DIR/access.json"
if [ -f "$acc" ]; then
  # 未設 dmPolicy 時 server 預設為 pairing
  pol="$(jq -r '.dmPolicy // "pairing"' "$acc")"
  if [ "$pol" = allowlist ]; then say PASS 5.授權 "dmPolicy=allowlist"; else say FAIL 5.授權 "dmPolicy=${pol}，配對完應切 allowlist"; fi
  say INFO 5.授權 "$(jq -r '"allowFrom \(.allowFrom // [] | length) 人、群組 \(.groups // {} | length) 個"' "$acc")"
  # 判準同 server：三欄取整後大於 0 才算限速；數值高低由負責人自訂，不檢查
  lim_keys='["messagesPerMinute","messagesPerHour","tokensPerDay"]'
  if ! jq -e '.limits | type == "object"' "$acc" >/dev/null; then
    say FAIL 5.授權 "未設 limits（防 AI 間迴圈）"
  elif jq -e --argjson k "$lim_keys" '[.limits[$k[]] | (tonumber? // 0) | floor | select(. > 0)] | length > 0' "$acc" >/dev/null; then
    say PASS 5.授權 "已設 limits（$(jq -r '.limits | to_entries | map("\(.key)=\(.value)") | join(" ")' "$acc")）"
  else
    say FAIL 5.授權 "limits 值無效，等同不限（至少一欄須大於 0）"
  fi
  # userLimits 明設 0 或負數會覆寫成不限，可能是刻意，交人判斷
  ul="$(jq -r --argjson k "$lim_keys" '[.userLimits // {} | to_entries[] | select(.value | type == "object") | select([.value | to_entries[] | select(.key | IN($k[])) | .value | (tonumber? // 0) | floor | select(. <= 0)] | length > 0) | .key] | join(",")' "$acc")"
  [ -z "$ul" ] || say WARN 5.授權 "userLimits 有不限額度的 ID：${ul}（須確認不是其他 bot）"
  # admins 不受 limits 限制；是否只有負責人須人工比對，故只報人數
  if jq -e '.admins | length > 0' "$acc" >/dev/null 2>&1; then
    say INFO 5.授權 "admins $(jq '.admins | length' "$acc") 人：須只有負責人"
  else
    say WARN 5.授權 "未設 admins"
  fi
  # 觸發字 @all 為群組廣播契約（collaboration.md〈訊息契約〉）；以樣式實際比對 "@all"，不比字面
  if jq -e '.mentionPatterns // [] | any(. as $p | "@all" | test($p))' "$acc" >/dev/null 2>&1; then
    say PASS 5.授權 "mentionPatterns 可觸發 @all"
  else
    say FAIL 5.授權 "mentionPatterns 無 @all 觸發字（設法見 setup.md〈群組與授權〉）"
  fi
  # requireMention 未設時 server 預設為 true；設 false 的群組每則訊息都進 session
  n="$(jq '[.groups // {} | .[] | select(.requireMention == false)] | length' "$acc")"
  if [ "$n" -gt 0 ]; then say FAIL 5.授權 "$n 個群組 requireMention=false，未 @ 的訊息也會觸發"; else say PASS 5.授權 "群組皆需 @ 才觸發"; fi
else
  say FAIL 5.授權 "$acc 不存在（尚未配對）"
fi

# 步驟 6 祕書目錄：存在、非 git repo、只在此啟用 plugin、AGENTS.md 宣告資料目錄、拒寫清單、登錄檔已建
if [ -d "$SEC_DIR" ]; then
  if git -C "$SEC_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    say FAIL 6.協作skill "祕書目錄 $SEC_DIR 在 git repo 內，資料含 ID 與個資，須改用非 repo 目錄"
  else
    say PASS 6.協作skill "祕書目錄 $SEC_DIR"
  fi
  if jq -e --arg k "$PLUGIN_KEY" '.enabledPlugins[$k] == true' "$SEC_DIR/.claude/settings.json" >/dev/null 2>&1; then
    say PASS 6.協作skill "祕書目錄 .claude/settings.json 已啟用 telegram plugin"
  else
    say FAIL 6.協作skill "祕書目錄 .claude/settings.json 未啟用 telegram plugin（見 setup.md〈祕書目錄〉）"
  fi
  if grep -qF '`data/`' "$SEC_DIR/AGENTS.md" 2>/dev/null; then
    say PASS 6.協作skill "AGENTS.md 已宣告資料目錄"
  else
    say FAIL 6.協作skill "AGENTS.md 未宣告資料目錄（載入規則見 collaboration.md〈登錄檔〉）"
  fi
  # 工具層防線：拒寫清單須涵蓋指令檔與受保護設定（setup.md〈群組與授權〉「拒寫自身設定」）；只認 Edit／Write 類規則含檔名，Bash 寫入無法靜態判定
  deny="$(cat "$SEC_DIR/.claude/settings.json" "$SEC_DIR/.claude/settings.local.json" "$HOME/.claude/settings.json" 2>/dev/null | jq -rs '[.[].permissions.deny // [] | .[] | select(test("^(Edit|Write|MultiEdit|NotebookEdit)\\("))] | join("\n")' 2>/dev/null)"
  miss=""
  for f in AGENTS.md CLAUDE.md internal.md access.json; do printf '%s' "$deny" | grep -qF "$f" || miss="$miss $f"; done
  if [ -n "$miss" ]; then say FAIL 6.協作skill "permissions.deny 的 Edit／Write 未涵蓋：${miss# }（IM 回合可能改寫；見 setup.md〈群組與授權〉）"; else say PASS 6.協作skill "permissions.deny 的 Edit／Write 涵蓋指令檔與受保護設定（Bash 寫入須另行實測）"; fi
  reg="$SEC_DIR/data/internal.md"
  if [ -f "$reg" ]; then
    say PASS 6.協作skill "internal.md 已建"
    # 內容：自介與同意的必要欄位已填、無模版佔位；只報欄位名與數量，不輸出值
    miss="$(reg_missing "$reg")"
    if [ -n "$miss" ]; then say FAIL 6.協作skill "internal.md 未填：${miss}（自介會被擋；依 collaboration.md〈自介來源〉）"; else say PASS 6.協作skill "internal.md 必要欄位已填"; fi
    # 引言行（> 開頭）是模版說明，不計
    n="$(cat "$reg" "$SEC_DIR"/data/internal/*.md 2>/dev/null | grep -v '^>' | grep -c '<[^<>]\+>')"
    [ "$n" -gt 0 ] && say FAIL 6.協作skill "internal 登錄殘留 $n 行模版佔位 <…>"
    n="$(cat "$reg" "$SEC_DIR"/data/internal/*.md 2>/dev/null | grep -v '^>' | grep -c '待確認')"
    [ "$n" -gt 0 ] && say WARN 6.協作skill "internal 登錄有 $n 行「待確認」，須負責人定版"
  else
    say FAIL 6.協作skill "缺 data/internal.md（建檔見 internal-setup.md）"
  fi
  # 權限：登錄檔含 ID 與個資，主檔與子檔皆應 600
  bad="$(find "$SEC_DIR/data" -maxdepth 2 -type f -name '*.md' \( -path "$SEC_DIR/data/internal*" -o -path "$SEC_DIR/data/external*" \) ! -perm 600 2>/dev/null | sed "s|^$SEC_DIR/data/||" | tr '\n' ' ' | sed 's/ $//')"
  if [ -n "$bad" ]; then say WARN 6.協作skill "登錄檔權限非 600：$bad"; else say PASS 6.協作skill "登錄檔權限皆 600"; fi
else
  say FAIL 6.協作skill "祕書目錄 $SEC_DIR 不存在（MH_TG_SECRETARY_DIR 可改；見 setup.md〈祕書目錄〉）"
fi

# 步驟 7 執行期：poller 唯一、一般 shell 無 token 變數、無 MCP 失敗快取
# 只允許單一接收 session（帶 --channels plugin:telegram 的 claude）底下的 server；其餘皆為殘留，一律清除
# 以執行檔名 claude 篩選再比對參數，避免誤中含相同字串的 shell；npm 安裝者由 node 執行，看第二個字
# DECISION: 未採 pgrep -x，因 macOS 預設略過祖先行程
hosts=()
for p in $(ps -A -ww -o pid= -o args= 2>/dev/null | awk '
    { pid = $1; c = $2; if (c ~ /(^|\/)node$/) c = $3; sub(/.*\//, "", c) }
    (c == "claude" || c == "cli.js") && index($0, "--channels plugin:telegram") { print pid }'); do
  hosts+=("$p")
done
# 只算 telegram plugin 的 server：以工作目錄在 plugin cache 下判定，避免誤殺其他專案的 bun server.ts
srv_cwd() { readlink "/proc/$1/cwd" 2>/dev/null || lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; }
servers=()
for p in $(pgrep -f 'bun.*server\.ts' 2>/dev/null); do
  case "$(srv_cwd "$p")" in "$CACHE_DIR"/*) servers+=("$p") ;; esac
done
lock_pid="$(cat "$CH_DIR/data/telegram.lock" 2>/dev/null)"
# 沿父行程往上找，祖先含任一接收 session 即屬於它
owned() {
  local p="$1"
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [[ " ${hosts[*]:-} " == *" $p "* ]] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}
kept=(); strays=()
# 空陣列在 bash 3.2 的 set -u 下展開會中止，先判斷數量
if [ ${#servers[@]} -gt 0 ]; then
  for s in "${servers[@]}"; do if owned "$s"; then kept+=("$s"); else strays+=("$s"); fi; done
fi
case ${#hosts[@]} in
  0) say INFO 7.驗證 "無接收 session 執行（未帶 --channels 啟動）" ;;
  1) say PASS 7.驗證 "接收 session ${hosts[0]}，其下 server ${#kept[@]} 個"
     [ "$(srv_cwd "${hosts[0]}")" = "$SEC_DIR" ] || say FAIL 7.驗證 "接收 session 不在祕書目錄啟動（目前：$(srv_cwd "${hosts[0]}")）" ;;
  *) say FAIL 7.驗證 "${#hosts[@]} 個 session 帶 --channels（${hosts[*]}），只能留一個" ;;
esac
if [ ${#strays[@]} -gt 0 ]; then
  hint=""; [[ " ${strays[*]} " == *" $lock_pid "* ]] && hint="；其中 $lock_pid 持有 telegram.lock，清除後於接收 session 執行 /mcp 重連"
  say FAIL 7.驗證 "殘留 server ${#strays[@]} 個（不屬接收 session）：kill ${strays[*]}$hint"
else
  say PASS 7.驗證 "無殘留 server"
fi
# token 應只在 .env；export 到 shell 會被所有子行程繼承
if env | grep -q '^TELEGRAM_'; then say FAIL 7.驗證 "目前 shell 有 TELEGRAM_ 環境變數"; else say PASS 7.驗證 "shell 無 TELEGRAM_ 環境變數"; fi
# 曾連線失敗的 MCP server 會被快取，15 分鐘內同名 server 略過不啟動
if jq -e 'keys | any(test("telegram"))' "$HOME/.claude/mcp-needs-auth-cache.json" >/dev/null 2>&1; then
  say WARN 7.驗證 "MCP 失敗快取有 telegram 項，15 分鐘內會被略過"
fi

finish
