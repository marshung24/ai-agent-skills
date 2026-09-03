# mh-external-advisor 實作細節（維護用）

> **執行期用不到本檔**：呼叫顧問、排查失敗、撰寫諮詢 prompt 一律看 [references/detail.md](../references/detail.md)。
> 本檔給要改腳本、新增 adapter 或追底層行為的維護者；設計理由與驗證證據見 [design.md](design.md)。

## 清單腳本的內部行為

使用面（用途、結束碼、設定檔位置）見 detail.md〈清單腳本〉；以下是 `advisor-list.sh`／`advisor-set.sh` 的內部規則。

- 設定檔 schema：`version` 必須為 `1`、`enabled` 必須是字串陣列，每項須符合 `\A[a-z0-9-]+\z`
- 壞法分兩級處置：**結構壞**（version 非 1、enabled 非陣列、非 JSON）→ 整份不可信，退化為「尚未啟用」；**單項壞**（非字串、含非法字元、含換行）→ 只丟該項並警告，合法項保留（否則 `--add` 會因一個殘留壞名稱清掉使用者原本設好的顧問）
- getter 對讀出的每個名稱都先驗字元集、再與支援清單做**精確集合比對**才組路徑；不以設定檔內容直接組路徑測 `-f`（設定檔可能被 setter 以外的途徑寫入）
- 「支援」的判準是 `scripts/` 下**可執行**的 `ask-*.sh`（`-f` 且 `-x`）：只驗 `-f` 會讓「檔案在但沒有執行權限」在 setter 收下、到 getter 才失敗
- `--add`／`--remove` 讀既有清單時，會一併清掉「已無對應 adapter」的殘留名稱並警告——避免使用者移除某支後，設定檔裡的舊名一直跟著被寫回
- `--remove` 的參數**只驗字元集、不驗支援清單**（其餘模式驗兩者，不支援即 exit 2）：adapter 被移除後，其名稱可能仍留在設定檔裡，若比照他模式擋下就會變成「移不掉」

## 額度查詢的底層介面

用法與結束碼見 detail.md〈額度查詢〉；以下是各 CLI 的介面與實作防線。

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
- 額度查詢不讀任何 CLI 的私有 session log（codex 的 `~/.codex/sessions/**` rollout log 雖也含 `rate_limits`，但路徑與 schema 非公開契約，見 [design.md](design.md) §5.12）

## 底層指令

呼叫端一律走 `ask-*.sh`，不直接呼叫下列指令；本節供改 adapter 時對照。

| | 開新 | 延續 | 回覆欄位 | id 欄位 |
|---|---|---|---|---|
| codex | `codex exec --json … -` | `codex exec resume --json … <id> -` | `item.completed` 事件 `.item.text`（type=agent_message，取最後一則） | `thread.started` 事件 `.thread_id` |
| claude | `claude -p --output-format json …` | 加 `--resume <id>` | `.result` | `.session_id` |
| opencode | `opencode run <免互動旗標> --format json … -- "<prompt>"` | 加 `--session <id>` | `text` 事件 `.part.text`（依序串接） | 任一事件頂層 `.sessionID` |
| agy | `agy --dangerously-skip-permissions --output-format json -p "<prompt>"` | 加 `--conversation <id>`（置於 `-p` 前） | `.response` | `.conversation_id` |

- codex/claude 的 prompt 走 stdin（codex 用 `-`），免長字串／特殊字元的引號轉義；opencode 的 `run` 以引數收 prompt，前置 `--` 分隔符防止以 `-` 開頭的 prompt 被誤解析為旗標；agy 的 `-p` 是**吃值旗標**（prompt 即其值），必須排在其他旗標之後、prompt 緊跟其後
- opencode 的 `<免互動旗標>` 由 `run --help` 偵測（公開名 `--auto` 優先、次選 hidden 舊名 `--dangerously-skip-permissions`，皆無則 exit 127；`--help` 本身失敗另報「能力查詢失敗」）——旗標名版本相依，理由見下方設計取捨
- agy 的錯誤走 **stdout 的 `.error` 欄位**（`status` 為 `ERROR`），stderr 可能全空——故其失敗診斷印「`.status`／`.error`＋stderr 尾」；stdout 非預期格式時才 byte 設限倒原文
- opencode 的錯誤走 **stdout 的 `error` 事件**（`.error.data.message`），stderr 可能全空（實測 1.18.18）——故其失敗診斷印「錯誤事件訊息＋事件型別序列＋stderr 尾」
- codex 的失敗訊息在 stderr，resume 失效時 stdout 全空（實測；成功序列為 `thread.started → turn.started → item.completed → turn.completed`）——診斷印「事件型別序列＋stderr 尾」，序列超過 20 則只留末 20 則
- NDJSON 一律 slurp 整檔後在 jq 內取值（多行文字安全；**不可**對 jq 輸出行用 `tail`/`head` 取「最後一則」，會截斷多行回覆）
- NDJSON 逐行以 `fromjson? // empty` 容錯（會夾雜非 JSON 警告行）

