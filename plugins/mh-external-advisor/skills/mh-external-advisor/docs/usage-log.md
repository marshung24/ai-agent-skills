# 用量記錄與錯誤記錄

`usage.log` 的資料契約：寫什麼、不寫什麼、各欄位怎麼解讀。**本檔是 log 語意的單一出處**；呼叫端要的操作面摘要在 [references/detail.md](../references/detail.md)，怎麼拿它做統計在 [usage-analysis.md](usage-analysis.md)。

> 讀本檔的時機：要改 `lib/usage-log.sh` 或任何寫事件的地方、要新增欄位、或要判斷某個數字能不能從這份 log 算出來。

## 1. 位置與形態

| | |
|---|---|
| 路徑 | `${XDG_STATE_HOME:-$HOME/.local/state}/mh-external-advisor/quota/usage.log` |
| 格式 | JSONL（一行一個事件物件） |
| 輪替 | 超過 1 MB 搬成 `.1`，只留兩代；輪替與 append 共用一支鎖 |
| 內容 | **🚫 不含 prompt 原文、回覆內容或主題** |

放在 state 而非 config：它是可丟棄的執行紀錄，與表達使用者意圖的 `enabled.json` 分開，備份設定時不會把它一起搬走。

**這份資料是營運 telemetry，不是稽核帳本。** 寫入失敗一律靜默吞掉並回成功——記錄失敗不得擋下顧問呼叫。因此**缺事件不等於沒發生**，任何分析都不能把「沒記到」讀成「沒做過」。

## 2. 事件模型

同一次 adapter 呼叫共用一個 `invocation_id`，各生命週期節點**各追加一行**。

```
throttle_decision ──▶ call_attempted ──▶ call_finished
   （扣桶完成）        （走到啟動 CLI）      （拿到結果）
```

| 事件 | 何時寫 | 證明了什麼 |
|------|--------|-----------|
| `throttle_decision` | 扣桶完成，allow／deny 都寫 | 節流器做了決策 |
| `call_attempted` | 即將啟動顧問 CLI | adapter 走到這一步 |
| `call_finished` | 取得 CLI 結果並完成判定 | adapter 拿到結束碼 |
| `reset` | 使用者重置水位 | 管理操作，不是呼叫 |

**🚫 不回頭改寫舊行**：舊行可能已被輪替搬到 `.1`，原地改寫也不是原子操作，兩個並行 adapter 會改錯行。要補資訊就追加新事件，查詢時再依 `invocation_id` 聚合。

### 三條界線

這三句話決定了哪些數字算得出來，也是最容易被誤讀的地方：

1. **`allow` 不等於 prompt 已送出。** 扣桶發生在送出前，中間還會失敗。
2. **`call_attempted` 也不等於 prompt 已送達。** 走到啟動那一步之後，CLI 仍可能啟動失敗。
3. **唯一能證明往返完成的是結束碼 0 的 `call_finished`。** 這個資料源沒有更強的送達證據。

有 `throttle_decision: allow` 卻沒有對應 `call_finished` 的 invocation ＝ **結果未知**。它不是成功，也不是失敗，🚫 不得歸進任何一邊。

## 3. 欄位字典

### 共通

| 欄位 | 型別 | 說明 |
|---|---|---|
| `v` | number | schema 版本，目前 `1` |
| `ts` | string | ISO 8601 含時區 |
| `event` | string | 見上表 |
| `invocation_id` | string | 配對用。並行時靠時間或 PID 都配不起來——同一秒可有多次呼叫，PID 也會重用 |
| `advisor` | string | 顧問名；`reset --all` 時為 `*` |

### `throttle_decision`

| 欄位 | 型別 | 說明 |
|---|---|---|
| `decision` | string | `allow` \| `deny` |
| `source` | string | `adapter` \| `manual`。`consume` 是公開子命令，人可直接跑；不分開會讓手動操作污染實際請求數 |
| `declared_scope` | string | **呼叫端宣告**的 scope，不是觀測事實。統計上須與結束碼、水位這類機器事實分開標示 |
| `capacity` / `cost` | number | 當下生效值。🚫 不可事後讀設定檔回推——設定會被覆寫 |
| `remaining_before` | number | 補水後、扣款前的水位 |
| `remaining_after` | number | 扣款後水位 |
| `refill_seconds` | number | 當下生效的恢復速率，會隨顧問剩餘額度變動 |
| `retry_after_seconds` | number | 僅 `deny` |
| `principal.{kind,id,comm,lstart}` | — | 桶的身分。識別一個桶要 `kind`＋`id`＋`lstart` 三者；`comm` 只能給人看 |

`remaining_before` 為什麼必要：少了它就分不出「靠補水剛好放行」與「桶本來就滿」，也無法驗證實際扣量——相鄰兩筆的 `remaining` 差值會被中間的補水混淆，例如 `20 → 14` 不代表成本是 6。

`principal.lstart` 為什麼必要：PID 會被重用。沒有這個 incarnation key，兩個不同時期、剛好同 PID 的程序會被合併統計，而實作上它們是兩個不同的桶。

