# shellcheck shell=bash
# lib/marketplace.sh — marketplace 模式（claude／codex）：註冊、換來源、安裝、移除、更新與 source 子命令
# 由 tools/skills.sh 載入，沿用其設定的全域變數（REPO_ROOT、MARKETPLACE、SOURCE 等）；只定義函式與常數，不執行動作

# ════════════════ marketplace 模式（claude／codex）════════════════
# 兩家各一組 install/remove/update，由主流程以 marketplace_<agent>_<cmd> 動態呼叫。
# 骨架相同（檢查 CLI → 遺留偵測 → 逐 skill 執行），差異只在各家 CLI 的子命令與參數形狀。
#
# 每個 skill 是一個獨立的 plugin（plugin 名即 skill 名），故安裝／移除都要逐個處理。
#
# remove 一律先判斷有沒有裝再下指令：claude 對「移除不存在的東西」回非零，
# 會被 run() 記成失敗，讓乾淨環境跑 remove 也回 rc=1。codex 回 0，一併對齊。

# marketplace_claude_install — 註冊 marketplace 後逐一安裝選定的 skill
# I/O：無參數（讀全域 SOURCE）；進度走 stdout；失敗累計至 FAILED
marketplace_claude_install() {
  local p
  skip_missing claude claude && return
  leftover_guard claude || return
  marketplace_register claude
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
  shared_notice codex
  marketplace_register codex
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
# 判準取自 codex 自己的註冊狀態（`marketplace list --json` 的 sourceType）：本機來源不能 upgrade，
# 誤跑會得到「is not configured as a Git marketplace」而被記成失敗
codex_marketplace_is_git() {
  [ "$(codex plugin marketplace list --json 2>/dev/null \
       | jq -r --arg n "$MARKETPLACE" \
         '.marketplaces[]? | select(.name==$n) | .marketplaceSource.sourceType')" = git ]
}

# marketplace_codex_update — Git 來源刷新快照，本機來源逐一重裝（codex 無獨立的 plugin update）
marketplace_codex_update() {
  local p
  skip_missing codex codex && return
  # Git 來源的 upgrade 會連已安裝的快取一起刷新；本機來源不能 upgrade，要重裝才會覆蓋快取
  if codex_marketplace_is_git; then
    run "codex：刷新 marketplace 快照" codex plugin marketplace upgrade "$MARKETPLACE"
  elif has_marketplace codex; then
    while IFS= read -r p; do
      case "$(marketplace_state codex "$p")" in
        -) printf '  [略過] codex：%s 未安裝\n' "$p" ;;
        # plugin add 會把停用的 plugin 重新啟用
        *disabled*) printf '  [略過] codex：%s 已停用，重裝會重新啟用\n' "$p" ;;
        *) run "codex：更新 $p" codex plugin add "$p@$MARKETPLACE" ;;
      esac
    done < <(target_skills)
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
    run "${agent}：移除 marketplace" "$agent" plugin marketplace remove "$MARKETPLACE"
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

  # marketplace／plugin 模式的 agent：殘留是 skills 目錄裡的副本
  [ "$mode" != copy ] && has_copy "$agent" && copy_remove "$agent"

  # 共用目錄不動，但要講清楚 skill 仍會被載入
  shared_notice "$agent"
}

# ── 來源註冊 ──

# marketplace_source <agent> — 該 agent 目前登記的本 marketplace 來源
# I/O：輸入 agent 代號；輸出 Git URL 或本機路徑到 stdout，未註冊時無輸出
marketplace_source() {
  case "$1" in
    claude)
      have claude && claude plugin marketplace list --json 2>/dev/null \
        | jq -r --arg n "$MARKETPLACE" '.[]? | select(.name==$n) | .url // .path // .repo // empty'
      ;;
    codex)
      have codex && codex plugin marketplace list --json 2>/dev/null \
        | jq -r --arg n "$MARKETPLACE" '.marketplaces[]? | select(.name==$n) | .marketplaceSource.source // empty'
      ;;
  esac
  return 0
}

