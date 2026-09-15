#!/usr/bin/env bash
# usage-log.sh — 用量事件記錄（JSONL）
#
# 用途：把顧問呼叫的生命週期寫成可分析的事件流。與節流狀態分開管理——節流桶按
#       principal×advisor×scope 分鎖，那些鎖保護不到單一份 log 檔，輪替必須自己
#       序列化，否則多程序同時跨過門檻會互相覆蓋 .1。
#
# 匯出：USAGE_LOG / USAGE_SCHEMA_VERSION
#       usage_new_invocation_id / usage_now_ms / usage_event
#       usage_call_attempted / usage_call_finished
#
# 事件模型：同一次 adapter 呼叫共用一個 invocation_id，各生命週期節點各追加一行，
#           🚫 不回頭改寫舊行——舊行可能已被輪替搬走，原地改寫也非原子操作。
#
#   throttle_decision  扣桶完成當下（allow／deny 都寫）
#   call_attempted     adapter 走到啟動顧問 CLI 這一步
#   call_finished      已取得 CLI 結果並完成輸出判定
#
# 🚫 沒有任何事件能證明 prompt 抵達顧問服務端——call_attempted 之後 CLI 仍可能啟動
# 失敗，這與「allow 不等於送出」是同一類界線。唯一能證明往返完成的是結束碼 0 的
# call_finished。只有 throttle_decision 而沒有 call_finished ＝ 結果未知。

USAGE_SCHEMA_VERSION=1
USAGE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mh-external-advisor/quota"
USAGE_LOG="$USAGE_STATE_DIR/usage.log"
USAGE_LOG_MAX_BYTES=1048576
USAGE_LOCK_WAIT_STEPS=20       # 0.1s × 20 ＝ 最多等 2 秒

# ── 時間 ────────────────────────────────────────────────────────────

# 毫秒時戳：EPOCHREALTIME 是 bash 5+ 的純內建變數，不 fork；舊 bash 退到秒級。
# 耗時要用得上就得有毫秒，但為此每次多 fork 一個 date 不划算
usage_now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local s="${EPOCHREALTIME%%[.,]*}" f="${EPOCHREALTIME##*[.,]}"
    printf '%s%s\n' "$s" "${f:0:3}"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

# ── invocation id ──────────────────────────────────────────────────

# 配對扣桶決策與最終結果用。並行時靠時間或 PID 都配不起來：同一秒可以有多次呼叫，
# PID 也會重用。時戳＋PID＋隨機值三者併用，碰撞機率低到不必處理
usage_new_invocation_id() {
  printf '%s-%s-%04x\n' "$(date +%s)" "$$" "$((RANDOM))"
}

# ── 輪替鎖 ──────────────────────────────────────────────────────────

# 鎖是一個以 noclobber 建立的檔案：`set -C` 下的 `>` 帶 O_EXCL，建立與寫入 owner
# metadata 是同一個動作。改用檔案而非 mkdir + 另寫 owner，是因為那兩步之間存在
# 「鎖已存在但還沒有 owner」的狀態，等待者無從判斷該等還是該回收，怎麼訂規則都會
# 在高頻換手時誤傷——要嘛搶走剛建好的活躍鎖，要嘛讓真正的孤兒鎖永遠卡住。
#
# 內容三行：PID／nonce／owner 的 start time。
_usage_lock_payload() {
  printf '%s\n%s\n%s\n' "$$" "$USAGE_LOCK_NONCE" \
    "$(ps -o lstart= -p $$ 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
}

# owner 是否仍是當初那個程序。三態，🚫 不可壓成兩態——`ps` 在高並行下會偶發查不到，
# 把它當成「已死」就會去搶活著 owner 的鎖。
# 0＝同一個程序仍在；1＝已死或 PID 已被重用（可回收）；2＝判不出來（不據此回收）
_usage_owner_state() {
  local pid="$1" want="$2" now
  [ -n "$pid" ] || return 2
  kill -0 "$pid" 2>/dev/null || return 1       # 不 fork 的存在性檢查
  now="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  [ -n "$now" ] || return 2                    # ps 暫時失敗：誤刪比多等昂貴
  [ "$now" = "$want" ] && return 0
  return 1                                     # PID 被重用給別的程序，舊鎖失效
}

# 取鎖。搶不到不是致命錯誤，見 usage_event。
#
# 回收殘留鎖前要**同一份內容連看兩次**：只看一次是 TOCTOU——判定「owner 已死」到真的
# 動手之間鎖可能已經換手，移走的就成了別人剛取得的鎖。nonce 每次取鎖都不同，內容沒變
# 才表示還是同一個殘留鎖
_usage_lock() {
  local lock="$USAGE_LOG.lock" waited=0 snap
  USAGE_LOCK_NONCE="$$-$RANDOM-$RANDOM"
  while ! ( set -C; _usage_lock_payload > "$lock" ) 2>/dev/null; do
    snap="$(cat "$lock" 2>/dev/null)"
    if [ -n "$snap" ]; then
      _usage_owner_state "$(printf '%s' "$snap" | sed -n '1p')" "$(printf '%s' "$snap" | sed -n '3p')"
      if [ $? = 1 ]; then
        sleep 0.2
        [ "$snap" = "$(cat "$lock" 2>/dev/null)" ] && { rm -f "$lock" 2>/dev/null; continue; }
        waited=$((waited + 2))
      fi
    fi
    [ "$waited" -ge "$USAGE_LOCK_WAIT_STEPS" ] && return 1
    sleep 0.1
    waited=$((waited + 1))
  done
  return 0
}

