#!/usr/bin/env bash
# advisor-quota.sh — 查詢外部顧問的訂閱額度餘量（只查額度，不諮詢）
#
# 用途：讓呼叫端 AI 在追加諮詢前先知道各顧問還剩多少額度窗，據以決定
#       繼續追問、改問另一支或停手。走各 CLI 官方的非互動額度介面，
#       不讀其私有 session log，也不啟動任何對話輪次。
#
# I/O：
#   輸入  ─ 無參數：查已啟用的全部顧問；帶 <ai>… 則只查指定的（須在支援清單內）
#           --min-remain：改印機器可讀的單一數字（見下），供腳本取用
#   輸出  ─ stdout：逐支的額度窗餘量與重置時間；不支援者明示不支援
#           --min-remain 模式：只印所有查得額度窗中的**最小**剩餘百分比（整數），無其他文字
#           stderr：警告（查詢失敗、輸出格式不符預期等，一律 [warn] 前綴）
#   結束碼─ 0 至少一支查得餘量；1 全數查不到或皆不支援；2 參數錯誤；
#           4 尚未啟用任何顧問；127 缺依賴
#
# 用法：
#   advisor-quota.sh                        # 已啟用的全部
#   advisor-quota.sh codex agy              # 指定幾支
#   advisor-quota.sh --min-remain codex     # 只印最小剩餘百分比（供節流等機器取用）

# 不用 set -e：單支查詢失敗是正常分支（其餘支仍要查完），不可讓非零結束碼直接中止
set -uo pipefail

# ── 路徑自解析：以腳本自身位置為準，不信任 cwd ──
SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── 前置檢查：依賴不存在時立即明確報錯 ──
command -v jq >/dev/null || { echo "錯誤：找不到 jq（解析各 CLI 的額度輸出需要）" >&2; exit 127; }
# 逾時執行器：缺它就沒有「CLI 卡住」的止血點，故列為硬依賴而非降級執行。
# macOS 的 GNU coreutils 裝成 gtimeout，兩者皆無才報缺依賴（--kill-after 需 GNU 版）
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout)" \
  || { echo "錯誤：找不到 timeout（GNU coreutils；macOS 安裝後為 gtimeout）" >&2; exit 127; }
# 名稱驗證與啟用清單讀取與 getter/setter 共用同一套規則，避免三邊漂移
# shellcheck source=lib/enabled-io.sh
. "$SCRIPTS_DIR/lib/enabled-io.sh"

# 單支查詢的逾時上限：額度查詢不含模型推論，逾此即視為 CLI 卡住
TIMEOUT=30

# 各支的暫存輸出與 codex 用的 fifo 統一放這裡，逾時或中斷也不殘留
# DECISION: 未採 mktemp -u 產名再建 fifo，因該寫法可被搶先佔名
TMPD="$(mktemp -d)" || { echo "錯誤：無法建立暫存目錄" >&2; exit 127; }
trap 'rm -rf "$TMPD"' EXIT

# ── 說明與參數解析 ──
usage() {
  echo "用法: $0 [--min-remain] [<ai>...]"
  echo "  無參數：查已啟用的全部顧問；可一次帶多支，只查指定的那幾支"
  echo "  --min-remain：只印所有查得額度窗中最小的剩餘百分比（整數），供腳本取用"
}
# 取最小而非平均或首個：最緊的那個窗才是實際可用量——7 天窗還很滿、5 小時窗已見底時，
# 用其他取法會高估餘量
MIN_MODE=0
if [ "${1:-}" = "--min-remain" ]; then MIN_MODE=1; shift; fi
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -*) echo "錯誤：未知選項「$1」" >&2; usage >&2; exit 2 ;;
esac

scan_supported

# 同名只查一次：參數與設定檔都可能重複，重查徒增呼叫也拿不到新資訊
TARGETS=()
add_target() {
  local n
  for n in "${TARGETS[@]:-}"; do [ "$n" = "$1" ] && return 0; done
  TARGETS+=("$1")
}

