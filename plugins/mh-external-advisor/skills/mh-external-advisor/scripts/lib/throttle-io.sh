#!/usr/bin/env bash
# throttle-io.sh — 漏桶節流的共用實作（供 advisor-throttle.sh / ask-*.sh 引用）
#
# 用途：把「誰的桶」「桶怎麼算」「怎麼上鎖」三條規則放在同一處。節流的價值來自
#       它不依賴呼叫端自律——扣桶動作嵌在 adapter 內部，呼叫端繞不過；因此這裡
#       的失敗一律 fail closed（擋住並明示 prompt 未送出），不得因環境差異放行。
#
# 匯出：THROTTLE_STATE_DIR / THROTTLE_LOG
#       resolve_principal / load_throttle_config / effective_refill
#       bucket_take / bucket_project / bucket_reset / throttle_gc / usage_log
#
# 使用前提：引用者需自行確保 SCRIPTS_DIR 已定義（指向本 skill 的 scripts/ 目錄）。

# 桶是可丟棄的執行狀態，與 enabled.json（使用者意圖）分開放——混放會讓備份或
# 同步設定時把配額水位一起搬走
THROTTLE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mh-external-advisor/quota"
THROTTLE_LOG="$THROTTLE_STATE_DIR/usage.log"
THROTTLE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/mh-external-advisor/throttle.json"

# scope 值固定 ASCII：中文只出現在文件，避開 locale、引號與正規化問題
THROTTLE_SCOPES="explore unblock review"

valid_scope() {
  case " $THROTTLE_SCOPES " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac
}

# ── 身分：桶屬於哪個 AI Agent ──────────────────────────────────────

# 沿祖先鏈取「第一個非 shell 祖先」，設定 PRINCIPAL_PID / PRINCIPAL_LSTART。
#
# 不以已知 CLI 名單比對：名單會過期，且 node 本身就可能是 agent 本體。改以
# 「跳過連續 shell」定位——呼叫鏈是 agent → shell → 本腳本，第一個非 shell
# 即呼叫端。取不到時回非零由呼叫端 fail closed；🚫 不得放行，否則環境差異
# 就成了繞過節流的途徑。
resolve_principal() {
  local pid ppid comm depth=0
  pid="$$"
  while [ "$depth" -lt 20 ]; do
    # macOS 的 comm 給完整路徑，取 basename 後比對；login shell 另有 - 前綴
    read -r ppid comm <<<"$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)"
    [ -n "${ppid:-}" ] || return 1
    comm="${comm##*/}"; comm="${comm#-}"
    case "$comm" in
      sh|bash|zsh|dash|ksh|fish) ;;
      # 本 skill 自己的 wrapper 也要跳過：實測 Linux 下 comm 為 bash（腳本由 bash
      # 執行），但若某平台或 shell 把 argv[0] 設成腳本名，principal 會落在這次
      # 短命的 wrapper 上——每次呼叫都變成新桶，節流形同失效
      advisor-*.sh|ask-*.sh|advisor-*|ask-*) ;;
      "") return 1 ;;
      *) PRINCIPAL_PID="$pid"; PRINCIPAL_COMM="$comm"; break ;;
    esac
    pid="$ppid"
    # PID 0/1 代表已追到 init 或容器入口，中間沒有可辨識的 agent
    [ "$pid" = "0" ] || [ "$pid" = "1" ] && return 1
    depth=$((depth + 1))
  done
  [ -n "${PRINCIPAL_PID:-}" ] || return 1
  # lstart 當 incarnation key：同一 PID 被重用時據此判定舊桶失效。
  # 不用 /proc/<pid>/stat（Linux only）——這裡不是安全身分驗證，秒級足夠
  PRINCIPAL_LSTART="$(ps -o lstart= -p "$PRINCIPAL_PID" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  [ -n "$PRINCIPAL_LSTART" ] || return 1
  return 0
}

# 進程是否仍存活且為同一 incarnation（GC 與 stale lock 回收共用）
same_incarnation() {
  local pid="$1" want="$2" now
  now="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')" || return 2
  [ -n "$now" ] || return 2          # 2＝查不到（可能已死，也可能 ps 暫時失敗）
  [ "$now" = "$want" ]
}

# ── 設定 ────────────────────────────────────────────────────────

