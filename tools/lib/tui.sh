# shellcheck shell=bash
# lib/tui.sh — 互動選單：checkbox 選單、skill 選單與 agent × skill 二維矩陣
# 由 tools/skills.sh 載入，沿用其設定的全域變數（REPO_ROOT、MARKETPLACE、SOURCE 等）；只定義函式與常數，不執行動作

# ── 通用 checkbox 選單 ────────────────────────────────────────────────
# 兩個地方要挑東西（要處理哪些 agent、哪些 skill），形狀相同，故抽成同一組函式。
# 呼叫端以 process substitution 餵入項目清單（不可用 pipeline——那會讓函式跑在
# subshell 裡，寫不回全域 PICKED）：
#     pick_list agent 安裝 agent_desc < <(printf '%s\n' $ALL_AGENTS)
# 結果：PICKED＝空白分隔的選擇；PICKED_ALL＝1 表示全選（呼叫端可據此走「全部」的既有路徑）

PICKED=""      # 選擇結果（空白分隔）
PICKED_ALL=""  # 1 ＝使用者選了全部

# pick_tui <名詞> <動詞> <描述函式> — 上下鍵移動、空白鍵勾選的 checkbox 選單
# I/O：項目清單自 stdin（每行一個）；選單畫在 stderr；結果寫入 PICKED／PICKED_ALL
#      回 0 ＝繼續；回 1 ＝使用者取消
#
# DECISION: 不引入 fzf／whiptail／dialog——本 repo 目前只依賴 jq 與 rsync，
#           為了一個選單多一個必裝的外部程式並不划算；純 bash + tput 自足且行為可控。
#           代價是要自己處理游標與重畫，故有 fit() 的截斷與 trap 的還原
pick_tui() {
  local noun="$1" verb="$2" descfn="$3"
  local all=() lines=() n i cur=0 key rest cols namew descw
  local up clr hide show bold dim rst
  local -a mark

  while IFS= read -r i; do [ -n "$i" ] && all+=("$i"); done
  n=${#all[@]}; [ "$n" -gt 0 ] || return 0
  for (( i=0; i<n; i++ )); do mark[i]=1; done   # 預設全選，最常見的意圖是「全部」

  up="$(tput cuu1)"; clr="$(tput el)"; hide="$(tput civis)"; show="$(tput cnorm)"
  bold="$(tput bold)"; dim="$(tput dim)"; rst="$(tput sgr0)"
  cols="$(tput cols)"

  # 名稱欄取最長名稱＋2，但不得吃掉描述的空間；前綴 "❯ [x] " 固定 6 欄
  namew=0
  for i in "${all[@]}"; do
    [ "$(str_width "$i")" -gt "$namew" ] && namew="$(str_width "$i")"
  done
  namew=$((namew + 2))
  [ "$namew" -gt $((cols - 16)) ] && namew=$((cols - 16))
  descw=$((cols - namew - 6))

  # DECISION: 每列只在進選單時算一次——fit() 逐字元呼叫 wc，放進 draw() 會讓每次
  #           按鍵都重算 n×描述長度 次子行程，在慢終端上按鍵會明顯延遲
  for (( i=0; i<n; i++ )); do
    lines[i]="$(pad "$(fit "${all[i]}" "$namew")" "$namew")$(fit "$("$descfn" "${all[i]}")" "$descw")"
  done

  # 任何離開路徑都要還原游標，否則使用者的終端會一直看不到游標
  tui_restore() { printf '%s' "$show" >&2; trap - INT TERM HUP; }
  trap 'tui_restore; return 1' INT TERM HUP

  draw() {
    local i prefix box
    for (( i=0; i<n; i++ )); do
      [ "$i" = "$cur" ] && prefix="${bold}❯ ${rst}" || prefix="  "
      [ "${mark[i]}" = 1 ] && box="${bold}[x]${rst}" || box="[ ]"
      printf '%s%s %s %s\n' "$clr" "$prefix" "$box" "${lines[i]}" >&2
    done
  }

  printf '\n要%s哪些 %s：%s↑↓ 移動．空白 勾選．a 全選／全不選．Enter 確認．q 取消%s\n\n' \
         "$verb" "$noun" "$dim" "$rst" >&2
  printf '%s' "$hide" >&2
  draw

  while :; do
    IFS= read -rsn1 key < /dev/tty || key=q
    # 方向鍵是 ESC [ A/B 三個位元組，需再讀兩個；單獨的 ESC 則當取消
    if [ "$key" = $'\e' ]; then
      read -rsn2 -t 0.05 rest < /dev/tty || rest=""
      key="$key$rest"
    fi
    case "$key" in
      $'\e[A'|k) cur=$(( (cur - 1 + n) % n )) ;;
      $'\e[B'|j) cur=$(( (cur + 1) % n )) ;;
      ' ')       [ "${mark[cur]}" = 1 ] && mark[cur]=0 || mark[cur]=1 ;;
      a|A)       local any=0
                 for (( i=0; i<n; i++ )); do [ "${mark[i]}" = 0 ] && any=1; done
                 for (( i=0; i<n; i++ )); do mark[i]=$any; done ;;
      ''|$'\n') break ;;
      q|Q|$'\e') tui_restore; printf '→ 已取消\n' >&2; return 1 ;;
      *)         continue ;;
    esac
    for (( i=0; i<n; i++ )); do printf '%s' "$up" >&2; done   # 回到清單頂端重畫
    draw
  done

  tui_restore
  pick_finish all[@] mark[@] "$n"
}

