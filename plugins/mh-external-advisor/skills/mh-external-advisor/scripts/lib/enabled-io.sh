#!/usr/bin/env bash
# enabled-io.sh — 啟用清單的共用讀取與驗證（供 advisor-list.sh / advisor-set.sh 引用）
#
# 用途：把「什麼是合法的顧問名」「什麼是合法的設定檔」「哪些 adapter 算支援」
#       三條規則放在同一處：各自實作會漂移，驗證規則一旦不一致，
#       setter 收下的名稱 getter 可能拒收（反之亦然）。
#
# 匯出：ADVISOR_CONFIG_DIR / ADVISOR_CONFIG（設定檔路徑）
#       valid_name / scan_supported / is_supported / read_enabled / join_names
#
# 使用前提：引用者需自行確保 SCRIPTS_DIR 已定義（指向本 skill 的 scripts/ 目錄）。

# 設定檔位置：依 XDG 慣例，未設 XDG_CONFIG_HOME 時 fallback 至 $HOME/.config
ADVISOR_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mh-external-advisor"
ADVISOR_CONFIG="$ADVISOR_CONFIG_DIR/enabled.json"

# 顧問名字元集：僅小寫英數與連字號。
# 名稱會用來組出 scripts/ask-<name>.sh 路徑，含 / 或 .. 者可逃出 scripts/ 指向他處
valid_name() {
  [[ "${1:-}" =~ ^[a-z0-9-]+$ ]]
}

# 掃描 Level 1 支援清單填入全域 SUPPORTED 陣列。
# 「支援」＝scripts/ 下可執行的 ask-*.sh：getter 要實際執行它取 --info，
# 只驗 -f 會讓「檔案在但沒有執行權限」在 setter 收下、到 getter 才失敗
scan_supported() {
  SUPPORTED=()
  local f n
  for f in "$SCRIPTS_DIR"/ask-*.sh; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    n="${f##*/ask-}"
    SUPPORTED+=("${n%.sh}")
  done
}

# 精確集合比對：判斷名稱是否在 SUPPORTED 內。
# 不可改用「組出路徑再測 -f」——那等於讓設定檔內容決定要測哪個路徑
is_supported() {
  local want="${1:-}" n
  for n in "${SUPPORTED[@]:-}"; do
    [ "$n" = "$want" ] && return 0
  done
  return 1
}

# 讀出啟用清單（一行一個名稱，僅輸出合法名稱）。
#
# 兩級處置，因為兩種壞法的合理反應不同：
#   結構壞（version 非 1、enabled 不是陣列）：整份不可信 → 警告後無輸出，退化為「尚未啟用」
#   單項壞（非字串、含非法字元）：其餘項仍可信 → 只丟該項並警告，不牽連合法項
#     （否則 `--add` 遇到一個殘留的壞名稱，會把使用者原本設好的顧問一起清掉）
#
# 逐項驗證放在 jq 內而非 bash：多行字串會被 read 拆成多個名稱，
# 到 bash 端已無法分辨（實測 ["codex\nclaude"] 會被當成兩支顧問）。
# 錨點用 \A \z 而非 ^ $——明確表意為「整個字串」而非「某一行」。
read_enabled() {
  [ -f "$ADVISOR_CONFIG" ] || return 0
  local out total kept
  out="$(jq -r '
    if (.version? == 1) and ((.enabled? | type) == "array")
    then (.enabled | length), (.[]? | empty),
         ([.enabled[] | select(type == "string" and test("\\A[a-z0-9-]+\\z"))] | .[])
    else error("structure")
    end' "$ADVISOR_CONFIG" 2>/dev/null)" || {
    echo "[warn] 啟用清單結構不合（${ADVISOR_CONFIG}），視同尚未啟用；請重跑 setter 重建" >&2
    return 0
  }
  # 第一行是原始項數，其餘為通過驗證的名稱——用來偵測「有項目被丟掉」
  total="$(printf '%s\n' "$out" | head -1)"
  kept="$(printf '%s\n' "$out" | tail -n +2 | grep -c . || true)"
  if [ "$total" -gt "$kept" ]; then
    echo "[warn] 啟用清單有 $((total - kept)) 項名稱不合法，已略過（請重跑 setter 清理）" >&2
  fi
  printf '%s\n' "$out" | tail -n +2
}

# 以「, 」串接陣列：${arr[*]} 只取 IFS 首字元當分隔符，無法直接產生「, 」
join_names() {
  local out="" n
  for n in "$@"; do [ -n "$n" ] || continue; [ -n "$out" ] && out+=", "; out+="$n"; done
  printf '%s' "${out:-無}"
}
