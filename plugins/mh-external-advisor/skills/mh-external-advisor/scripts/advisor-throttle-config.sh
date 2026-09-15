#!/usr/bin/env bash
# advisor-throttle-config.sh — 節流設定檔 throttle.json 的檢視、修改與自檢
#
# 用途：throttle.json 過去只能手寫。本腳本補上「看得到、改得動、重裝時自己檢查」
#       三件事。它管的是**政策設定**，與 advisor-throttle.sh 管的**桶水位**是
#       兩回事——後者 reset 會清空硬節流水位，本腳本任何操作都不碰水位。
#
# 值域規則不在本檔：合不合法一律把值餵給 reader（load_throttle_config／
# scope_param）判定，看它有沒有印 [warn]。自己寫一份必然與 reader 漂移，
# 而漂移的後果是管理工具說合法、執行期卻退回預設。
#
# 注意：set／unset／check 為 read-modify-write，**不可並行執行**（無鎖，交錯執行
#       會互相覆蓋）。與 advisor-set.sh 採同一取捨：lock 目錄在強殺後殘留會永久
#       卡住 setter，比競態更糟，而這些是偶爾手動跑一次的管理指令。
#
# I/O：
#   輸入  ─ 子命令 show / check / set / unset
#   輸出  ─ stdout：人類可讀報表（show --json 為機器可讀）；stderr：警告與診斷
#   結束碼─ 0 成功（check 無論有無修復皆為 0）；1 執行失敗；2 參數錯誤；127 缺依賴
#
# 用法：
#   advisor-throttle-config.sh show [--json]
#   advisor-throttle-config.sh check [--dry-run]
#   advisor-throttle-config.sh set <key> <value>
#   advisor-throttle-config.sh unset <key>

set -uo pipefail

SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null || { echo "錯誤：找不到 jq（讀寫設定檔需要）" >&2; exit 127; }

# reader 是本腳本的值域裁判，也是 THROTTLE_CONFIG／THROTTLE_SCOPES 的出處
# shellcheck source=lib/throttle-io.sh
. "$SCRIPTS_DIR/lib/throttle-io.sh"

# ── 已知欄位表 ────────────────────────────────────────────────────
#
# 這張表只回答「本工具認得哪些欄位」，🚫 不含值域。它有兩個用途：set/unset
# 擋拼字錯誤，以及 check 指出設定檔裡的陌生欄位。
#
# ⚠️ 表過期時只會少認得欄位，🚫 不得據此刪除使用者的設定——舊版工具遇到新版
#    欄位、或新版工具遇到舊版欄位都會誤判，而刪除是不可逆的。

TOP_KEYS="quota_thresholds.low_below quota_thresholds.high_at quota_cache_ttl_seconds
quota_stale_max_seconds lock_timeout_seconds gc_interval_seconds gc_max_age_seconds"

# 每個 scope 可覆寫的欄位，與 bucket_take 實際會查的三個一致
SCOPE_KEYS="capacity cost refill_seconds"

# version 是寫入時的 schema 戳記，供本腳本比對用；reader 不讀它
SCHEMA_VERSION=1

# 列出所有合法的點號路徑
known_keys() {
  local s k
  for k in $SCOPE_KEYS; do echo "scopes.default.$k"; done
  for s in $THROTTLE_SCOPES; do
    for k in $SCOPE_KEYS; do echo "scopes.$s.$k"; done
  done
  for k in $TOP_KEYS; do echo "$k"; done
}

# 已知 key 的所有前綴，例如 scopes / scopes.default / quota_thresholds
known_prefixes() {
  local k
  while IFS= read -r k; do
    while [ "$k" != "${k%.*}" ]; do k="${k%.*}"; echo "$k"; done
  done < <(known_keys) | sort -u
}

# 把陌生的葉節點路徑收斂成「最短的陌生前綴」：陣列元素與整包未知欄位各報一次就夠
unknown_root() {
  local path="$1" acc="" seg
  local IFS=.
  for seg in $path; do
    acc="${acc:+$acc.}$seg"
    if ! printf '%s\n' "$KNOWN_PREFIXES" | grep -qxF "$acc"; then printf '%s' "$acc"; return 0; fi
  done
  printf '%s' "$path"
}

