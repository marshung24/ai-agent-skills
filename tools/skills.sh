#!/usr/bin/env bash
# skills.sh — 把本 repo 的 skills 安裝／移除／更新到各 AI agent
#
# 用途：各 agent 的安裝機制與 CLI 介面互不相同。本腳本把差異封裝起來，對外只暴露一組子命令。
#
#       使用案例：
#         tools/skills.sh install                     # 四家；互動終端會跳選單挑 skill
#         tools/skills.sh status                      # 看各家現況
#         SOURCE=$PWD tools/skills.sh install         # 開發時改裝工作目錄的內容
#         tools/skills.sh remove agy                  # 單一 agent
#
# repo 佈局：plugins/<name>/skills/<name>/SKILL.md，plugin 名與 skill 名一致。
#   marketplace 的 source 指向 plugins/<name>/，故各 agent 的快取只含該 plugin 的內容
#   （實測 508K → 64K）；plugins/<name>/plugin.json 則讓 agy 也能單獨安裝該 skill。
#   source 不可指向 skills/<name>/ 本身——Codex 的掃描只認 <plugin root>/skills/<name>/SKILL.md，
#   Claude 雖支援「plugin root 直放 SKILL.md」但那是它獨有的（實測，見 docs/marketplace-guide.md）。
#
# 安裝方式是 per-agent 固定的，沒有選項（見 agent_mode）：
#   | agent    | 方式        | 依據                                                    |
#   |----------|-------------|---------------------------------------------------------|
#   | claude   | marketplace | .claude-plugin/marketplace.json，marketplace add → install |
#   | codex    | marketplace | 同一份 manifest，marketplace add → plugin add             |
#   | agy      | copy        | 複製進 ~/.gemini/skills（plugin 機制可用但只收本機目錄）    |
#   | opencode | copy        | 複製進 $XDG_CONFIG_HOME/opencode/skills（無 plugin 機制）  |
#
#   claude／codex 能直接吃 Git URL，是真正的發佈途徑，故走 marketplace。
#   agy 的 `plugin install` 實測可用（會匯入 skills），但只收本機目錄、不吃 Git URL，
#   也無法發佈 catalog——走 plugin 換不到 copy 沒有的好處，卻多一層要維護的狀態，故走 copy。
#
# 遺留偵測：每個 agent 只走一種方式，但另一種機制的殘留（舊版工具裝的、手動複製的）
#   仍會被同時載入而重複。故 install 前偵測並擋下（FORCE=1 可略過），
#   remove 一律兩邊都掃，status 只在真的有東西時才多印一列 ⚠遺留。
#
# Domain knowhow — 各家 CLI 的行為差異（實測所得，升版需重驗）：
#   - claude 的 `plugin list` 只列**已安裝**者，格式為縮排區塊（`❯ 名稱` 後接 Version/Scope/Status）
#   - codex  的 `plugin list` 連**未安裝**者一起列（marketplace 已註冊即出現），格式為表格，
#            狀態欄可能是 `installed, enabled` 或 `not installed`——判斷時不可用子字串比對
#   - claude／codex 對「移除不存在的東西」都回非零，故 remove 前一律先判斷是否真的裝了；
#            agy 的 uninstall 本身即冪等。三家對齊到冪等，乾淨環境跑 remove 不該回失敗
#   - codex  除 `.claude-plugin/marketplace.json` 外亦接受 `agents/plugins/api_marketplace.json`；
#            plugin manifest 找 `.codex-plugin/plugin.json`，缺少時**由 marketplace entry 自動生成**
#            一份放進快取，故本 repo 不需自備 codex manifest
#   - agy    的 `plugin list` 輸出 JSON；無任何 plugin 時改印純文字 `No imported plugins.`
#   - agy    的全域 skills 目錄實測有兩處：~/.gemini/skills 與 ~/.gemini/antigravity-cli/skills
#            （以兩個標記 skill 實測，兩處都載得到）；本腳本用前者
#   - opencode 的 plugin 是 JS/TS 模組（掛 hook、加 tool），不承載 skills，也沒有 marketplace
#   - opencode 的全域 skills 來源有三處：$XDG_CONFIG_HOME/opencode/skills、~/.claude/skills、
#            ~/.agents/skills。**它會吃到 claude 目錄下的東西**，是唯一的跨 agent 重複來源
#
# 派發慣例：主流程以 `marketplace_<agent>_<cmd>` 與 `copy_<cmd>` 的命名動態呼叫對應函式。
#           新增 agent 只需補齊該組函式、加進 ALL_AGENTS 並在 agent_mode 宣告方式。
#
# I/O：
#   輸入  ─ $1     子命令：install | remove | update | status | validate
#           $2..   agent 代號：claude | codex | agy | opencode（可多個；省略＝全部）
#           SKILLS 環境變數：只處理指定的 skill；不設時 install/remove 會跳互動選單
#           SOURCE 環境變數：覆寫 marketplace 來源；開發時用 SOURCE=$PWD
#           FORCE  環境變數：非空 ＝ 略過遺留偵測
#   輸出  ─ 進度與結果走 stdout；警告與錯誤走 stderr
#   結束碼─ 0 全數成功；1 至少一個 agent 失敗或被擋下；2 參數錯誤；127 缺依賴

# DECISION: 不用 set -e——單一 agent 失敗（例如某家 CLI 暫時異常）不應中斷其餘 agent，
#           改以 FAILED 累計後於結尾回報，讓一次執行能處理完所有目標
set -uo pipefail

# ── 定位 repo：以腳本自身位置回推，讓腳本可從任意工作目錄呼叫 ──
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/marketplace.json"

# ── 前置檢查：依賴與 manifest 缺一不可，缺了就沒有繼續的意義，直接結束 ──
command -v jq >/dev/null || { echo "錯誤：找不到 jq（讀取 manifest 需要）" >&2; exit 127; }
[ -f "$MANIFEST" ] || { echo "錯誤：找不到 $MANIFEST" >&2; exit 127; }

# ── 名稱一律讀自 manifest ──
# DECISION: 不在腳本內寫死任何名稱——manifest 是單一事實來源，寫死會讓改名時出現
#           「manifest 改了、腳本沒改」的靜默失效
MARKETPLACE="$(jq -r '.name' "$MANIFEST")"
[ -n "$MARKETPLACE" ] && [ "$MARKETPLACE" != null ] || { echo "錯誤：manifest 缺 name" >&2; exit 127; }

# 每個 skill 各自是一個 plugin，plugin 名即 skill 名（entry 以 skills 欄位限定範圍）
MP_PLUGINS="$(jq -r '.plugins[].name' "$MANIFEST")"
[ -n "$MP_PLUGINS" ] || { echo "錯誤：manifest 的 plugins 為空" >&2; exit 127; }

# LEGACY_PLUGINS — 已從 marketplace 移除的舊 plugin 名，取自 manifest 的 renames
# 這些名稱不再是 entry，但使用者機器上可能還裝著：
#   claude 會標註「Removed from the marketplace」，plugin list 仍看得到
#   codex  沒有 renames 概念，plugin list 直接看不到它，但 config.toml 與快取都還在，
#          執行期照樣載入——是隱形卻仍在運作的孤兒，必須主動偵測
LEGACY_PLUGINS="$(jq -r '(.renames // {}) | keys[]' "$MANIFEST" 2>/dev/null)"

# GITHUB_SOURCE — 從 manifest 的 repository 欄位推導出可直接交給 CLI 的 Git URL
# DECISION: 不寫死網址，比照其餘名稱一律讀自 manifest，避免搬 repo 時兩處不同步
# DECISION: 用 HTTPS URL 而非 `owner/repo` 簡寫——簡寫在 Claude Code 預設走 SSH clone，
#           沒有金鑰的使用者會直接失敗（需另設 CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1）；
#           HTTPS URL 兩家都收，且不依賴使用者的 SSH 設定
GITHUB_SOURCE="$(jq -r '[.plugins[].repository] | map(select(. != null)) | first // empty' "$MANIFEST")"
case "$GITHUB_SOURCE" in
  https://*) GITHUB_SOURCE="${GITHUB_SOURCE%.git}.git" ;;
  *) GITHUB_SOURCE="" ;;   # 非 HTTPS 或未填：退回本機路徑，由 agent_source 處理
esac

# ── 可由環境變數覆寫的執行參數 ──
# DECISION: SOURCE 的覆寫值另存為 SOURCE_OVERRIDE——主流程會把「本輪 agent 解析出的來源」
#           寫回 SOURCE 給 marketplace_* 函式讀，若判斷來源也是同一個變數，
#           第一圈寫入後就會被誤認為「使用者有指定」，其餘 agent 全部沿用第一家的值
SOURCE_OVERRIDE="${SOURCE:-}"
SOURCE=""      # 逐 agent 解析後填入，供 marketplace_* 函式讀取
FORCE="${FORCE:-}"
SKILLS="${SKILLS:-}"   # 空＝repo 內全部；否則只處理指定的那幾個（主流程會驗證名稱）

