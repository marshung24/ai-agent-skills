# shellcheck shell=bash
# lib/plugin.sh — plugin 模式（agy）
# 由 tools/skills.sh 載入，沿用其設定的全域變數（REPO_ROOT、MARKETPLACE、SOURCE 等）；只定義函式與常數，不執行動作

# ════════════════ plugin 模式（agy）════════════════
# 沒有 marketplace 可註冊，每個 skill 直接從來源安裝；agy 無 plugin update，更新即重裝。

# agy_plugin_target <skill> — 該 skill 交給 `agy plugin install` 的目標
# I/O：輸入 skill 名（讀全域 SOURCE）；輸出本機目錄或 GitHub 子目錄 URL 到 stdout
agy_plugin_target() {
  local src="${SOURCE%.git}"
  # 本機目錄優先判斷，其次 URL；其餘視為 owner/repo 簡寫
  if [ -d "$SOURCE" ]; then printf '%s/plugins/%s\n' "$(cd "$SOURCE" && pwd)" "$1"; return; fi
  case "$src" in *://*) ;; *) src="https://github.com/$src" ;; esac
  printf '%s/tree/main/plugins/%s\n' "$src" "$1"
}

# plugin_agy_install — 逐一安裝選定的 skill
# I/O：無參數（讀全域 SOURCE）；進度走 stdout；失敗累計至 FAILED
plugin_agy_install() {
  local p
  skip_missing agy agy && return
  leftover_guard agy || return
  while IFS= read -r p; do
    run "agy：安裝 $p" agy plugin install "$(agy_plugin_target "$p")"
  done < <(target_skills)
}

plugin_agy_remove() {
  local p
  skip_missing agy agy && return
  while IFS= read -r p; do
    if has_plugin agy "$p"; then
      run "agy：移除 $p" agy plugin uninstall "$p"
    else
      printf '  [略過] agy：%s 未安裝\n' "$p"
    fi
  done < <(target_skills)
}

# plugin_agy_update — 重裝已安裝的 skill；重裝會取代舊內容，保留停用狀態
plugin_agy_update() {
  local p
  skip_missing agy agy && return
  leftover_guard agy || return
  while IFS= read -r p; do
    if has_plugin agy "$p"; then
      run "agy：更新 $p" agy plugin install "$(agy_plugin_target "$p")"
    else
      printf '  [略過] agy：%s 未安裝\n' "$p"
    fi
  done < <(target_skills)
}