is_known_key() {
  local want="$1" k
  while IFS= read -r k; do [ "$k" = "$want" ] && return 0; done < <(known_keys)
  return 1
}

usage() {
  cat >&2 <<EOF
用法:
  $0 show [--json]          檢視生效中的設定與各值來源
  $0 check [--dry-run]      檢查設定並修復已失效的內容（--dry-run 只報不改）
  $0 set <key> <value>      設定一個欄位
  $0 unset <key>            移除一個欄位或整個 scope

  key 為點號路徑，例如：
    scopes.default.cost          共用的每次扣量
    scopes.review.refill_seconds  review 專屬的恢復速率
    quota_thresholds.low_below    額度倍率門檻
  可設定的完整清單：$0 set 時填錯 key 即會列出
EOF
}

# ── 設定檔存取 ────────────────────────────────────────────────────

CONFIG_DIR="$(dirname "$THROTTLE_CONFIG")"

config_exists() { [ -f "$THROTTLE_CONFIG" ]; }

# 讀回設定檔內容；缺檔給空骨架，讓上層不必逐處分支
read_config() {
  if config_exists; then cat "$THROTTLE_CONFIG"
  else printf '{"version":%s}\n' "$SCHEMA_VERSION"; fi
}

config_parses() { config_exists && jq -e . "$THROTTLE_CONFIG" >/dev/null 2>&1; }

# 原子寫入：同目錄暫存檔 + mv。改動前留單一份 .bak——check 會在安裝流程中
# 無人看管地改檔，一份可回溯的舊檔是便宜的保險（🚫 不做輪替，那是另一個問題）
write_config() {
  local tmp
  mkdir -p "$CONFIG_DIR" || { echo "錯誤：無法建立設定目錄 ${CONFIG_DIR}" >&2; return 1; }
  tmp="$(mktemp "$CONFIG_DIR/.throttle.XXXXXX")" || { echo "錯誤：無法建立暫存檔" >&2; return 1; }
  if ! jq -S . >"$tmp"; then
    rm -f "$tmp"; echo "錯誤：設定序列化失敗" >&2; return 1
  fi
  config_exists && cp -p "$THROTTLE_CONFIG" "${THROTTLE_CONFIG}.bak" 2>/dev/null
  mv "$tmp" "$THROTTLE_CONFIG" || { rm -f "$tmp"; echo "錯誤：寫入 ${THROTTLE_CONFIG} 失敗" >&2; return 1; }
}

# 刪掉欄位後收拾空物件。留著不影響 reader，但會讓 check 與人工檢視多出噪音；
# check 與 unset 都會刪欄位，收殼只在這裡寫一份
tidy_config() {
  jq '
    if has("scopes") then .scopes |= with_entries(select((.value|length) > 0)) else . end
    | if has("scopes") and (.scopes|length) == 0 then del(.scopes) else . end
    | if has("quota_thresholds") and (.quota_thresholds|length) == 0 then del(.quota_thresholds) else . end
  '
}

# ── 值的判定：一律交給 reader ──────────────────────────────────────

# 用 reader 判定「這個路徑放這個值」合不合法。
#   $1 點號路徑  $2 JSON 值
# stdout 印 reader 的警告（空＝合法）；回傳 0＝合法、1＝不合法
#
# 只含該欄位的設定檔餵給 reader：其餘欄位缺漏時 reader 走內建預設，不會互相干擾。
# scope 覆寫由 scope_param 驗，default 與頂層欄位由 load_throttle_config 驗——
# 兩者的守門位置不同，驗錯地方會抓不到
probe_value() {
  local path="$1" val="$2" tmp out scope key neutral
  tmp="$(mktemp "${TMPDIR:-/tmp}/throttle-probe.XXXXXX")" || return 1
  # 中和對造欄位：只留單一欄位時，另一半會落在內建預設上，於是 cost=99 這種
  # 「本身合法、只是與 capacity 衝突」的值會被誤判成值域錯而遭移除。關係型違反
  # 要捨棄哪一邊屬使用者意圖，一律交給整份設定的檢查去回報
  neutral='{}'
  case "$path" in
    scopes.default.cost)     neutral='{"scopes":{"default":{"capacity":999999999}}}' ;;
    scopes.default.capacity) neutral='{"scopes":{"default":{"cost":1}}}' ;;
  esac
  if ! jq -n --arg p "$path" --argjson v "$val" --argjson base "$neutral" \
       '$base | setpath($p|split("."); $v)' >"$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  # 子 shell 隔離：load_throttle_config 會覆寫全部 TH_* 全域
  out="$(
    THROTTLE_CONFIG="$tmp"
    case "$path" in
      scopes.default.*|scopes.default) load_throttle_config 2>&1 >/dev/null ;;
      scopes.*)
        scope="${path#scopes.}"; key="${scope#*.}"; scope="${scope%%.*}"
        load_throttle_config >/dev/null 2>&1
        scope_param "$scope" "$key" 1 2>&1 >/dev/null
        ;;
      *) load_throttle_config 2>&1 >/dev/null ;;
    esac
  )"
  rm -f "$tmp"
  printf '%s' "$out"
  [ -z "$out" ]
}