ALL_AGENTS="claude codex agy opencode"
FAILED=0   # 任一步驟失敗即設為 1，作為整體結束碼

# ════════════════ 共用工具 ════════════════

# have <cli> — 該 CLI 是否存在於 PATH
# I/O：輸入 CLI 名稱；無輸出；回 0 表示存在
have() { command -v "$1" >/dev/null 2>&1; }

# skip_missing <agent> <cli> — CLI 不存在時印出略過訊息
# I/O：輸入 agent 代號與其 CLI 名稱；訊息走 stdout
#      回 0 ＝該 agent 應被略過（呼叫端慣例為 `skip_missing x y && return`）；回 1 ＝可繼續
# DECISION: CLI 未安裝不計入 FAILED——使用者不一定三家都用，把「沒裝」當失敗會讓正常情境
#           也回非零結束碼，反而讓真正的錯誤被淹沒
skip_missing() {
  have "$2" && return 1
  printf '  [略過] %s：找不到 %s CLI\n' "$1" "$2"
  return 0
}

# run <說明> <指令...> — 執行外部指令並回報結果，失敗時累計 FAILED
# I/O：輸入顯示用說明字串與待執行指令；成功印一行 ✔ 到 stdout，
#      失敗印 ✗ 與該指令的完整輸出（縮排）到 stderr
# DECISION: 輸出先收暫存檔而非直接流出——成功時各家 CLI 的進度訊息沒有閱讀價值，
#           會把三家×多步驟的報告淹掉；失敗時才需要全文診斷
run() {
  local label="$1"; shift
  local out; out="$(mktemp)" || { echo "錯誤：mktemp 失敗" >&2; FAILED=1; return; }
  if "$@" >"$out" 2>&1; then
    printf '  ✔ %s\n' "$label"
  else
    printf '  ✗ %s（失敗）\n' "$label" >&2
    sed 's/^/      /' "$out" >&2
    FAILED=1
  fi
  rm -f "$out"
}

