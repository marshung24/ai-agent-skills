# mh-external-advisor 設計文件

> 本文記錄設計理念、架構決策與驗證證據，供維護與擴充時參考。
> 使用面的輸出契約、參數、疑難排解見 `references/detail.md`（單一事實來源，本文不重複）。

## 1. 目的與定位

讓呼叫端 AI（主要是 Claude Code）把其他 AI CLI 當「顧問」諮詢：非互動送出 prompt、取回純文字回覆，並能在**同一任務內延續同一段對話**（顧問記得前文）。

設計目標依序為：

1. **正確的 session 綁定**：延續的對話必須是「這個任務的那一段」，不能誤接到別段
2. **統一介面**：呼叫端對四個 CLI 使用同一套呼叫慣例與輸出契約，不需記各家差異
3. **誠實的失敗**：失敗要可診斷（exit code 分流 + stderr 保留），不靜默吞錯
4. **無狀態**：script 本身不保存任何狀態，session id 由呼叫端持有

## 2. 架構總覽

```
呼叫端 AI（持有 session id 於對話脈絡中）
   │  ask-<cli>.sh [-r <id>] [--] "<prompt>"
   ▼
┌─────────────────────────────────────────────┐
│ ask-*.sh（統一外殼）                          │
│  1. 依賴檢查（CLI / jq）        → exit 127   │
│  2. 參數解析（-r 延續目標）      → exit 2    │
│  3. prompt 取得（參數優先，stdin 次之）       │
│  4. [resume] 前置驗證（agy 專屬） → exit 3    │
│  5. 呼叫底層 CLI（stdout/stderr 分流暫存）    │
│  6. 解析回覆與 session id                    │
│  7. 輸出：回覆 + `[External Advisor <AI名> session_id: <id>]`        │
└─────────────────────────────────────────────┘
   │ 底層 adapter（各 CLI 差異封裝在此層）
   ▼
 codex exec │ claude -p │ opencode run │ agy -p
```

**分層原則**：介面骨架（第 1–3、7 步）四支 script 一致（統一外殼）；第 4 步（resume 前置驗證）僅 agy 有，第 5–6 步（呼叫方式與解析）依 CLI 而異，exit 3 語意與 id 缺失原因也有 agy 明示例外（見 detail.md exit code 表）。修改統一行為時四支需同步，但同步時勿抹平 adapter 特例。

**文件同步點**（detail.md 的「設計取捨」節是本文 §5 的使用面摘要，屬明文接受的重複；改版時依此清單同步）：

- resume 不自動重送政策：SKILL.md 使用方式、detail.md resume 失敗行為、本文 §5.2、四支腳本註解
- 免互動核可旗標與風險：README 安全前提、detail.md 設計取捨、本文 §5.5、腳本註解
- 多段對話簿記規則：SKILL.md 延續 vs 開新、本文 §5.6
- exit code 契約：detail.md 表為 SSOT，SKILL.md 只留摘要、腳本 header 同步

## 3. Session 延續協定

核心迴圈（呼叫端視角）：

```
首次：ask-x.sh "問題"          → 末行 [External Advisor <AI名> session_id: <id>]，把 <id> 記在對話脈絡
延續：ask-x.sh -r <id> "追問"  → 顧問帶前文回答；以本輪末行 id 更新簿記
```

- **id 由呼叫端保存在自身對話脈絡**（非檔案、非環境變數）。天然效果：呼叫端 `/clear` 後脈絡清空 → id 遺失 → 下次自動開新——「顧問 session 生命週期跟隨呼叫端 session」不需任何 hook。
- **每輪以最新末行 id 為準**（Claude review 提出）：「resume 後 id 不變」是版本相依行為——部分 claude CLI 版本 resume 會 fork 出新 session_id，沿用首輪 id 會靜默遺失中間輪次。協定改為每輪更新簿記，對兩種行為皆免疫、成本為零。
- 此協定源自 crossmind `ai-provider.ts` 的 sessionId 迴圈設計（首次擷取 → 後續帶入），改造為 shell 介面。

## 4. 各 CLI adapter 差異