# 查詢對象：有指名就用指名的（只驗支援清單，明確點名者不要求已在啟用清單）
if [ $# -gt 0 ]; then
  for name in "$@"; do
    if ! valid_name "$name" || ! is_supported "$name"; then
      echo "錯誤：不支援的顧問名「${name}」（支援：$(join_names "${SUPPORTED[@]:-}")）" >&2
      exit 2
    fi
    add_target "$name"
  done
else
  while IFS= read -r line; do
    [ -n "$line" ] && add_target "$line"
  done < <(read_enabled)
  if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "尚未啟用任何外部顧問。"
    echo
    echo "本 skill 支援：$(join_names "${SUPPORTED[@]:-}")"
    echo
    echo "請使用者挑選其實際擁有的，例如："
    echo "  $SCRIPTS_DIR/advisor-set.sh ${SUPPORTED[0]:-<ai>}"
    exit 4
  fi
fi

# ── 共用小工具 ──

# epoch 秒轉可讀時間；date 不支援 -d @ 時退回原值，不因格式化失敗丟掉資訊
fmt_epoch() {
  date -d "@$1" '+%Y-%m-%d %H:%M %z' 2>/dev/null || printf '%s' "$1"
}

# 分鐘轉窗口名：codex 只給窗長，需自行命名才看得懂是 5 小時窗還是週窗
fmt_window() {
  case "$1" in
    300)   printf '5 小時窗' ;;
    10080) printf '7 天窗' ;;
    *)     printf '%s 分鐘窗' "$1" ;;
  esac
}

# 印一個額度窗：統一表述為「剩餘百分比」，各 CLI 的已用／剩餘差異在呼叫端消化
MIN_REMAIN=""
put_window() {
  local label="$1" remain="$2" reset="$3"
  # 各 CLI 的百分比可能帶小數，bash 不做浮點比較，交給 awk
  if [ -z "$MIN_REMAIN" ] || awk -v a="$remain" -v b="$MIN_REMAIN" 'BEGIN{exit !(a+0 < b+0)}'; then
    MIN_REMAIN="$remain"
  fi
  [ "$MIN_MODE" -eq 1 ] && return 0
  if [ -n "$reset" ]; then
    printf '  %s：剩 %s%%（重置 %s）\n' "$label" "$remain" "$reset"
  else
    printf '  %s：剩 %s%%\n' "$label" "$remain"
  fi
}

# ── 各顧問的額度查詢：函式名即支援判準（quota_<ai> 不存在＝該支不支援）──

# codex：app-server 的 JSON-RPC account/rateLimits/read（官方協定，非私有 log）
# stdin 一旦 EOF，app-server 會在回應前直接結束，故以 fifo 持有寫端保持連線
quota_codex() {
  local ififo ofifo err resp W pid srv_rc rc=1 line win row remain mins reset primary secondary plan credits
  ififo="$TMPD/codex.in"; ofifo="$TMPD/codex.out"; err="$TMPD/codex.err"
  rm -f "$ififo" "$ofifo"
  mkfifo "$ififo" "$ofifo" || return 1
  exec {W}<>"$ififo"
  # server 必須關掉繼承來的寫端（{W}>&-）：留著就等不到 stdin EOF，收工後會孤兒化
  # 存活到 timeout；--kill-after 另防它不理會 SIGTERM
  "$TIMEOUT_BIN" --kill-after=5s "$TIMEOUT" codex app-server <"$ififo" >"$ofifo" 2>"$err" {W}>&- &
  pid=$!
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"mh_external_advisor","title":"mh-external-advisor","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}' >&"$W"
  # 認 JSON 的 .id 而非字串片段：夾雜的通知不帶 id，而 "id": 2 的空白變體
  # 會漏判、"id":20 會誤判。收到回應即關寫端讓 server 收 EOF 自行結束，但**續讀到 EOF**
  # 才收工：提前停讀會讓它寫後續通知時吃 EPIPE，結束碼就無法再代表「是否正常結束」
  while IFS= read -r line; do
    [ -n "${resp:-}" ] && continue
    if printf '%s' "$line" | jq -e 'type == "object" and .id == 2' >/dev/null 2>&1; then
      resp="$line"; exec {W}>&-
    fi
  done <"$ofifo"
  # 未收到回應時寫端仍開著，補關以免 wait 卡到 timeout
  [ -n "${resp:-}" ] || exec {W}>&-
  # server 已關 stdout，wait 取其真實結束碼並順帶回收；不主動 kill——kill 過的結束碼
  # 只反映我們自己下的訊號，無法拿來判斷輸出可不可信
  wait "$pid"; srv_rc=$?

  # CLI 非零即不採信其輸出（與 ask-*.sh 同原則）：半截或殘缺輸出仍可能通過欄位檢查
  if [ "$srv_rc" -ne 0 ]; then
    { echo "[warn] codex 額度查詢失敗（app-server 結束碼 ${srv_rc}）。stderr 末幾行："
      tail -3 "$err"; } >&2
  elif [ -n "${resp:-}" ] && printf '%s' "$resp" | jq -e '.result.rateLimits' >/dev/null 2>&1; then
    # 先驗型別與 0–100 範圍再換算：超界值換算後會印出負數或大於 100 的假餘量
    win='select((.usedPercent | type) == "number" and .usedPercent >= 0 and .usedPercent <= 100)
      | "\((100 - .usedPercent) | round)\t\(.windowDurationMins)\t\(.resetsAt)"'
    primary="$(printf '%s' "$resp" | jq -r ".result.rateLimits.primary // empty | $win")"
    secondary="$(printf '%s' "$resp" | jq -r ".result.rateLimits.secondary // empty | $win")"
    for row in "$primary" "$secondary"; do
      [ -n "$row" ] || continue
      IFS=$'\t' read -r remain mins reset <<<"$row"
      put_window "$(fmt_window "$mins")" "$remain" "$(fmt_epoch "$reset")"
      rc=0
    done
    plan="$(printf '%s' "$resp" | jq -r '.result.rateLimits.planType // empty')"
    [ -n "$plan" ] && printf '  方案：%s\n' "$plan"
    # 重置券是 codex 特有的救命資源，額度吃緊時會影響「還能不能再問」的判斷
    credits="$(printf '%s' "$resp" | jq -r '.result.rateLimitResetCredits.availableCount // 0')"
    [ "$credits" -gt 0 ] 2>/dev/null && printf '  額度重置券：%s 張可用\n' "$credits"
  else
    { echo "[warn] codex 額度查詢失敗（app-server 無 account/rateLimits/read 回應）。stderr 末幾行："
      tail -3 "$err"; } >&2
  fi
  return "$rc"
}

