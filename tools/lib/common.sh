# shellcheck shell=bash
# lib/common.sh — 共用工具與 agent 基本屬性（方式、目錄、來源）
# 由 tools/skills.sh 載入，沿用其設定的全域變數（REPO_ROOT、MARKETPLACE、SOURCE 等）；只定義函式與常數，不執行動作

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
# 因此建到一半、缺 SKILL.md 的 plugin 目錄不會被誤認
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
# I/O：輸入 agent 代號；輸出 marketplace、plugin 或 copy 到 stdout；未知代號回 1
#
# DECISION: 每個 agent 只走一種方式，沒有讓使用者選的餘地，故不設 METHOD 開關。
#   claude／codex ─ marketplace：兩家吃同一份 .claude-plugin/marketplace.json，
#                   而且能直接吃 Git URL，安裝與更新都交給 CLI 處理，是真正的發佈途徑
#   agy           ─ plugin：不能註冊第三方 marketplace，但可直接從本機目錄或 GitHub URL 安裝
#   opencode      ─ copy：它的 plugin 不吃本 repo 的 manifest；HTTP 目錄要另備 index.json
agent_mode() {
  case "$1" in
    claude|codex)  printf 'marketplace\n' ;;
    agy)           printf 'plugin\n' ;;
    opencode)      printf 'copy\n' ;;
    *) return 1 ;;
  esac
}

# agent_source <agent> — 該 agent 在 marketplace／plugin 模式下的安裝來源
# I/O：輸入 agent 代號；輸出來源字串（Git URL 或本機路徑）到 stdout
# marketplace 模式沿用已登記的來源（由 source 子命令切換），未註冊時用 GitHub；
# plugin 模式（agy）不記錄來源，一律用 GitHub；copy 模式用不到
agent_source() {
  local cur=""
  [ "$(agent_mode "$1")" = marketplace ] && cur="$(marketplace_source "$1")"
  printf '%s\n' "${cur:-$GITHUB_SOURCE}"
}

# use_source <agent> — 把該 agent 的來源填入全域 SOURCE；取不到時記失敗、回 1，由呼叫端略過該 agent
use_source() {
  SOURCE="$(agent_source "$1")"
  [ -n "$SOURCE" ] && return 0
  printf '  ✗ %s：GitHub 來源%s\n' "$1" "$GITHUB_HINT" >&2; FAILED=1; return 1
}