# pad <字串> <目標顯示寬度> — 依終端顯示寬度補足空白，不換行
# I/O：輸入待輸出字串與目標欄寬；輸出字串加補白到 stdout
#
# 計算式：顯示寬度 = 字元數 + (位元組數 − 字元數) / 2
#   UTF-8 下 ASCII 佔 1 byte、全形 CJK 佔 3 bytes。設 CJK 字元數為 n，
#   則 (3n − n) / 2 = n，加上字元數 n 得 2n，正好等於全形字的顯示欄數；ASCII 則兩者相等。
#   之所以要自己算：printf 的 %-Ns 以「字元數」補白，中文會少補一半而使欄位錯位。
pad() {
  local s="$1" target="$2" chars bytes width
  chars=${#s}
  bytes=$(printf '%s' "$s" | wc -c)
  width=$(( chars + (bytes - chars) / 2 ))
  printf '%s' "$s"
  while [ "$width" -lt "$target" ]; do printf ' '; width=$((width + 1)); done
}

# report <agent> <方式> <狀態> [細節] — status 的統一輸出格式
# I/O：輸入四欄內容；輸出一列對齊文字到 stdout
# 各家 list 的原始輸出形狀完全不同（縮排區塊／表格／JSON），一律轉成同一格式才能橫向比較
# 欄寬取最長內容再留 2 格空隙：AGENT 欄的 opencode 佔 8、方式欄的 marketplace 佔 11
report() {
  printf '  '; pad "$1" 10; pad "$2" 13; pad "$3" 8; printf '%s\n' "${4:-}"
}

# skill_dir <skill> — 該 skill 的原始檔位置
# I/O：輸入 skill 名；輸出目錄絕對路徑到 stdout
# 佈局為 plugins/<name>/skills/<name>/，plugin 名與 skill 名一致
skill_dir() { printf '%s/plugins/%s/skills/%s\n' "$REPO_ROOT" "$1" "$1"; }

# plugin_dir <skill> — 該 skill 所屬 plugin 的根目錄（marketplace 的 source 指向這裡）
# I/O：輸入 skill 名；輸出目錄絕對路徑到 stdout
plugin_dir() { printf '%s/plugins/%s\n' "$REPO_ROOT" "$1"; }

# repo_skills — 列出 repo 內的 skill 名稱
# I/O：無參數；每行一個名稱到 stdout（順序由 glob 決定，即字典序）
# 判準與各家的掃描規則一致：plugins/<name>/skills/<name>/SKILL.md 存在才算一個 skill，
# 因此 template/ 或未完成的目錄不會被誤認
repo_skills() {
  local d n
  for d in "$REPO_ROOT"/plugins/*/; do
    n="$(basename "$d")"
    [ -f "$d/skills/$n/SKILL.md" ] && printf '%s\n' "$n"
  done
}

# target_skills — 本次要處理的 skill 名稱
# I/O：無參數（讀全域 SKILLS）；每行一個名稱到 stdout
# SKILLS 未設＝repo 內全部；設了就只處理指定的那幾個（名稱已於主流程驗證過）
target_skills() {
  local s
  if [ -z "$SKILLS" ]; then repo_skills; return; fi
  for s in $SKILLS; do printf '%s\n' "$s"; done
}

# skill_desc <skill> — 取該 skill 在 manifest 裡的描述
# I/O：輸入 skill 名；輸出描述文字到 stdout（沒有 entry 時輸出空字串）
# 描述一律讀自 manifest，不在腳本內另寫一份，避免兩處不同步
skill_desc() {
  jq -r --arg n "$1" '(.plugins[] | select(.name==$n) | .description) // ""' "$MANIFEST" 2>/dev/null
}

# str_width <字串> — 依終端顯示寬度計算字串佔幾欄
# I/O：輸入字串；輸出欄數到 stdout
# 與 pad 同一套判準：多位元組字元算 2 欄、ASCII 算 1 欄
# 計算式：顯示寬度 = 字元數 + (位元組數 − 字元數) / 2（推導見 pad 的註解）
str_width() {
  local s="$1" chars bytes
  chars=${#s}; bytes=$(printf '%s' "$s" | wc -c)
  printf '%d' $(( chars + (bytes - chars) / 2 ))
}

# fit <字串> <目標顯示寬度> — 依顯示寬度截斷，超出者以 … 收尾
# I/O：輸入字串與上限寬度；輸出截斷後的字串到 stdout，保證顯示寬度不超過 limit
# 之所以要截斷：選單靠「游標上移 N 行再重畫」更新，任何一行折行都會讓行數對不上而畫壞
# DECISION: 省略號本身佔 2 欄，必須從預算裡先扣掉——只在超出時才補 … 而不預留寬度的話，
#           截斷後的結果會比 limit 還寬，反而製造出它要防的折行
fit() {
  local s="$1" limit="$2" out="" w=0 i c cw budget
  [ "$limit" -lt 1 ] && return
  [ "$(str_width "$s")" -le "$limit" ] && { printf '%s' "$s"; return; }

  # 省略號本身就要 2 欄，limit 小於 2 時連它都放不下，只能輸出空字串
  budget=$((limit - 2))
  [ "$budget" -lt 1 ] && { [ "$limit" -ge 2 ] && printf '…'; return; }
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    [ "${#c}" -eq 1 ] && [ "$(printf '%s' "$c" | wc -c)" -gt 1 ] && cw=2 || cw=1
    [ $((w + cw)) -gt "$budget" ] && break
    out+="$c"; w=$((w + cw))
  done
  printf '%s…' "$out"
}

# TUI_MIN_COLS / TUI_MIN_ROWS — 低於此尺寸就不畫 checkbox 選單
# 欄：前綴 "❯ [x] " 佔 6 欄，名稱欄最長約 24，再留 10 欄給描述
# 列：標題 2 列 + 清單 n 列 + 結果 2 列
TUI_MIN_COLS=40
TUI_ROWS_OVERHEAD=4

# tui_capable <項目數> — 終端是否支援且放得下 checkbox 選單
# I/O：輸入清單項目數；無輸出；回 0 表示可用
# stderr 必須是終端：選單畫在 stderr，游標控制碼送到非終端只會變成亂碼
# DECISION: 尺寸放不下就回 1 讓呼叫端退回編號輸入版，而不是硬畫——清單一旦折行或捲動，
#           「上移 n 行重畫」的前提就不成立，畫面會逐輪錯位，比不畫更難用
tui_capable() {
  local n="${1:-0}" cols rows
  [ -t 2 ] || return 1
  case "${TERM:-}" in ''|dumb) return 1 ;; esac
  have tput && tput cuu1 >/dev/null 2>&1 || return 1
  cols="$(tput cols 2>/dev/null)" || return 1
  rows="$(tput lines 2>/dev/null)" || return 1
  [ "$cols" -ge "$TUI_MIN_COLS" ] || return 1
  [ "$rows" -ge $((n + TUI_ROWS_OVERHEAD)) ] || return 1
}

# ── 通用 checkbox 選單 ────────────────────────────────────────────────
# 兩個地方要挑東西（要處理哪些 agent、哪些 skill），形狀相同，故抽成同一組函式。
# 呼叫端以 process substitution 餵入項目清單（不可用 pipeline——那會讓函式跑在
# subshell 裡，寫不回全域 PICKED）：
#     pick_list agent 安裝 agent_desc < <(printf '%s\n' $ALL_AGENTS)
# 結果：PICKED＝空白分隔的選擇；PICKED_ALL＝1 表示全選（呼叫端可據此走「全部」的既有路徑）

PICKED=""      # 選擇結果（空白分隔）
PICKED_ALL=""  # 1 ＝使用者選了全部

# pick_tui <名詞> <動詞> <描述函式> — 上下鍵移動、空白鍵勾選的 checkbox 選單
# I/O：項目清單自 stdin（每行一個）；選單畫在 stderr；結果寫入 PICKED／PICKED_ALL
#      回 0 ＝繼續；回 1 ＝使用者取消
#
# DECISION: 不引入 fzf／whiptail／dialog——本 repo 目前只依賴 jq 與 rsync，
#           為了一個選單多一個必裝的外部程式並不划算；純 bash + tput 自足且行為可控。
#           代價是要自己處理游標與重畫，故有 fit() 的截斷與 trap 的還原
pick_tui() {
  local noun="$1" verb="$2" descfn="$3"
  local all=() lines=() n i cur=0 key rest cols namew descw
  local up clr hide show bold dim rst
  local -a mark

  while IFS= read -r i; do [ -n "$i" ] && all+=("$i"); done
  n=${#all[@]}; [ "$n" -gt 0 ] || return 0
  for (( i=0; i<n; i++ )); do mark[i]=1; done   # 預設全選，最常見的意圖是「全部」

  up="$(tput cuu1)"; clr="$(tput el)"; hide="$(tput civis)"; show="$(tput cnorm)"
  bold="$(tput bold)"; dim="$(tput dim)"; rst="$(tput sgr0)"
  cols="$(tput cols)"

  # 名稱欄取最長名稱＋2，但不得吃掉描述的空間；前綴 "❯ [x] " 固定 6 欄
  namew=0
  for i in "${all[@]}"; do
    [ "$(str_width "$i")" -gt "$namew" ] && namew="$(str_width "$i")"
  done
  namew=$((namew + 2))
  [ "$namew" -gt $((cols - 16)) ] && namew=$((cols - 16))
  descw=$((cols - namew - 6))

  # DECISION: 每列只在進選單時算一次——fit() 逐字元呼叫 wc，放進 draw() 會讓每次
  #           按鍵都重算 n×描述長度 次子行程，在慢終端上按鍵會明顯延遲
  for (( i=0; i<n; i++ )); do
    lines[i]="$(pad "$(fit "${all[i]}" "$namew")" "$namew")$(fit "$("$descfn" "${all[i]}")" "$descw")"
  done

  # 任何離開路徑都要還原游標，否則使用者的終端會一直看不到游標
  tui_restore() { printf '%s' "$show" >&2; trap - INT TERM HUP; }
  trap 'tui_restore; return 1' INT TERM HUP

  draw() {
    local i prefix box
    for (( i=0; i<n; i++ )); do
      [ "$i" = "$cur" ] && prefix="${bold}❯ ${rst}" || prefix="  "
      [ "${mark[i]}" = 1 ] && box="${bold}[x]${rst}" || box="[ ]"
      printf '%s%s %s %s\n' "$clr" "$prefix" "$box" "${lines[i]}" >&2
    done
  }

  printf '\n要%s哪些 %s：%s↑↓ 移動．空白 勾選．a 全選／全不選．Enter 確認．q 取消%s\n\n' \
         "$verb" "$noun" "$dim" "$rst" >&2
  printf '%s' "$hide" >&2
  draw

  while :; do
    IFS= read -rsn1 key < /dev/tty || key=q
    # 方向鍵是 ESC [ A/B 三個位元組，需再讀兩個；單獨的 ESC 則當取消
    if [ "$key" = $'\e' ]; then
      read -rsn2 -t 0.05 rest < /dev/tty || rest=""
      key="$key$rest"
    fi
    case "$key" in
      $'\e[A'|k) cur=$(( (cur - 1 + n) % n )) ;;
      $'\e[B'|j) cur=$(( (cur + 1) % n )) ;;
      ' ')       [ "${mark[cur]}" = 1 ] && mark[cur]=0 || mark[cur]=1 ;;
      a|A)       local any=0
                 for (( i=0; i<n; i++ )); do [ "${mark[i]}" = 0 ] && any=1; done
                 for (( i=0; i<n; i++ )); do mark[i]=$any; done ;;
      ''|$'\n') break ;;
      q|Q|$'\e') tui_restore; printf '→ 已取消\n' >&2; return 1 ;;
      *)         continue ;;
    esac
    for (( i=0; i<n; i++ )); do printf '%s' "$up" >&2; done   # 回到清單頂端重畫
    draw
  done

  tui_restore
  pick_finish all[@] mark[@] "$n"
}

# pick_prompt <名詞> <動詞> <描述函式> — 編號輸入版（終端不支援游標定位時的退路）
# I/O：與 pick_tui 相同
pick_prompt() {
  local noun="$1" verb="$2" descfn="$3"
  local all=() n i sel picked=() idx
  local -a mark

  while IFS= read -r i; do [ -n "$i" ] && all+=("$i"); done
  n=${#all[@]}; [ "$n" -gt 0 ] || return 0

  {
    printf '\n要%s哪些 %s：\n\n' "$verb" "$noun"
    for (( i=0; i<n; i++ )); do
      printf '  %d) ' "$((i+1))"; pad "${all[$i]}" 26; printf '%s\n' "$("$descfn" "${all[$i]}")"
    done
    printf '\n'
  } >&2

  while :; do
    printf '請選擇（編號，空白或逗號分隔／a＝全部／q＝取消）[a]：' >&2
    IFS= read -r sel < /dev/tty || sel=a
    sel="${sel//,/ }"                       # 逗號與空白等價，使用者不必記格式
    case "${sel:-a}" in
      a|A|all)  for (( i=0; i<n; i++ )); do mark[i]=1; done
                pick_finish all[@] mark[@] "$n"; return ;;
      q|Q|quit) printf '→ 已取消\n' >&2; return 1 ;;
    esac

    picked=(); idx=ok
    for (( i=0; i<n; i++ )); do mark[i]=0; done
    for i in $sel; do
      case "$i" in ''|*[!0-9]*) idx=bad; break ;; esac
      [ "$i" -ge 1 ] && [ "$i" -le "$n" ] || { idx=bad; break; }
      mark[$((i-1))]=1; picked+=(x)
    done
    if [ "$idx" = ok ] && [ "${#picked[@]}" -gt 0 ]; then
      pick_finish all[@] mark[@] "$n"; return
    fi
    printf '  輸入無效，請輸入 1-%d 的編號、a 或 q\n' "$n" >&2
  done
}

# pick_finish <項目陣列[@]> <勾選陣列[@]> <總數> — 把勾選結果收斂成 PICKED／PICKED_ALL
# I/O：以陣列名稱展開傳入（bash 慣用法）；回 0 ＝有選；回 1 ＝一個都沒選（視同取消）
pick_finish() {
  local all=("${!1}") mark=("${!2}") n="$3" i out=()
  for (( i=0; i<n; i++ )); do [ "${mark[i]}" = 1 ] && out+=("${all[i]}"); done
  if [ "${#out[@]}" -eq 0 ]; then
    printf '\n→ 一個都沒選，已取消\n' >&2; return 1
  fi
  PICKED="${out[*]}"
  [ "${#out[@]}" = "$n" ] && PICKED_ALL=1 || PICKED_ALL=""
  printf '\n→ %s\n\n' "$PICKED" >&2
  return 0
}

# pick_list <名詞> <動詞> <描述函式> — 選單入口，依終端能力挑實作
# I/O：項目清單自 stdin；結果寫入 PICKED／PICKED_ALL
# DECISION: 終端不支援游標定位時退回編號輸入版，而不是直接放棄選擇能力——
#           TERM=dumb、非 xterm 相容終端或無 tput 的精簡環境都還是能挑
pick_list() {
  local items n
  items="$(cat)"; n="$(printf '%s\n' "$items" | grep -c .)"
  # DECISION: 用 process substitution 而非 pipeline——pipeline 會讓被呼叫的函式跑在
  #           subshell 裡，PICKED／PICKED_ALL 寫不回呼叫端，選擇結果會靜默遺失
  if tui_capable "$n"; then
    pick_tui   "$@" < <(printf '%s\n' "$items")
  else
    pick_prompt "$@" < <(printf '%s\n' "$items")
  fi
}

# agent_desc <agent> — 選單裡顯示的 agent 說明（方式＋會動到哪裡）
# I/O：輸入 agent 代號；輸出說明文字到 stdout
agent_desc() {
  local mode; mode="$(agent_mode "$1")" || return
  if [ "$mode" = marketplace ]; then printf 'marketplace  %s' "$(agent_source "$1")"
  else                               printf 'copy         %s' "$(agent_skills_dir "$1")"; fi
}

# pick_skills <動詞> — 互動選單入口，把使用者的選擇寫進全域 SKILLS
# I/O：輸入顯示用動詞（安裝｜移除）；回 0 ＝繼續；回 1 ＝使用者取消
#
# DECISION: 只在「互動終端 ＋ 未指定 SKILLS ＋ 子命令為 install/remove」三者同時成立時才跳選單。
#           少了 TTY 判斷，CI 或 `make install < /dev/null` 會停在 read 等一個永遠不會來的
#           輸入；非互動情境一律沿用舊行為（全部），才不會把自動化流程弄壞。
#           SKILLS 仍保留為覆寫途徑：指定了就直接照做，不再多問一次
# DECISION: update 不跳選單——「把裝著的都更新到最新」本來就是它唯一合理的意圖，
#           而未安裝者本就會被略過，多問一次只是徒增步驟
# DECISION: 終端不支援游標定位時退回編號輸入版，而不是直接放棄選擇能力——
#           TERM=dumb、非 xterm 相容終端或無 tput 的精簡環境都還是能挑
pick_skills() {
  pick_list skill "$1" skill_desc < <(repo_skills) || return 1
  # 全選時清空 SKILLS，讓後續流程走「全部」的既有路徑
  [ -n "$PICKED_ALL" ] && SKILLS="" || SKILLS="$PICKED"
  return 0
}

# pick_agents <動詞> — 讓使用者挑要處理哪幾家 agent，結果寫進全域 TARGETS
# I/O：輸入顯示用動詞；回 0 ＝繼續；回 1 ＝使用者取消
pick_agents() {
  pick_list agent "$1" agent_desc < <(printf '%s\n' $ALL_AGENTS) || return 1
  TARGETS="$PICKED"
  return 0
}

# agent_skills_dir <agent> — 取得該 agent 的使用者級 skills 目錄（copy 模式的安裝目的地）
# I/O：輸入 agent 代號；輸出目錄絕對路徑到 stdout（不保證該目錄存在）；未知代號回 1
# 路徑依 Agent Skills 標準；codex 另受 $CODEX_HOME 影響（未設時預設 ~/.codex），
# opencode 受 $XDG_CONFIG_HOME 影響（未設時預設 ~/.config）
agent_skills_dir() {
  case "$1" in
    claude)   printf '%s/.claude/skills\n' "$HOME" ;;
    codex)    printf '%s/skills\n' "${CODEX_HOME:-$HOME/.codex}" ;;
    agy)      printf '%s/.gemini/skills\n' "$HOME" ;;
    opencode) printf '%s/opencode/skills\n' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
    *) return 1 ;;
  esac
}

# agent_mode <agent> — 該 agent 用哪種安裝方式（固定，不可覆寫）
# I/O：輸入 agent 代號；輸出 marketplace 或 copy 到 stdout；未知代號回 1
#
# DECISION: 每個 agent 只走一種方式，沒有讓使用者選的餘地，故不設 METHOD 開關。
#   claude／codex ─ marketplace：兩家吃同一份 .claude-plugin/marketplace.json，
#                   而且能直接吃 Git URL，安裝與更新都交給 CLI 處理，是真正的發佈途徑
#   agy           ─ copy：它的 plugin 機制雖然可用（`agy plugin install <目錄>` 實測會匯入
#                   skills），但只收本機目錄、不吃 Git URL，也無法發佈 catalog——
#                   走 plugin 換不到任何 copy 沒有的好處，卻多一層要維護的狀態
#   opencode      ─ copy：它的 plugin 是 JS/TS 模組，不承載 skills，本來就沒有別的選擇
agent_mode() {
  case "$1" in
    claude|codex)  printf 'marketplace\n' ;;
    agy|opencode)  printf 'copy\n' ;;
    *) return 1 ;;
  esac
}

# agent_source <agent> — 該 agent 在 marketplace 模式下的安裝來源
# I/O：輸入 agent 代號；輸出來源字串（Git URL 或本機路徑）到 stdout
# 只有 marketplace 模式的 agent 用得到；SOURCE 未設時一律用 manifest 推導出的 GitHub URL，
# 開發時要裝工作目錄的內容用 SOURCE=$PWD 覆寫
agent_source() {
  [ -n "$SOURCE_OVERRIDE" ] && { printf '%s\n' "$SOURCE_OVERRIDE"; return; }
  printf '%s\n' "${GITHUB_SOURCE:-$REPO_ROOT}"
}

# ════════════════ 遺留偵測：另一種機制留下的東西會重複載入 ════════════════
#
# 每個 agent 只走一種方式，但「另一種機制的殘留」仍可能存在——舊版工具裝的、手動複製的、
# 或從別的來源裝的。各家都會同時載入 plugin 與自己的 skills 目錄，殘留即重複載入。
# 故 install 前偵測並擋下，remove 一律兩邊都掃，status 只在真的有東西時才多印一列。

# has_plugin <agent> <plugin> — 該 agent 是否已用 plugin 機制裝了指定的 plugin
# I/O：輸入 agent 代號與 plugin 名稱；無輸出；回 0 表示已安裝
has_plugin() {
  local agent="$1" plugin="$2"
  case "$agent" in
    # claude 的 list 只列已安裝者，名稱命中即代表已安裝
    claude)
      have claude && claude plugin list 2>/dev/null | grep -qF "$plugin@$MARKETPLACE"
      ;;
    # codex 的 list 會把「marketplace 已註冊但未安裝」的 plugin 一併列出，狀態欄為 not installed。
    # DECISION: 不可用 `grep installed` 判斷——"not installed" 含有 "installed" 子字串，
    #           會把未安裝誤判為已安裝。改以 awk 取第一欄完全相符的那列，
    #           剝掉 PLUGIN 欄後要求狀態欄「以 installed 開頭」
    codex)
      have codex && codex plugin list 2>/dev/null \
        | awk -v p="$plugin@$MARKETPLACE" '$1==p { sub(/^[^ \t]+[ \t]+/, ""); print; exit }' \
        | grep -q '^installed'
      ;;
    # agy 的 list 是 JSON；無 plugin 時輸出非 JSON 純文字，故 jq 需吞錯（不算命中）
    agy)
      have agy && agy plugin list 2>/dev/null \
        | jq -e --arg n "$plugin" '.imports[]? | select(.name==$n)' >/dev/null 2>&1
      ;;
    # opencode 無 plugin 機制，永遠視為未安裝（與未知代號同路徑，但理由不同故獨立列出）
    opencode) return 1 ;;
    *) return 1 ;;
  esac
}

# installed_legacy <agent> — 列出該 agent 上仍裝著的舊 plugin 名（已從 marketplace 移除者）
# I/O：輸入 agent 代號；每行一個名稱到 stdout
# codex 的 plugin list 看不到已移除的 entry，故改以 config.toml 的 [plugins."名稱@marketplace"] 判斷——
# 那才是「執行期會不會載入」的依據；只信 plugin list 會漏掉這種隱形孤兒
installed_legacy() {
  local agent="$1" n cfg
  [ -n "$LEGACY_PLUGINS" ] || return 0
  cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
  for n in $LEGACY_PLUGINS; do
    case "$agent" in
      claude) have claude && claude plugin list 2>/dev/null | grep -qF "$n@$MARKETPLACE" && printf '%s\n' "$n" ;;
      codex)  have codex && [ -f "$cfg" ] && grep -qF "[plugins.\"$n@$MARKETPLACE\"]" "$cfg" && printf '%s\n' "$n" ;;
    esac
  done
  return 0
}

# has_marketplace <agent> — 該 agent 是否已註冊本 marketplace
# I/O：輸入 agent 代號；無輸出；回 0 表示已註冊
# 用途：remove 前先判斷，避免對不存在的東西下移除指令而收到非零結束碼（誤報為失敗）
has_marketplace() {
  case "$1" in
    # claude：每個 marketplace 一個 `❯ 名稱` 區塊；取第二欄完全相符，避免前綴誤命中
    claude)
      have claude && claude plugin marketplace list 2>/dev/null \
        | awk -v m="$MARKETPLACE" '$1=="❯" && $2==m {f=1} END{exit !f}'
      ;;
    # codex：表格，第一欄即名稱；一個都沒有時輸出純文字，awk 自然不命中
    codex)
      have codex && codex plugin marketplace list 2>/dev/null \
        | awk -v m="$MARKETPLACE" '$1==m {f=1} END{exit !f}'
      ;;
    *) return 1 ;;
  esac
}

# dir_has_skills <目錄> — 該目錄是否已有本 repo 的任一 skill
# I/O：輸入 skills 目錄路徑；無輸出；回 0 表示至少有一個
# 以 -e 或 -L 判斷：斷掉的 symlink 過不了 -e，但它同樣是「舊安裝的殘留」，必須算數
dir_has_skills() {
  local dir="$1" s
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  while IFS= read -r s; do
    if [ -e "$dir/$s" ] || [ -L "$dir/$s" ]; then return 0; fi
  done < <(repo_skills)
  return 1
}

# has_copy <agent> — 該 agent 的 skills 目錄是否已有本 repo 的任一 skill
# I/O：輸入 agent 代號；無輸出；回 0 表示至少有一個
has_copy() {
  local dir
  dir="$(agent_skills_dir "$1")" || return 1
  dir_has_skills "$dir"
}

# agy_plugin_leftovers [agent] — agy 上以 plugin 機制裝著的本 repo skill
# I/O：可選的 agent 代號（非 agy 時輸出空）；每行一個 plugin 名到 stdout
# 佈局改為 plugins/<name>/ 後，agy 的 `plugin install ./plugins/<name>` 裝的就是單一 skill，
# plugin 名等於 skill 名，故直接以 skill 名逐個判斷
agy_plugin_leftovers() {
  local agent="${1:-agy}" n
  [ "$agent" = agy ] || return 0
  while IFS= read -r n; do
    has_plugin agy "$n" && printf '%s\n' "$n"
  done < <(repo_skills)
  return 0
}

# opencode_shared_dirs — opencode 除自己的目錄外，還會掃描哪些其他 agent 的 skills 目錄
# I/O：無參數；每行一個路徑到 stdout
# 這是 opencode 特有的：它把 claude 與 Agent Skills 標準目錄一併納入全域掃描範圍
opencode_shared_dirs() {
  printf '%s/.claude/skills\n' "$HOME"
  printf '%s/.agents/skills\n' "$HOME"
}

# opencode_shared_guard — 偵測 opencode 是否已從別的 agent 的目錄載到同一批 skill
# I/O：無參數（讀全域 EXPLICIT_TARGETS）；訊息走 stdout 或 stderr
#      回 0 ＝可繼續；回 1 ＝呼叫端應中止
# DECISION: 這道守衛與 leftover_guard 分開實作——leftover_guard 管的是「同一個 agent 的另一種機制」，
#           這裡管的是「跨 agent 的目錄共用」，只有 opencode 有這個問題，混進去會讓通用邏輯長出特例
opencode_shared_guard() {
  local d hit=""
  while IFS= read -r d; do
    dir_has_skills "$d" && hit="$d" && break
  done < <(opencode_shared_dirs)
  [ -n "$hit" ] || return 0

  # FORCE 時仍執行，但必須留下警告——並存是有意識的選擇，不該事後看不出來
  if [ -n "$FORCE" ]; then
    printf '  [警告] opencode：%s 已有本 repo 的 skill 且同樣會被掃描；FORCE=1 已略過偵測，會重複載入\n' \
           "$hit" >&2
    return 0
  fi

  # DECISION: 沒有點名 opencode 時不計入 FAILED——若 ~/.claude/skills 有殘留，全 agent 的
  #           install 會讓 opencode 必然命中它。此時不裝是**正確的結果**（skill 已經載得到），
  #           當成失敗會讓文件寫的正常用法永遠回非零，與「CLI 未安裝不計入 FAILED」同一個
  #           理由：誤報會淹掉真正的錯誤
  if [ -z "$EXPLICIT_TARGETS" ]; then
    printf '  [略過] opencode：%s 已有本 repo 的 skill，opencode 會掃到該目錄，不必再放一份\n' "$hit"
    return 1
  fi

  # 點名 opencode ＝ 使用者明確要裝在 opencode 自己的目錄，這時擋下並回報失敗才合理
  {
    printf '  ✗ opencode：%s 已有本 repo 的 skill，opencode 也會掃描該目錄，中止以免重複載入\n' "$hit"
    printf '      opencode 已經吃得到那批 skill，通常不必再裝一次\n'
    printf '      若要改成裝在 opencode 自己的目錄：先移除上述來源，或確定要並存：FORCE=1 ...\n'
  } >&2
  FAILED=1
  return 1
}

# leftover_guard <agent> — 安裝前偵測「另一種機制的殘留」
# I/O：輸入 agent 代號；被擋下時把原因與出路印到 stderr 並設 FAILED
#      回 0 ＝可繼續；回 1 ＝呼叫端應中止該 agent
# 殘留的來源不限本工具（舊版、手動複製、別處裝的都算），只要存在就會與本次安裝重複載入
leftover_guard() {
  local agent="$1" mode msg legacy
  mode="$(agent_mode "$agent")" || return 0

  # 舊 plugin（已從 marketplace 移除但機器上還裝著）優先報——它一裝就是全部 skill，
  # 與本次要裝的單一 skill 必然重疊，且 codex 上看不見，不主動講使用者不會知道
  legacy="$(installed_legacy "$agent" | tr '\n' ' ')"
  if [ -n "${legacy// /}" ]; then
    msg="仍裝著已下架的 plugin：${legacy% }"
  elif [ "$mode" = marketplace ]; then
    # 本次走 marketplace → 殘留是 skills 目錄裡的副本
    has_copy "$agent" || return 0
    msg="$(agent_skills_dir "$agent") 已有本 repo 的 skill"
  else
    # 本次走 copy → 殘留是 plugin 安裝（agy 手動裝的整包）
    local lp; lp="$(agy_plugin_leftovers | tr '\n' ' ')"
    [ -n "${lp// /}" ] || return 0
    msg="已用 plugin 機制安裝（${lp% }）"
  fi

  # FORCE 時仍執行，但必須留下警告——並存是有意識的選擇，不該事後看不出來
  if [ -n "$FORCE" ]; then
    printf '  [警告] %s：%s；FORCE=1 已略過偵測，同名 skill 會重複載入\n' "$agent" "$msg" >&2
    return 0
  fi

  # 預設中止，並直接給出可執行的出路，免得使用者還要回頭查文件
  {
    printf '  ✗ %s：%s，中止以免重複載入\n' "$agent" "$msg"
    printf '      remove 會把殘留一起清掉：tools/skills.sh remove %s\n' "$agent"
    printf '      或確定要並存：FORCE=1 ...\n'
  } >&2
  FAILED=1
  return 1
}

# ════════════════ marketplace 模式（claude／codex）════════════════
# 兩家各一組 install/remove/update，由主流程以 marketplace_<agent>_<cmd> 動態呼叫。
# 骨架相同（檢查 CLI → 遺留偵測 → 逐 skill 執行），差異只在各家 CLI 的子命令與參數形狀。
#
# 每個 skill 是一個獨立的 plugin（plugin 名即 skill 名），故安裝／移除都要逐個處理。
#
# remove 一律先判斷有沒有裝再下指令：claude 與 codex 對「移除不存在的東西」都回非零，
# 會被 run() 記成失敗，讓乾淨環境跑 remove 也回 rc=1。agy 則是冪等的，各家對齊到冪等。

# marketplace_claude_install — 註冊 marketplace 後逐一安裝選定的 skill
# I/O：無參數（讀全域 SOURCE）；進度走 stdout；失敗累計至 FAILED
marketplace_claude_install() {
  local p
  skip_missing claude claude && return
  leftover_guard claude || return
  run "claude：註冊 marketplace $MARKETPLACE" claude plugin marketplace add "$SOURCE"
  while IFS= read -r p; do
    run "claude：安裝 $p" claude plugin install "$p@$MARKETPLACE"
  done < <(target_skills)
}

# marketplace_claude_remove — 移除選定的 plugin；全部移除時連 marketplace 一起註銷
# DECISION: 只有在「這個 marketplace 已無任何本 repo 的 plugin」時才註銷——
#           選裝其中幾個時註銷會把其餘還裝著的 plugin 一起弄失效
marketplace_claude_remove() {
  local p
  skip_missing claude claude && return
  while IFS= read -r p; do
    if has_plugin claude "$p"; then
      run "claude：移除 $p" claude plugin uninstall "$p@$MARKETPLACE"
    else
      printf '  [略過] claude：%s 未安裝\n' "$p"
    fi
  done < <(target_skills)
  marketplace_cleanup claude
}

# marketplace_claude_update — 先刷新 marketplace 快照，再逐一更新
# 兩步不可省其一：只更新 plugin 會拿到舊快照裡的版本
marketplace_claude_update() {
  local p
  skip_missing claude claude && return
  run "claude：更新 marketplace 快照" claude plugin marketplace update "$MARKETPLACE"
  while IFS= read -r p; do
    if has_plugin claude "$p"; then
      run "claude：更新 $p" claude plugin update "$p@$MARKETPLACE"
    else
      printf '  [略過] claude：%s 未安裝\n' "$p"
    fi
  done < <(target_skills)
}

# marketplace_codex_install — 與 claude 同流程，差別在安裝子命令是 add 而非 install
marketplace_codex_install() {
  local p
  skip_missing codex codex && return
  leftover_guard codex || return
  run "codex：註冊 marketplace $MARKETPLACE" codex plugin marketplace add "$SOURCE"
  while IFS= read -r p; do
    run "codex：安裝 $p" codex plugin add "$p@$MARKETPLACE"
  done < <(target_skills)
}

marketplace_codex_remove() {
  local p
  skip_missing codex codex && return
  while IFS= read -r p; do
    if has_plugin codex "$p"; then
      run "codex：移除 $p" codex plugin remove "$p@$MARKETPLACE"
    else
      printf '  [略過] codex：%s 未安裝\n' "$p"
    fi
  done < <(target_skills)
  marketplace_cleanup codex
}

# codex_marketplace_is_git — codex 目前註冊的這個 marketplace 是否為 Git 來源
# I/O：無參數；無輸出；回 0 表示是 Git 來源（可 upgrade）
# DECISION: 判準取自 codex 自己的註冊狀態（`marketplace list --json` 的 sourceType），
#           而非本次的 SOURCE——兩者可以不一致：使用者可能用 SOURCE=$PWD 裝好（註冊成 local），
#           之後直接跑 update（預設來源是 GitHub）。以 SOURCE 判斷會誤跑 upgrade，
#           得到「is not configured as a Git marketplace」而被記成失敗
codex_marketplace_is_git() {
  [ "$(codex plugin marketplace list --json 2>/dev/null \
       | jq -r --arg n "$MARKETPLACE" \
         '.marketplaces[]? | select(.name==$n) | .marketplaceSource.sourceType')" = git ]
}

# marketplace_codex_update — 刷新 marketplace 快照（codex 無獨立的 plugin update）
marketplace_codex_update() {
  skip_missing codex codex && return
  # 本機來源讀的就是工作目錄現況、沒有快照要刷新，硬呼叫 upgrade 只會換來一個誤報的失敗
  if codex_marketplace_is_git; then
    run "codex：刷新 marketplace 快照" codex plugin marketplace upgrade "$MARKETPLACE"
  elif has_marketplace codex; then
    printf '  [略過] codex：marketplace 註冊為本機來源，無快照需刷新（內容即時反映 repo）\n'
  else
    printf '  [略過] codex：尚未註冊 marketplace %s，無可更新的內容\n' "$MARKETPLACE"
  fi
}

# marketplace_cleanup <agent> — 本 repo 的 plugin 全數移除後，把 marketplace 一起註銷
# I/O：輸入 agent 代號；有動作才印進度
# 這個 marketplace 只為本 repo 的 plugin 存在，一個都不剩時留著是殘留設定
# DECISION: 註銷前也要確認沒有已下架的舊 plugin 還裝著——實測 `claude plugin marketplace
#           remove` 會連帶移除該 marketplace 底下已安裝的 plugin，若此時還有舊 bundle，
#           就會在使用者沒要求的情況下把它一起清掉（選了部分 skill 時尤其不該發生）
marketplace_cleanup() {
  local agent="$1" p
  if [ -n "$(installed_legacy "$agent")" ]; then
    printf '  [略過] %s：仍有已下架的 plugin 裝著，保留 marketplace %s 註冊\n' "$agent" "$MARKETPLACE"
    return
  fi
  while IFS= read -r p; do
    has_plugin "$agent" "$p" && return   # 還有裝著的，不能註銷
  done < <(printf '%s\n' $MP_PLUGINS)
  if has_marketplace "$agent"; then
    run "$agent：移除 marketplace" "$agent" plugin marketplace remove "$MARKETPLACE"
  else
    printf '  [略過] %s：marketplace %s 未註冊\n' "$agent" "$MARKETPLACE"
  fi
}

# legacy_remove <agent> — 清掉已從 marketplace 下架、但機器上還裝著的舊 plugin
# I/O：輸入 agent 代號；有東西才印進度
# codex 的 plugin list 看不到它，但 `plugin remove` 仍可正常移除（實測會清掉 config.toml 與快取）
legacy_remove() {
  local agent="$1" n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$agent" in
      claude) run "claude：移除已下架的 $n" claude plugin uninstall "$n@$MARKETPLACE" ;;
      codex)  run "codex：移除已下架的 $n"  codex plugin remove "$n@$MARKETPLACE" ;;
    esac
  done < <(installed_legacy "$agent")
}

# leftover_remove <agent> — 清掉該 agent「非本工具所用機制」的殘留
# I/O：輸入 agent 代號；有東西才印進度，沒有則完全靜默
# remove 一律呼叫此函式：每個 agent 雖只走一種方式，但另一種機制的殘留同樣會被載入，
# 只清自己那一邊等於留著重複載入的來源
# 註：已下架的舊 plugin 由 legacy_remove 另外處理，且必須在註銷 marketplace 之前執行
leftover_remove() {
  local agent="$1" mode
  mode="$(agent_mode "$agent")" || return

  if [ "$mode" = marketplace ]; then
    # marketplace 模式的 agent：殘留是 skills 目錄裡的副本
    has_copy "$agent" && copy_remove "$agent"
  elif [ "$agent" = agy ]; then
    # copy 模式的 agent：殘留是 plugin 安裝。只有 agy 可能有——opencode 沒有 plugin 機制
    # agy 的 uninstall 本身即冪等，但仍先判斷，避免對沒裝的情況印出無意義的進度列
    local n
    while IFS= read -r n; do
      [ -n "$n" ] && run "agy：移除殘留的 plugin $n" agy plugin uninstall "$n"
    done < <(agy_plugin_leftovers agy)
  fi
}

# ════════════════ copy 模式 ════════════════
# 三家共用同一套邏輯，唯一差異是目的地（agent_skills_dir），故不需要 per-agent 函式。

# copy_install <agent> — 把選定的 skill 同步進該 agent 的 skills 目錄（SKILLS 未設＝全部）
# I/O：輸入 agent 代號；每個 skill 一行進度到 stdout；失敗累計至 FAILED
# DECISION: 用 rsync -a --delete 而非 cp -r——rsync 會把目的地多出來的舊檔一併刪除，
#           重跑即得到與 repo 完全一致的狀態；cp -r 會留下 repo 已刪除的殘檔
copy_install() {
  local agent="$1" dir s target
  dir="$(agent_skills_dir "$agent")" || return
  leftover_guard "$agent" || return

  # opencode 另有跨 agent 的重複來源（它會掃 ~/.claude/skills 等目錄），需多一道偵測
  [ "$agent" = opencode ] && { opencode_shared_guard || return; }

  # 目的地可能尚未建立（該 agent 從未裝過任何 skill）
  mkdir -p "$dir" || { echo "  ✗ $agent：無法建立 $dir" >&2; FAILED=1; return; }

  # 逐一同步；每個 skill 各自判斷是否可安全寫入
  while IFS= read -r s; do
    target="$dir/$s"

    # 目的地是 symlink 時必須跳過：rsync 會沿著連結寫進「目標」，
    # 而目標多半是另一個 agent 的副本（常見佈局是 codex/gemini 連到 claude），
    # 寫穿等於在使用者不知情下改到別處
    if [ -L "$target" ]; then
      printf '  ✗ %s／%s：目的地是 symlink（→ %s），略過以免寫穿；請先移除該連結\n' \
             "$agent" "$s" "$(readlink "$target")" >&2
      FAILED=1; continue
    fi

    run "$agent：$s → $dir" rsync -a --delete "$(skill_dir "$s")/" "$target/"
  done < <(target_skills)
}

# copy_remove <agent> — 移除該 agent skills 目錄下屬於本 repo 的項目
# I/O：輸入 agent 代號；每個移除項一行進度到 stdout；失敗累計至 FAILED
# DECISION: 只走訪本 repo 的 skill 名稱、不掃目的地目錄——使用者可能另有第三方 skill 裝在同一處，
#           以目的地為基準列舉會把它們一併刪掉
copy_remove() {
  local agent="$1" dir s target
  dir="$(agent_skills_dir "$agent")" || return
  [ -d "$dir" ] || { printf '  [略過] %s：%s 不存在\n' "$agent" "$dir"; return; }

  while IFS= read -r s; do
    target="$dir/$s"

    # 路徑守衛：刪除是不可逆操作，組成路徑的兩段都必須非空，且結果的 basename 必須等於
    # skill 名。少了這道檢查，$s 為空時 rm -rf "$dir/$s" 會退化成刪掉整個 skills 目錄
    if [ -z "$dir" ] || [ -z "$s" ] || [ "$(basename "$target")" != "$s" ]; then
      echo "  ✗ 路徑守衛擋下：$target" >&2; FAILED=1; continue
    fi

    # symlink 與實體目錄的移除方式不同：對 symlink 用 rm -rf 只會刪到連結本身沒錯，
    # 但分開處理才能在訊息中標示型態，讓使用者看得出剛才移除的是連結而非副本
    if [ -L "$target" ]; then
      run "$agent：移除 $s（symlink）" rm -f "$target"
    elif [ -d "$target" ]; then
      run "$agent：移除 $s" rm -rf "$target"
    fi
  done < <(target_skills)
}

# copy_update <agent> — 與 install 同義：rsync --delete 本身即是「同步到最新」
copy_update() { copy_install "$1"; }

# ════════════════ status ════════════════

# copy_state <skills 目錄> <skill> — 判定單一項目在該目錄中的狀態
# I/O：輸入 skills 目錄與 skill 名稱；輸出狀態碼到 stdout（不含換行）
#      `-`＝未安裝、`✓一致`、`≠有差異`、`→<目標>`＝symlink、`✗斷鏈`
# 判斷順序固定為 symlink → 目錄 → 內容比對：symlink 必須先判，否則 -d 會沿著連結
# 判成目錄，使「連到別處」被誤報為實體副本
copy_state() {
  local dir="$1" s="$2" p="$1/$2"

  # symlink：再分「指得到」與「斷鏈」
  if [ -L "$p" ]; then
    if [ -e "$p" ]; then printf '→%s' "$(readlink "$p")"; else printf '✗斷鏈'; fi
    return
  fi

  # 非 symlink 且非目錄 ＝ 沒裝
  [ -d "$p" ] || { printf -- '-'; return; }

  # 實體副本：與 repo 逐檔比對，區分「一致」與「已飄移」
  if diff -rq "$(skill_dir "$s")" "$p" >/dev/null 2>&1; then printf '✓一致'; else printf '≠有差異'; fi
}

# marketplace_state <agent> <plugin> — 單一 plugin 在該 agent 的安裝狀態
# I/O：輸入 agent 代號與 plugin 名；輸出狀態碼到 stdout（不含換行）
#      `-`＝未安裝；claude 回版本字串、codex 回其狀態欄
# 兩家 list 的輸出形狀不同（縮排區塊／表格），各自解析
marketplace_state() {
  local agent="$1" plugin="$2"
  has_plugin "$agent" "$plugin" || { printf -- '-'; return; }
  case "$agent" in
    # claude：名稱那列之後 3 行內有 `Version: <值>`
    claude) printf '%s' "$(claude plugin list 2>/dev/null \
              | grep -A3 -F "$plugin@$MARKETPLACE" | awk -F': ' '/Version:/{print $2; exit}')" ;;
    # codex：表格列，剝掉 PLUGIN 欄後取到下一組連續空白為止，即狀態欄
    codex)  codex plugin list 2>/dev/null | grep -F "$plugin@$MARKETPLACE" \
              | head -1 | sed -E 's/^\S+\s+//; s/\s{2,}.*$//' | tr -d '\n' ;;
  esac
}

# agent_detail <agent> — 該 agent 逐 skill 的狀態字串
# I/O：輸入 agent 代號；輸出「<skill>=<狀態> ...」到 stdout；一個都沒裝時輸出空字串
# marketplace 與 copy 兩種模式在此收斂成同一種呈現：都是「哪些 skill 裝了、各自什麼狀態」
agent_detail() {
  local agent="$1" mode dir s state out=""
  mode="$(agent_mode "$agent")" || return
  dir="$(agent_skills_dir "$agent")"
  while IFS= read -r s; do
    if [ "$mode" = marketplace ]; then state="$(marketplace_state "$agent" "$s")"
    else                                state="$(copy_state "$dir" "$s")"; fi
    [ "$state" = "-" ] || out+="$s=$state "
  done < <(repo_skills)
  printf '%s' "$out"
}

# agent_status <agent> — 印出單一 agent 的安裝狀態
# I/O：輸入 agent 代號；一至數列報告到 stdout
# DECISION: 只印該 agent 實際使用的那一種方式——每個 agent 只走一種，另一種永遠是「未安裝」，
#           印出來只是固定的雜訊。但另一種機制若真的留有東西就會重複載入，
#           故改為「有東西才多印一列」：正常情況乾淨，出問題時看得見
# DECISION: 逐 skill 列出而非只報 plugin 名——每個 skill 各自是一個 plugin，
#           使用者可以只裝其中幾個，一個整體的「已安裝／未安裝」表達不了實際狀態
agent_status() {
  local agent="$1" mode detail legacy
  skip_missing "$agent" "$agent" && return
  mode="$(agent_mode "$agent")" || return

  detail="$(agent_detail "$agent")"
  if [ -n "$detail" ]; then
    report "$agent" "$mode" 已安裝 "$detail"
  else
    if [ "$mode" = marketplace ]; then report "$agent" "$mode" 未安裝 "$(agent_source "$agent")"
    else                               report "$agent" "$mode" 未安裝 "$(agent_skills_dir "$agent")"; fi
  fi

  # 已下架但仍裝著的舊 plugin：一裝就是全部 skill，且 codex 上完全看不見
  legacy="$(installed_legacy "$agent" | tr '\n' ' ')"
  [ -n "${legacy// /}" ] && report "$agent" 已下架 ⚠遺留 "${legacy% }：仍會載入全部 skill，建議移除"

  # 另一種機制的殘留：只在真的有東西時才現身
  if [ "$mode" = marketplace ]; then
    detail="$(copy_detail "$agent")"
    [ -n "$detail" ] && report "$agent" copy ⚠遺留 "$(agent_skills_dir "$agent")：$detail"
  else
    local lp; lp="$(agy_plugin_leftovers "$agent" | tr '\n' ' ')"
    [ -n "${lp// /}" ] && report "$agent" plugin ⚠遺留 "已用 plugin 機制安裝（${lp% }），會與 copy 重複載入"
  fi

  # opencode 另列它從別處掃到的來源——只看自己的目錄會誤判為「沒裝」，
  # 但實際上 skill 早就載入了，這一列正是決定「要不要再裝一次」的依據
  if [ "$agent" = opencode ]; then
    while IFS= read -r detail; do
      dir_has_skills "$detail" && report "$agent" 共用 已掃到 "$detail"
    done < <(opencode_shared_dirs)
  fi
}

# copy_detail <agent> — copy 目錄逐 skill 的狀態字串（供 marketplace 模式的殘留列使用）
# I/O：輸入 agent 代號；輸出「<skill>=<狀態> ...」到 stdout
copy_detail() {
  local dir s state out=""
  dir="$(agent_skills_dir "$1")" || return
  while IFS= read -r s; do
    state="$(copy_state "$dir" "$s")"
    [ "$state" = "-" ] || out+="$s=$state "
  done < <(repo_skills)
  printf '%s' "$out"
}

# ════════════════ validate ════════════════

# do_validate — 離線檢查 repo 的 plugin 結構，不需註冊、不動任何 agent 設定
# I/O：無參數；逐項結果到 stdout（失敗項到 stderr）；失敗累計至 FAILED
do_validate() {
  # marketplace.json：官方要求的必要欄位（name / owner.name / plugins[].name / plugins[].source）
  if jq -e '.name and .owner.name and (.plugins|length>0)
            and all(.plugins[]; .name and .source)' "$MANIFEST" >/dev/null; then
    printf '  ✔ marketplace.json 必要欄位齊全\n'
  else
    printf '  ✗ marketplace.json 缺必要欄位\n' >&2; FAILED=1
  fi

  # 佈局不變式：plugins/<name>/skills/<name>/SKILL.md
  # DECISION: 直接走訪 plugins/*/ 而非用 repo_skills——後者的職責是「列出有效 skill」，
  #           會刻意略過不合格的目錄，正好把要回報的問題藏起來
  local d n bad_layout=0
  for d in "$REPO_ROOT"/plugins/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    if [ ! -f "$d/skills/$n/SKILL.md" ]; then
      printf '  ✗ plugins/%s 缺 skills/%s/SKILL.md，不會被任何 agent 掃描到\n' "$n" "$n" >&2
      bad_layout=1; FAILED=1
    fi
    # agy 靠每個 plugin 目錄自己的 plugin.json 才能單獨安裝，缺了只影響 agy
    [ -f "$d/plugin.json" ] || printf '  [警告] plugins/%s 缺 plugin.json：agy 無法單獨安裝這個 skill\n' "$n" >&2
  done
  [ "$bad_layout" = 0 ] && printf '  ✔ 每個 plugins/<name>/ 都有 skills/<name>/SKILL.md\n'

  # entry 的 source 必須指向存在的 plugin 目錄
  local bad_src=0 e sp
  while IFS=$'\t' read -r e sp; do
    [ -n "$sp" ] || continue
    [ -d "$REPO_ROOT/${sp#./}" ] || { printf '  ✗ %s 的 source 不存在：%s\n' "$e" "$sp" >&2; bad_src=1; FAILED=1; }
  done < <(jq -r '.plugins[] | select(.source|type=="string") | [.name, .source] | @tsv' "$MANIFEST")
  [ "$bad_src" = 0 ] && printf '  ✔ 所有 entry 的 source 都指向存在的目錄\n'

  # 每個 skill 都要有對應的 entry，否則新增了卻沒發佈，使用者裝不到
  local missing="" sk
  while IFS= read -r sk; do
    jq -e --arg n "$sk" 'any(.plugins[]; .name==$n)' "$MANIFEST" >/dev/null 2>&1 || missing+="$sk "
  done < <(repo_skills)
  if [ -z "$missing" ]; then
    printf '  ✔ 每個 skill 都有對應的 marketplace entry\n'
  else
    printf '  ✗ 這些 skill 沒有 marketplace entry，使用者裝不到：%s\n' "${missing% }" >&2; FAILED=1
  fi

  # 各家自己的驗證器：權威性高於上面的欄位檢查，有裝就跑
  # （codex 沒有對應的 validate 子命令，故只有兩家）
  # --strict 把「無法辨識的欄位」也視為錯誤，可攔下拼錯的欄位名（實測本 repo 通過）
  have claude && run "claude plugin validate --strict" claude plugin validate "$REPO_ROOT" --strict
  # agy 驗的是單一 plugin 目錄（它只認該目錄的 plugin.json），故逐個跑
  if have agy; then
    while IFS= read -r sk; do
      run "agy plugin validate（$sk）" agy plugin validate "$(plugin_dir "$sk")"
    done < <(repo_skills)
  fi
}

# ════════════════ 主流程 ════════════════

# ── 解析子命令：validate 與 help 不需要後續的參數處理，就地結束 ──
CMD="${1:-}"; shift || true
case "$CMD" in
  install|remove|update|status) ;;
  validate) do_validate; exit "$FAILED" ;;
  ""|help|-h|--help)
    cat <<EOF