# 正整數守門：jq 的 number 可能是 0、負數或小數，而後續全是 shell 整數算術。
# 無效值個別退回預設，不整份放棄——設定寫錯不該讓所有諮詢停擺
_th_int() {
  local v="${1:-}" d="$2" min="${3:-1}" name="${4:-}"
  # 欄位不存在（空值）是正常的「沿用預設」，不警告；有值但無效才要讓使用者知道，
  # 否則他改了設定卻沒生效，只能從節流行為反推
  case "$v" in
    "") printf '%s' "$d"; return 0 ;;
    *[!0-9]*) [ -n "$name" ] && echo "[warn] throttle 設定 ${name}=「${v}」不是正整數，改用預設 ${d}" >&2
              printf '%s' "$d"; return 0 ;;
  esac
  if ! [ "$v" -ge "$min" ] 2>/dev/null; then
    [ -n "$name" ] && echo "[warn] throttle 設定 ${name}=${v} 低於下限 ${min}，改用預設 ${d}" >&2
    printf '%s' "$d"; return 0
  fi
  printf '%s' "$v"
}

# 讀 throttle.json 填入 TH_* 全域；缺檔或欄位缺漏時用內建預設，不報錯。
# 設定壞掉不應讓諮詢全面停擺，但也不得因此變寬鬆——預設值本身就是保守值。
load_throttle_config() {
  TH_CAPACITY=30          # 容量：最大 burst＝capacity/cost 次，🚫 不隨額度倍率改變
  TH_COST=10              # 每次諮詢扣多少
  TH_REFILL=60            # 基數：每 60 秒回 1 單位
  TH_LOW_BELOW=40         # 額度剩餘低於此 → 速率減半
  TH_HIGH_AT=70           # 額度剩餘達此 → 速率加倍
  TH_CACHE_TTL=300        # quota 快取新鮮期
  TH_CACHE_STALE=1800     # 逾期後仍可沿用的上限，再舊即採最保守檔
  TH_LOCK_TIMEOUT=5
  TH_GC_INTERVAL=21600
  TH_GC_MAX_AGE=604800
  [ -f "$THROTTLE_CONFIG" ] || return 0
  local v
  v="$(jq -r '
    def n(p; d): (p // d) | if type == "number" then . else d end;
    [ n(.scopes.default.capacity; 30),
      n(.scopes.default.cost; 10),
      n(.scopes.default.refill_seconds; 60),
      n(.quota_thresholds.low_below; 40),
      n(.quota_thresholds.high_at; 70),
      n(.quota_cache_ttl_seconds; 300),
      n(.quota_stale_max_seconds; 1800),
      n(.lock_timeout_seconds; 5),
      n(.gc_interval_seconds; 21600),
      n(.gc_max_age_seconds; 604800) ] | @tsv' "$THROTTLE_CONFIG" 2>/dev/null)" || {
    echo "[warn] throttle 設定檔不可解析（${THROTTLE_CONFIG}），改用內建預設" >&2
    return 0
  }
  local _cap _cost _rf _lb _ha _ttl _stale _lt _gi _gm
  IFS=$'\t' read -r _cap _cost _rf _lb _ha _ttl _stale _lt _gi _gm <<<"$v"
  TH_CAPACITY="$(_th_int "$_cap" "$TH_CAPACITY" 1 "capacity")"
  TH_COST="$(_th_int "$_cost" "$TH_COST" 1 "cost")"
  TH_REFILL="$(_th_int "$_rf" "$TH_REFILL" 1 "refill_seconds")"
  TH_LOW_BELOW="$(_th_int "$_lb" "$TH_LOW_BELOW" 0 "quota_thresholds.low_below")"
  TH_HIGH_AT="$(_th_int "$_ha" "$TH_HIGH_AT" 0 "quota_thresholds.high_at")"
  TH_CACHE_TTL="$(_th_int "$_ttl" "$TH_CACHE_TTL" 0 "quota_cache_ttl_seconds")"
  TH_CACHE_STALE="$(_th_int "$_stale" "$TH_CACHE_STALE" 0 "quota_stale_max_seconds")"
  TH_LOCK_TIMEOUT="$(_th_int "$_lt" "$TH_LOCK_TIMEOUT" 1 "lock_timeout_seconds")"
  TH_GC_INTERVAL="$(_th_int "$_gi" "$TH_GC_INTERVAL" 0 "gc_interval_seconds")"
  TH_GC_MAX_AGE="$(_th_int "$_gm" "$TH_GC_MAX_AGE" 1 "gc_max_age_seconds")"
  # 欄位間關係：cost 大於 capacity 會讓桶永遠取不到，兩者都退回預設較可預測
  if [ "$TH_COST" -gt "$TH_CAPACITY" ]; then
    echo "[warn] throttle 設定的 cost（${TH_COST}）大於 capacity（${TH_CAPACITY}），兩者改用預設" >&2
    TH_CAPACITY=30; TH_COST=10
  fi
  return 0
}

