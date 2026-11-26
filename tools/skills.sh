#!/usr/bin/env bash
# skills.sh — 把本 repo 的 skills 安裝／移除／更新到各 AI agent
#
# 用途：各 agent 的安裝機制與 CLI 介面互不相同。本腳本把差異封裝起來，對外只暴露一組子命令。
#
#       使用案例：
#         tools/skills.sh install                     # 四家；互動終端會跳選單挑 skill
#         tools/skills.sh status                      # 看各家現況
#         tools/skills.sh source local                # marketplace 改用工作目錄（github 切回）
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
#   | agy      | plugin      | 從 GitHub 子目錄 URL 逐 skill 執行 agy plugin install     |
#   | opencode | copy        | 複製進 $XDG_CONFIG_HOME/opencode/skills（不吃本 repo 的 manifest）|
#
#   claude／codex 能註冊本 repo 為 marketplace，安裝與更新交給 CLI，故走 marketplace。
#   agy 不能註冊第三方 marketplace，但 `plugin install` 收本機目錄與 GitHub URL，故走 plugin。
#
# 遺留偵測：每個 agent 只走一種方式，但另一種機制的殘留（舊版工具裝的、手動複製的）
#   仍會被同時載入而重複。故 install 前偵測並擋下（FORCE=1 可略過），
#   remove 一律兩邊都掃，status 只在真的有東西時才多印一列 ⚠遺留。
#
# Domain knowhow — 各家 CLI 的行為差異（實測所得，升版需重驗）：
#   - claude 的 `plugin list` 只列**已安裝**者，格式為縮排區塊（`❯ 名稱` 後接 Version/Scope/Status）
#   - codex  的 `plugin list` 連**未安裝**者一起列（marketplace 已註冊即出現），格式為表格，
#            狀態欄可能是 `installed, enabled` 或 `not installed`——判斷時不可用子字串比對
#   - claude 對同名 marketplace 再 `marketplace add` 會原地換來源、已裝的 plugin 保留，但新來源與
#            settings.json 的 extraKnownMarketplaces 宣告不符時會拒絕（目錄→Git 必中），須先改寫宣告；
#            `marketplace remove`（含 --scope）會連帶解除安裝底下所有 plugin，不可拿來換來源
#   - codex  對同名 marketplace 換來源一律拒絕，須先 `marketplace remove`；remove 不動 config.toml
#            的 plugin 設定，重新 add 後即恢復
#   - claude 對「移除不存在的東西」回非零，codex 與 agy 回 0；remove 前一律先判斷是否真的裝了，
#            三家對齊到冪等，乾淨環境跑 remove 不該回失敗
#   - codex  除 `.claude-plugin/marketplace.json` 外亦接受 `.agents/plugins/` 下的 `marketplace.json` 與 `api_marketplace.json`；
#            plugin manifest 找 `.codex-plugin/plugin.json`，缺少時**由 marketplace entry 自動生成**
#            一份放進快取，故本 repo 不需自備 codex manifest
#   - codex  的全域 skills 來源另有 ~/.agents/skills；該處的同名 skill 會與 plugin 版並存
#   - agy    的 `plugin list` 格式隨版本不同：1.2.3 直接輸出 JSON 物件（`.imports`），
#            1.5.15 改為人讀格式，JSON 要加 `--json` 且頂層是陣列
#   - agy    的 plugin skill 與 ~/.gemini/skills 的同名 skill 會並存，兩份都列出
#   - agy    的全域 skills 目錄實測有兩處：~/.gemini/skills 與 ~/.gemini/antigravity-cli/skills
#            （以兩個標記 skill 實測，兩處都載得到）；本腳本只用前者偵測與清除殘留
#   - opencode 另可用設定檔的 `skills` 指向本機目錄或 HTTP 目錄；plugin 是 JS/TS 套件，
#            不吃本 repo 的 manifest
#   - opencode 的全域 skills 來源有三處：$XDG_CONFIG_HOME/opencode/skills、~/.claude/skills、
#            ~/.agents/skills。同名只載入一份，它自己的目錄優先，另外兩處的會被遮蔽
#
# 檔案佈局：本檔只放設定與主流程；各區段函式依名稱分在 tools/lib/（common／tui／detect／marketplace／
#           plugin／copy／status／validate），由下方的載入迴圈依序 source。
#
# 派發慣例：主流程以 `marketplace_<agent>_<cmd>`、`plugin_<agent>_<cmd>` 與 `copy_<cmd>` 的命名動態呼叫對應函式。
#           新增 agent 只需補齊該組函式、加進 ALL_AGENTS 並在 agent_mode 宣告方式。
#
# I/O：
#   輸入  ─ $1     子命令：install | remove | update | status | source | validate
#           source 另帶來源：github | local | status（省略＝status），其後才是 agent 代號
#           $2..   agent 代號：claude | codex | agy | opencode（可多個；省略＝全部）
#           SKILLS 環境變數：只處理指定的 skill；不設時 install/remove 會跳互動選單
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