用法：tools/skills.sh <install|remove|update|status|validate> [agent...]

  agent   claude | codex | agy | opencode（可多個；省略＝全部）

每個 skill 各自是一個 plugin，可單獨安裝。安裝方式則是 per-agent 固定的：
  claude    marketplace  ${GITHUB_SOURCE:-$REPO_ROOT}
  codex     marketplace  ${GITHUB_SOURCE:-$REPO_ROOT}
  agy       copy         $HOME/.gemini/skills
  opencode  copy         ${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills

  SKILLS  只處理指定的 skill（空白分隔）；不設＝互動選單（非互動時＝全部）
          可用：$(repo_skills | tr '\n' ' ')
  SOURCE  覆寫 marketplace 來源；開發時裝工作目錄的內容用 SOURCE=\$PWD
  FORCE   1 ＝略過「另一種機制留有殘留」的偵測

install 與 remove 在互動終端會先跳選單讓你挑；非互動（CI、pipe）一律視為全部。

範例：
  tools/skills.sh install                                    # 四家，跳選單挑 skill
  tools/skills.sh install claude                             # 只處理 claude
  SKILLS="mh-code-review" tools/skills.sh install            # 只裝一個 skill
  SKILLS="mh-code-review mh-humanizer-zh-tw" tools/skills.sh install claude
  SOURCE=\$PWD tools/skills.sh install                       # 開發時裝工作目錄的內容
  tools/skills.sh status                                     # 逐 skill 的現況
EOF
    exit 0 ;;
  *) echo "錯誤：未知子命令「$CMD」（可用：install/remove/update/status/validate）" >&2; exit 2 ;;