# 每個 scope 可覆寫容量與速率；未覆寫則用 default
scope_param() {
  local scope="$1" key="$2" fallback="$3" v
  [ -f "$THROTTLE_CONFIG" ] || { printf '%s' "$fallback"; return 0; }
  v="$(jq -r --arg s "$scope" --arg k "$key" '
    (.scopes[$s][$k] // empty) | if type == "number" then . else empty end' \
    "$THROTTLE_CONFIG" 2>/dev/null)"
  # 覆寫值與 default 套同一道驗證：只驗 default 會讓 scope 層繞過守門
  _th_int "${v:-}" "$fallback" 1 "scopes.${scope}.${key}"
}

# ── 額度倍率：以顧問的最小剩餘百分比決定恢復速率 ──────────────────

# 回傳「生效的恢復秒數」。只調速率不調容量：兩者一起放大會讓高餘量時的尖峰
# 過度膨脹。查詢走快取，且一律不在桶鎖內執行——一次網路卡住會阻塞同桶所有
# 背景諮詢。
effective_refill() {
  local ai="$1" base="$2" cache remain age now
  cache="$THROTTLE_STATE_DIR/quota-$ai.json"
  now="$(date +%s)"
  remain=""
  if [ -f "$cache" ]; then
    age="$(jq -r --argjson n "$now" '($n - (.at // 0)) | floor' "$cache" 2>/dev/null)"
    if [ -n "${age:-}" ] && [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -le "$TH_CACHE_TTL" ]; then
      remain="$(jq -r '.remain // empty' "$cache" 2>/dev/null)"
    fi
  fi
  if [ -z "$remain" ]; then
    remain="$("$SCRIPTS_DIR/advisor-quota.sh" --min-remain "$ai" 2>/dev/null)"
    if [ -n "$remain" ]; then
      mkdir -p "$THROTTLE_STATE_DIR" 2>/dev/null
      { printf '{"v":1,"remain":%s,"at":%s}\n' "$remain" "$now" > "$cache.tmp.$$"; } 2>/dev/null \
        && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null
    else
      # 查不到就沿用舊值一段時間；再舊即採最保守檔——網路故障不得成為放寬節流的途徑
      if [ -f "$cache" ] && [ -n "${age:-}" ] && [ "$age" -le "$TH_CACHE_STALE" ] 2>/dev/null; then
        remain="$(jq -r '.remain // empty' "$cache" 2>/dev/null)"
        echo "[warn] ${ai} 額度查詢失敗，沿用 ${age} 秒前的舊值（剩 ${remain}%）" >&2
      else
        echo "[warn] ${ai} 額度查詢失敗且無可用快取，採最保守速率（減半）" >&2
        printf '%s' "$((base * 2))"; return 0
      fi
    fi
  fi
  # 百分比可能帶小數，交給 awk 比較
  if awk -v r="$remain" -v t="$TH_LOW_BELOW" 'BEGIN{exit !(r+0 < t+0)}'; then
    printf '%s' "$((base * 2))"          # 剩餘低 → 間隔加倍
  elif awk -v r="$remain" -v t="$TH_HIGH_AT" 'BEGIN{exit !(r+0 >= t+0)}'; then
    printf '%s' "$(( base / 2 > 0 ? base / 2 : 1 ))"   # 剩餘高 → 間隔減半
  else
    printf '%s' "$base"
  fi
}

# ── 鎖：每桶一個 mkdir 目錄鎖 ────────────────────────────────────