# 每個 skill 各自是一個 plugin，plugin 名即 skill 名（各 entry 以 source 指向自己的 plugin 目錄）
MP_PLUGINS="$(jq -r '.plugins[].name' "$MANIFEST")"
[ -n "$MP_PLUGINS" ] || { echo "錯誤：manifest 的 plugins 為空" >&2; exit 127; }

# LEGACY_PLUGINS — 已從 marketplace 移除的舊 plugin 名，取自 manifest 的 renames
# 這些名稱不再是 entry，但使用者機器上可能還裝著：
#   claude plugin list 仍看得到
#   codex  沒有 renames 概念，plugin list 直接看不到它，但 config.toml 與快取都還在，
#          執行期照樣載入——是隱形卻仍在運作的孤兒，必須主動偵測
LEGACY_PLUGINS="$(jq -r '(.renames // {}) | keys[]' "$MANIFEST" 2>/dev/null)"

# GITHUB_SOURCE — GitHub 來源網址，讀自 repo 根目錄 .env 的 MARKETPLACE_GITHUB_URL（缺檔時讀 .env.example）
# 無效或未設時為空：只有真的要從 GitHub 安裝或切換時才報錯，查詢、移除與本機來源不受影響
# DECISION: 未採 `owner/repo` 簡寫，因其 clone 協定隨 SSH 設定而變
ENV_FILE="$REPO_ROOT/.env"
github_url() {
  local f="$ENV_FILE" u
  [ -f "$f" ] || f="$ENV_FILE.example"
  # 只取該行的值，不 source 整份檔案，避免執行到其他內容
  u="$(sed -n 's/^MARKETPLACE_GITHUB_URL=//p' "$f" 2>/dev/null | tail -n 1 | tr -d "\"' \r")"
  case "$u" in https://*) printf '%s\n' "${u%.git}.git" ;; esac
}
GITHUB_SOURCE="$(github_url)"
GITHUB_HINT="（未設定：請在 $ENV_FILE 設 MARKETPLACE_GITHUB_URL=https://…）"

# ensure_env — 動手的子命令才補建 .env，讓使用者有地方改網址；查詢類子命令不產生檔案
ensure_env() {
  [ -f "$ENV_FILE" ] || [ ! -f "$ENV_FILE.example" ] && return 0
  cp "$ENV_FILE.example" "$ENV_FILE" && echo "[注意] 已由 .env.example 建立 .env" >&2
}

# ── 可由環境變數覆寫的執行參數 ──
SOURCE=""      # 逐 agent 解析後填入，供 marketplace_*／plugin_* 函式讀取
FORCE="${FORCE:-}"
SKILLS="${SKILLS:-}"   # 空＝repo 內全部；否則只處理指定的那幾個（主流程會驗證名稱）

ALL_AGENTS="claude codex agy opencode"
FAILED=0   # 任一步驟失敗即設為 1，作為整體結束碼
INSTALLED_ANY=0  # 是否真的有 agent 走完安裝／更新——決定要不要跑安裝後自檢