## 節流的內部行為

使用面（`--scope`、exit 5、`advisor-throttle.sh` 的子命令）見 detail.md〈節流〉；以下是 `lib/throttle-io.sh` 的實作細節。

- **身分**：沿祖先鏈取第一個非 shell 祖先（只跳過 `sh`／`bash`／`zsh`／`dash`／`ksh`／`fish`），最多追 20 層。🚫 不以已知 CLI 名單比對——名單會過期，且 `node` 本身可能就是 agent 本體。追到 PID 0／1 代表中間沒有可辨識的 agent，視為解析失敗
- **incarnation key**：`ps -o lstart=`（Linux／macOS 皆有）。桶檔內存 lstart，不符即視為 PID 已被重用、舊桶失效。🚫 不用 `/proc/<pid>/stat`（Linux only）——這裡不是安全身分驗證，秒級足夠
- **狀態**：`${XDG_STATE_HOME:-$HOME/.local/state}/mh-external-advisor/quota/buckets/<pid>/<advisor>-<scope>.json`。水位用整數單位（`capacity` 30／`cost` 10／每 `refill_seconds` 回 1）；`refill_seconds` 存「上次生效」的恢復秒數
- **計算順序**：舊 `refill` 排水 → 判斷 → 寫回時才換成新 `refill`。`elapsed` 為負（時鐘倒退、NTP 校時）取 0 並警告，🚫 不得反向增加水位
- **鎖**：每桶一個 `mkdir` 目錄鎖（macOS 無 `flock`）。owner 檔存 PID／lstart／nonce／建立時間；回收 stale 鎖先原子 `mv` 成唯一名再刪，避免兩個等待者同時拆鎖；解鎖前比對 nonce，防被回收的舊 owner 刪掉後來者的鎖。`ps` 查不到（回 2）時**不**回收——誤刪比多等昂貴；另設「鎖存在超過 12 倍逾時」的保底回收，避免永久鎖死
- **額度查詢一律在鎖外**：它走網路要數秒，持鎖期間查會阻塞同桶所有背景諮詢。快取按顧問名分開，TTL 5 分鐘、失敗沿用舊值至多 30 分鐘
- **GC**：取用時至多觸發一次、間隔 6 小時；只清 lstart 不符或超過 7 天的桶。`ps` 暫時失敗不得據以刪除；GC 失敗只警告
- **peek 不寫檔**：投影公式對同一時間點冪等，唯讀查詢不必改 `updated_at`

## 設計取捨（DECISION）

以下是使用面摘要，完整理由與證據鏈見 [design.md](design.md) §5。

- **明確 id 而非 `--last`／`--continue`**：`--last` 只取「當前 cwd 最新一段」，多任務交錯或換目錄會誤接到無關 session；明確 id 天然綁定「這個任務」，且不受 cwd 影響。
- **stateless、不存 pointer 檔**：id 由呼叫端保存在自身對話脈絡。副作用是 `/clear` 後 id 自然遺失 → 免 hook／環境變數即達成「session 隨 Claude session 生命週期」。
- **resume 失敗不自動重送**：prompt 可能含副作用指示，自動 fallback 開新重送有重複執行風險；exit 3 交由呼叫端決定。
- **保留免互動核可旗標**（codex/claude/agy 為 `--dangerously-*`；opencode 為版本相依，腳本以 `--help` 偵測公開旗標名——1.17.10 為 `--dangerously-skip-permissions`，約 1.17.12 起更名 `--auto`、舊名轉 hidden 相容別名）：本 workspace 定位為外部沙箱環境，諮詢型呼叫需免互動核可才能自動化；此 skill 若移作他用需重新評估。偵測而非 hardcode 或版本號推斷：能力偵測不受版本字串與 downstream build 影響，且在送出 prompt 前就失敗（完整證據鏈見 design.md §5.5）。
- **claude 用 `--output-format json` 而非 `stream-json`**：同步 wrapper 只需等最終結果、無 idle timeout 顧慮，單一 JSON 物件解析更簡單。