# 用 mkdir 而非 flock：flock 在 macOS 沒有，而 mkdir 的原子性兩邊都成立。
# 必須上鎖——不上鎖時兩個程序同讀舊水位會雙雙判定可取用，硬上限直接失效。
bucket_lock() {
  local dir="$1" deadline opid olstart oat now stale
  LOCK_DIR="$dir"
  LOCK_NONCE="$$-$RANDOM-$RANDOM"
  deadline=$(( $(date +%s) + TH_LOCK_TIMEOUT ))
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      # 先建目錄才寫 metadata：順序相反的話，別的等待者會看到沒有 owner 的鎖
      printf '%s\n%s\n%s\n%s\n' "$$" "$SELF_LSTART" "$LOCK_NONCE" "$(date +%s)" > "$dir/owner" 2>/dev/null
      return 0
    fi
    now="$(date +%s)"
    stale=0
    if [ -f "$dir/owner" ]; then
      opid="$(sed -n '1p' "$dir/owner" 2>/dev/null)"
      olstart="$(sed -n '2p' "$dir/owner" 2>/dev/null)"
      same_incarnation "$opid" "$olstart"
      case $? in
        0) ;;            # owner 還活著，繼續等
        1) stale=1 ;;    # PID 被重用給別的程序 → owner 已死
        2) ;;            # ps 查不到：可能已死也可能暫時失敗，不據此回收（誤刪比多等昂貴）
      esac
      oat="$(sed -n '4p' "$dir/owner" 2>/dev/null)"
      # 保底：owner 判定不了但鎖已存在超過保存期，仍回收，否則會永久鎖死
      [ -n "${oat:-}" ] && [ $((now - oat)) -gt $((TH_LOCK_TIMEOUT * 12)) ] 2>/dev/null && stale=1
    else
      # 剛建立、尚未寫 metadata 的鎖給一段 grace；超過即視為建立者中途死亡
      stale=1
      sleep 1
      [ -f "$dir/owner" ] && stale=0
    fi
    if [ "$stale" -eq 1 ]; then
      # 先原子 rename 成唯一名再刪：兩個等待者同時回收時只有一個 mv 會成功，
      # 不會出現「A 刪掉 B 剛建好的鎖」
      if mv "$dir" "$dir.stale.$$.$RANDOM" 2>/dev/null; then
        rm -rf "$dir".stale.* 2>/dev/null
        echo "[warn] 回收殘留的鎖（owner 已不存在）：$dir" >&2
      fi
      continue
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

# 解鎖前比對 nonce：不比對的話，被回收的舊 owner 會刪掉後來者的鎖
bucket_unlock() {
  local dir="${LOCK_DIR:-}" n
  [ -n "$dir" ] || return 0
  n="$(sed -n '3p' "$dir/owner" 2>/dev/null)"
  [ "$n" = "${LOCK_NONCE:-}" ] && rm -rf "$dir" 2>/dev/null
  LOCK_DIR=""
}

# ── 桶 ──────────────────────────────────────────────────────────

bucket_path() {
  printf '%s/buckets/%s/%s-%s.json' "$THROTTLE_STATE_DIR" "$PRINCIPAL_PID" "$1" "$2"
}