esac

# ── 決定目標 agent：省略＝全部；指定則先驗證代號，避免拼錯被靜默忽略成「什麼都沒做」 ──
# EXPLICIT_TARGETS 供守衛區分「使用者點名這個 agent」與「它只是被全體掃到」，
# 兩者該不該算失敗不同（見 opencode_shared_guard）
# SKILLS 名稱驗證：拼錯若放行會靜默少裝一個，比照未知 agent 當場擋下
for sk in $SKILLS; do
  case "$(printf '%s\n' $(repo_skills) | tr '\n' ' ')" in
    *" $sk "*|"$sk "*|*" $sk") ;;
    *) echo "錯誤：未知 skill「$sk」（可用：$(repo_skills | tr '\n' ' ')）" >&2; exit 2 ;;
  esac
done

[ "$#" -gt 0 ] && EXPLICIT_TARGETS=1 || EXPLICIT_TARGETS=""
TARGETS="${*:-$ALL_AGENTS}"
for a in $TARGETS; do
  case " $ALL_AGENTS " in
    *" $a "*) ;;
    *) echo "錯誤：未知 agent「$a」（可用：$ALL_AGENTS）" >&2; exit 2 ;;
  esac
done

# ── status 走獨立分支：它只報告現況，不需要來源解析 ──
if [ "$CMD" = status ]; then
  echo "status"
  report AGENT 方式 狀態 細節
  for a in $TARGETS; do agent_status "$a"; done
  exit "$FAILED"