# pick_prompt <名詞> <動詞> <描述函式> — 編號輸入版（終端不支援游標定位時的退路）
# I/O：與 pick_tui 相同
pick_prompt() {
  local noun="$1" verb="$2" descfn="$3"
  local all=() n i sel picked=() idx
  local -a mark

  while IFS= read -r i; do [ -n "$i" ] && all+=("$i"); done
  n=${#all[@]}; [ "$n" -gt 0 ] || return 0

  {
    printf '\n要%s哪些 %s：\n\n' "$verb" "$noun"
    for (( i=0; i<n; i++ )); do
      printf '  %d) ' "$((i+1))"; pad "${all[$i]}" 26; printf '%s\n' "$("$descfn" "${all[$i]}")"
    done
    printf '\n'
  } >&2

  while :; do
    printf '請選擇（編號，空白或逗號分隔／a＝全部／q＝取消）[a]：' >&2
    IFS= read -r sel < /dev/tty || sel=a
    sel="${sel//,/ }"                       # 逗號與空白等價，使用者不必記格式
    case "${sel:-a}" in
      a|A|all)  for (( i=0; i<n; i++ )); do mark[i]=1; done
                pick_finish all[@] mark[@] "$n"; return ;;
      q|Q|quit) printf '→ 已取消\n' >&2; return 1 ;;
    esac

    picked=(); idx=ok
    for (( i=0; i<n; i++ )); do mark[i]=0; done
    for i in $sel; do
      case "$i" in ''|*[!0-9]*) idx=bad; break ;; esac
      [ "$i" -ge 1 ] && [ "$i" -le "$n" ] || { idx=bad; break; }
      mark[$((i-1))]=1; picked+=(x)
    done
    if [ "$idx" = ok ] && [ "${#picked[@]}" -gt 0 ]; then
      pick_finish all[@] mark[@] "$n"; return
    fi
    printf '  輸入無效，請輸入 1-%d 的編號、a 或 q\n' "$n" >&2
  done
}

# pick_finish <項目陣列[@]> <勾選陣列[@]> <總數> — 把勾選結果收斂成 PICKED／PICKED_ALL
# I/O：以陣列名稱展開傳入（bash 慣用法）；回 0 ＝有選；回 1 ＝一個都沒選（視同取消）
pick_finish() {
  local all=("${!1}") mark=("${!2}") n="$3" i out=()
  for (( i=0; i<n; i++ )); do [ "${mark[i]}" = 1 ] && out+=("${all[i]}"); done
  if [ "${#out[@]}" -eq 0 ]; then
    printf '\n→ 一個都沒選，已取消\n' >&2; return 1
  fi
  PICKED="${out[*]}"
  [ "${#out[@]}" = "$n" ] && PICKED_ALL=1 || PICKED_ALL=""
  printf '\n→ %s\n\n' "$PICKED" >&2
  return 0
}