# 取用或試算一個桶。
#   $1 顧問名  $2 scope  $3 mode（take＝實際扣，peek＝唯讀投影不寫檔）
# stdout 印 JSON；回傳 0＝放行、1＝桶滿、2＝鎖或狀態失敗（呼叫端須 fail closed）
#
# 順序固定：用「上次生效的 refill」排完這段水 → 判斷 → 最後才把 refill 換成新值。
# 若一開始就用新值，等於拿現在的額度檔位回溯改寫過去那段時間的水位。
bucket_take() {
  local ai="$1" scope="$2" mode="$3"
  local cap cost refill_base f now remaining refill updated new_updated elapsed gain rem carry new_refill lstart retry avail

  cap="$(scope_param "$scope" capacity "$TH_CAPACITY")"
  cost="$(scope_param "$scope" cost "$TH_COST")"
  refill_base="$(scope_param "$scope" refill_seconds "$TH_REFILL")"
  # 欄位關係要在「套用 scope 覆寫之後」再驗一次：只驗 default 的話，單設
  # review.capacity=5（cost 沿用 10）會讓該 scope 每次都取不到、永遠 exit 5。
  # TH_CAPACITY/TH_COST 在載入時已驗過關係，退回它們是安全的
  if [ "$cost" -gt "$cap" ] 2>/dev/null; then
    echo "[warn] scope ${scope} 的 cost（${cost}）大於 capacity（${cap}），該 scope 改用預設 ${TH_CAPACITY}/${TH_COST}" >&2
    cap="$TH_CAPACITY"; cost="$TH_COST"
  fi
  f="$(bucket_path "$ai" "$scope")"
  now="$(date +%s)"

  # quota 查詢放在鎖外：它走網路要數秒，持鎖期間查會阻塞同桶所有背景諮詢。
  # peek 是唯讀查詢，🚫 不查網路——沿用桶內既有速率（讀檔後補），沒有桶就用基數
  if [ "$mode" = "take" ]; then
    new_refill="$(effective_refill "$ai" "$refill_base")"
    [ "${new_refill:-0}" -gt 0 ] 2>/dev/null || new_refill="$refill_base"
  else
    new_refill="$refill_base"
  fi

  # peek 不建任何目錄：它對外宣稱唯讀，建目錄會在 XDG state 留下痕跡
  if [ "$mode" = "take" ]; then
    mkdir -p "$(dirname "$f")" 2>/dev/null || { echo "[warn] 無法建立桶目錄" >&2; return 2; }
  fi
  if [ "$mode" = "take" ]; then
    bucket_lock "$f.lock" || { echo "[warn] 等鎖逾時（${TH_LOCK_TIMEOUT}s）：$f" >&2; return 2; }
  fi

  remaining="$cap"; refill="$new_refill"; updated="$now"
  if [ -f "$f" ]; then
    lstart="$(jq -r '.principal.lstart // empty' "$f" 2>/dev/null)"
    # lstart 不符＝這個 PID 已被重用給別的程序，舊桶失效，重新開一個滿桶
    if [ "$lstart" = "$PRINCIPAL_LSTART" ]; then
      remaining="$(jq -r '.remaining // empty' "$f" 2>/dev/null)"
      refill="$(jq -r '.refill_seconds // empty' "$f" 2>/dev/null)"
      updated="$(jq -r '.updated_at // empty' "$f" 2>/dev/null)"
      # 任一欄位讀不到就當桶損壞，重建為滿桶而非沿用殘值
      if ! [ "${remaining:-x}" -ge 0 ] 2>/dev/null || ! [ "${refill:-0}" -gt 0 ] 2>/dev/null \
         || ! [ "${updated:-x}" -ge 0 ] 2>/dev/null; then
        echo "[warn] 桶狀態不完整，重建：$f" >&2
        remaining="$cap"; refill="$new_refill"; updated="$now"
      fi
    fi
  fi

  # peek 沿用桶內速率：唯讀查詢不重新判定額度檔位
  [ "$mode" = "take" ] || new_refill="$refill"

  elapsed=$((now - updated))
  # 時鐘倒退（睡眠喚醒、NTP 校時）：elapsed 取 0，🚫 不得讓負值反向增加水位
  if [ "$elapsed" -lt 0 ]; then
    echo "[warn] 偵測到時鐘倒退（${elapsed}s），本次不計恢復量" >&2
    elapsed=0
  fi
  # 只兌現整數單位；未滿一單位的餘數換算成新速率下的等值時間，錨點設在 now 之前。
  # 直接設 now 會丟掉餘數（每次最多丟 refill-1 秒）；直接留舊 updated_at 則更糟——
  # 速率變動時，那段在舊速率下累積的時間會被新速率回溯計算（120s 制下的 119 秒
  # 切到 30s 制會憑空變成 3 個單位）
  gain=$((elapsed / refill))
  rem=$((elapsed % refill))
  [ "$gain" -gt 0 ] && remaining=$((remaining + gain))
  # 等值換算：舊速率下 rem/refill 個單位的進度，在新速率下值 rem*new_refill/refill 秒
  carry=$(( rem * new_refill / refill ))
  new_updated=$((now - carry))
  # 滿桶後餘數沒有意義，時間錨點直接對齊現在
  if [ "$remaining" -ge "$cap" ]; then remaining="$cap"; new_updated="$now"; fi

  if [ "$remaining" -ge "$cost" ]; then
    [ "$mode" = "take" ] && remaining=$((remaining - cost))
    retry=0
  else
    # 用寫回後的狀態計算：未來按 new_refill 恢復，已累積的是 now - new_updated
    retry=$(( (cost - remaining) * new_refill - (now - new_updated) ))
    [ "$retry" -lt 0 ] && retry=0
  fi
  avail=$((now + retry))

  # peek 只投影不寫檔——公式對同一時間點是冪等的，唯讀查詢不必改 updated_at
  if [ "$mode" = "take" ]; then
    printf '{"version":1,"principal":{"pid":%s,"lstart":"%s"},"scope":"%s","advisor":"%s","remaining":%s,"updated_at":%s,"refill_seconds":%s}\n' \
      "$PRINCIPAL_PID" "$PRINCIPAL_LSTART" "$scope" "$ai" "$remaining" "$new_updated" "$new_refill" \
      > "$f.tmp.$$" 2>/dev/null \
      && mv -f "$f.tmp.$$" "$f" 2>/dev/null \
      || { rm -f "$f.tmp.$$" 2>/dev/null; bucket_unlock; echo "[warn] 桶狀態寫入失敗：$f" >&2; return 2; }
    bucket_unlock
  fi

  if [ "$retry" -eq 0 ]; then
    printf '{"allowed":true,"scope":"%s","advisor":"%s","remaining":%s,"capacity":%s,"cost":%s,"refill_seconds":%s}\n' \
      "$scope" "$ai" "$remaining" "$cap" "$cost" "$new_refill"
    return 0
  fi
  printf '{"allowed":false,"scope":"%s","advisor":"%s","retry_after_seconds":%s,"available_at":%s,"remaining":%s,"capacity":%s,"cost":%s,"refill_seconds":%s}\n' \
    "$scope" "$ai" "$retry" "$avail" "$remaining" "$cap" "$cost" "$new_refill"
  return 1
}

