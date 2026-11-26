# shellcheck shell=bash
# lib/validate.sh — validate 子命令：離線檢查 manifest 與 plugin 結構
# 由 tools/skills.sh 載入，沿用其設定的全域變數（REPO_ROOT、MARKETPLACE、SOURCE 等）；只定義函式與常數，不執行動作

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
      run "agy plugin validate（${sk}）" agy plugin validate "$(plugin_dir "$sk")"
    done < <(repo_skills)
  fi
}