# 整份設定跑一次 reader，收齊所有警告。set 用「改之前 vs 改之後」的差集判斷
# 本次改動有沒有引入新問題——單鍵隔離驗證看不到欄位之間的關係，會把
# 「capacity=200 時設 cost=99」這種合法組合誤擋。
#   $1 設定檔路徑；stdout 逐行印警告
config_warnings() {
  local f="$1" s k cap cost
  (
    THROTTLE_CONFIG="$f"
    load_throttle_config 2>&1 >/dev/null
    # scope 覆寫由 scope_param 守門，load_throttle_config 看不到
    for s in $THROTTLE_SCOPES; do
      for k in $SCOPE_KEYS; do scope_param "$s" "$k" 1 2>&1 >/dev/null; done
    done
    # scope 層的 cost>capacity 檢查位在 bucket_take，不在任何 io 函式裡；
    # 這是全檔唯一一處回顯規則，避免要動到節流的執行路徑才驗得到
    load_throttle_config >/dev/null 2>&1
    for s in $THROTTLE_SCOPES; do
      cap="$(scope_param "$s" capacity "$TH_CAPACITY" 2>/dev/null)"
      cost="$(scope_param "$s" cost "$TH_COST" 2>/dev/null)"
      [ "$cost" -gt "$cap" ] 2>/dev/null && \
        echo "[warn] scope ${s} 的 cost（${cost}）大於 capacity（${cap}）"
    done
  ) | sort -u
}

# ── show ─────────────────────────────────────────────────────────

# 某個路徑是不是「生效中的覆寫」：檔案裡是數字，且 reader 最後採用的就是它。
#   $1 點號路徑  $2 目前生效值
#
# 只看 JSON 型別不夠：cost=0 是數字但會被 reader 退回預設，只驗型別會把它標成
# 「來自設定檔」，顯示的卻是預設值——使用者拿到的是錯的值來源
effective_override() {
  local raw
  config_exists || return 1
  raw="$(jq -r --arg p "$1" \
    '(getpath($p|split(".")) // empty) | if type == "number" then . else empty end' \
    "$THROTTLE_CONFIG" 2>/dev/null)"
  [ -n "$raw" ] && [ "$raw" = "$2" ]
}

pad() { printf '%-*s' "$2" "$1"; }

