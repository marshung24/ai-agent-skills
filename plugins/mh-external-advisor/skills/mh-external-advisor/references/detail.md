# mh-external-advisor 細節

## 清單腳本（getter / setter）

顧問清單分三層：**支援**＝`scripts/` 下可執行的 `ask-*.sh`（檔案系統為單一事實來源）；**啟用**＝使用者寫進設定檔的清單；**授權**＝本次對話中被點名的那支（見 SKILL.md）。

| 腳本 | 用途 | 結束碼 |
|------|------|--------|
| `advisor-list.sh` | 列出已啟用顧問及其呼叫式（各支的自述由 `ask-<ai>.sh --info` 提供，`{SELF}` 由 getter 換成絕對路徑） | 0 有已啟用顧問；4 尚未啟用；127 缺 `jq` |
| `advisor-set.sh` | 寫入啟用清單：`<ai>...` 覆寫、`--add`／`--remove`／`--clear` | 0 成功；2 參數錯誤（含不支援的顧問名——`--remove` 除外，見下）；127 缺 `jq` |

- 設定檔：`${XDG_CONFIG_HOME:-$HOME/.config}/mh-external-advisor/enabled.json`，格式 `{"version":1,"enabled":["codex",…]}`
- 設定檔 schema：`version` 必須為 `1`、`enabled` 必須是字串陣列，每項須符合 `\A[a-z0-9-]+\z`
- 壞法分兩級處置：**結構壞**（version 非 1、enabled 非陣列、非 JSON）→ 整份不可信，退化為「尚未啟用」；**單項壞**（非字串、含非法字元、含換行）→ 只丟該項並警告，合法項保留（否則 `--add` 會因一個殘留壞名稱清掉使用者原本設好的顧問）
- 檔案不存在、結構壞、清單為空**一律回 exit 4**——三者處置相同：請使用者重設
- getter 對讀出的每個名稱都先驗字元集、再與支援清單做**精確集合比對**才組路徑；不以設定檔內容直接組路徑測 `-f`（設定檔可能被 setter 以外的途徑寫入）
- 「支援」的判準是 `scripts/` 下**可執行**的 `ask-*.sh`（`-f` 且 `-x`）：只驗 `-f` 會讓「檔案在但沒有執行權限」在 setter 收下、到 getter 才失敗
- `advisor-set.sh` **不可並行**（read-modify-write 無鎖，理由見 design.md §7）
- setter 驗「支援」但**不驗 CLI 是否已安裝**——啟用是宣告擁有／想用，未安裝由各 adapter 執行時以 exit 127 擋；在 setter 擋會讓「先設定、之後再裝」不可能
- `--add`／`--remove` 讀既有清單時，會一併清掉「已無對應 adapter」的殘留名稱並警告——避免使用者移除某支後，設定檔裡的舊名一直跟著被寫回
- `--remove` 的參數**只驗字元集、不驗支援清單**（其餘模式驗兩者，不支援即 exit 2）：adapter 被移除後，其名稱可能仍留在設定檔裡，若比照他模式擋下就會變成「移不掉」

## 額度查詢

`advisor-quota.sh [<ai>...]`：查各顧問的訂閱額度餘量。可一次帶多支，無參數則查已啟用的全部；帶名稱時**只驗支援清單、不要求已啟用**（使用者明確點名者即查）。

| 結束碼 | 意義 |
|--------|------|
| 0 | 至少一支查得餘量 |
| 1 | 全數查不到或皆不支援 |
| 2 | 參數錯誤（名稱不在支援清單） |
| 4 | 尚未啟用任何顧問（僅無參數時） |
| 127 | 缺依賴（`jq` 或 GNU `timeout`／`gtimeout` 未安裝，或暫存目錄無法建立） |