# claude：print 模式執行內建的 /usage，回覆是純文字報告，需逐行抽百分比
# DECISION: 未採免互動核可旗標，因額度查詢不執行任何工具
quota_claude() {
  local out err rc=1 crc line label used reset
  out="$TMPD/claude.out"; err="$TMPD/claude.err"
  "$TIMEOUT_BIN" "$TIMEOUT" claude -p --output-format json '/usage' >"$out" 2>"$err"
  crc=$?
  # CLI 非零即不採信其輸出（與 ask-*.sh 同原則）：殘缺輸出仍可能通過下方欄位檢查
  if [ "$crc" -ne 0 ]; then
    { echo "[warn] claude 額度查詢失敗（CLI 結束碼 ${crc}）。stderr 末幾行："
      tail -3 "$err"; } >&2
    return 1
  fi
  # num_turns 非 0 代表 /usage 沒被當內建命令、而是當 prompt 送進模型：
  # 此時 .result 是模型編出來的說法，不可當額度，且已白費一次額度
  if ! jq -e '.is_error == false and .num_turns == 0' "$out" >/dev/null 2>&1; then
    { echo "[warn] claude 額度查詢失敗（/usage 未被當成內建命令執行，回覆不可信）。stderr 末幾行："
      tail -3 "$err"; } >&2
    return 1
  fi
  # 報告每行形如「Current session: 23% used · resets Sep 1, 7:49pm (Asia/Taipei)」
  while IFS= read -r line; do
    # 整行錨定「標籤: N% used[ · resets …]」並驗 0–100：報告其他段落也會出現百分比，
    # 只驗行首會讓「23% used」後接任意文字的非額度行也被採信
    [[ "$line" =~ ^([^:]+):[[:space:]]+([0-9]{1,3})%[[:space:]]+used([[:space:]]+·[[:space:]]+resets[[:space:]]+.+)?$ ]] || continue
    label="${BASH_REMATCH[1]}"; used="${BASH_REMATCH[2]}"
    [ "$used" -le 100 ] || continue
    reset="$(printf '%s' "$line" | sed -n 's/.*resets \(..*\)$/\1/p')"
    put_window "$label" "$((100 - used))" "$reset"
    rc=0
  done < <(jq -r '.result // empty' "$out")
  # 版本更動報告格式時，寧可明說抽不到也不要靜默回報「無額度資訊」
  [ "$rc" -eq 0 ] || echo "[warn] claude 額度查詢：/usage 報告中找不到百分比欄位（格式可能已改）" >&2
  return "$rc"
}