fi

# ── 互動選單：先挑 agent，再挑 skill ──
# 條件缺一即沿用「全部」，確保非互動情境（CI、pipe、< /dev/null）不會停在等輸入。
# 已在命令列點名 agent（如 make install-claude）時跳過 agent 那段，與 SKILLS 的邏輯一致。
# DECISION: update 兩段都不跳——「把裝著的都更新到最新」本來就是它唯一合理的意圖，
#           未安裝者本就會被略過，多問只是徒增步驟
if [ -t 0 ] && [ -r /dev/tty ]; then
  case "$CMD" in
    install|remove)
      verb=安裝; [ "$CMD" = remove ] && verb=移除
      [ -z "$EXPLICIT_TARGETS" ] && { pick_agents "$verb" || exit 0; }
      [ -z "$SKILLS" ]           && { pick_skills "$verb" || exit 0; }
      ;;
  esac
fi

# ── install / remove / update ──
# DECISION: 先印「計畫」再執行——方式與來源逐 agent 不同，單一行標頭必然對其中幾家是錯的。
#           把解析結果攤開，使用者在動手前就能確認每家各自會用什麼方式、動到哪裡
printf '%s（方式與來源）\n' "$CMD"
for a in $TARGETS; do
  mode="$(agent_mode "$a")"
  # marketplace 看來源、copy 看目的地——兩者都是「這次會動到哪裡」，同一欄呈現才好對照
  if [ "$mode" = marketplace ]; then detail="$(agent_source "$a")"; else detail="$(agent_skills_dir "$a")"; fi
  printf '  '; pad "$a" 10; pad "$mode" 13; printf '%s\n' "$detail"