# ── 載入各區段函式：lib/ 只定義函式與常數，依名稱分檔 ──
for _lib in common tui detect marketplace plugin copy status validate; do
  # shellcheck source=/dev/null
  . "$REPO_ROOT/tools/lib/$_lib.sh"
done
unset _lib

# ════════════════ 主流程 ════════════════

# ── 解析子命令：validate 與 help 不需要後續的參數處理，就地結束 ──
CMD="${1:-}"; shift || true
case "$CMD" in
  install|update) ensure_env ;;
  remove|status) ;;
  source) SRC_MODE="${1:-status}"; shift || true
          case "$SRC_MODE" in github|local) ensure_env ;; esac ;;
  validate) do_validate; exit "$FAILED" ;;
  ""|help|-h|--help)
    cat <<EOF
用法：tools/skills.sh <install|remove|update|status|validate> [agent...]
      tools/skills.sh source [github|local|status] [agent...]

  agent   claude | codex | agy | opencode（可多個；省略＝全部）

每個 skill 各自是一個 plugin，可單獨安裝。安裝方式則是 per-agent 固定的：
  claude    marketplace  已登記的來源；未註冊時 $GITHUB_SOURCE
  codex     marketplace  已登記的來源；未註冊時 $GITHUB_SOURCE
  agy       plugin       $GITHUB_SOURCE
  opencode  copy         ${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills

  SKILLS  只處理指定的 skill（空白分隔）；不設＝互動選單（非互動時＝全部）
          可用：$(repo_skills | tr '\n' ' ')
  FORCE   1 ＝略過「另一種機制留有殘留」的偵測

install 與 remove 在互動終端會先跳選單讓你挑；非互動（CI、pipe）一律視為全部。
source 切換 claude／codex 的 marketplace 來源：github＝.env 的 MARKETPLACE_GITHUB_URL，local＝本 repo 目錄。

範例：
  tools/skills.sh install                                    # 四家，跳選單挑 skill
  tools/skills.sh install claude                             # 只處理 claude
  SKILLS="mh-code-review" tools/skills.sh install            # 只裝一個 skill
  SKILLS="mh-code-review mh-humanizer-zh-tw" tools/skills.sh install claude
  tools/skills.sh source local                               # 改用工作目錄（github 切回）
  tools/skills.sh source                                     # 看目前來源
  tools/skills.sh status                                     # 逐 skill 的現況
EOF
    exit 0 ;;
  *) echo "錯誤：未知子命令「${CMD}」（可用：install/remove/update/status/source/validate）" >&2; exit 2 ;;
esac

# ── 決定目標 agent：省略＝全部；指定則先驗證代號，避免拼錯被靜默忽略成「什麼都沒做」 ──
# SKILLS 名稱驗證：拼錯若放行會靜默少裝一個，比照未知 agent 當場擋下
for sk in $SKILLS; do
  case "$(printf '%s\n' $(repo_skills) | tr '\n' ' ')" in
    *" $sk "*|"$sk "*|*" $sk") ;;
    *) echo "錯誤：未知 skill「${sk}」（可用：$(repo_skills | tr '\n' ' ')）" >&2; exit 2 ;;
  esac
done

TARGETS="${*:-$ALL_AGENTS}"
for a in $TARGETS; do
  case " $ALL_AGENTS " in
    *" $a "*) ;;
    *) echo "錯誤：未知 agent「${a}」（可用：${ALL_AGENTS}）" >&2; exit 2 ;;
  esac
done

# ── source 只動 marketplace 註冊，不進安裝流程 ──
if [ "$CMD" = source ]; then
  do_source "$SRC_MODE"
  exit "$FAILED"
fi

# ── status 走獨立分支：它只報告現況，不需要來源解析 ──
if [ "$CMD" = status ]; then
  echo "status"
  report AGENT 方式 狀態 細節
  for a in $TARGETS; do agent_status "$a"; done
  exit "$FAILED"
fi