do_show() {
  local json=0
  # 未知旗標要擋下，🚫 不得靜默當成沒帶——使用者會以為自己拿到了指定的輸出格式
  case "${1:-}" in
    "")     ;;
    --json) json=1 ;;
    *)      echo "錯誤：show 只接受 --json" >&2; return 2 ;;
  esac
  [ $# -gt 1 ] && { echo "錯誤：show 只接受 --json" >&2; return 2; }

  load_throttle_config 2>/dev/null

  if [ "$json" -eq 1 ]; then
    show_json
    return 0
  fi

  printf '設定檔：%s' "$THROTTLE_CONFIG"
  if config_exists; then
    config_parses && printf '\n' || printf '（內容不是合法 JSON，reader 全面改用內建預設）\n'
  else
    printf '（不存在，使用內建預設）\n'
  fi
  printf '\n'

  # 桶參數逐 scope 攤開：設定是繼承模型，只看檔案原文算不出某個 scope 的最終值
  printf '  '; pad scope 10; pad capacity 10; pad cost 8; pad refill 8; pad burst 7; printf '來源\n'
  local s cap cost rf src
  for s in default $THROTTLE_SCOPES; do
    if [ "$s" = default ]; then
      cap="$TH_CAPACITY"; cost="$TH_COST"; rf="$TH_REFILL"
      if effective_override scopes.default.capacity "$cap" \
        || effective_override scopes.default.cost "$cost" \
        || effective_override scopes.default.refill_seconds "$rf"; then src="設定檔"; else src="內建"; fi
    else
      cap="$(scope_param "$s" capacity "$TH_CAPACITY" 2>/dev/null)"
      cost="$(scope_param "$s" cost "$TH_COST" 2>/dev/null)"
      rf="$(scope_param "$s" refill_seconds "$TH_REFILL" 2>/dev/null)"
      src=""
      if config_exists; then
        local k kv
        for k in $SCOPE_KEYS; do
          case "$k" in capacity) kv="$cap" ;; cost) kv="$cost" ;; *) kv="$rf" ;; esac
          effective_override "scopes.$s.$k" "$kv" && src+="$k "
        done
      fi
      [ -n "$src" ] && src="覆寫 ${src% }" || src="繼承 default"
    fi
    printf '  '; pad "$s" 10; pad "$cap" 10; pad "$cost" 8; pad "$rf" 8
    pad "$((cost > 0 ? cap / cost : 0))" 7; printf '%s\n' "$src"
  done
  printf '\n  burst＝capacity/cost，refill 為基數秒數；實際恢復速率另受顧問額度倍率調整\n\n'

  printf '  其他參數（★＝來自設定檔）\n'
  local p v
  for p in $TOP_KEYS; do
    case "$p" in
      quota_thresholds.low_below)  v="$TH_LOW_BELOW" ;;
      quota_thresholds.high_at)    v="$TH_HIGH_AT" ;;
      quota_cache_ttl_seconds)     v="$TH_CACHE_TTL" ;;
      quota_stale_max_seconds)     v="$TH_CACHE_STALE" ;;
      lock_timeout_seconds)        v="$TH_LOCK_TIMEOUT" ;;
      gc_interval_seconds)         v="$TH_GC_INTERVAL" ;;
      gc_max_age_seconds)          v="$TH_GC_MAX_AGE" ;;
    esac
    printf '    '; pad "$p" 30
    if effective_override "$p" "$v"; then printf '%-10s★\n' "$v"; else printf '%s\n' "$v"; fi
  done
}

show_json() {
  local s cap cost rf scopes_json="{}"
  for s in $THROTTLE_SCOPES; do
    cap="$(scope_param "$s" capacity "$TH_CAPACITY" 2>/dev/null)"
    cost="$(scope_param "$s" cost "$TH_COST" 2>/dev/null)"
    rf="$(scope_param "$s" refill_seconds "$TH_REFILL" 2>/dev/null)"
    scopes_json="$(jq -c --arg s "$s" --argjson c "$cap" --argjson k "$cost" --argjson r "$rf" \
      '.[$s] = {capacity:$c, cost:$k, refill_seconds:$r}' <<<"$scopes_json")"
  done
  jq -n --arg path "$THROTTLE_CONFIG" \
        --argjson exists "$(config_exists && echo true || echo false)" \
        --argjson parses "$(config_parses && echo true || echo false)" \
        --argjson d "$(jq -n --argjson c "$TH_CAPACITY" --argjson k "$TH_COST" --argjson r "$TH_REFILL" \
                        '{capacity:$c, cost:$k, refill_seconds:$r}')" \
        --argjson sc "$scopes_json" \
        --argjson lb "$TH_LOW_BELOW" --argjson ha "$TH_HIGH_AT" \
        --argjson ttl "$TH_CACHE_TTL" --argjson stale "$TH_CACHE_STALE" \
        --argjson lt "$TH_LOCK_TIMEOUT" --argjson gi "$TH_GC_INTERVAL" --argjson gm "$TH_GC_MAX_AGE" \
    '{config_path:$path, config_exists:$exists, config_parses:$parses,
      effective:{default:$d, scopes:$sc,
                 quota_thresholds:{low_below:$lb, high_at:$ha},
                 quota_cache_ttl_seconds:$ttl, quota_stale_max_seconds:$stale,
                 lock_timeout_seconds:$lt, gc_interval_seconds:$gi, gc_max_age_seconds:$gm}}'
}