done

for a in $TARGETS; do
  mode="$(agent_mode "$a")"
  # DECISION: 已下架的舊 plugin 必須在模式移除之前清——marketplace_*_remove 末端會在
  #           「本 repo 的 plugin 全數移除」時註銷 marketplace，一旦註銷，
  #           claude plugin list 就查不到那個舊 plugin，legacy 偵測會靜默失效
  # DECISION: 只在「處理全部 skill」時才清舊 plugin——舊的是含全部 skill 的整包，
  #           無法只從中拿掉一個。選了部分 skill 卻連帶把整包移除，等於在使用者
  #           沒要求的情況下擴大移除範圍；改為提示並保留，由使用者自行決定
  if [ "$CMD" = remove ]; then
    if [ -z "$SKILLS" ]; then
      legacy_remove "$a"
    elif [ -n "$(installed_legacy "$a")" ]; then
      printf '  [略過] %s：仍裝著已下架的 %s（含全部 skill，無法只移除其中一個）\n' \
             "$a" "$(installed_legacy "$a" | tr '\n' ' ')" >&2
      printf '        要清掉它請不指定 SKILLS 執行一次：tools/skills.sh remove %s\n' "$a" >&2
    fi
  fi

  if [ "$mode" = marketplace ]; then
    # marketplace 模式每個 agent 各有實作，CLI 存在與否由各函式自行檢查
    SOURCE="$(agent_source "$a")"
    "marketplace_${a}_${CMD}"
  else
    # copy 模式各家共用同一實作，故 CLI 檢查在此統一做
    skip_missing "$a" "$a" && continue
    "copy_${CMD}" "$a"
  fi

  # remove 一律連另一種機制的殘留一起清——只清自己那一邊等於留著重複載入的來源
  [ "$CMD" = remove ] && leftover_remove "$a"
done

exit "$FAILED"
