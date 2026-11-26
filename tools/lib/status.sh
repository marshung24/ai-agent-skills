# shellcheck shell=bash
# lib/status.sh — status 子命令：逐 agent、逐 skill 的安裝狀態
# 由 tools/skills.sh 載入，沿用其設定的全域變數（REPO_ROOT、MARKETPLACE、SOURCE 等）；只定義函式與常數，不執行動作

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
    codex)  codex_plugin_list | grep -F "$plugin@$MARKETPLACE" \
              | head -1 | sed -E 's/^\S+\s+//; s/\s{2,}.*$//' | tr -d '\n' ;;
  esac
}

# agy_plugin_state <skill> — 單一 plugin 在 agy 的安裝狀態
# I/O：輸入 skill 名；輸出狀態碼到 stdout（不含換行），碼同 copy_state
agy_plugin_state() {
  local state
  has_plugin agy "$1" || { printf -- '-'; return; }
  state="$(copy_state "$HOME/.gemini/config/plugins/$1/skills" "$1")"
  # 有登記卻沒有檔案：仍算已安裝，否則 remove 前看不見
  [ "$state" = "-" ] && state='✗缺檔'
  printf '%s' "$state"
}

# agent_detail <agent> — 該 agent 逐 skill 的狀態字串
# I/O：輸入 agent 代號；輸出「<skill>=<狀態> ...」到 stdout；一個都沒裝時輸出空字串
# 各種模式在此收斂成同一種呈現：都是「哪些 skill 裝了、各自什麼狀態」
agent_detail() {
  local agent="$1" mode dir s state out=""
  mode="$(agent_mode "$agent")" || return
  dir="$(agent_skills_dir "$agent")"
  while IFS= read -r s; do
    case "$mode" in
      marketplace) state="$(marketplace_state "$agent" "$s")" ;;
      plugin)      state="$(agy_plugin_state "$s")" ;;
      *)           state="$(copy_state "$dir" "$s")" ;;
    esac
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
    if [ "$mode" != copy ]; then report "$agent" "$mode" 未安裝 "$(agent_source "$agent")"
    else                         report "$agent" "$mode" 未安裝 "$(agent_skills_dir "$agent")"; fi
  fi

  # 已登記的來源：GitHub 與本機工作目錄可互相切換，只看版本號分不出裝的是哪邊
  if [ "$mode" = marketplace ]; then
    detail="$(marketplace_source "$agent")"
    [ -n "$detail" ] && report "$agent" 來源 已登記 "$detail"
  fi

  # 已下架但仍裝著的舊 plugin：一裝就是全部 skill，且 codex 上完全看不見
  legacy="$(installed_legacy "$agent" | tr '\n' ' ')"
  [ -n "${legacy// /}" ] && report "$agent" 已下架 ⚠遺留 "${legacy% }：仍會載入全部 skill，建議移除"

  # 另一種機制的殘留：只在真的有東西時才現身
  if [ "$mode" != copy ]; then
    detail="$(copy_detail "$agent")"
    [ -n "$detail" ] && report "$agent" copy ⚠遺留 "$(agent_skills_dir "$agent")：$detail"
  fi

  # 另列它從共用目錄掃到的來源——只看自己的目錄會誤判為「沒裝」，
  # 但實際上 skill 早就載入了，這一列正是決定「要不要再裝一次」的依據
  while IFS= read -r detail; do
    dir_has_skills "$detail" && report "$agent" 共用 已掃到 "$detail"
  done < <(shared_dirs "$agent")
}

# copy_detail <agent> — copy 目錄逐 skill 的狀態字串（供 marketplace／plugin 模式的殘留列使用）
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