| 面向 | codex | claude | opencode | agy |
|---|---|---|---|---|
| 輸出格式 | NDJSON（`--json`） | 單一 JSON（`--output-format json`） | NDJSON（`--format json`） | 純文字 |
| prompt 傳遞 | stdin（`-`） | stdin | 命令列引數（前置 `--`） | `-p` 的值（吃值旗標） |
| 免互動旗標 | `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-skip-permissions` | `--help` 動態偵測（§5.5） | `--dangerously-skip-permissions` |
| id 來源 | `thread.started` 事件 | `.session_id` 欄位 | 事件頂層 `.sessionID` | **磁碟偵測**（見 §5.4） |
| resume 方式 | `exec resume <id>` | `--resume <id>` | `--session <id>` | `--conversation <id>` |
| resume 失敗偵測 | 非零結束碼 | 非零結束碼 | 非零結束碼 | **前置檢查**（無效 id 靜默開新） |

## 5. 關鍵決策（DECISION）

### 5.1 明確 id 定址，不用 `--last` / `--continue`
- **捨**：`codex exec resume --last`、`opencode -c`、`agy -c`（實作最簡）
- **取**：明確 id 定址
- **理由**：`--last` 語意是「當前 cwd 時間上最新的一段」，與任務無關。多任務交錯或換目錄會誤接到無關對話且**不自知**（實測：無前段時靜默開新、不報錯）。明確 id 天然綁定任務、不受 cwd 影響。

### 5.2 resume 失敗不自動 fallback 重送（Codex review 提出）
- **捨**：resume 失敗自動改開新對話重送（初版行為，體驗較順）
- **取**：exit 3 停止，由呼叫端決定是否重送
- **理由**：prompt 可能含副作用指示（跑指令、改檔案）。resume 可能在部分執行後才失敗，自動重送 = 重複執行風險。呼叫端是 AI，收到 exit 3 與說明文字即可自行判斷。

### 5.3 多行回覆解析必須在 jq 內取值（自我 review 發現）
- **教訓**：初版 `jq ... | tail -1` 意圖取「最後一則訊息」，實際取到「最後一行文字」——多行回覆被截斷。smoke test 用單行回覆（`OK`）掩蓋了此 bug。
- **規則**：NDJSON 一律 slurp 整檔、在 jq 表達式內以 `last`/`first` 取「則」；禁止對 jq 輸出行用 `head`/`tail` 取「則」。

### 5.4 agy 的 id 取得走磁碟偵測（本 skill 最特殊處）
實測證據鏈（agy 版本 2026-07 時點）：

1. `--conversation <自產 UUID>` 無效——兩輪測試皆「無前文」、id 不落地（與網路流傳用法不符）
2. `--conversation <agy 自建 id>` **有效**——可正確帶前文
3. headless（`-p`）不印 id；Auto-Save Resume 的「結束時印 resume 指令」僅互動模式
4. 對話落地於 `~/.gemini/antigravity-cli/brain/<uuid>/`；`cache/last_conversations.json` 維護「cwd → 最後 conversation id」對照表

**id 取得設計**（兩層）：
- 主路徑：查 `last_conversations.json[$PWD]`，並驗證 `brain/<id>` mtime 比執行前 marker 新（防讀到同 cwd 的舊 id）
- fallback：掃 `brain/` 比 marker 新的目錄，mtime 最新者
- **風險註記**：兩者皆為 agy 內部實作細節（非公開 API），agy 升版後必須重驗

**resume 前置驗證**：agy 對無效 id 會靜默開新（結束碼 0），無法事後偵測；故在呼叫前檢查 `brain/<id>` 目錄存在，不存在即 exit 3——把「靜默錯接」轉為「明確失敗」。