- 單支失敗只在 stderr 印 `[warn]` 並續查其餘支，stdout 該支位置印「查詢失敗（詳見 stderr）」——一支查不到不影響其他支的結果
- 統一表述為**剩餘百分比**（codex／claude 原生給的是已用百分比，腳本換算）。窗口長度各家不同，**跨顧問不可直接比較**
- 標頭沿用 `ask-<ai>.sh --info` 的首行，顯示名不在本腳本另立一份

| | 額度介面 | 欄位 | 消耗 |
|---|---|---|---|
| codex | `codex app-server` 的 JSON-RPC `account/rateLimits/read` | `rateLimits.primary`／`.secondary` 的 `usedPercent`、`windowDurationMins`、`resetsAt`（epoch）；另有 `planType` 與 `rateLimitResetCredits.availableCount` | 不啟動 thread／turn |
| claude | `claude -p --output-format json '/usage'` | `.result` 純文字報告，逐行抽 `N% used` 與 `resets …` | `num_turns=0` |
| agy | `agy --output-format json -p '/usage'` | `.command.data.groups[].buckets[]` 的 `remaining_fraction`、`reset_time` | `num_turns=0` |
| opencode | 無 | — | — |

- codex 的 app-server **stdin 一旦 EOF 就會在回應前結束**，故以 fifo 持有寫端保持連線，讀到 `.id == 2` 的回應才關寫端。它會繼承腳本開的 fifo 寫端，只關父端等不到 EOF、會孤兒化存活到 timeout（實測），故啟動時即以 `{W}>&-` 關掉其繼承的寫端
- 關寫端後**續讀 stdout 至 EOF 再 `wait`**，不主動 `kill`：提前停讀會讓 server 寫後續通知時吃 EPIPE，主動 kill 則讓結束碼只反映自己下的訊號——兩者都會讓下方的結束碼防線失去意義
- codex 的 stdout 夾雜 `configWarning`、`remoteControl/status/changed` 等通知，不可只取首行；id 要認 JSON 欄位而非字串片段（`"id": 2` 的空白變體會漏判、`"id":20` 會誤判）
- **CLI 結束碼非零一律不採信其輸出**（與 `ask-*.sh` 同原則，三支皆適用；codex 取的是 app-server 自行結束的碼）：半截或殘缺輸出仍可能通過欄位檢查，先看結束碼再解析
- **百分比先驗型別與範圍再換算**：codex 的 `usedPercent` 須為 0–100 的數值、agy 的 `remaining_fraction` 須為 0–1、claude 的報告行須整行錨定為 `標籤: N% used` 且 N ≤ 100。越界值換算後會印出負數或超過 100 的假餘量——給錯數字比查不到更危險
- claude／agy 走的是 CLI **內建的 `/usage` 命令**，不是模型推論——腳本必須驗證這點（claude 認 `.num_turns == 0`、agy 認 `.command.name == "usage"`）：若該版本改把 `/usage` 當一般 prompt 送進模型，回覆會是模型編出來的說法，且白白吃掉一次額度
- 額度查詢**不加免互動核可旗標**（與 `ask-*.sh` 不同）：查額度不執行任何工具，不需要放權
- 額度查詢不讀任何 CLI 的私有 session log（codex 的 `~/.codex/sessions/**` rollout log 雖也含 `rate_limits`，但路徑與 schema 非公開契約，見 design.md §5.12）

## 輸出契約

四支腳本對呼叫端暴露一致介面（內部實作各異；agy 與「id 缺失」為明示例外）：