### `call_attempted` / `call_finished`

| 欄位 | 型別 | 說明 |
|---|---|---|
| `mode` | string | `new` \| `resume`。兩者的失敗語意不同，混在一起會讓失敗率誤判 |
| `adapter_exit_code` | number | **adapter 自己的**結束碼，不是顧問 CLI 的。見下節對照 |
| `duration_ms` | number | `call_attempted` 到結束的毫秒數 |
| `outcome` | string | `ok`（結束碼 0）\| `error` |

## 4. 錯誤記錄涵蓋範圍

**只記扣桶之後的失敗。** 扣桶前的失敗一律不入帳——它們連決策都沒發生，記進來會讓 `throttle_decision` 這個分母混入沒有決策的樣本。

| 失敗情境 | 結束碼 | 留下的事件 |
|---|---|---|
| 參數錯誤（缺 `--scope` 等） | 2 | **無** |
| 找不到 CLI 或 `jq` | 127 | **無** |
| 節流檢查失敗（身分／鎖／桶狀態） | 6 | **無**（桶沒扣成） |
| 額度用盡 | 5 | `throttle_decision: deny` |
| CLI 執行失敗 | 1 | `allow` → `attempted` → `finished(rc=1)` |
| CLI 回傳但無可用回覆 | 1 | 同上 |
| resume 失效 | 3 | `allow` → `attempted` → `finished(rc=3)` |
| 被 SIGKILL | — | `allow` → `attempted`，**無 finished** → 結果未知 |

結束事件掛在 adapter 的 `EXIT` trap 上，不是逐條失敗路徑各寫一次——中途 exit 的路徑太多（CLI 失敗、resume 失效、解析失敗），逐條補必定漏。

`adapter_exit_code` 記的是 adapter 的結束碼：顧問 CLI 自己回 9，adapter 會依自身契約映射成 1。要查 CLI 原始錯誤請看該次呼叫的 stderr，log 不留。

## 5. 輪替與鎖

輪替是「檢查大小 → `mv` → append」三步，**必須整段序列化**。桶鎖按 `principal × advisor × scope` 分，保護不到單一份 log 檔——多個程序同時看到超標會各自 `mv` 一次，`.1` 被反覆蓋掉，兩代保留被提早摧毀，實測留存量會從穩定值掉到三分之一並伴隨寫入錯誤。

鎖的四個要點：

- **鎖與 owner metadata 一次寫成**：鎖是以 `set -C`（noclobber，帶 `O_EXCL`）建立的檔案，建立與寫入 PID／nonce／start time 是同一個動作。先前用 `mkdir` 再另寫 owner 會出現「鎖已存在但還沒有 owner」的中間狀態，等待者無從判斷該等還是該回收——高頻換手時怎麼訂規則都會誤傷：不是搶走剛建好的活躍鎖，就是讓真正的孤兒鎖永遠卡住。
- **搶不到鎖不阻塞**：退化成「只 append 不輪替」。append 本身夠短，真正會壞資料的只有輪替；寧可讓檔案暫時超過門檻，也不能漏事件或擋住呼叫。
- **只回收確定失效的鎖**：owner 已死，或 PID 被重用（start time 不符）。`ps` 在高並行下會偶發查不到，那要當成「判不出來」而**不是**「已死」，否則會搶走活著 owner 的鎖。🚫 **不因為持鎖太久就搶**——搶鎖只能讓舊 owner 的 unlock 失效，攔不住它恢復後跑完 `size → mv → append`，兩個 writer 仍會同時在 critical section。
- **回收前同一份內容要連看兩次**：只看一次是 TOCTOU——從判定「owner 已死」到真的動手之間，鎖可能已經換手，移走的就成了別人剛取得的鎖。nonce 每次取鎖都不同，內容沒變才表示還是同一個殘留鎖。解鎖同樣核對 nonce，對不上就不刪。

## 6. 舊格式

2026-09 以前的紀錄是空白分隔的文字行：

```
2026-09-15T11:08:31+0800  claude(42680)  codex/review  allow  remaining=20/30 refill=30s
```

它們沒有 `invocation_id`、沒有結果欄位，`principal` 只有顯示名稱。**不做轉換**——缺的欄位補不回來，硬轉等於編造。分析工具會辨識並單獨計數，🚫 不併入任何比率的分母。

## 7. 要新增欄位時

先問它屬於哪一類，兩類**不得混寫**：

- **機器事實**：adapter 或節流器自己就知道的值（結束碼、水位、耗時、PID）。可直接加。
- **呼叫端自述**：需要 AI 判斷才填得出來的值（這次諮詢有沒有用、為什麼要問）。一律以 `declared_` 前綴命名、允許缺值，🚫 不得當成節流有效性或任何效益判斷的硬分母——那等於用被約束者自己產生的資料去約束自己。

新增欄位一律往後追加，不改既有欄位語意；真要改語意就升 `v`。