### 5.5 保留免互動核可旗標（已接受的風險決策）
- **捨**：改為可設定項並預設安全模式（Codex review 原建議；codex 有 `--sandbox read-only` 等選項）
- **取**：維持免互動核可旗標（codex/claude/agy hardcode `--dangerously-*`；opencode 因旗標名版本相依改以 `--help` 動態偵測，見本節末段），以文件明示風險與使用前提
- **理由**：諮詢型呼叫需免互動核可才能自動化，本 skill 的預設使用情境即為沙箱／受控環境；加設定項會增加介面複雜度，且「安全模式」在各 CLI 的旗標與語意不一致，統一外殼難以維持一致契約。
- **風險聲明**：這些旗標讓外部 CLI 跳過互動核可與沙箱限制——被諮詢的 AI 取得**與執行使用者相同的檔案、程序、網路與憑證權限，不限當前工作目錄**（可讀 `$HOME`、SSH/cloud 憑證、其他 repo，可對外連網），一句含副作用指示的 prompt、或被讀取內容中的 prompt injection，就足以觸發改檔案、跑指令、外送資料。**只有在已隔離檔案系統、敏感憑證、網路與宿主控制介面的 sandbox 中才可視為安全**——「容器」本身不等於安全（掛 Docker socket、注入 production 憑證、可自由連網的容器都不算）；已版控只防檔案損毀，防不了資料外洩與外部副作用。README 對使用者同步載明此前提。
- **旗標為版本相依（opencode 以 `--help` 動態偵測）**：實測證據鏈——1.17.10 的 `run --help` 列 `--dangerously-skip-permissions`；1.17.18 改列 `--auto`，但執行檔內仍含舊名字串、帶舊旗標呼叫仍成功（源碼 `run.ts`：`--auto` 公開、`--yolo` 與 `--dangerously-skip-permissions` 為 `hidden: true`，三者在 handler 內 OR 合併），即**約 1.17.12 起公開名更名為 `--auto`、舊名轉 hidden 相容別名**。另實測 opencode 對未知旗標不報錯（非嚴格解析）——hidden 別名一旦被上游移除，帶舊名呼叫會變 no-op 且無任何錯誤，免互動核可靜默失效。故 `ask-opencode.sh` 不 hardcode，改以 `run --help` 偵測公開旗標名（舊名優先、次選 `--auto`、皆無則 exit 127 明確報錯）。其餘三支 CLI 升版後仍需以 `--help` 重驗旗標存在。

### 5.6 穩定可靠優先的收斂決策
以「寧可少功能也要可靠」收斂三條使用規則：

- **使用者授權守門**：使用者買了哪些 AI 不一定，未經使用者指定可用的 CLI 不得主動呼叫（可詢問/建議）。裝機檢查（exit 127）只擋「沒安裝」，擋不了「沒訂閱/不想用」，授權是更上位的閘
- **多段並存靠呼叫端簿記，不可靠時退化為每 CLI 一段**：script 只能偵測無效 id（exit 3），「有效但屬別段」的 id 無法偵測、會靜默接錯脈絡（Codex 指出的關鍵盲點）。故允許多段並存，但呼叫端必須維護「CLI／主題／id」對照（SKILL.md 為此協定的 SSOT）；歸屬無法唯一對應時不延續、一律開新並附齊背景——簿記失守時自然退化為每 CLI 至多一段，錯配面收到最小。配套原則「延續是優化非必需，不確定一律開新」
- **子 Agent 原則禁用**：跨 agent 邊界傳遞 id 會產生 owner 沒看過的前文，之後任一方延續都是盲區。唯一例外為主 Agent 明確委派的單次自包含諮詢（不帶 -r、不回報 id）
- 配套修正：開新路徑補 CLI 結束碼檢查（非零即 exit 1，不信任殘缺輸出）、agy 的 -r 與偵測所得 id 皆套字元集驗證（防路徑蒙混與污損來源）、fallback 掃描用 `find -exec ls -td {} +`（無匹配不執行，免空跑產生垃圾 id；不用 xargs——空輸入行為 BSD/GNU 不一致）

### 5.7 其他工程慣例
- prompt 盡量走 stdin（codex `-`、claude），免長字串/特殊字元引號轉義；opencode/agy 受 CLI 限制走引數
- stderr 一律留檔，失敗時隨診斷印出（初版 `2>/dev/null` 吞錯，失敗死得不明不白）
- 不用 `set -e`：失敗路徑需分流處理（exit 1/2/3/127），不可讓非零結束碼直接中止
- 變數後緊接全形字必須 `${VAR}` 加大括號——bash 會把多位元組字元首位元組黏進變數名（`set -u` 下報 unbound variable）
- 跨平台（macOS + Ubuntu 容器）：避免 `stat`（旗標不相容），以 `ls -td` 排序 mtime

## 6. 驗證方式