| 項目 | 內容 |
|------|------|
| stdout | AI 回覆純文字；成功且取得 id 時最後一行為 `[External Advisor <AI名> session_id: <id>]`（AI 名＝codex/claude/opencode/agy），未取得 id 時該行缺席（stderr 印 `[warn]`） |
| stderr | 警告／錯誤（含失敗時的診斷。四支一律 **byte 設限**，且**能解析時只印錯誤欄位與事件型別序列、不倒 stdout 原文**：NDJSON／單行 JSON 的一「行」可含整段回覆，以行設限等於不設限，會讓回覆滲進呼叫端的錯誤日誌。僅在 stdout 無法解析為該 CLI 的預期格式時才 byte 設限印出原文——此時它已不是正常回覆載體，而診斷正需要看見它。見底層指令節） |
| exit 0 | 成功 |
| exit 2 | 參數錯誤（缺 prompt、`-r` 的 id 為空字串等——空 id 常見於上一輪擷取失敗，若放行會靜默開新重送，故必擋） |
| exit 3 | resume 失敗。涵蓋範圍：codex/claude/opencode＝resume 路徑上 CLI 任何非零結束（含 id 失效與暫時性錯誤，看 stderr 區分；此三支的 exit 3 一律代表 **prompt 已送出**，CLI 已跑過才判定失敗）；agy＝id 不存在（前置檢查，**prompt 未送出**），或 agy 未接上該段而另開新對話（事後比對回傳 id；此時 **prompt 已執行**、回覆不輸出，stderr 給新 id）。**有效但屬別段的 id 皆無法偵測**，會靜默接錯脈絡（防範靠呼叫端簿記，見 SKILL.md 的多段並存規則） |
| exit 1 | 執行失敗：無回覆，或有回覆但不可採信（claude＝`is_error=true` 時錯誤文字不當回覆輸出；agy＝CLI 非零結束、輸出非合法 JSON、`status` 非 `SUCCESS`，或 `status=SUCCESS` 但 `.response` 為空，失敗原因見 stdout 的 `.error`）。**可能已產生部分副作用**，重送前先評估 |
| exit 127 | 缺依賴（CLI 未安裝或缺 `jq`；opencode 另含「能力查詢失敗」與「偵測不到免互動旗標」——旗標名版本相依，見底層指令節） |

- 輸出末行標記前一律先驗 id 格式，不合格即**視同未取得 id**（清空改印 `[warn]`，不輸出不可信的 id）：agy 用 `^[A-Za-z0-9-]+$`（其 id 會拼進 `brain/<id>` 路徑做 resume 前置檢查，須防路徑蒙混）；codex/claude/opencode 用 `^[[:graph:]]+$`（id 直接取自各 CLI 的 JSON 欄位，只擋會撐破末行契約的空白與控制字元，過嚴會在上游改格式時誤殺）
- 成功但未取得 id 時：stdout 無 `[External Advisor ...]` 行，stderr 印 `[warn] 未取得 session_id…，本段對話無法延續`——呼叫端據此得知不可延續。**判斷一律認 `[warn]` 前綴，勿比對全文**：括號內的補充說明各腳本不同（如 agy 會註明是 `conversation_id` 格式不合法）。
- **對外一律稱 `session_id`**（參數、警語、輸出行皆同）；各 CLI 內部的真實名稱（codex＝thread_id、agy＝conversation id）只在下方「底層指令」表出現。

擷取 id 範例：

```bash
err=$(mktemp)
ai=codex   # 本次受詢的顧問名（codex/claude/opencode/agy），同時決定腳本與比對字樣
out=$(scripts/ask-"$ai".sh "問題" 2>"$err")
rc=$?
# 先 tail -n1 只看最後一行再比對——回覆內容本身可能引用同格式字樣（如請顧問
# review 本 skill 時），逐行比對會誤抓出多筆
# 顧問名用 $ai 綁定本次受詢的 CLI，不可寫 .*——多顧問並用時 .* 會把別支顧問的
# id 也視為合法，交叉歸屬到錯誤的對話段
id=$(printf '%s' "$out" | tail -n1 | sed -n "s/^\[External Advisor $ai session_id: \(..*\)\]\$/\1/p")
# 契約警告一律認行首，不比對全文——CLI 診斷訊息中段可能夾帶 [warn] 字樣
grep -q '^\[warn\]' "$err" && id=""
[ "$rc" -eq 0 ] && [ -n "$id" ] && scripts/ask-"$ai".sh -r "$id" "追問"
rm -f "$err"
```

