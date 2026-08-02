#!/usr/bin/env bash
# advisor-list.sh — 列出「已啟用的外部顧問」及其呼叫方式（getter）
#
# 用途：呼叫端 AI 取得本次可用顧問範圍與正確呼叫式的唯一來源。
#       skill 內建的 adapter 是「支援」（scripts/ 下可執行的 ask-*.sh），
#       使用者實際擁有並願意使用的是「啟用」（設定檔），兩者不一定相同。
#
# I/O：
#   輸入  ─ 無參數
#   輸出  ─ stdout：已啟用顧問清單（名稱 + 開新/延續呼叫式 + 特例警語）；
#                   未啟用時改印引導文（含支援清單與 set 指令）
#           stderr：警告（設定檔格式不合、adapter 失效等）
#   結束碼─ 0 有已啟用顧問；4 尚未啟用任何顧問；127 缺依賴
#
# 用法：
#   advisor-list.sh

# 不用 set -e：未啟用（exit 4）是正常分支，不可讓非零結束碼直接中止
set -uo pipefail

# ── 路徑自解析：以腳本自身位置為準，不信任 cwd（輸出的呼叫式必須是絕對路徑）──
SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname -- "$SCRIPTS_DIR")"

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v jq >/dev/null || { echo "錯誤：找不到 jq（解析啟用清單需要）" >&2; exit 127; }
# 名稱驗證、支援掃描、設定檔讀取三條規則與 setter 共用，避免兩邊漂移
# shellcheck source=lib/enabled-io.sh
. "$SCRIPTS_DIR/lib/enabled-io.sh"

# ── 引導文：未啟用與「啟用項全數不可用」共用（兩者處置相同：請使用者重設）──
print_guide() {
  echo "$1"
  echo
  echo "本 skill 支援：$(join_names "${SUPPORTED[@]:-}")"
  echo
  echo "請使用者挑選其實際擁有的，例如："
  echo "  $SCRIPTS_DIR/advisor-set.sh ${SUPPORTED[0]:-<ai>}"
}

# ── Level 1 支援清單 ──
scan_supported

# ── Level 2 啟用清單（設定檔不存在、schema 不合、清單為空皆退化為未啟用）──
ENABLED=()
while IFS= read -r line; do
  [ -n "$line" ] && ENABLED+=("$line")
done < <(read_enabled)

if [ ${#ENABLED[@]} -eq 0 ]; then
  print_guide "尚未啟用任何外部顧問。"
  exit 4
fi

# ── 輸出：逐支取其自述（--info），{SELF} 換成絕對路徑 ──
# 描述文字由各 adapter 自己提供，本腳本只負責過濾與串接
OUT=""
COUNT=0
INFO_ERR="$(mktemp)"
trap 'rm -f "$INFO_ERR"' EXIT
for name in "${ENABLED[@]}"; do
  # 名稱先驗字元集、再與支援清單做精確集合比對，最後才組路徑——
  # 設定檔可能被 setter 以外的途徑寫入（手動編輯、同步工具、污損），
  # 若直接拿其內容組路徑去測 -f，等於讓設定檔內容決定要執行哪個檔案
  if ! valid_name "$name" || ! is_supported "$name"; then
    echo "[warn] 已啟用的「${name}」不在支援清單內，本次略過（請重跑 setter 清理）" >&2
    continue
  fi
  adapter="$SCRIPTS_DIR/ask-$name.sh"
  # --info 非零結束碼或無輸出即視為該支不可用：印出殘缺自述會讓呼叫端拿到錯誤呼叫式
  info="$("$adapter" --info 2>"$INFO_ERR")"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$info" ]; then
    { echo "[warn] ${name} 的 --info 取得失敗（exit ${rc}），本次略過。stderr 末幾行："
      tail -3 "$INFO_ERR"; } >&2
    continue
  fi
  OUT+="${info//\{SELF\}/$adapter}"$'\n\n'
  COUNT=$((COUNT + 1))
done

# 全部啟用項都取不到自述：等同無可用顧問，走引導分支而非印空清單
if [ "$COUNT" -eq 0 ]; then
  print_guide "已啟用的顧問目前皆不可用（詳見上方警告）。"
  exit 4
fi

printf '啟用的外部顧問（%s 支）：\n\n' "$COUNT"
printf '%s' "$OUT"
echo "輸出契約與錯誤分流見 ${SKILL_DIR}/references/detail.md"