# ── check：檢查並修復已失效的內容 ──────────────────────────────────
#
# renew 的邊界：**只動 reader 現在就已經在忽略或退回預設的欄位**。修完的節流
# 行為與修之前完全相同，差別只有檔案變乾淨、每次呼叫的 [warn] 消失。
#
# 🚫 不動生效中的值。使用者釘住的覆寫與新內建預設不同時只回報——安裝流程會
#    無人看管地跑本子命令，自動改生效值等於趁機偷換使用者的政策。
# 🚫 不刪陌生欄位。認不得可能是工具比 reader 舊或新，刪除不可逆。

# 內建預設：讓 reader 在「沒有設定檔」的狀態下自己算一次，🚫 不在本檔複製預設值
builtin_of() {
  local path="$1"
  (
    THROTTLE_CONFIG="/nonexistent/throttle.json"
    load_throttle_config >/dev/null 2>&1
    case "$path" in
      scopes.default.capacity)      printf '%s' "$TH_CAPACITY" ;;
      scopes.default.cost)          printf '%s' "$TH_COST" ;;
      scopes.default.refill_seconds) printf '%s' "$TH_REFILL" ;;
      quota_thresholds.low_below)   printf '%s' "$TH_LOW_BELOW" ;;
      quota_thresholds.high_at)     printf '%s' "$TH_HIGH_AT" ;;
      quota_cache_ttl_seconds)      printf '%s' "$TH_CACHE_TTL" ;;
      quota_stale_max_seconds)      printf '%s' "$TH_CACHE_STALE" ;;
      lock_timeout_seconds)         printf '%s' "$TH_LOCK_TIMEOUT" ;;
      gc_interval_seconds)          printf '%s' "$TH_GC_INTERVAL" ;;
      gc_max_age_seconds)           printf '%s' "$TH_GC_MAX_AGE" ;;
    esac
  )
}

