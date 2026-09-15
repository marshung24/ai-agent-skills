#!/usr/bin/env bash
# advisor-usage.sh — 顧問用量的營運診斷（唯讀）
#
# 用途：從 usage.log 讀出「節流器做了哪些決策、adapter 實際跑成什麼樣」，供調節流
#       參數與確認節流有擋到。🚫 不推論使用者習慣，也不自動建議參數——log 裡沒有
#       可接受的等待與政策目標，同一串連續呼叫既可讀成容量該調大，也可讀成正該擋。
#
# I/O：
#   輸入  ─ 選項 --advisor / --scope / --since / --json；資料源固定為 usage.log(.1)
#   輸出  ─ stdout：預設人類可讀摘要，--json 印同一組數字的 JSON
#   結束碼─ 0 成功；1 整份資料讀不到或解析不出；2 參數錯誤；4 查無資料；127 缺依賴
#           個別損壞行不影響結束碼，另計為 malformed_lines 並在報告中明示
#
# 三個分母不可互相代換，輸出一律分開標示：
#   throttle_decision  節流器做過決策（allow＋deny）
#   call_attempted     adapter 走到啟動顧問 CLI 這一步，🚫 不等於 prompt 已送達
#   call_finished      adapter 拿到結果並完成判定
# 往返確實完成的唯一證據是結束碼 0 的 call_finished；只有 decision 而沒有 finished
# 的 invocation ＝ 結果未知，🚫 不得計為成功或已送出。

set -uo pipefail

SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null || { echo "錯誤：找不到 jq（解析事件需要）" >&2; exit 127; }

# shellcheck source=lib/usage-log.sh
. "$SCRIPTS_DIR/lib/usage-log.sh"

usage() {
  echo "用法: $0 [選項]"
  echo "  --advisor <ai>    只看這支顧問"
  echo "  --scope <scope>   只看這個宣告 scope"
  echo "  --since <YYYY-MM-DD>  只看這天（含）以後"
  echo "  --json            輸出 JSON 而非文字摘要"
}

FILTER_AI=""; FILTER_SCOPE=""; SINCE=""; AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --advisor) FILTER_AI="${2:-}"; shift 2 || { echo "錯誤：--advisor 缺值" >&2; exit 2; } ;;
    --scope)   FILTER_SCOPE="${2:-}"; shift 2 || { echo "錯誤：--scope 缺值" >&2; exit 2; } ;;
    --since)   SINCE="${2:-}"; shift 2 || { echo "錯誤：--since 缺值" >&2; exit 2; } ;;
    --json)    AS_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "錯誤：未知選項「$1」" >&2; usage >&2; exit 2 ;;
  esac
done