# pick_list <名詞> <動詞> <描述函式> — 選單入口，依終端能力挑實作
# I/O：項目清單自 stdin；結果寫入 PICKED／PICKED_ALL
# DECISION: 終端不支援游標定位時退回編號輸入版，而不是直接放棄選擇能力——
#           TERM=dumb、非 xterm 相容終端或無 tput 的精簡環境都還是能挑
pick_list() {
  local items n
  items="$(cat)"; n="$(printf '%s\n' "$items" | grep -c .)"
  # DECISION: 用 process substitution 而非 pipeline——pipeline 會讓被呼叫的函式跑在
  #           subshell 裡，PICKED／PICKED_ALL 寫不回呼叫端，選擇結果會靜默遺失
  if tui_capable "$n"; then
    pick_tui   "$@" < <(printf '%s\n' "$items")
  else
    pick_prompt "$@" < <(printf '%s\n' "$items")
  fi
}

# agent_desc <agent> — 選單裡顯示的 agent 說明（方式＋會動到哪裡）
# I/O：輸入 agent 代號；輸出說明文字到 stdout
agent_desc() {
  local mode; mode="$(agent_mode "$1")" || return
  if [ "$mode" != copy ]; then printf '%s  %s' "$mode" "$(agent_source "$1")"
  else                         printf 'copy         %s' "$(agent_skills_dir "$1")"; fi
}

# pick_skills <動詞> — 互動選單入口，把使用者的選擇寫進全域 SKILLS
# I/O：輸入顯示用動詞（安裝｜移除）；回 0 ＝繼續；回 1 ＝使用者取消
#
# DECISION: 只在「互動終端 ＋ 未指定 SKILLS ＋ 子命令為 install/remove」三者同時成立時才跳選單。
#           少了 TTY 判斷，CI 或 `make install < /dev/null` 會停在 read 等一個永遠不會來的
#           輸入；非互動情境一律沿用舊行為（全部），才不會把自動化流程弄壞。
#           SKILLS 仍保留為覆寫途徑：指定了就直接照做，不再多問一次
# DECISION: update 不跳選單——「把裝著的都更新到最新」本來就是它唯一合理的意圖，
#           而未安裝者本就會被略過，多問一次只是徒增步驟
# DECISION: 終端不支援游標定位時退回編號輸入版，而不是直接放棄選擇能力——
#           TERM=dumb、非 xterm 相容終端或無 tput 的精簡環境都還是能挑
pick_skills() {
  pick_list skill "$1" skill_desc < <(repo_skills) || return 1
  # 全選時清空 SKILLS，讓後續流程走「全部」的既有路徑
  [ -n "$PICKED_ALL" ] && SKILLS="" || SKILLS="$PICKED"
  return 0
}

# ════════════════ 二維勾選矩陣（agent × skill）════════════════
#
# 安裝狀態本來就是 agent × skill 的二維資料。壓成一維清單就得補上「聚合成幾態」
# 「預設勾選哪個方向」「執行前的差異預覽」等一堆補丁；直接畫成格子則全部不需要——
# 畫面本身就是狀態，使用者改成什麼就同步成什麼。
#
# 勾選框一律代表「**應該裝著**」，install 與 remove 共用同一個意義：
#   install ─ 起始狀態＝現況，改完即同步（勾起來是裝、取消是移除）
#   remove  ─ 起始狀態＝全空（Enter 就是清光），可再勾回想留下的
#
# 結果寫入關聯陣列 TGT；呼叫端以 CUR 與 TGT 的差集算出每個 agent 要裝／要移除什麼。

declare -A CUR   # CUR[agent,skill]=1 表示目前裝著
declare -A TGT   # TGT[agent,skill]=1 表示使用者希望裝著