# ── 互動選單：agent × skill 矩陣，畫不下時退回只挑 skill ──
# 條件缺一即沿用「全部」，確保非互動情境（CI、pipe、< /dev/null）不會停在等輸入。
# 已在命令列點名 agent（如 tools/skills.sh install claude）時，矩陣只列該 agent。
# DECISION: update 不跳選單——「把裝著的都更新到最新」本來就是它唯一合理的意圖，
#           未安裝者本就會被略過，多問只是徒增步驟
USE_MATRIX=""
if [ -z "$SKILLS" ] && [ -t 0 ] && [ -r /dev/tty ]; then
  case "$CMD" in
    install|remove)
      verb=安裝; [ "$CMD" = remove ] && verb=移除
      if tui_capable $(( $(repo_skills | wc -l) + 3 )); then
        matrix_load
        pick_matrix "$verb" || exit 0
        USE_MATRIX=1
      else
        # 終端畫不下格子時退回一維選單（只挑 skill，套用到所有 agent）
        pick_skills "$verb" || exit 0
      fi
      ;;
  esac
fi

# ── 安裝後自檢 ────────────────────────────────────────────────────
# 使用者設定（家目錄）不隨 skill 一起更新，skill 版本前進後可能出現已失效的欄位。
# 這裡只定約定、不認得任何特定 plugin：skill 自己提供 scripts/post-install-check.sh
# 就會被呼叫。設定是 per-user 的，所以逐 skill 只跑一次，🚫 不隨 agent 數重複。
# DECISION: 自檢結束碼一律吞掉，不併入 FAILED——安裝本身成功與否，不該由使用者
#           設定的檢查結果決定
# 安裝失敗、或每家 agent 都因缺 CLI 被略過時不跑：沒裝成任何東西卻改了使用者
# 設定，是使用者無從預期的副作用。
# DECISION: 用整體結果守門，未逐 skill 追蹤成敗——後者要把狀態穿進 run／copy_*／
#           marketplace_* 整條鏈，代價遠大於它擋掉的情境
run_post_install_check() {
  if [ "$FAILED" -ne 0 ] || [ "$INSTALLED_ANY" -eq 0 ]; then
    return 0
  fi
  post_install_check "$@"
}

post_install_check() {
  local sk hook done_list=""
  for sk in "$@"; do
    [ -n "$sk" ] || continue
    case " $done_list " in *" $sk "*) continue ;; esac
    done_list+="$sk "
    hook="$REPO_ROOT/plugins/$sk/skills/$sk/scripts/post-install-check.sh"
    [ -x "$hook" ] || continue
    printf '\n[%s] 安裝後自檢\n' "$sk"
    "$hook" || true
  done
}

# ── install / remove / update ──
# DECISION: 先印「計畫」再執行——方式與來源逐 agent 不同，單一行標頭必然對其中幾家是錯的。
#           把解析結果攤開，使用者在動手前就能確認每家各自會用什麼方式、動到哪裡
# ── 依矩陣執行：逐 agent 算出要裝什麼、要移除什麼 ──
# DECISION: 不另寫執行邏輯，而是把差集塞進 SKILLS 再沿用既有的 marketplace_*／copy_* ——
#           那些函式本來就是「處理 target_skills 列出的每個 skill」，重用可避免兩套實作漂移
if [ -n "$USE_MATRIX" ]; then
  printf '%s（差異更新）\n' "$CMD"
  declare -A ADD_MAP RM_MAP
  for a in $(matrix_agents); do
    add=""; rm=""
    while IFS= read -r sk; do
      want="${TGT[$a,$sk]:-0}"; now="${CUR[$a,$sk]:-0}"
      [ "$want" = 1 ] && [ "$now" != 1 ] && add+="$sk "
      [ "$want" != 1 ] && [ "$now" = 1 ] && rm+="$sk "
    done < <(repo_skills)
    ADD_MAP[$a]="$add"; RM_MAP[$a]="$rm"
    detail=""
    [ -n "$add" ] && for sk in $add; do detail+="+$sk "; done
    [ -n "$rm" ]  && for sk in $rm;  do detail+="-$sk "; done
    printf '  '; pad "$a" 10; printf '%s\n' "${detail:-（無變化）}"
  done

  for a in $(matrix_agents); do
    mode="$(agent_mode "$a")"
    # 先移除再安裝：兩者若同時發生，先清掉舊的可避免中間狀態出現重複載入
    if [ -n "${RM_MAP[$a]}" ]; then
      SKILLS="${RM_MAP[$a]}"
      if [ "$mode" != copy ]; then SOURCE="$(agent_source "$a")"; "${mode}_${a}_remove"
      else skip_missing "$a" "$a" || copy_remove "$a"; fi
      leftover_remove "$a"
    fi
    if [ -n "${ADD_MAP[$a]}" ]; then
      SKILLS="${ADD_MAP[$a]}"
      if [ "$mode" != copy ]; then use_source "$a" && { "${mode}_${a}_install"; INSTALLED_ANY=1; }
      else skip_missing "$a" "$a" || { copy_install "$a"; INSTALLED_ANY=1; }; fi
    fi
  done
  # 只對本次真的裝上／更新到的 skill 跑，未變動的不打擾
  run_post_install_check $(for a in $(matrix_agents); do printf '%s ' "${ADD_MAP[$a]}"; done)
  SKILLS=""
  exit "$FAILED"