do_check() {
  local dry=0
  case "${1:-}" in
    --dry-run) dry=1; shift ;;
    "") ;;
    *) echo "錯誤：check 只接受 --dry-run" >&2; return 2 ;;
  esac
  [ $# -gt 0 ] && { echo "錯誤：check 只接受 --dry-run" >&2; return 2; }

  printf '節流設定：%s\n' "$THROTTLE_CONFIG"

  # 缺檔是合法狀態：走內建預設即可，🚫 不得順手建一個
  if ! config_exists; then
    printf '  ✔ 設定檔不存在，使用內建預設，無需更新\n'
    return 0
  fi
  # 壞 JSON 無法安全地局部修復：結構都讀不出來，改哪裡都是猜
  if ! config_parses; then
    printf '  ⚠ 內容不是合法 JSON，reader 會全面改用內建預設\n'
    printf '    本子命令不修復這種情況（結構讀不出來，改哪裡都是猜）\n'
    printf '    請自行檢視，或刪除該檔回到內建預設\n'
    return 0
  fi

  local fixed=() manual=() unknown=() cfg
  cfg="$(read_config)"
  KNOWN_PREFIXES="$(known_prefixes)"

  # 第一趟：逐一檢視已知欄位。從 known_keys 出發而非走訪檔案的葉節點——
  # 空物件與空陣列沒有葉節點，走訪法看不到它們，但 reader 一樣會靜默忽略
  local p t val warn bi root
  while IFS= read -r p; do
    t="$(jq -r --arg p "$p" 'getpath($p|split(".")) | type' <<<"$cfg" 2>/dev/null)"
    { [ -z "$t" ] || [ "$t" = null ]; } && continue   # 沒設定，沿用上層或內建
    # 型別錯是唯一不會被 reader 警告的失效：jq 的 n(p; d) 直接換成預設，無聲
    if [ "$t" != number ]; then
      fixed+=("$p：型別是 ${t}、不是數字，reader 靜默改用預設 → 移除")
      cfg="$(jq --arg p "$p" 'delpaths([$p|split(".")])' <<<"$cfg")"
      continue
    fi
    val="$(jq -c --arg p "$p" 'getpath($p|split("."))' <<<"$cfg")"
    if ! warn="$(probe_value "$p" "$val")"; then
      fixed+=("$p=${val}：${warn#\[warn\] } → 移除")
      cfg="$(jq --arg p "$p" 'delpaths([$p|split(".")])' <<<"$cfg")"
      continue
    fi
    # 合法且生效中。與新內建預設不同只是提醒，🚫 不動它
    bi="$(builtin_of "$p")"
    [ -n "$bi" ] && [ "$val" != "$bi" ] && \
      manual+=("$p=${val}（目前內建預設為 ${bi}；這是生效中的覆寫，未更動）")
  done < <(known_keys)

  # 第二趟：找出不屬於任何已知欄位的子樹。走訪所有節點（不只葉節點），
  # 每個陌生子樹只報最上層那一個
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = "version" ] && continue
    is_known_key "$p" && continue
    printf '%s\n' "$KNOWN_PREFIXES" | grep -qxF "$p" && continue
    root="$(unknown_root "$p")"
    printf '%s\n' "${unknown[@]:-}" | grep -qxF "$root" || unknown+=("$root")
  done < <(jq -r 'paths | map(tostring) | join(".")' <<<"$cfg" 2>/dev/null)

  # version 是本工具寫入時蓋的 schema 戳記，日後欄位改名時靠它判斷要不要 migrate
  local fv
  fv="$(jq -r '.version // empty' <<<"$cfg" 2>/dev/null)"
  if [ -z "$fv" ]; then
    fixed+=("version：缺少 schema 戳記 → 補上 ${SCHEMA_VERSION}")
    cfg="$(jq --argjson v "$SCHEMA_VERSION" '.version = $v' <<<"$cfg")"
  elif [ "$fv" != "$SCHEMA_VERSION" ]; then
    manual+=("version=${fv}：本版工具只認得 schema ${SCHEMA_VERSION}，未定義的 migration 不自行猜")
  fi

  # 關係型規則（cost > capacity）單欄位驗不出來，要丟哪一個又是使用者的意圖
  local relwarn tmp line
  tmp="$(mktemp "${TMPDIR:-/tmp}/throttle-rel.XXXXXX")" && {
    printf '%s' "$cfg" >"$tmp"
    relwarn="$(config_warnings "$tmp")"
    rm -f "$tmp"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      manual+=("${line#\[warn\] }（要捨棄哪一個屬使用者意圖，未更動）")
    done <<<"$relwarn"
  }

  local n_fixed=${#fixed[@]} n_manual=${#manual[@]} n_unknown=${#unknown[@]} i
  if [ "$n_fixed" -eq 0 ] && [ "$n_manual" -eq 0 ] && [ "$n_unknown" -eq 0 ]; then
    printf '  ✔ 無需更新\n'
    return 0
  fi

  if [ "$n_fixed" -gt 0 ]; then
    [ "$dry" -eq 1 ] && printf '  可修復 %d 項（--dry-run，未實際修改）：\n' "$n_fixed" \
                     || printf '  已修復 %d 項：\n' "$n_fixed"
    for i in "${fixed[@]}"; do printf '    - %s\n' "$i"; done
  fi
  [ "$n_manual" -gt 0 ] && {
    printf '  需要你判斷 %d 項：\n' "$n_manual"
    for i in "${manual[@]}"; do printf '    - %s\n' "$i"; done
  }
  [ "$n_unknown" -gt 0 ] && {
    printf '  本版工具不認得 %d 項（未更動——可能來自不同版本的 skill）：\n' "$n_unknown"
    for i in "${unknown[@]}"; do printf '    - %s\n' "$i"; done
  }

  if [ "$n_fixed" -gt 0 ] && [ "$dry" -eq 0 ]; then
    write_config < <(printf '%s' "$cfg" | tidy_config) || return 1
    printf '  原檔已備份：%s.bak\n' "$THROTTLE_CONFIG"
  fi
  return 0
}