bucket_reset() {
  local ai="$1" scope="$2" f
  f="$(bucket_path "$ai" "$scope")"
  [ -f "$f" ] || return 0
  bucket_lock "$f.lock" || return 2
  rm -f "$f" 2>/dev/null
  bucket_unlock
}

# ── GC 與記錄 ───────────────────────────────────────────────────

# 有間隔的 bounded GC：正常路徑不掃整棵狀態樹。
# 只清「PID 已被重用」或「超過保存期」的桶——ps 暫時失敗不得據以刪除，
# 否則會誤刪仍在使用中的桶。
throttle_gc() {
  local stamp="$THROTTLE_STATE_DIR/.gc" now last d pid f lstart mtime
  now="$(date +%s)"
  last=0
  [ -f "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
  [ "${last:-0}" -gt 0 ] 2>/dev/null && [ $((now - last)) -lt "$TH_GC_INTERVAL" ] && return 0
  { printf '%s\n' "$now" > "$stamp"; } 2>/dev/null
  for d in "$THROTTLE_STATE_DIR"/buckets/*/; do
    [ -d "$d" ] || continue
    pid="$(basename "$d")"
    for f in "$d"*.json; do
      [ -f "$f" ] || continue
      lstart="$(jq -r '.principal.lstart // empty' "$f" 2>/dev/null)"
      same_incarnation "$pid" "$lstart"
      if [ $? -eq 1 ]; then rm -f "$f" 2>/dev/null; continue; fi
      # 保底保存期：平台查不到程序時仍能清掉長期垃圾。
      # 用 -mtime（BSD/GNU find 皆支援）而非 -newermt（GNU 專有）——精度到天已足夠
      mtime="$(find "$f" -mtime "+$((TH_GC_MAX_AGE / 86400))" 2>/dev/null)"
      [ -n "$mtime" ] && rm -f "$f" 2>/dev/null
    done
    rmdir "$d" 2>/dev/null
  done
  return 0
}

# 用量記錄：allow 與 deny 都記——只記成功就看不出節流有沒有真的擋到，
# 也無從回頭調參數。🚫 不記 prompt 內容：這份檔案比對話脈絡持久。
usage_log() {
  local line size
  line="$(date '+%Y-%m-%dT%H:%M:%S%z')  ${AGENT_LABEL:-agent}(${PRINCIPAL_PID:-?})  $*"
  mkdir -p "$THROTTLE_STATE_DIR" 2>/dev/null || return 0
  # 依大小輪替，留一份舊檔：長期執行不做輪替會無限成長
  size=0
  [ -f "$THROTTLE_LOG" ] && size="$(wc -c < "$THROTTLE_LOG" 2>/dev/null || echo 0)"
  [ "${size:-0}" -gt 1048576 ] 2>/dev/null && mv -f "$THROTTLE_LOG" "$THROTTLE_LOG.1" 2>/dev/null
  { printf '%s\n' "$line" >> "$THROTTLE_LOG"; } 2>/dev/null
  return 0
}