## 參數

```
ask-<ai>.sh [-r <session_id>] [--] "<prompt>"    # 四支皆同
ask-<ai>.sh --info                               # 印自述（供 getter 組裝清單）
```

- `-r <id>`：延續指定對話；省略則開新
- `--info`：置於 getopts 與依賴檢查之前——長選項會讓 getopts 落入錯誤分支，且 CLI 未安裝時仍須印得出自述
- `<prompt>`：命令列參數優先；無參數時僅在 stdin 非 TTY 才讀（互動誤用不會掛住）
- **prompt 以 `-` 開頭時必加 `--`**（結束腳本自身的選項解析，四支皆適用）：`ask-codex.sh -- "-r 是什麼？"`；走 stdin 則無此問題
- **agy 特例**：agy 對無效 id 會靜默開新對話且結束碼仍為 0，故 resume 設兩道防線——送出前檢查 `~/.gemini/antigravity-cli/brain/<id>` 目錄存在（不存在即 exit 3，prompt 未送出），送出後比對回傳的 `conversation_id` 是否等於傳入 id（不等即 exit 3 且不輸出回覆）。前置檢查僅在能確認 `brain/` 為單層 UUID 目錄結構時才擋；無法確認（路徑不存在、為空、或改為分層存放）即放行、僅靠事後比對，此時 stderr 印 `[note]` 且 **exit 3 不再保證 prompt 未送出**。

## resume 失敗行為

帶 `-r <id>` 但延續失敗（id 失效等）時，腳本 **exit 3 並停止，不自動改開新對話重送**。呼叫端應先看 stderr：若是暫時性錯誤（網路/CLI 問題），同 id 重試即可、別急著放棄該段；確認 id 確實失效且 prompt 無重複執行疑慮後，再不帶 `-r` 重送開新。

**agy 例外**（同 exit code 表）：agy 的 exit 3 涵蓋「前置檢查 id 不存在」與「事後比對發現另開新對話」兩種；其餘執行失敗一律 exit 1。事後比對是直接核對 agy 回傳的 id，故 agy 對「resume 未接上」的偵測比其他三支（僅靠非零結束碼）確實。

## 底層指令

| | 開新 | 延續 | 回覆欄位 | id 欄位 |
|---|---|---|---|---|
| codex | `codex exec --json … -` | `codex exec resume --json … <id> -` | `item.completed` 事件 `.item.text`（type=agent_message，取最後一則） | `thread.started` 事件 `.thread_id` |
| claude | `claude -p --output-format json …` | 加 `--resume <id>` | `.result` | `.session_id` |
| opencode | `opencode run <免互動旗標> --format json … -- "<prompt>"` | 加 `--session <id>` | `text` 事件 `.part.text`（依序串接） | 任一事件頂層 `.sessionID` |
| agy | `agy --dangerously-skip-permissions --output-format json -p "<prompt>"` | 加 `--conversation <id>`（置於 `-p` 前） | `.response` | `.conversation_id` |

- codex/claude 的 prompt 走 stdin（codex 用 `-`），免長字串／特殊字元的引號轉義；opencode 的 `run` 以引數收 prompt，前置 `--` 分隔符防止以 `-` 開頭的 prompt 被誤解析為旗標；agy 的 `-p` 是**吃值旗標**（prompt 即其值），必須排在其他旗標之後、prompt 緊跟其後
- opencode 的 `<免互動旗標>` 由 `run --help` 偵測（公開名 `--auto` 優先、次選 hidden 舊名 `--dangerously-skip-permissions`，皆無則 exit 127；`--help` 本身失敗另報「能力查詢失敗」）——旗標名版本相依，理由見設計取捨
- agy 的錯誤走 **stdout 的 `.error` 欄位**（`status` 為 `ERROR`），stderr 可能全空——故其失敗診斷印「`.status`／`.error`＋stderr 尾」；stdout 非預期格式時才 byte 設限倒原文
- opencode 的錯誤走 **stdout 的 `error` 事件**（`.error.data.message`），stderr 可能全空（實測 1.18.18）——故其失敗診斷印「錯誤事件訊息＋事件型別序列＋stderr 尾」
- codex 的失敗訊息在 stderr，resume 失效時 stdout 全空（實測；成功序列為 `thread.started → turn.started → item.completed → turn.completed`）——診斷印「事件型別序列＋stderr 尾」，序列超過 20 則只留末 20 則
- NDJSON 一律 slurp 整檔後在 jq 內取值（多行文字安全；**不可**對 jq 輸出行用 `tail`/`head` 取「最後一則」，會截斷多行回覆）
- NDJSON 逐行以 `fromjson? // empty` 容錯（會夾雜非 JSON 警告行）