# matrix_load — 掃出目前的安裝狀態，填入 CUR
# I/O：無參數；填 CUR；進度提示走 stderr
# DECISION: 每個 agent 只查一次 CLI 再逐 skill 比對，不是每格各查一次——
#           `claude plugin list` 約 0.16s，16 格各查一次會拖到 2 秒以上
matrix_load() {
  local a s mode listing
  for a in $ALL_AGENTS; do
    mode="$(agent_mode "$a")" || continue
    have "$a" || continue
    if [ "$mode" != copy ]; then
      case "$a" in
        agy)   listing="$(agy_plugin_names)" ;;
        codex) listing="$(codex_plugin_list)" ;;
        *)     listing="$(eval "$a plugin list" 2>/dev/null)" ;;
      esac
      while IFS= read -r s; do
        case "$a" in
          claude) grep -qF "$s@$MARKETPLACE" <<<"$listing" && CUR["$a,$s"]=1 ;;
          codex)  awk -v p="$s@$MARKETPLACE" '$1==p { sub(/^[^ \t]+[ \t]+/,""); print; exit }' \
                    <<<"$listing" | grep -q '^installed' && CUR["$a,$s"]=1 ;;
          agy)    grep -qxF "$s" <<<"$listing" && CUR["$a,$s"]=1 ;;
        esac
        # remove 時舊副本也算現況，否則矩陣算不出差集、清不到殘留
        [ "$CMD" = remove ] && has_copy_of "$a" "$s" && CUR["$a,$s"]=1
      done < <(repo_skills)
    else
      while IFS= read -r s; do
        has_copy_of "$a" "$s" && CUR["$a,$s"]=1
      done < <(repo_skills)
    fi
  done
}

# matrix_agents — 這次要顯示在格子裡的 agent（CLI 沒裝的不列，選了也沒用）
matrix_agents() {
  local a
  for a in $TARGETS; do have "$a" && printf '%s\n' "$a"; done
}

