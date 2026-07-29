#!/usr/bin/env bash
# advisor-set.sh — 設定「已啟用的外部顧問」清單（setter）
#
# 用途：把使用者實際擁有並願意使用的 AI 寫進耐久設定檔，供 advisor-list.sh 讀取。
#       啟用哪幾支是使用者的決定，本腳本只負責寫入，不代為判斷。
#
# DECISION: 驗支援清單（scripts/ 下可執行的 ask-<name>.sh）但不驗 CLI 是否已安裝——
#           「啟用」是宣告擁有/想用，安裝與否由各 adapter 執行時以 exit 127 擋；
#           在此擋會讓「先設定、之後再裝」變得不可能。
#
# 注意：本腳本為 read-modify-write，**不可並行執行**（無鎖，交錯執行會互相覆蓋）。
#       不加鎖是刻意取捨：lock 目錄在強殺後殘留會永久卡住 setter，
#       比競態更糟，而本腳本是使用者偶爾手動跑一次的設定指令。
#
# I/O：
#   輸入  ─ <ai>...        覆寫整份清單（冪等，重跑不會疊加）
#           --add <ai>...     加入指定顧問
#           --remove <ai>...  移除指定顧問
#           --clear           清空清單
#   輸出  ─ stdout：寫入後的清單；stderr：錯誤
#   結束碼─ 0 成功；2 參數錯誤（含不支援的顧問名）；127 缺依賴
#
# 用法：
#   advisor-set.sh codex claude      # 覆寫全清單
#   advisor-set.sh --add agy         # 加一支
#   advisor-set.sh --remove claude   # 移除一支
#   advisor-set.sh --clear           # 清空

set -uo pipefail

# ── 路徑自解析：以腳本自身位置為準，不信任 cwd ──
SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v jq >/dev/null || { echo "錯誤：找不到 jq（讀寫啟用清單需要）" >&2; exit 127; }
# 名稱驗證、支援掃描、設定檔讀取三條規則與 getter 共用，避免兩邊漂移
# shellcheck source=lib/enabled-io.sh
. "$SCRIPTS_DIR/lib/enabled-io.sh"

usage() {
  cat >&2 <<EOF
用法:
  $0 <ai>...           覆寫整份啟用清單
  $0 --add <ai>...     加入指定顧問
  $0 --remove <ai>...  移除指定顧問
  $0 --clear           清空啟用清單
EOF
}

# 名稱驗證：字元集 + 支援清單，兩關都要過才可寫入
validate_name() {
  local name="$1"
  if ! valid_name "$name"; then
    echo "錯誤：顧問名格式不合法（僅允許小寫英數與連字號）：$name" >&2
    exit 2
  fi
  if ! is_supported "$name"; then
    echo "錯誤：本 skill 不支援 ${name}（支援：$(join_names "${SUPPORTED[@]:-}")）" >&2
    exit 2
  fi
}

# ── 寫入：原子寫（同目錄 tmp + mv），避免中途失敗留下半份清單 ──
write_list() {
  mkdir -p "$ADVISOR_CONFIG_DIR" || { echo "錯誤：無法建立設定目錄 ${ADVISOR_CONFIG_DIR}" >&2; exit 1; }
  local tmp
  tmp="$(mktemp "$ADVISOR_CONFIG_DIR/.enabled.XXXXXX")" || { echo "錯誤：無法建立暫存檔" >&2; exit 1; }
  # 去重並保序：先到先留，同名只留一份（不用 unique——它會改成字典序）
  printf '%s\n' "$@" | jq -Rrs 'split("\n") | map(select(. != ""))
    | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)
    | {version: 1, enabled: .}' >"$tmp" || {
      rm -f "$tmp"; echo "錯誤：清單序列化失敗" >&2; exit 1; }
  mv "$tmp" "$ADVISOR_CONFIG" || { rm -f "$tmp"; echo "錯誤：寫入 ${ADVISOR_CONFIG} 失敗" >&2; exit 1; }
}

# ── Level 1 支援清單 ──
scan_supported

# ── 參數解析：四種模式互斥，第一個參數即決定模式 ──
# 選項模式（--add/--remove/--clear）要 shift 掉模式旗標；
# 覆寫模式不 shift——第一個參數本身就是顧問名，"$@" 即完整清單
[ $# -gt 0 ] || { usage; exit 2; }

MODE=""
case "${1:-}" in
  --add)     MODE="add";    shift ;;
  --remove)  MODE="remove"; shift ;;
  --clear)   MODE="clear";  shift ;;
  --help|-h) usage; exit 0 ;;
  -*) echo "錯誤：未知選項 $1" >&2; usage; exit 2 ;;
  *)  MODE="set" ;;   # 非選項開頭＝顧問名，走覆寫模式（不 shift）
esac

# clear 之外的模式都需要至少一個顧問名
if [ "$MODE" != "clear" ] && [ $# -eq 0 ]; then
  echo "錯誤：缺少顧問名" >&2; usage; exit 2
fi
if [ "$MODE" = "clear" ] && [ $# -ne 0 ]; then
  echo "錯誤：--clear 不接受額外參數" >&2; exit 2
fi

# ── 組出目標清單 ──
# add/remove 讀既有清單：read_enabled 已濾掉 schema 不合的內容，
# 這裡再濾一次支援清單——adapter 被移除後，其名稱可能仍留在設定檔裡
RESULT=()
case "$MODE" in
  set)
    for n in "$@"; do validate_name "$n"; RESULT+=("$n"); done
    ;;
  add)
    for n in "$@"; do validate_name "$n"; done
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if is_supported "$line"; then
        RESULT+=("$line")
      else
        echo "[warn] 既有清單中的「${line}」已無對應 adapter，本次一併清除" >&2
      fi
    done < <(read_enabled)
    RESULT+=("$@")
    ;;
  remove)
    for n in "$@"; do
      if ! valid_name "$n"; then
        echo "錯誤：顧問名格式不合法：$n" >&2; exit 2
      fi
    done
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # 本次指定移除的：直接丟棄（使用者自己下的指令，不需警告）
      keep=1
      for n in "$@"; do [ "$line" = "$n" ] && keep=0; done
      # 未被指定、但已無對應 adapter 的殘留名稱：一併清除並警告（與 --add 同行為）
      if [ "$keep" -eq 1 ] && ! is_supported "$line"; then
        echo "[warn] 既有清單中的「${line}」已無對應 adapter，本次一併清除" >&2
        keep=0
      fi
      [ "$keep" -eq 1 ] && RESULT+=("$line")
    done < <(read_enabled)
    ;;
  clear)
    RESULT=()
    ;;
esac

# ── 寫檔並回報結果 ──
if [ ${#RESULT[@]} -eq 0 ]; then
  write_list
  echo "啟用清單已清空（${ADVISOR_CONFIG}）"
  echo "尚未啟用任何顧問，諮詢前需先設定。"
else
  write_list "${RESULT[@]}"
  echo "已啟用的外部顧問（${ADVISOR_CONFIG}）："
  jq -r '.enabled[] | "  - " + .' "$ADVISOR_CONFIG"
fi