## 送出 prompt 的實務

硬規則在 SKILL.md（副作用權限、預設背景）；以下是需要判斷、失效可逆的部分，不佔每次載入的篇幅。

- **範圍怎麼給**：拆成兩個獨立問題——「**必查集合**是否明確」（哪些檔案／變更必須逐一覆蓋）與「**證據邊界**是否封閉」（顧問能否看清單外的資料來判斷這些檔案）。指定 PR 或目錄通常只有前者明確，後者並不封閉：正確 review 往往仍需看呼叫端、測試、歷史與規範
- 附檔案清單時**必須寫明「清單是最低覆蓋集合，不是探索上限」**——顧問會把清單當查核表，優先逐項覆蓋，較少質疑有沒有第 N+1 個檔案，也較少去翻 git history、鄰近模組與專案慣例；清單還會先吃掉時間與 token 預算，壓縮自主探索
- **要它找盲點或診斷成因時不附清單**，只給起點與問題。清單等於把呼叫端的假設偷渡進去，顧問照著既定的圈找，回來的還是呼叫端自己的視角
- 絕對路徑提升的是**定位確定性，不是結果可重現性**——檔案內容在兩次諮詢間會變；要可重現須給 commit、diff base 或內容快照
- **要求標示證據等級**：請顧問把未實際執行的結論標為推論、不得稱為實測。與接收端硬規則不重複——這條降低錯誤率（避免它拿虛構實測當前提往下推、把靜態推論包裝成「已驗證」），接收端那條限制損害
- **最值得提供的前置資訊**是顧問無法自行推知的：要裁決的具體問題與成功條件、必查集合是最低還是封閉、PR 的 base/head 或未提交變更範圍、SSOT 與規範衝突時的優先序、使用者明定的限制、repo 外的背景事實、以及「要它獨立探索還是驗證某個具體假設」。檔案數與行數統計則幾乎沒有價值

## 背景執行與並行

- 背景執行為預設（SKILL.md 硬規則）。核心不變量：**每個背景呼叫獨立保存「顧問／主題／程序身分／stdout／stderr／exit code」，完成後才解析，且只回收一次**
- **每個呼叫的輸出必須獨立回收**（各自導向獨立檔案逐一解析，不可混流）——多個背景輸出交錯會讓 id 對應錯亂
- 背景執行的其他失效模式：**完成前搶讀**（拿到半截 stdout 或尚未寫出的末行 id）；**exit code 遺失**（只存輸出不存結束碼，把「有文字但 exit 1」誤當成功）；**stdout/stderr 合流**（`[warn]` 判不出來，會誤存不可用的 id）；**重複啟動**（誤以為沒送出而重送，prompt 若含副作用即重複執行）；**回收順序誤配**（完成順序不等於送出順序，不可用「第一個回來的」對應「第一個送出的」）；**環境漂移**（等待期間工作樹被其他工作改動，顧問看到的不是送出當下的狀態）；**取消不等於未執行**（終止本地 wrapper 時遠端可能已收到 prompt、副作用可能已發生）
- **多顧問並行的前提**：任務唯讀或各顧問副作用範圍互相隔離、看到同一個工作樹狀態、資源與服務限額容許。只有 id 擷取可並行，不代表任務本身可安全並行
- **交叉驗證要並行，不要序列**：目標是取得互相獨立的第一輪意見時，同一份自包含 prompt 並行送出、互不揭露答案。序列即使不轉述前一份答案，呼叫端已看過，會無意識修改後續 prompt、補資料或改變提問重點（實驗者偏誤）；轉述前一份答案則根本不是交叉驗證，而是 critique／辯論，屬第二輪的事