# marketplace_register <agent> — 以全域 SOURCE 註冊本 marketplace；已登記其他來源時改換
# I/O：輸入 claude 或 codex；進度走 stdout；失敗累計至 FAILED
# 換來源時 claude 先改寫 settings.json 的宣告，codex 先註銷（兩家的限制見檔頭 Domain knowhow）
marketplace_register() {
  local cur
  cur="$(marketplace_source "$1")"
  if [ -n "$cur" ] && [ "$cur" != "$SOURCE" ]; then
    case "$1" in
      claude) run "claude：改寫 marketplace 宣告（原 $cur）" claude_declare_source ;;
      codex)  run "codex：改換 marketplace 來源（原 $cur）" codex plugin marketplace remove "$MARKETPLACE" ;;
    esac
  fi
  run "$1：註冊 marketplace $MARKETPLACE" "$1" plugin marketplace add "$SOURCE"
}

# claude_declare_source — 把 ~/.claude/settings.json 中本 marketplace 的宣告改成全域 SOURCE
# I/O：無參數；無宣告時不動；寫入失敗回非零。先寫暫存檔再換名，避免寫到一半毀損設定檔
claude_declare_source() {
  local f="$HOME/.claude/settings.json" src
  [ -f "$f" ] && jq -e --arg n "$MARKETPLACE" '.extraKnownMarketplaces[$n]' "$f" >/dev/null || return 0
  if [ -d "$SOURCE" ]; then src="$(jq -n --arg p "$SOURCE" '{source:"directory",path:$p}')"
  else                      src="$(jq -n --arg u "$SOURCE" '{source:"git",url:$u}')"; fi
  jq --arg n "$MARKETPLACE" --argjson s "$src" '.extraKnownMarketplaces[$n].source = $s' "$f" > "$f.tmp.$$" \
    && mv "$f.tmp.$$" "$f"
}

# ════════════════ source ════════════════

# do_source <github|local|status> — 切換或查看 marketplace 來源
# I/O：輸入來源模式（讀全域 TARGETS）；結果表到 stdout；未知模式回 rc=2
# local＝本 repo 所在目錄（以腳本位置換算，worktree 即該 worktree）；只改註冊、不增減 plugin，
# 已裝者之後由 update 從新來源更新
do_source() {
  local a cur kind state
  case "$1" in
    github) SOURCE="$GITHUB_SOURCE"
            [ -n "$SOURCE" ] || { echo "錯誤：GitHub 來源$GITHUB_HINT" >&2; exit 127; } ;;
    local)  SOURCE="$REPO_ROOT" ;;
    status) ;;
    *) echo "錯誤：未知來源「$1」（可用：github/local/status）" >&2; exit 2 ;;
  esac
  if [ "$1" != status ]; then
    for a in $TARGETS; do
      [ "$(agent_mode "$a")" = marketplace ] || continue
      skip_missing "$a" "$a" || marketplace_register "$a"
    done
  fi

  echo "source"
  report AGENT 來源 狀態 細節
  for a in $TARGETS; do
    have "$a" || continue
    case "$(agent_mode "$a")" in
      marketplace)
        cur="$(marketplace_source "$a")"
        case "$cur" in
          "")               kind=-      ;;
          "$GITHUB_SOURCE") kind=github ;;
          "$REPO_ROOT")     kind=local  ;;
          /*)               kind=他處目錄 ;;
          *)                kind=其他   ;;
        esac
        state=已登記; [ -n "$cur" ] || state=未註冊
        report "$a" "$kind" "$state" "${cur:-install 時用 ${GITHUB_SOURCE:-GitHub$GITHUB_HINT}}" ;;
      plugin) report "$a" github 固定 "不記錄來源，一律從 ${GITHUB_SOURCE:-GitHub$GITHUB_HINT} 安裝" ;;
    esac
  done
}