# pick_matrix <動詞> — agent × skill 的二維勾選介面
# I/O：輸入顯示用動詞（安裝｜移除）；畫面走 stderr；結果寫入 TGT
#      回 0 ＝確定；回 1 ＝取消
pick_matrix() {
  local verb="$1"
  local rows=() cols=() nr nc r c i cur_r=0 cur_c=0 key rest
  local namew colw=() total
  local up clr hide show bold dim rev rst
  local -A init

  while IFS= read -r i; do rows+=("$i"); done < <(repo_skills)
  while IFS= read -r i; do cols+=("$i"); done < <(matrix_agents)
  nr=${#rows[@]}; nc=${#cols[@]}
  { [ "$nr" -gt 0 ] && [ "$nc" -gt 0 ]; } || return 0

  # 起始狀態：install 用現況，remove 從全空開始
  for r in "${rows[@]}"; do for c in "${cols[@]}"; do
    if [ "$verb" = 安裝 ] && [ "${CUR[$c,$r]:-}" = 1 ]; then TGT["$c,$r"]=1; else TGT["$c,$r"]=0; fi
    init["$c,$r"]="${TGT[$c,$r]}"
  done; done

  up="$(tput cuu1)"; clr="$(tput el)"; hide="$(tput civis)"; show="$(tput cnorm)"
  bold="$(tput bold)"; dim="$(tput dim)"; rev="$(tput rev)"; rst="$(tput sgr0)"

  namew=0
  for i in "${rows[@]}"; do [ "$(str_width "$i")" -gt "$namew" ] && namew="$(str_width "$i")"; done
  namew=$((namew + 2))
  total=$((2 + namew)); for i in "${cols[@]}"; do
    c=$(( ${#i} > 3 ? ${#i} : 3 )); colw+=($((c + 2))); total=$((total + c + 2)); done

  tui_restore() { printf '%s' "$show" >&2; trap - INT TERM HUP; }
  trap 'tui_restore; return 1' INT TERM HUP

  # 畫面共 nr + 3 列（表頭、格子、空列、按鈕列）
  draw() {
    local r c line box
    printf '%s%s' "$clr" "$(printf '%*s' $((2 + namew)) '')" >&2
    for (( c=0; c<nc; c++ )); do printf '%s%s%s' "$dim" "$(pad "${cols[c]}" "${colw[c]}")" "$rst" >&2; done
    printf '\n' >&2
    for (( r=0; r<nr; r++ )); do
      [ "$r" = "$cur_r" ] && line="${bold}❯ ${rst}" || line="  "
      line+="$(pad "${rows[r]}" "$namew")"
      for (( c=0; c<nc; c++ )); do
        [ "${TGT[${cols[c]},${rows[r]}]}" = 1 ] && box="[x]" || box="[ ]"
        [ "${CUR[${cols[c]},${rows[r]}]:-}" = 1 ] && box="${bold}${box}${rst}" || box="${dim}${box}${rst}"
        [ "$r" = "$cur_r" ] && [ "$c" = "$cur_c" ] && box="${rev}${box}${rst}"
        line+="$(printf '%s%*s' "$box" $(( colw[c] - 3 )) '')"
      done
      printf '%s%s\n' "$clr" "$line" >&2
    done
    printf '%s\n' "$clr" >&2
    # 三個動作固定以按鍵觸發，不做成可移動的焦點——焦點只用來指「哪一格」，
    # 讓方向鍵的意義單一，不必在格子與按鈕之間切換模式
    printf '%s%s%s[u 還原]  [Esc 取消]  [Enter 確定]%s\n' \
           "$clr" "$(printf '%*s' $((2 + namew)) '')" "$dim" "$rst" >&2
  }

  # scope_toggle <範圍> — a/r/c 共用：範圍內有任一未勾就全勾，否則全不勾
  scope_toggle() {
    local scope="$1" r c any=0
    for (( r=0; r<nr; r++ )); do for (( c=0; c<nc; c++ )); do
      case "$scope" in
        all) ;; row) [ "$r" = "$cur_r" ] || continue ;; col) [ "$c" = "$cur_c" ] || continue ;;
      esac
      [ "${TGT[${cols[c]},${rows[r]}]}" = 0 ] && any=1
    done; done
    for (( r=0; r<nr; r++ )); do for (( c=0; c<nc; c++ )); do
      case "$scope" in
        all) ;; row) [ "$r" = "$cur_r" ] || continue ;; col) [ "$c" = "$cur_c" ] || continue ;;
      esac
      TGT["${cols[c]},${rows[r]}"]=$any
    done; done
  }

  printf '\n要%s哪些（%s粗體＝目前已裝%s）\n%s↑↓←→ 移動．空白 切換該格．a 全部／r 整列／c 整欄%s\n\n' \
         "$verb" "$dim" "$rst" "$dim" "$rst" >&2
  printf '%s' "$hide" >&2
  draw

  while :; do
    IFS= read -rsn1 key < /dev/tty || key=q
    if [ "$key" = $'\e' ]; then
      read -rsn2 -t 0.05 rest < /dev/tty || rest=""
      key="$key$rest"
    fi
    case "$key" in
      $'\e[A'|k) cur_r=$(( (cur_r - 1 + nr) % nr )) ;;
      $'\e[B'|j) cur_r=$(( (cur_r + 1) % nr )) ;;
      $'\e[D'|h) cur_c=$(( (cur_c - 1 + nc) % nc )) ;;
      $'\e[C'|l) cur_c=$(( (cur_c + 1) % nc )) ;;
      # 空白只做一件事：切換游標所在的那一格
      ' ')       [ "${TGT[${cols[cur_c]},${rows[cur_r]}]}" = 1 ] \
                   && TGT["${cols[cur_c]},${rows[cur_r]}"]=0 || TGT["${cols[cur_c]},${rows[cur_r]}"]=1 ;;
      a|A)       scope_toggle all ;;
      r|R)       scope_toggle row ;;
      c|C)       scope_toggle col ;;
      u|U)       for i in "${!init[@]}"; do TGT["$i"]="${init[$i]}"; done ;;
      ''|$'\n') break ;;
      q|Q|$'\e') tui_restore; printf '→ 已取消\n' >&2; return 1 ;;
      *)         continue ;;
    esac
    for (( i=0; i<nr+3; i++ )); do printf '%s' "$up" >&2; done
    draw
  done

  tui_restore
  printf '\n' >&2
  return 0
}