[ -z "$SINCE" ] || [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
  || { echo "錯誤：--since 需為 YYYY-MM-DD" >&2; exit 2; }

# 讀取順序 .1 在前：兩份合起來才是時間上連續的一段，反過來接會讓時間窗口倒錯
SOURCES=()
[ -f "$USAGE_LOG.1" ] && SOURCES+=("$USAGE_LOG.1")
[ -f "$USAGE_LOG" ] && SOURCES+=("$USAGE_LOG")
[ "${#SOURCES[@]}" -gt 0 ] || { echo "查無用量資料（$USAGE_LOG）" >&2; exit 4; }

# 兩個檔案的指紋。讀取期間若發生輪替，已讀完的 .1 會被當前檔覆蓋，那一整段事件就
# 憑空消失在報告外——本工具唯讀、🚫 不取 writer 的鎖，只能靠前後比對偵測並重讀
snapshot_id() { stat -c '%i:%s:%Y' "$USAGE_LOG.1" "$USAGE_LOG" 2>/dev/null | paste -sd'|' -; }

RAW=""; SNAPSHOT_STABLE=1
for _try in 1 2 3; do
  _before="$(snapshot_id)"
  RAW="$(cat "${SOURCES[@]:-}" 2>/dev/null)"
  [ "$_before" = "$(snapshot_id)" ] && { SNAPSHOT_STABLE=1; break; }
  SNAPSHOT_STABLE=0
done

# ── 彙總 ────────────────────────────────────────────────────────────
#
# 一次 jq 走完全部統計：分開跑等於同一份檔案解析多次，也容易讓各區數字取樣到
# 不同時點的檔案內容（分析期間 adapter 仍可能在寫入）。
REPORT="$(printf '%s' "$RAW" | jq -Rs --arg ai "$FILTER_AI" \
  --arg scope "$FILTER_SCOPE" --arg since "$SINCE" --argjson stable "$SNAPSHOT_STABLE" '
  # scope 只出現在扣桶決策上，生命週期事件得靠 invocation_id 回推是否屬於本次篩選
  def in_scope($ids): ($scope == "") or ($ids[.invocation_id // ""] != null);

  split("\n") | map(select(length > 0)) as $lines

  # fromjson 失敗有兩種原因，🚫 不可混為一談：舊格式是設計上的既有資料，可安全略過；
  # 解析不了又不像舊格式的則是資料損壞，把它說成「舊資料」會讓人以為忽略無妨
  | ($lines | map(fromjson? // empty) | map(select(type == "object" and has("event")))) as $events
  | ($lines | length) as $total_lines
  | ($events | length) as $parsed
  # 舊格式的形狀：ISO 時戳 + 兩個空白 + label(pid)
  | ($lines | map(select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+  \\S+\\([0-9?]+\\)  "))) | length) as $legacy

  # advisor 與 since 每種事件都帶得動，直接濾——直接拿 declared_scope 比對生命週期
  # 事件會把它們整批濾掉，報出「已送出 0」這種假數字
  | ($events
      | map(select(($ai == "") or (.advisor == $ai)))
      | map(select(($since == "") or (.ts >= $since)))) as $base

  | ($base | map(select(.event == "throttle_decision"))
          | map(select(($scope == "") or (.declared_scope == $scope)))) as $dec
  # 用物件當集合而非 index()：後者對陣列是線性搜尋，兩邊各數千筆時會變成千萬次比對
  | ($dec | map(.invocation_id) | map(select(. != null)) | INDEX(.)) as $scope_ids

  | ($base | map(select(.event == "call_attempted")) | map(select(in_scope($scope_ids)))) as $started
  | ($base | map(select(.event == "call_finished"))  | map(select(in_scope($scope_ids)))) as $finished
  | ($base | map(select(.event == "reset")))         as $resets
  | ($dec + $started + $finished + $resets) as $e

  # 結果未知：扣桶放行了，但沒有對應的結束事件。adapter 在啟動 CLI 前中止、
  # 程序被 kill、或 log 寫入失敗都會落到這裡——它不是失敗，也不是成功
  | ($dec | map(select(.decision == "allow") | .invocation_id) | map(select(. != null))) as $allow_ids
  | ($finished | map(.invocation_id) | map(select(. != null)) | INDEX(.)) as $fin_ids
  | ($allow_ids | map(select($fin_ids[.] == null))) as $unknown_ids

  | {
      window: {
        parsed_events: $parsed,
        legacy_lines: $legacy,
        malformed_lines: ($total_lines - $parsed - $legacy),
        snapshot_stable: ($stable == 1),
        matched_events: ($e | length),
        first_ts: ($events | map(.ts) | min),
        last_ts:  ($events | map(.ts) | max),
        schema_versions: ($events | map(.v) | group_by(.) | map({key: (.[0]|tostring), value: length}) | from_entries)
      },
      throttle: {
        decisions: ($dec | length),
        allow: ($dec | map(select(.decision == "allow")) | length),
        deny:  ($dec | map(select(.decision == "deny"))  | length),
        by_source: ($dec | group_by(.source) | map({key: (.[0].source // "unknown"), value: length}) | from_entries),
        resets: ($resets | length),
        deny_detail: ($dec | map(select(.decision == "deny")
          | {ts, advisor, scope: .declared_scope, remaining_before, retry_after_seconds, source}))
      },
      calls: {
        attempted: ($started | length),
        finished: ($finished | length),
        round_trip_ok: ($finished | map(select(.adapter_exit_code == 0)) | length),
        unknown_outcome: ($unknown_ids | length),
        by_exit_code: ($finished | group_by(.adapter_exit_code)
          | map({key: (.[0].adapter_exit_code // "null" | tostring), value: length}) | from_entries),
        by_mode: ($started | group_by(.mode) | map({key: (.[0].mode // "unknown"), value: length}) | from_entries),
        duration_ms: (($finished | map(.duration_ms) | map(select(. != null)) | sort) as $d
          | if ($d | length) == 0 then null
            else {n: ($d|length), min: $d[0], p50: $d[(($d|length)/2|floor)], max: $d[-1]} end)
      },
      tuning: {
        by_advisor_scope: ($dec | group_by([.advisor, .declared_scope])
          | map({key: "\(.[0].advisor)/\(.[0].declared_scope)", value: length}) | from_entries),
        by_refill: ($dec | map(select(.refill_seconds != null)) | group_by(.refill_seconds)
          | map({key: "\(.[0].refill_seconds)s", value: length}) | from_entries),
        near_empty: ($dec | map(select(.decision == "allow" and .remaining_after != null
          and .cost != null and .remaining_after < .cost)) | length)
      },
      principals: ($dec | map(select(.principal != null))
        | group_by(.principal.comm)
        | map({ comm: (.[0].principal.comm // "unknown"),
                events: length,
                distinct_ids: (map(.principal.id) | unique | length),
                kinds: (map(.principal.kind) | unique) })
        | sort_by(-.events))
    }
  ' 2>/dev/null)"

[ -n "$REPORT" ] || { echo "錯誤：解析用量事件失敗" >&2; exit 1; }

if [ "$AS_JSON" -eq 1 ]; then printf '%s\n' "$REPORT" | jq .; exit 0; fi

# ── 文字報告 ────────────────────────────────────────────────────────
#
# 每一區都先講資料邊界再給數字：這份資料是 best effort telemetry，寫入失敗會被
# 靜默吞掉，把它當稽核帳本讀就會把「沒記到」誤讀成「沒發生」。
printf '%s' "$REPORT" | jq -r '
  def pct($n; $d): if $d == 0 then "—" else "\(($n * 1000 / $d | floor) / 10)%" end;
  def kv: to_entries | map("\(.key)=\(.value)") | join("  ");

  "═══ 資料品質與窗口 ═══",
  "  事件行數      \(.window.parsed_events)（另有 \(.window.legacy_lines) 行舊格式，未納入以下統計）",
  (if .window.malformed_lines > 0 then
    "  ⚠ 有 \(.window.malformed_lines) 行既非事件也非舊格式——資料損壞，相關統計會少算" else empty end),
  (if .window.snapshot_stable | not then
    "  ⚠ 讀取期間檔案發生輪替，重試後仍不穩定：本次報告可能少算一整段已輪替的事件" else empty end),
  "  納入統計      \(.window.matched_events)（套用 --advisor/--scope/--since 後）",
  "  時間窗口      \(.window.first_ts // "—") ～ \(.window.last_ts // "—")",
  "  schema 版本   \(.window.schema_versions | kv)",
  "  ⚠ 記錄為 best effort：寫入失敗會被靜默略過，缺事件不等於沒發生",
  "",
  "═══ 節流證據 ═══",
  "  決策數        \(.throttle.decisions)（allow \(.throttle.allow) / deny \(.throttle.deny)）",
  "  已記錄決策中的 deny 比例  \(pct(.throttle.deny; .throttle.decisions))",
  "  發起來源      \(.throttle.by_source | kv)",
  "  reset 次數    \(.throttle.resets)",
  (if (.throttle.deny_detail | length) > 0 then
    "  deny 明細：", (.throttle.deny_detail[] |
      "    \(.ts)  \(.advisor)/\(.scope)  before=\(.remaining_before // "—") retry_after=\(.retry_after_seconds // "—")s  來源=\(.source // "—")")
   else "  deny 明細：無" end),
  "",
  "═══ 呼叫結果 ═══",
  "  嘗試送出（call_attempted） \(.calls.attempted)  ← 只證明 adapter 走到啟動這一步",
  "  已完成（call_finished）    \(.calls.finished)",
  "  往返完成（結束碼 0）       \(.calls.round_trip_ok)  ← 本資料源唯一能證明送達的數字",
  "  結果未知                \(.calls.unknown_outcome)  ← 放行了但沒有結束事件，🚫 不計為成功或已送出",
  "  結束碼分布    \(.calls.by_exit_code | kv)",
  "  新開/延續     \(.calls.by_mode | kv)",
  (if .calls.duration_ms then
    "  耗時(ms)      n=\(.calls.duration_ms.n) min=\(.calls.duration_ms.min) p50=\(.calls.duration_ms.p50) max=\(.calls.duration_ms.max)"
   else "  耗時(ms)      無資料（需要 call_finished 事件）" end),
  "",
  "═══ 調參觀測 ═══",
  "  顧問/宣告scope  \(.tuning.by_advisor_scope | kv)",
  "  實際 refill 檔位 \(.tuning.by_refill | kv)",
  "  ⚠ refill 檔位由顧問剩餘額度決定，非隨機分派，🚫 不可用來比較各檔成效",
  "  放行後低於單次成本  \(.tuning.near_empty) 次",
  "",
  "═══ principal 分桶完整性 ═══",
  "  桶是按 principal 分的；同一個名字若每次都是新 PID，等於每次都拿到滿桶",
  (.principals[] |
    "  \(.comm)  事件=\(.events)  不同PID=\(.distinct_ids)  kind=\(.kinds | join(","))" +
    (if .events > 1 and .distinct_ids == .events then "  ⚠ 每次都是新 PID，結構上可繞過 burst 上限" else "" end))
'