每支 script 以三案例實測（真實 CLI，非 mock）：

1. **開新 + 多行回覆**：驗證 id 擷取與多行不截斷（§5.3 的回歸案例）
2. **`-r <id>` 延續**：前一輪埋入記憶點（數字/詞），追問驗證顧問記得
3. **失效 id**：驗證 exit 3 與診斷輸出（agy 另驗 fallback 與查表一致性）

> 待辦（Codex review 建議）：bats + PATH stub fake CLI 的自動化測試，覆蓋 exit code 與輸出契約，免依賴真實 CLI 與網路。

## 7. 已知限制

- agy 的 id 取得依賴內部儲存位置（§5.4），版本升級需重驗；**同一 state 目錄（同一使用者）下任何並行開新**都有錯配窗口——主路徑以 cwd 查表，但 fallback 掃整個 `brain/`，不限同 cwd。另 `-newer $MARK` 的偵測依賴檔案系統 mtime 粒度——粗粒度（秒級）檔案系統上，與 marker 同秒建立的對話目錄可能漏判（現代 ext4/APFS 為奈秒級，實務影響極低）；fallback 的 `find -exec ls -td {} +` 在目錄數超過單批 argv 上限時會分批執行、排序失準（需上千個對話目錄才觸發，機率低）
- 各 CLI 的免互動旗標為版本相依（§5.5）；opencode 已改動態偵測，codex/claude/agy 仍為 hardcode，升版需以 `--help` 重驗。opencode 對未知旗標不報錯（非嚴格解析），旗標失效無法靠錯誤偵測
- 各 CLI 的事件格式為觀測所得（smoke test 確認），官方未必保證穩定；解析已以 `fromjson? // empty` 容錯，但欄位更名仍會失效
- 無自動化測試（§6 待辦）
- `gemini` CLI 已汰除不納入；若未來恢復，可比照 `ask-claude.sh` 模式擴充

## 8. 版本記錄

> 入 repo 後的版本演進以 git history 為準，本節僅記錄重大版本的摘要。

- **1.5.0**：入 repo 前的開發期版本（設計、四支 adapter、實測驗證，見 §6）
- **1.6.0**：入 repo 首發修訂——§5.5 改為明確接受的風險決策並於 README 載明安全前提；opencode prompt 前加 `--` 分隔符（防旗標誤解析，實測支援）；id 擷取範例改先 `tail -n1` 並以 exit 0 為前提（防回覆內容含同格式字樣誤抓）；警語判讀規則明確化（認 `[warn]` 前綴）；補 mtime 粒度已知限制。經 Codex 交叉 review（以本 skill 的 ask-codex.sh 執行）再修訂：opencode 免互動旗標改以 `run --help` 動態偵測公開名（1.17.10 為 `--dangerously-skip-permissions`、約 1.17.12 起更名 `--auto`、舊名轉 hidden 相容別名，證據見 §5.5）；usage 補 `[--]`（leading-dash prompt 需以 `--` 結束腳本選項解析）；安全聲明權限範圍改為「執行使用者級、不限 cwd」；§5.6 多段對話規則與 SKILL.md 對齊（允許多段、簿記失守退化單段）；§2 分層說明改為「骨架一致 + agy 明示例外」；agy 並行錯配範圍修正為「同 state 目錄不限 cwd」。經 Claude 獨立 review（以本 skill 的 ask-claude.sh 執行，乾淨視角）三修：四支補「`-r` 空 id 必擋 exit 2」（空 id 會靜默繞過 resume 防線改開新重送——本輪唯一 High）；SKILL.md 補環境安全前提段（安全聲明原本只在 README，呼叫端載入的 SKILL.md 反而沒有）；opencode `--auto` 偵測改邊界比對（防誤中 `--auto*` 系列旗標）；ask-claude.sh 補 `is_error` 檢查、移除吞錯的 `2>/dev/null`；session 協定改「每輪以最新末行 id 更新簿記」（resume 後 id 不變屬版本相依行為）；ask-agy.sh 的 prompt 檢查移到 resume 驗證前（exit 2/3 順序與他支一致）、失敗診斷補印 stdout；§2 補文件同步點清單；detail.md 疑難排解補「掛住」症狀；README 補第三方外送註記