fi

# ── install / remove / update（非矩陣路徑：指定 SKILLS、或非互動）──
# DECISION: 先印「計畫」再執行——方式與來源逐 agent 不同，單一行標頭必然對其中幾家是錯的。
#           把解析結果攤開，使用者在動手前就能確認每家各自會用什麼方式、動到哪裡
printf '%s（方式與來源）\n' "$CMD"
for a in $TARGETS; do
  mode="$(agent_mode "$a")"
  # marketplace／plugin 看來源、copy 看目的地——兩者都是「這次會動到哪裡」，同一欄呈現才好對照
  if [ "$mode" != copy ]; then detail="$(agent_source "$a")"; else detail="$(agent_skills_dir "$a")"; fi
  printf '  '; pad "$a" 10; pad "$mode" 13; printf '%s\n' "$detail"
done

for a in $TARGETS; do
  # DECISION: 已下架的舊 plugin 必須在模式移除之前清——marketplace_*_remove 末端會在
  #           「本 repo 的 plugin 全數移除」時註銷 marketplace，一旦註銷，
  #           claude plugin list 就查不到那個舊 plugin，legacy 偵測會靜默失效
  # DECISION: 只在「處理全部 skill」時才清舊 plugin——舊的是含全部 skill 的整包，
  #           無法只從中拿掉一個
  if [ "$CMD" = remove ]; then
    if [ -z "$SKILLS" ]; then
      legacy_remove "$a"
    elif [ -n "$(installed_legacy "$a")" ]; then
      printf '  [略過] %s：仍裝著已下架的 %s（含全部 skill，無法只移除其中一個）\n' \
             "$a" "$(installed_legacy "$a" | tr '\n' ' ')" >&2
      printf '        要清掉它請不指定 SKILLS 執行一次：tools/skills.sh remove %s\n' "$a" >&2
    fi
  fi

  mode="$(agent_mode "$a")"
  if [ "$mode" != copy ]; then
    if [ "$CMD" = remove ]; then SOURCE="$(agent_source "$a")"
    else use_source "$a" || continue; fi
    "${mode}_${a}_${CMD}"
    have "$a" && INSTALLED_ANY=1
  else
    skip_missing "$a" "$a" && continue
    "copy_${CMD}" "$a"
    INSTALLED_ANY=1
  fi

  [ "$CMD" = remove ] && leftover_remove "$a"
done

# remove 不跑自檢：設定留著是刻意的，重裝後還要用
case "$CMD" in
  install) run_post_install_check $(target_skills) ;;
  # update 會略過未安裝的 skill，自檢對象也要跟著縮小
  update)  run_post_install_check $(installed_targets) ;;
esac

exit "$FAILED"