## 設計取捨（DECISION）

- **明確 id 而非 `--last`／`--continue`**：`--last` 只取「當前 cwd 最新一段」，多任務交錯或換目錄會誤接到無關 session；明確 id 天然綁定「這個任務」，且不受 cwd 影響。
- **stateless、不存 pointer 檔**：id 由呼叫端保存在自身對話脈絡。副作用是 `/clear` 後 id 自然遺失 → 免 hook／環境變數即達成「session 隨 Claude session 生命週期」。
- **resume 失敗不自動重送**：prompt 可能含副作用指示，自動 fallback 開新重送有重複執行風險；exit 3 交由呼叫端決定。
- **保留免互動核可旗標**（codex/claude/agy 為 `--dangerously-*`；opencode 為版本相依，腳本以 `--help` 偵測公開旗標名——1.17.10 為 `--dangerously-skip-permissions`，約 1.17.12 起更名 `--auto`、舊名轉 hidden 相容別名）：本 workspace 定位為外部沙箱環境，諮詢型呼叫需免互動核可才能自動化；此 skill 若移作他用需重新評估。偵測而非 hardcode 或版本號推斷：能力偵測不受版本字串與 downstream build 影響，且在送出 prompt 前就失敗（完整證據鏈見 design.md §5.5）。
- **claude 用 `--output-format json` 而非 `stream-json`**：同步 wrapper 只需等最終結果、無 idle timeout 顧慮，單一 JSON 物件解析更簡單。

## 疑難排解

| 症狀 | 檢查 |
|------|------|
| 額度查詢回「查詢失敗」 | 看 stderr 的 `[warn]`：CLI 未安裝、未登入，或該版本已改變 `/usage`／app-server 行為（腳本會擋下不可信的回覆，不會把模型編的說法當額度） |
| exit 4（`advisor-list.sh`） | 尚未啟用任何顧問——請使用者跑 `advisor-set.sh <ai>...`。設定檔不存在、格式污損、清單為空皆回此碼；污損時 stderr 另有 `[warn]` |
| exit 127 | 對應 CLI 或 `jq` 未安裝／不在 PATH（`advisor-quota.sh` 另需 GNU `timeout`／`gtimeout`）；opencode 另可能是 `run --help` 執行失敗（CLI 損壞／環境異常）或免互動旗標偵測失敗（升版更名），以 `opencode run --help` 確認 |
| exit 3 | 看 stderr 區分：暫時性錯誤 → 同 id 重試；id 確實失效 → 確認無重複執行疑慮後不帶 `-r` 重送 |
| 無回覆、exit 1 | 看 stderr 印的錯誤訊息與事件序列（stdout 原文僅在無法解析時才 byte 設限印出）；確認 CLI 已登入 |
| resume 沒記得前文 | 確認帶的 `-r <id>` 是上一次輸出末行那個 id |
| resume 接到不相干脈絡 | 用了「有效但屬別段」的 id（script 偵測不到）；不確定歸屬就別延續，開新並附齊背景 |
| stdout 沒有 session_id 行 | 見 stderr 的 `[warn]`——本段對話無法延續 |
| 長時間無輸出（掛住） | 底層 CLI 網路停滯或卡死；wrapper 無 timeout，逾時由呼叫端管理。強殺後注意：prompt 可能已部分執行、id 未回收——重送前依「resume 失敗行為」的重複執行判準評估 |