# agy：print 模式執行內建的 /usage，額度以結構化欄位回在 .command.data
# DECISION: 未採免互動核可旗標，因額度查詢不執行任何工具
quota_agy() {
  local out err rc=1 crc label remain reset
  out="$TMPD/agy.out"; err="$TMPD/agy.err"
  "$TIMEOUT_BIN" "$TIMEOUT" agy --output-format json -p '/usage' >"$out" 2>"$err"
  crc=$?
  # CLI 非零即不採信其輸出（與 ask-*.sh 同原則）：殘缺輸出仍可能通過下方欄位檢查
  if [ "$crc" -ne 0 ]; then
    { echo "[warn] agy 額度查詢失敗（CLI 結束碼 ${crc}）。stdout 的 .error 與 stderr 末幾行："
      jq -r '.error // empty' "$out" 2>/dev/null; tail -3 "$err"; } >&2
    return 1
  fi
  # 認 command.name＝確認走的是內建命令而非模型推論（理由同 claude 的 num_turns 檢查）
  if ! jq -e '.status == "SUCCESS" and .command.name == "usage"' "$out" >/dev/null 2>&1; then
    { echo "[warn] agy 額度查詢失敗（/usage 未被當成內建命令執行）。stdout 的 .error 與 stderr 末幾行："
      jq -r '.error // empty' "$out" 2>/dev/null; tail -3 "$err"; } >&2
    return 1
  fi
  while IFS=$'\t' read -r label remain reset; do
    [ -n "$label" ] || continue
    put_window "$label" "$remain" "$reset"
    rc=0
  done < <(jq -r '.command.data.groups[]? as $g | $g.buckets[]?
    | select((.remaining_fraction | type) == "number"
             and .remaining_fraction >= 0 and .remaining_fraction <= 1)
    | "\($g.name) / \(.name)\t\(.remaining_fraction * 100 | round)\t\(.reset_time // "")"' "$out")
  [ "$rc" -eq 0 ] || echo "[warn] agy 額度查詢：/usage 回應中沒有任何額度窗（格式可能已改）" >&2
  return "$rc"
}

# ── 主流程：逐支查詢，單支失敗只警告不中斷 ──
OK=0
# --min-remain 只要一個數字：把人類可讀輸出整段導掉，比在每個 printf 加分支不易漏
[ "$MIN_MODE" -eq 1 ] && exec 3>&1 1>/dev/null
printf '外部顧問額度（%s 支）：\n\n' "${#TARGETS[@]}"
for name in "${TARGETS[@]}"; do
  # 標頭沿用 adapter 自述首行，顯示名不在本腳本另立一份（避免與 getter 漂移）
  header="$("$SCRIPTS_DIR/ask-$name.sh" --info 2>/dev/null | head -1)"
  printf '%s\n' "${header:-$name}"
  if ! declare -F "quota_$name" >/dev/null; then
    printf '  不支援額度查詢（該 CLI 未提供非互動額度介面）\n\n'
    continue
  fi
  # CLI 未安裝時不進查詢函式：其失敗訊息會是一堆 command not found，診斷價值低
  if ! command -v "$name" >/dev/null; then
    echo "[warn] ${name} 的 CLI 未安裝或不在 PATH，本次略過" >&2
    printf '  查詢失敗（CLI 未安裝，詳見 stderr）\n\n'
    continue
  fi
  "quota_$name" && OK=$((OK + 1)) || printf '  查詢失敗（詳見 stderr）\n'
  echo
done

[ "$MIN_MODE" -eq 1 ] && exec 1>&3 3>&-

# 全數查不到：等同沒有可用結果，讓呼叫端據結束碼分流，不必去 parse stdout
if [ "$OK" -eq 0 ]; then
  echo "[warn] 沒有任何顧問回報額度" >&2
  exit 1
fi

# 取得結果但一個窗都沒解析出來時不輸出殘缺值：呼叫端據 exit 1 走自己的退化路徑
if [ "$MIN_MODE" -eq 1 ]; then
  if [ -z "$MIN_REMAIN" ]; then
    echo "[warn] 查得回應但未解析出任何額度窗" >&2
    exit 1
  fi
  printf '%s\n' "$MIN_REMAIN"
fi
