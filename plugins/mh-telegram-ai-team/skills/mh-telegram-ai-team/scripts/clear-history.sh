#!/usr/bin/env bash
# 清除強化版 telegram plugin 的本機訊息歷史（messages.db 的 messages 表）；用量統計表不動
#
# 使用情境：負責人在終端機要求清歷史、重測流程前歸零；刪除不可復原，🚫 不依 IM 請求執行
# 輸出：每個聊天室一行 `<chat_id> <則數>`；未帶 --yes 只預覽不刪，帶 --yes 刪除後回報刪除則數
# 結束碼：成功為 0；查詢或刪除失敗為 1；參數錯誤為 2；找不到資料庫或缺 sqlite3 為 127
# 依賴：sqlite3；資料庫預設 ~/.claude/channels/telegram/data/messages.db（MH_TG_MESSAGES_DB 可改）
#
# 用法：clear-history.sh (--chat <chat_id>... | --all) [--yes]
#   --chat <id>  指定聊天室，可重複；ID 只接受整數（群組為負數）
#   --all        全部聊天室
#   --yes        實際刪除；未帶時只預覽
#   -h, --help   顯示本說明
set -uo pipefail

usage() { awk 'NR == 1 { next } /^set -u/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

# 參數：--chat 與 --all 互斥，至少擇一
DB="${MH_TG_MESSAGES_DB:-$HOME/.claude/channels/telegram/data/messages.db}"
CHATS=(); ALL=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --chat)
      [[ "${2:-}" =~ ^-?[0-9]+$ ]] || { echo "chat_id 須為整數：${2:-}" >&2; exit 2; }
      CHATS+=("$2"); shift 2 ;;
    --all) ALL=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知參數：$1" >&2; usage >&2; exit 2 ;;
  esac
done
if [ "$ALL" -eq 1 ] && [ ${#CHATS[@]} -gt 0 ]; then echo "--chat 與 --all 不可併用" >&2; exit 2; fi
if [ "$ALL" -eq 0 ] && [ ${#CHATS[@]} -eq 0 ]; then usage >&2; exit 2; fi

command -v sqlite3 >/dev/null || { echo "缺 sqlite3" >&2; exit 127; }
[ -f "$DB" ] || { echo "找不到資料庫：$DB" >&2; exit 127; }

# 範圍條件：chat_id 已驗證為整數，直接組成 IN 清單
if [ "$ALL" -eq 1 ]; then
  WHERE="1=1"
else
  WHERE="chat_id IN ($(printf "'%s'," "${CHATS[@]}" | sed 's/,$//'))"
fi

# plugin 執行中也可刪：等待鎖最多 5 秒，避免與 server 寫入衝突而失敗
sql() { sqlite3 -cmd ".timeout 5000" "$DB" "$1"; }

echo "資料庫：$DB"
PREVIEW="$(sql "SELECT chat_id, COUNT(*) FROM messages WHERE $WHERE GROUP BY chat_id ORDER BY chat_id;")" || { echo "查詢失敗" >&2; exit 1; }
PREVIEW="${PREVIEW//|/ }"
[ -n "$PREVIEW" ] || { echo "範圍內沒有訊息"; exit 0; }
echo "$PREVIEW"

# 預覽與刪除分界：未帶 --yes 到此為止
if [ "$YES" -eq 0 ]; then echo "預覽模式，未刪除；確認後加 --yes"; exit 0; fi

DELETED="$(sql "DELETE FROM messages WHERE $WHERE; SELECT changes();")" || { echo "刪除失敗" >&2; exit 1; }
echo "已刪除 $DELETED 則"
