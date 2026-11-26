# shellcheck shell=bash
# lib/detect.sh — 現況偵測：已裝 plugin、marketplace 註冊、遺留與共用目錄
# 由 tools/skills.sh 載入，沿用其設定的全域變數（REPO_ROOT、MARKETPLACE、SOURCE 等）；只定義函式與常數，不執行動作

# ════════════════ 遺留偵測：另一種機制留下的東西會重複載入 ════════════════
#
# 每個 agent 只走一種方式，但「另一種機制的殘留」仍可能存在——舊版工具裝的、手動複製的、
# 或從別的來源裝的。各家都會同時載入 plugin 與自己的 skills 目錄，殘留即重複載入。
# 故 install 前偵測並擋下，remove 一律兩邊都掃，status 只在真的有東西時才多印一列。

# agy_plugin_names — agy 已安裝的 plugin 名（含停用中的）
# I/O：無參數；每行一個名稱到 stdout
agy_plugin_names() {
  local out
  out="$(agy plugin list --json 2>/dev/null)"
  # 舊版的 JSON 在不帶 --json 的輸出裡；沒有任何 plugin 時印純文字，jq 需吞錯
  jq -e . <<<"$out" >/dev/null 2>&1 || out="$(agy plugin list 2>/dev/null)"
  jq -r '(if type=="array" then . else .imports end)[]?.name' <<<"$out" 2>/dev/null
}

# codex_plugin_list — codex 上本 marketplace 的 plugin 表格（含未安裝者）
# I/O：無參數；`codex plugin list` 的表格輸出到 stdout
# DECISION: 未採不帶 --marketplace，因它會等遠端目錄，單次可達 60 秒以上
codex_plugin_list() {
  # 舊版 CLI 不認 --marketplace 會回非零，退回不帶旗標的慢查詢
  codex plugin list --marketplace "$MARKETPLACE" 2>/dev/null || codex plugin list 2>/dev/null
}

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
      have codex && codex_plugin_list \
        | awk -v p="$plugin@$MARKETPLACE" '$1==p { sub(/^[^ \t]+[ \t]+/, ""); print; exit }' \
        | grep -q '^installed'
      ;;
    agy)
      have agy && agy_plugin_names | grep -qxF "$plugin"
      ;;
    # opencode 的 plugin 不吃本 repo 的 manifest，永遠視為未安裝（與未知代號同路徑，但理由不同故獨立列出）
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
has_marketplace() { [ -n "$(marketplace_source "$1")" ]; }

# has_copy_of <agent> <skill> — 該 agent 的 skills 目錄是否有指定 skill（含斷鏈）
# I/O：輸入 agent 代號與 skill 名；無輸出；回 0 表示有
has_copy_of() {
  local dir; dir="$(agent_skills_dir "$1")" || return 1
  [ -e "$dir/$2" ] || [ -L "$dir/$2" ]
}

# installed_targets — 本次處理的 skill 中，至少裝在一家目標 agent 上的
# I/O：無參數（讀全域 TARGETS、SKILLS）；每行一個名稱到 stdout
installed_targets() {
  local s a
  while IFS= read -r s; do
    for a in $TARGETS; do
      have "$a" || continue
      if [ "$(agent_mode "$a")" = copy ]; then has_copy_of "$a" "$s"; else has_plugin "$a" "$s"; fi \
        && { printf '%s\n' "$s"; break; }
    done
  done < <(target_skills)
}

# dir_has_skills <目錄> [列舉函式] — 該目錄是否已有本 repo 的任一 skill
# I/O：輸入 skills 目錄路徑與列舉 skill 名的函式（預設 repo_skills）；無輸出；回 0 表示至少有一個
# 以 -e 或 -L 判斷：斷掉的 symlink 過不了 -e，但它同樣是「舊安裝的殘留」，必須算數
dir_has_skills() {
  local dir="$1" names="${2:-repo_skills}" s
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  while IFS= read -r s; do
    if [ -e "$dir/$s" ] || [ -L "$dir/$s" ]; then return 0; fi
  done < <("$names")
  return 1
}

# has_copy <agent> — 該 agent 的 skills 目錄是否已有本 repo 的任一 skill
# I/O：輸入 agent 代號；無輸出；回 0 表示至少有一個
has_copy() {
  local dir
  dir="$(agent_skills_dir "$1")" || return 1
  dir_has_skills "$dir"
}

# shared_dirs <agent> — 該 agent 除自己的目錄外，還會掃描哪些共用的全域 skills 目錄
# I/O：輸入 agent 代號；每行一個路徑到 stdout；沒有則輸出空
shared_dirs() {
  case "$1" in
    codex)    printf '%s/.agents/skills\n' "$HOME" ;;
    opencode) printf '%s/.claude/skills\n%s/.agents/skills\n' "$HOME" "$HOME" ;;
  esac
}

# shared_notice <agent> — 共用目錄有本次處理的同名 skill 時提醒；不擋、不刪、不影響結束碼
# I/O：輸入 agent 代號；有同名才印一行到 stdout
# DECISION: 未採擋下，因共用目錄非本工具所裝且擋下會連帶漏裝
shared_notice() {
  local agent="$1" d
  while IFS= read -r d; do
    dir_has_skills "$d" target_skills \
      && printf '  [注意] %s：%s 有同名 skill 也會被載入；該目錄為多家共用，本工具不動它\n' "$agent" "$d"
  done < <(shared_dirs "$agent")
  return 0
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
  elif [ "$mode" != copy ]; then
    # 本次走 marketplace／plugin → 殘留是 skills 目錄裡的副本
    has_copy "$agent" || return 0
    msg="$(agent_skills_dir "$agent") 已有本 repo 的 skill"
  else
    return 0   # copy 模式只剩 opencode，沒有另一種機制
  fi

  # FORCE 時仍執行，但必須留下警告——並存是有意識的選擇，不該事後看不出來
  if [ -n "$FORCE" ]; then
    printf '  [警告] %s：%s；FORCE=1 已略過偵測，同名 skill 會重複載入\n' "$agent" "$msg" >&2
    return 0
  fi

  # 預設中止，並直接給出可執行的出路，免得使用者還要回頭查文件
  {
    printf '  ✗ %s：%s，中止以免重複載入\n' "$agent" "$msg"
    printf '      remove 會把殘留一起清掉，清完再重裝：tools/skills.sh remove %s && tools/skills.sh install %s\n' "$agent" "$agent"
    printf '      或確定要並存：FORCE=1 ...\n'
  } >&2
  FAILED=1
  return 1
}
