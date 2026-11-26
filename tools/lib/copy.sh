# shellcheck shell=bash
# lib/copy.sh — copy 模式（opencode 等直接複製）
# 由 tools/skills.sh 載入，沿用其設定的全域變數（REPO_ROOT、MARKETPLACE、SOURCE 等）；只定義函式與常數，不執行動作

# ════════════════ copy 模式 ════════════════
# 安裝與更新只有 opencode 走這裡；移除另供各家清除殘留副本。

# copy_install <agent> — 把選定的 skill 同步進該 agent 的 skills 目錄（SKILLS 未設＝全部）
# I/O：輸入 agent 代號；每個 skill 一行進度到 stdout；失敗累計至 FAILED
# DECISION: 用 rsync -a --delete 而非 cp -r——rsync 會把目的地多出來的舊檔一併刪除，
#           重跑即得到與 repo 完全一致的狀態；cp -r 會留下 repo 已刪除的殘檔
copy_install() {
  local agent="$1" dir s target
  dir="$(agent_skills_dir "$agent")" || return
  leftover_guard "$agent" || return

  # 目的地可能尚未建立（該 agent 從未裝過任何 skill）
  mkdir -p "$dir" || { echo "  ✗ ${agent}：無法建立 $dir" >&2; FAILED=1; return; }

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

    run "${agent}：$s → $dir" rsync -a --delete "$(skill_dir "$s")/" "$target/"
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
      run "${agent}：移除 ${s}（symlink）" rm -f "$target"
    elif [ -d "$target" ]; then
      run "${agent}：移除 $s" rm -rf "$target"
    fi
  done < <(target_skills)
}

# copy_update <agent> — 只同步已安裝的 skill；未安裝的略過
copy_update() {
  local agent="$1" s installed=""
  while IFS= read -r s; do
    if has_copy_of "$agent" "$s"; then installed+="$s "
    else printf '  [略過] %s：%s 未安裝\n' "$agent" "$s"; fi
  done < <(target_skills)
  [ -n "$installed" ] || return 0
  # SKILLS 為空代表全部，故上面先擋掉空清單
  local SKILLS="$installed"
  copy_install "$agent"
}
