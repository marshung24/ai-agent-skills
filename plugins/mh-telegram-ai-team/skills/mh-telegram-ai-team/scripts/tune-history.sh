#!/usr/bin/env bash
# 調整強化版 telegram plugin 的訊息歷史保存上限：改寫本機執行中的 server.ts 裡 prune() 的寫死數值
#
# 使用情境：歷史不夠回溯時放寬保存上限；官方 plugin 更新或重跑強化版安裝會蓋回原值，check-setup.sh 會提示重跑
# 目標值：每聊天室（每 bot）保留 5000 則、140 天；資料庫超過 500MB 時每聊天室縮到 2000 則
# 輸出：每項一行 `<項目> 目前=<值> 目標=<值>`；--apply 另回報是否改寫
# 結束碼：--check 時全數符合為 0、有不符為 1；--apply 成功為 0；找不到檔案或樣式不符為 3；參數錯誤為 2
# 依賴：awk、sed；改寫後須重開接 Telegram 的 session 才生效
#
# 用法：tune-history.sh [--check | --apply] [--file <server.ts>]
#   --check      只比對目前值與目標值（預設）
#   --apply      改寫為目標值，原檔備份為 server.ts.bak-history
#   --file <路徑>  指定 server.ts；預設為 cache 內版本號最大的官方 telegram plugin 目錄
#   -h, --help   顯示本說明
set -uo pipefail

usage() { awk 'NR == 1 { next } /^set -u/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

# 目標值：天數、每聊天室上限、資料庫門檻（MB）、超過門檻後的每聊天室上限
WANT_DAYS=140; WANT_KEEP=5000; WANT_MB=500; WANT_TRIM=2000

MODE=check; FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --apply) MODE=apply; shift ;;
    --file) [ -n "${2:-}" ] || { echo "--file 須帶路徑" >&2; exit 2; }; FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知參數：$1" >&2; usage >&2; exit 2 ;;
  esac
done

# 預設目標：與 check-setup.sh 同一判定，執行的是 cache 內版本號最大的目錄
if [ -z "$FILE" ]; then
  CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
  ver="$(ls "$CACHE_DIR" 2>/dev/null | sort -V | tail -n 1)"
  FILE="$CACHE_DIR/${ver:-?}/server.ts"
fi
[ -f "$FILE" ] || { echo "找不到 server.ts：$FILE" >&2; exit 3; }

# 讀現值：prune() 內四個寫死數值；每聊天室上限出現兩次，第一次為一般上限、第二次為超過門檻後的上限
read_values() {
  DAYS="$(sed -nE 's/.*Date\.now\(\) \/ 1000\) - ([0-9]+) \* 86400.*/\1/p' "$FILE")"
  MB="$(sed -nE 's/.*pageCount \* pageSize > ([0-9]+) \* 1024 \* 1024.*/\1/p' "$FILE")"
  COUNTS="$(sed -nE 's/.*m2\.date >= m\.date\) > ([0-9]+).*/\1/p' "$FILE")"
  KEEP="$(sed -n 1p <<<"$COUNTS")"; TRIM="$(sed -n 2p <<<"$COUNTS")"
}
read_values

# 樣式守門：每個數值須恰好找到一處（上限兩處），否則上游已改寫 prune()，不盲改
if [ "$(wc -l <<<"$DAYS")" -ne 1 ] || [ "$(wc -l <<<"$MB")" -ne 1 ] || [ "$(wc -l <<<"$COUNTS")" -ne 2 ] \
   || [ -z "$DAYS" ] || [ -z "$MB" ] || [ -z "$KEEP" ] || [ -z "$TRIM" ]; then
  echo "prune() 樣式與預期不符，可能是上游改版；請人工檢查：$FILE" >&2
  exit 3
fi

report() {
  echo "檔案：$FILE"
  echo "保存天數 目前=$DAYS 目標=$WANT_DAYS"
  echo "每聊天室上限 目前=$KEEP 目標=$WANT_KEEP"
  echo "資料庫門檻MB 目前=$MB 目標=$WANT_MB"
  echo "超過門檻後上限 目前=$TRIM 目標=$WANT_TRIM"
}
matches() { [ "$DAYS" = "$WANT_DAYS" ] && [ "$KEEP" = "$WANT_KEEP" ] && [ "$MB" = "$WANT_MB" ] && [ "$TRIM" = "$WANT_TRIM" ]; }

if [ "$MODE" = check ]; then
  report
  if matches; then echo "全數符合"; exit 0; fi
  echo "不符；改寫：$0 --apply，再重開接 Telegram 的 session"
  exit 1
fi

# 改寫：已符合就不動；否則備份後逐項替換，兩處上限依出現順序分別替換
if matches; then report; echo "已是目標值，未改寫"; exit 0; fi
cp -p "$FILE" "$FILE.bak-history"
TMP="$(mktemp)"
sed -E "s/(Date\.now\(\) \/ 1000\) - )[0-9]+( \* 86400)/\1$WANT_DAYS\2/; s/(pageCount \* pageSize > )[0-9]+( \* 1024 \* 1024)/\1$WANT_MB\2/" "$FILE" \
  | awk -v keep="$WANT_KEEP" -v trim="$WANT_TRIM" '
      /m2\.date >= m\.date\) > [0-9]+/ { n++; sub(/m2\.date >= m\.date\) > [0-9]+/, "m2.date >= m.date) > " (n == 1 ? keep : trim)) }
      { print }' > "$TMP" && cat "$TMP" > "$FILE"
rm -f "$TMP"

read_values; report
if matches; then echo "已改寫（備份：$FILE.bak-history）；重開接 Telegram 的 session 後生效"; exit 0; fi
echo "改寫後仍不符，已還原備份" >&2
cp -p "$FILE.bak-history" "$FILE"
exit 3