# 只解自己的鎖：nonce 對不上代表鎖已被回收轉手，刪它等於搶走現任 owner 的鎖
_usage_unlock() {
  local lock="$USAGE_LOG.lock"
  [ "$(sed -n '2p' "$lock" 2>/dev/null)" = "${USAGE_LOCK_NONCE:-}" ] || return 0
  rm -f "$lock" 2>/dev/null
}

# ── 寫入 ────────────────────────────────────────────────────────────

# 事件寫入：參數為 key=value 對，value 一律當字串交給 jq 轉義；數值欄位另列
# USAGE_NUM_KEYS 指定，jq 才不會把它們寫成帶引號的字串。
#
# 記錄失敗一律靜默吞掉並回成功——這份資料是營運 telemetry，不是稽核帳本，
# 🚫 不得因為寫不進 log 就擋下顧問呼叫。
usage_event() {
  local args=() kv k v size locked=1 line
  # 巢狀欄位用 a.b 表示，交給 jq 的 setpath 展開（principal.kind 這類）
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ "$k" = "$kv" ] && continue          # 沒有 = 的參數直接忽略，不讓它污染事件
    args+=(--arg "$k" "$v")
  done
  line="$(jq -cn "${args[@]}" \
    --arg _v "$USAGE_SCHEMA_VERSION" \
    --arg _ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --arg _num "${USAGE_NUM_KEYS:-}" '
      ($_num | split(" ") | map(select(length > 0))) as $nums
      | ($ARGS.named | del(._v, ._ts, ._num)) as $fields
      | reduce ($fields | keys_unsorted[]) as $k
          ({"v": ($_v | tonumber), "ts": $_ts};
           ($fields[$k]) as $raw
           | (if ($nums | index($k)) then ($raw | tonumber? // $raw) else $raw end) as $val
           | setpath($k | split("."); $val))
    ' 2>/dev/null)"
  [ -n "$line" ] || return 0

  mkdir -p "$USAGE_STATE_DIR" 2>/dev/null || return 0

  # 輪替與 append 要一起序列化，否則「檢查大小 → mv → append」會被別的程序插進來。
  # 搶不到鎖時退化成「只 append 不輪替」：append 本身夠短，O_APPEND 可容忍競爭，
  # 真正會壞資料的只有輪替；寧可讓檔案暫時超過門檻，也不能漏事件或擋住呼叫
  _usage_lock || locked=0
  if [ "$locked" = "1" ]; then
    size=0
    [ -f "$USAGE_LOG" ] && size="$(wc -c < "$USAGE_LOG" 2>/dev/null || echo 0)"
    [ "${size:-0}" -gt "$USAGE_LOG_MAX_BYTES" ] 2>/dev/null \
      && mv -f "$USAGE_LOG" "$USAGE_LOG.1" 2>/dev/null
  fi
  { printf '%s\n' "$line" >> "$USAGE_LOG"; } 2>/dev/null
  [ "$locked" = "1" ] && _usage_unlock
  return 0
}

# ── adapter 生命週期 ────────────────────────────────────────────────

# 啟動顧問 CLI 前呼叫，記的是「adapter 走到這一步」，🚫 不等於 prompt 已送達。結束事件
# 由 usage_call_finished 補，adapter 要把它掛進 EXIT trap——中途 exit 的路徑太多。
#
# $1=advisor  $2=mode(new|resume)
usage_call_attempted() {
  USAGE_CALL_ADVISOR="$1"; USAGE_CALL_MODE="$2"
  USAGE_CALL_START_MS="$(usage_now_ms)"
  usage_event event=call_attempted invocation_id="${USAGE_INVOCATION_ID:-}" \
    advisor="$USAGE_CALL_ADVISOR" mode="$USAGE_CALL_MODE"
}

# 由 EXIT trap 呼叫，$1 為結束碼。未曾 call_attempted 就不寫——扣桶被擋或參數錯誤
# 根本沒走到啟動 CLI，補一筆結束事件會讓「已送出」的分母灌水。
usage_call_finished() {
  local rc="${1:-0}" dur=""
  [ -n "${USAGE_CALL_START_MS:-}" ] || return 0
  dur=$(( $(usage_now_ms) - USAGE_CALL_START_MS ))
  USAGE_NUM_KEYS="adapter_exit_code duration_ms" \
  usage_event event=call_finished invocation_id="${USAGE_INVOCATION_ID:-}" \
    advisor="$USAGE_CALL_ADVISOR" mode="$USAGE_CALL_MODE" \
    adapter_exit_code="$rc" duration_ms="$dur" \
    outcome="$([ "$rc" -eq 0 ] 2>/dev/null && echo ok || echo error)"
  USAGE_CALL_START_MS=""      # trap 可能被觸發兩次（exit 後又收到訊號），避免重複記
}
