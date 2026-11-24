# Telegram 平台與橋接層

評估元件版本與成熟度、排查時要理解橋接層內部怎麼運作、或規劃多人部署時讀本檔；讀了得到 Telegram 平台限制、Claude Code 端（官方 plugin＋強化版）與 Codex 端（Codex-tg-Bridge）的功能比較、內部機制、已知缺陷與待確認事項。操作步驟、驗證與排查一律見 [references/setup.md](../references/setup.md)；需求、架構與選型結論見 [design.md](design.md)。

- **資料日期**：2026-11-12 依官方文件、各專案 README 與原始碼查證
- **實測範圍**：Claude Code 端標「實測」者已在真實 bot 驗證，其餘依原始碼或文件；Codex 端全部**未實測**
- **數字會變**：費用、上限、速率、stars 等數字引用前回原始來源確認

## 目錄

- 元件與成熟度
- Telegram 平台限制
- 功能比較
- Claude Code 端機制
- Claude Code 端歷史收錄
- Codex 端機制
- 多人部署考量
- 待確認
- 來源

## 元件與成熟度

選元件或評估升級風險時讀本段。

| 元件 | 版本／狀態 | 成熟度與維護風險 |
|---|---|---|
| Claude Code channels | research preview | 參數與協定可能變動；Pro／Max／Ultra 可用，Team／Enterprise 預設封鎖需 Owner 開啟，Bedrock／Vertex／Foundry 不可用（開啟方式見 setup.md〈Claude Code 端〉） |
| 官方 plugin `telegram@claude-plugins-official` | 0.0.7 | Anthropic 官方 |
| [claude-telegram-supercharged](https://github.com/k1p1l0/claude-telegram-supercharged)（強化版） | 隨 GitHub `master` | 第三方；以覆蓋官方 plugin cache 的 `server.ts` 等檔運作，官方更新即被蓋掉 |
| [HailSyner/Codex-tg-Bridge](https://github.com/HailSyner/Codex-tg-Bridge) | MIT，6 stars，最後 commit 2026-08-30 | 第三方、低採用、數月未更新的單人專案 |
| Codex 方案 | Plus、Business、Pro、Enterprise 等付費方案 | Free／Go 未列 |

- **用量歸屬**：bot 處理的所有請求計入執行 bot 那個帳號的訂閱額度（Claude 與 Codex 都有 5 小時與每週上限），超過改用 credits、API 計費或升級；群組人數越多越快用完
- **即時額度**：查法見 setup.md〈執行紀錄〉的 `quota.sh`

## Telegram 平台限制

判斷團隊擴大會不會卡住、或解釋平台層行為時讀本段。依官方文件，未實測。

| 項目 | 限制 | 影響 |
|---|---|---|
| bot 費用 | 免費 | — |
| 群組人數上限 | 200,000 | 遠高於團隊規模 |
| bot 發訊速率 | 每群組 20 則／分、每聊天室約 1 則／秒、全域約 30 則／秒 | 群組 20 則／分是硬上限、買不到（付費廣播需 10 萬 MAU 與 10 萬 Stars）；多人同時提問或長回覆分段時會 429 |
| 讀全部群組訊息 | 關隱私模式或把 bot 設為管理員，改後要重新進群 | 平台層擋下的訊息 bot 收不到，橋接層也無從收錄 |
| 歷史 | Bot API 無歷史；未取走的 update 只保留 24 小時 | 歷史只能靠常駐收錄；bot 停機超過 24 小時或加入前的訊息永久缺失 |
| 成員查詢 | 無完整成員名單；只能查管理員、總人數與已知 ID 的單一成員（`getChatAdministrators`、`getChatMemberCount`、`getChatMember`） | plugin 未提供這些工具（未實跑）；bot 身分只能由負責人交換 |
| `@all` | Telegram 無原生全體提及 | 以橋接層 `mentionPatterns` 文字比對實作，每個 bot 各自觸發、各自回答，不是協同 |
| 檔案 | 上傳 50MB、下載 20MB；自架 Local Bot API Server 可放寬 | 大檔案實際上限約 20MB |
| bot 互通 | Bot API 10.0 起支援 Bot-to-Bot Communication Mode，需在 BotFather 開啟；官方要求自行防迴圈 | 開啟位置見 setup.md〈bot 參數〉 |
| 群組升級 | 一般群組升級為超級群組後 ID 改變（超級群組 `-100` 開頭） | 重設方式見 setup.md〈群組與授權〉 |
| 訊息 ID | 一般群組內各帳號看到的同一則訊息 ID 不同（實測） | `reply_to` 只能用自己看到的 ID |

## 功能比較

比較兩端能力、決定哪端需要補強時讀本段。Claude Code 端依強化版；衝突處以已實測者為準。

| 能力 | Claude Code（官方 plugin＋強化版） | Codex（Codex-tg-Bridge，未實測） |
|---|---|---|
| 連接方式 | Telegram → MCP channel → Claude Code session | Telegram Bot API → Codex app-server |
| 執行環境 | Bun；server 為 Claude Code 子行程 | Node.js 20+；獨立常駐 bridge |
| 觸發 | 私訊、@bot、回覆 bot、`mentionPatterns` | 同左；群組 `requireMention: true` |
| 未觸發訊息 | 不執行 AI；在 gate 前寫入 SQLite | 不執行 AI；須收到 update 才存入記憶體 |
| 自動上下文 | 每則入站附該聊天室最近 5 則（實測） | `mentionContext.messageCount`，預設 10 |
| 歷史跨重啟 | SQLite 保留 | 記憶體，重啟即失 |
| 查歷史工具 | `get_history`／`search_messages` | 無 |
| Session | Claude Code session；`memory.md` 為跨 session 摘要，與 SQLite 原始訊息不同 | 單一持續 thread，預設私訊、群組、終端共用 |
| 存取控制 | `access.json`：私訊 policy、配對、群組 allowlist、`limits` | `config.json`：`allowedGroups`、`allowedUserIds` |
| 工具權限確認 | 強化版轉送至 Telegram 遠端核准 | 未查 |
| bot 互讀 | 群組內可互相觸發（實測） | 未實測 |
| 附加功能 | 附件、reply chain、Forum Topic、語音轉錄、Agentic Mode 進度顯示、每人每日 token 統計 | 可選明文 JSONL 收發紀錄 |
| 主要維護風險 | 官方更新覆蓋強化版 | 共用 thread 造成跨聊天室資料混雜；專案低維護 |

## Claude Code 端機制

理解 poller、合批、附件、更新覆蓋等行為，或排查結果與預期不符時讀本段。強化版只替換 plugin cache 內的 server，plugin 名稱、`/telegram:*` skill 與 `access.json` 沿用官方。

### Server 與 poller

| 機制 | 行為 | 依據 |
|---|---|---|
| 生命週期 | `server.ts` 是 Claude Code 子行程，session 結束即停；全部 session 關閉後 bot 不回應 | 原始碼 |
| 離線訊息 | 未設 `drop_pending_updates`，重啟後應收得到 24 小時內的 update | 原始碼，未實測 |
| 單一 poller（強化版） | 先到先得：`data/telegram.lock` 持有者存活時，後啟動的 server 進入 MCP-only（工具可用、不輪詢、收不到）；持有者已死才接手。鎖檔非原子鎖，同時啟動仍可能競爭 | 原始碼，未實測 |
| 單一 poller（官方版） | 相反：新 server SIGTERM 舊的 | 原始碼；全域啟用時一般 session 會搶走 poller（實測） |
| 跨環境同 token | host 與容器共用 token 會互踢，每則訊息只有一邊收到，發訊不受影響；鎖檔只對同機 PID 空間有效，`access.json` 也各自獨立 | 依程式碼與 Telegram 機制推論，未實測 |
| 失敗快取 | MCP 連線失敗記入 `~/.claude/mcp-needs-auth-cache.json`，以 server 名稱與設定 id 為鍵、跨 session 共用、不分環境變數，約 15 分鐘內同名 server 直接略過；之後連線成功也不會清掉該筆 | 實測 |
| 子行程 | 在祕書目錄內再啟動的 `claude`（含外部顧問）會讀到同一份 `.claude/settings.json`，plugin 可能啟用並起 server；其他目錄須依其有效設定判斷，不保證停用 | 依啟用機制推論，未實測 |
| 狀態目錄 | 強化版寫死預設路徑、不讀 `TELEGRAM_STATE_DIR`；多 session 各用一個 bot 並以不同 `TELEGRAM_STATE_DIR` 隔開，只有官方 server 支援 | 原始碼 |

單一 session 接收的做法見 setup.md〈Claude Code 端〉步驟 5。

### 入站

- **合批**：同一聊天室 5 秒內的多則訊息合成一次通知，`message_id`、`user_id` 只帶最後一則，另附 `batch_size`；觸發前 5 秒內未 @ 的訊息也會併入（原始碼）
- **編輯訊息**：入站通知未見編輯事件，無可靠判定訊號
- **入站附件**：未帶觸發字的附件只暫存 5 秒（`BATCH_WINDOW_MS`），期間有觸發才一併轉交；逾時即丟棄，歷史只記 `[document]`、不存 `file_id`，事後無法取回（實測）
- **自己的訊息**：發送端收不到自己發的訊息（實測）
- **觸發字**：`mentionPatterns` 全域生效、比對訊息與 caption 全文、設定後立即生效；bot 之間發的 `@all` 可互相觸發（實測）

### 出站

- **附件**：`reply` 帶 `files` 時文字與檔案拆兩則發送，檔案無 caption、帶不了 @；帶 `reply_to` 時檔案也回覆該訊息，因此回覆對方 bot 訊息即可讓對方收到檔案（實測）
- **到達順序**：檔案可能晚於文字到達，對方需確認檔名與大小後才算送達
- **工具標示上限**：傳送 50MB、下載 20MB（未實測）

### bot 互通

依 2026-11-05、11-12 實測：

- **群組管道可行**：雙向互通至少一方開 Bot-to-Bot 即可；回覆時須 @ 對方，否則對方收不到
- **私訊管道未驗證**：需雙方都開，且對方 bot ID 須進 `allowFrom`，但 `allowFrom` 內的人會收到並可核准工具權限確認
- **加入群組**：有加成員權限者可直接以 username 加入對方 bot，對方本人不必在群內；對方仍須在自己終端機授權該群組（依機制，未實測）
- **迴圈**：`@all` 問「誰看到請 @我」對方以 @ 回覆成功；確認後對方仍可能再發新的 `@all` 廣播。官方 0.0.7 原始碼未見去重或深度上限；限速硬防線為強化版 `limits`（見 setup.md〈群組與授權〉）

### 更新覆蓋與還原

- **覆蓋機制**：官方 plugin 更新會覆蓋強化版檔案，或改用不含強化版的新版本目錄；強化版功能（歷史、MCP-only 鎖、權限轉送）消失，但官方 server 仍讀預設目錄，基本收發看似正常（依原始碼推論，未實測）
- **重新套用**：見 setup.md〈Claude Code 端〉「官方 plugin 更新會蓋掉強化版」；強化版另提供 `/telegram:update`（未實跑）
- **還原官方版**：把 `~/.claude/plugins/cache/claude-plugins-official/telegram/` 下最新版本目錄的 `server.ts.official` 複製回 `server.ts`；還原後官方版改讀 `bot.pid`，`data/` 不再使用

### 常駐模式分析

強化版 `telegram-supervisor.ts`（安裝於 `~/.claude/scripts/`）提供崩潰重啟、context 超量自動重開、Agentic Mode 與 `/new`。不採用的結論見 setup.md〈Claude Code 端〉；阻礙如下：

| 阻礙 | 說明 |
|---|---|
| 需 `expect` | supervisor 以 `claude-daemon-wrapper.exp` 啟動 Claude |
| plugin 未啟用 | supervisor 的 `--settings` 只帶 hooks、不含 `enabledPlugins`，全域停用下不會載入 channel |
| 跳過權限寫死 | `--dangerously-skip-permissions` 在 `BASE_ARGS`，要拿掉只能改腳本；主機掛 docker socket 時風險及於宿主機 |

## Claude Code 端歷史收錄

查歷史結果不完整、或評估保存範圍時讀本段。依強化版 `server.ts` 原始碼，標「實測」者除外。

| 項目 | 行為 |
|---|---|
| 儲存 | `~/.claude/channels/telegram/data/messages.db`（SQLite），重啟保留 |
| 工具 | `get_history` 依時間往回翻（預設 50、上限 200 則，`before` 帶 unix 時間分頁）；`search_messages` 子字串比對（預設 20、上限 100 則），非 FTS，中文不需分詞；`clear_history` 清單一聊天室，加 `restart_context` 另重啟 session；只刪本機紀錄，`clear-history.sh` 為終端機版 |
| 自動附帶 | 每則入站通知附 `[Recent history — last N messages]`：該聊天室最近 5 則、依時間排序，每則截 300 字，bot 自己的發言標 `[BOT]` |
| 跨 `/clear` 記憶 | `save_memory` 把摘要追加到 `data/memory.md`，啟動時載入 MCP 指示；超過 1 萬字時較舊的一半壓縮；`clear_history` 與 `clear-history.sh` 都不清此檔 |
| 收錄範圍 | 所有入站訊息在 gate 檢查前寫入，含群組內沒 @ 的訊息；bot 自己的 `reply` 送出後也寫入；語音預設先轉寫再存（`autoTranscribe`，需轉寫服務，可能額外耗 API 費用或本機 CPU） |
| 保存期限 | 清理策略、非即時上限：每寫入 100 筆清一次，刪 14 天前與每聊天室 500 則以外者；資料庫超過 50MB 時每聊天室縮到 200 則，不保證降回 50MB；寫死於程式，改用 `scripts/tune-history.sh` 放寬（見 setup.md〈執行紀錄〉「調整保存上限」） |
| 收不到 | session 關閉期間只能靠 Telegram 24 小時 update 回補；加入群組前的訊息；隱私模式未關時沒 @ 的群組訊息 |

已知缺陷：

- **跨聊天室查詢**：`chat_id` 由模型傳入，只檢查是否為已授權聊天室，在私訊中可查到已授權群組的歷史；與 SKILL.md〈不變式〉「查歷史只限觸發的聊天室」不符，目前只靠規範約束
- **未授權聊天室也會存**：寫入在 gate 前，未加入的群組、陌生人私訊同樣進資料庫，只是不送進 session
- **同秒排序不定**：依秒級時間戳排序，同一秒內順序不定，`limit` 截斷時可能漏掉較新者（實測）
- **分頁漏訊息**：`before` 以 `date <` 篩選，同秒訊息跨頁會漏；要精確時多取幾則再依訊息 ID 排，仍無法保證完整（原始碼）

## Codex 端機制

評估 Codex 端能否滿足需求、或日後實測前了解其設計時讀本段。全部依 README、`config.example.json` 與 `src/bridge.mjs`，**未實測**。設定位置與觸發設定見 setup.md〈Codex 端〉。

### 上下文與紀錄

| 機制 | 用途 | 重啟保留 | 查詢 |
|---|---|---|---|
| `mentionContext` | 觸發時附加最近群組訊息 | 否，記憶體 | 無工具 |
| `liveLogEnabled` | 可選明文 JSONL 收發紀錄（state directory 下 `telegram-live.jsonl`，`liveLogMaxChars` 預設 6000） | 是 | 需自行分析 |
| Telegram Update Archive | 原始 update 的持久化與恢復 | 是 | 不是聊天歷史 API |

`mentionContext` 參數：

| 參數 | 意義 |
|---|---|
| `messageCount` | 觸發時最多附帶幾則，預設 10 |
| `maxStoredMessages` | 記憶體緩衝最多保留幾則 |
| `maxMessageChars` | 每則截斷長度 |
| `recordAllDeliveredMessages` | 收到的一般群組訊息也存入緩衝；不代表寫入 JSONL |

- **JSONL 不保證收齊**：部分未觸發的群組訊息在 `appendLiveLog` 前就已返回；只需近期上下文時不必啟用
- **與需求的符合度**：見 design.md

### Session 與權限

- **單一持續 thread**：README 說明預設私訊、群組與連接終端共用同一 thread；`allowedUserIds` 只管誰能觸發、不隔離上下文，多人或多群組要分 bridge instance 與 thread
- **工作目錄協定**：`AGENTS.example.md` 的協定可併入工作目錄的 `AGENTS.md`
- **群組唯讀、私人寫入工具預設關閉**（`privateToolsEnabled: false`）：對本 skill 的影響見 setup.md〈Codex 端〉

## 多人部署考量

規劃多位負責人、多個 AI 共用群組時讀本段。

- **群組 bot 與個人開發分開評估**：群組 bot 盡量唯讀、限定授權群組；各自改 repo 的開發環境需要各自的工作目錄、Git 身分、權限、session、訂閱與審核策略。bot 數量不等於執行環境數量，🚫 不把多人映射到同一個可寫 session 或工作目錄
- **Claude Code 端隔離**：強化版的群組與權限設定是否讓每位使用者的執行環境完全隔離，需實測，不能只依 allowlist 判定；同使用者的 session 仍讀得到 `.env`
- **Codex 端隔離**：單 thread 預設不適合直接當多人隔離部署，見〈Codex 端機制〉
- **額度與限速**：用量集中在執行 bot 的帳號（〈元件與成熟度〉）；強化版 `limits` 跨同一套強化版內所有 bot 合計，不同負責人的部署各自計算
- **資料檔**：token、AI 憑證、SQLite、JSONL 都需限制檔案權限並訂保留政策
- **成本觀測**：除 token 外，語音轉錄 API 費用、磁碟占用與日誌中的敏感資料都要分開統計

## 待確認

尚未查證或實測、但會影響部署判斷的事項。

| 項目 | 現況 |
|---|---|
| 帳號共用條款 | 一個 Claude 或 ChatGPT 帳號透過 bot 供全隊使用是否符合各家條款，未查 |
| 超級群組上限 | 是否另有上限，未查 |
| Bot-to-Bot 預設狀態 | 新 bot 預設開或關，未查 |
| 搶線後的訊息 | 沒帶 `--channels` 的 session 搶到 poller 時訊息是否丟失；要用真實 bot 測，會中斷現有連線 |
| 離線回補 | 重啟後是否確實收到 24 小時內的 update，未實測 |
| Codex 端全部行為 | 觸發、上下文、bot 互讀、權限確認轉送均未實測 |

## 來源

- Telegram：[Bots FAQ](https://core.telegram.org/bots/faq)、[Bot API](https://core.telegram.org/bots/api)、[Bot features](https://core.telegram.org/bots/features)、[Bot-to-bot communication](https://core.telegram.org/api/bots/bot-to-bot)、[Bot API changelog](https://core.telegram.org/bots/api-changelog)、[Telegram FAQ](https://telegram.org/faq)
- Claude Code：[channels](https://code.claude.com/docs/en/channels)、[feature availability](https://code.claude.com/docs/en/feature-availability)、[Max plan 用量](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-max-plan)、[官方 Telegram plugin](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/telegram)
- 強化版：[README](https://github.com/k1p1l0/claude-telegram-supercharged)、[ACCESS.md](https://github.com/k1p1l0/claude-telegram-supercharged/blob/master/ACCESS.md)
- Codex：[pricing](https://learn.chatgpt.com/docs/pricing)、Codex-tg-Bridge [README](https://github.com/HailSyner/Codex-tg-Bridge/blob/main/README.md)、[config.example.json](https://github.com/HailSyner/Codex-tg-Bridge/blob/main/config.example.json)、[src/bridge.mjs](https://github.com/HailSyner/Codex-tg-Bridge/blob/main/src/bridge.mjs)