# ── set / unset ──────────────────────────────────────────────────

do_set() {
  local key="${1:-}" val="${2:-}"
  [ $# -eq 2 ] || { echo "錯誤：set 需要 <key> 與 <value>" >&2; usage; return 2; }
  is_known_key "$key" || {
    echo "錯誤：不認得的設定項「${key}」" >&2
    echo "可設定的項目：" >&2; known_keys | sed 's/^/  /' >&2
    return 2
  }
  # 只收整數字面量：JSON 允許的其他數字形式（1e3、1.0）在 reader 眼中都不是正整數
  case "$val" in ""|*[!0-9-]*|-*-*) echo "錯誤：值必須是整數：${val}" >&2; return 2 ;; esac

  config_exists && ! config_parses && {
    echo "錯誤：現有設定檔不是合法 JSON，拒絕覆寫（先執行 $0 check 查看）" >&2; return 1
  }
  local cfg tmp before after added
  cfg="$(read_config | jq --arg p "$key" --argjson v "$val" \
    '(.version //= 1) | setpath($p|split("."); $v)')" || { echo "錯誤：設定合併失敗" >&2; return 1; }

  # 寫入前先讓 reader 判一次：擋在寫檔之前，使用者不會拿到一個自己不生效的設定。
  # 比的是差集而非「改後有無警告」——設定檔本來就有的問題不該讓這次改動背鍋
  tmp="$(mktemp "${TMPDIR:-/tmp}/throttle-set.XXXXXX")" || { echo "錯誤：無法建立暫存檔" >&2; return 1; }
  printf '%s' "$cfg" >"$tmp"
  before="$(config_exists && config_warnings "$THROTTLE_CONFIG" || true)"
  after="$(config_warnings "$tmp")"
  rm -f "$tmp"
  added="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')"
  if [ -n "$added" ]; then
    printf '錯誤：這個設定不會生效——\n' >&2
    printf '%s\n' "$added" | sed 's/^\[warn\] /      /' >&2
    echo "      未寫入任何內容" >&2
    return 2
  fi

  write_config <<<"$cfg" || return 1
  printf '已設定 %s = %s（%s）\n\n' "$key" "$val" "$THROTTLE_CONFIG"
  do_show
}

do_unset() {
  local key="${1:-}"
  [ $# -eq 1 ] || { echo "錯誤：unset 需要一個 <key>" >&2; usage; return 2; }
  # 整個 scope 一起移除是常用操作：逐欄位 unset 要打三次還容易漏
  local ok=0 s
  is_known_key "$key" && ok=1
  for s in $THROTTLE_SCOPES default; do [ "$key" = "scopes.$s" ] && ok=1; done
  [ "$ok" -eq 1 ] || { echo "錯誤：不認得的設定項「${key}」" >&2; return 2; }

  config_exists || { echo "設定檔不存在，無事可做：${THROTTLE_CONFIG}" >&2; return 0; }
  config_parses || { echo "錯誤：設定檔不是合法 JSON，拒絕覆寫（先執行 $0 check）" >&2; return 1; }

  jq -e --arg p "$key" 'getpath($p|split(".")) != null' "$THROTTLE_CONFIG" >/dev/null 2>&1 || {
    echo "${key} 本來就沒有設定，無事可做" >&2; return 0
  }
  local cfg
  cfg="$(jq --arg p "$key" 'delpaths([$p|split(".")])' "$THROTTLE_CONFIG" | tidy_config)" \
    || { echo "錯誤：設定合併失敗" >&2; return 1; }
  write_config <<<"$cfg" || return 1
  printf '已移除 %s（%s）\n\n' "$key" "$THROTTLE_CONFIG"
  do_show
}

# ── 分派 ─────────────────────────────────────────────────────────

CMD="${1:-}"
case "$CMD" in
  show)      shift; do_show "$@" ;;
  check)     shift; do_check "$@" ;;
  set)       shift; do_set "$@" ;;
  unset)     shift; do_unset "$@" ;;
  -h|--help) usage; exit 0 ;;
  "")        usage >&2; exit 2 ;;
  *)         echo "錯誤：未知的子命令「$CMD」" >&2; usage >&2; exit 2 ;;
esac
