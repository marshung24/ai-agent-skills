# Telegram 話題調查

評估群組要不要啟用話題（Topics／forum）、或排查話題內誤觸發與回錯位置時讀本檔；讀了得到話題的平台機制、Claude Code 端強化版對話題的處理、離線模擬結果、風險與待確認事項。現行規範以 [SKILL.md](../SKILL.md) 與 [references/](../references/) 為準，**目前沒有話題的專屬規則**；其他平台與橋接層事實見 [platforms.md](platforms.md)。

- **資料日期**：2026-11-24
- **查證版本**：官方 telegram plugin 0.0.7，覆蓋強化版的 `server.ts`（sha256 前 12 碼 `07ef47c172f6`，含本機歷史保存上限調整）
- **證據標示**：〔官方〕Telegram 官方文件、〔原始碼〕讀 `server.ts`、〔模擬〕離線模擬、〔回報〕第三方回報、〔推論〕未驗證
- **實測範圍**：**真實群組全部未實測**；只有模擬證明外掛收到某種 update 時的反應，不證明 Telegram 真的會送出那種 update

## 目錄

- 平台機制
- 外掛行為
- 離線模擬
- 不用 @ 就被喚醒
- 風險與建議
- 待確認
- 來源

## 平台機制

判斷話題能解決什麼、不能解決什麼時讀本段。

| 項目 | 說明 | 證據 |
|---|---|---|
| 畫面 | 話題各有訊息串，可用清單、分頁或合併訊息流呈現；固定有一個不可刪的 General | 〔官方〕 |
| 群組 ID | 話題共用同一個 chat ID，以 `message_thread_id` 區分；General 以外的話題 ID 等於建立該話題的服務訊息 ID | 〔官方〕 |
| 基本群組 | 須先升級成超級群組才能啟用；升級後 chat ID 改變（`migrate_to_chat_id`），要更新 `access.json` 與 `external.md` | 〔官方〕 |
| 送到 General | 照一般訊息送，不指定話題 | 〔官方〕 |
| 送到話題 | 底層以話題 ID 當作回覆對象送出（`inputReplyToMessage.reply_to_msg_id`） | 〔官方〕 |
| 建立話題 | Bot API `createForumTopic` 在超級群組要求 bot 是管理員且有 `can_manage_topics`；一般成員能否建立依群組權限 `can_manage_topics` | 〔官方〕 |
| 隔離 | 話題不是權限邊界，成員可看到全部話題 | 〔推論〕 |

## 外掛行為

要知道話題訊息進到 AI 時帶什麼、AI 回覆會送到哪裡時讀本段。

| 面向 | 行為 | 證據 |
|---|---|---|
| 入站 | 通知帶 `thread_id`；合批時欄位只取最後一則，正文不標話題，另附該群組最近 5 則歷史並標 `[topic:<ID>]`，可部分對回 | 〔原始碼〕〔模擬〕 |
| 觸發與授權 | 群組設定只有 `requireMention`、`allowFrom`，以 chat ID 為鍵，不能分話題 | 〔原始碼〕 |
| `reply` | 傳 `thread_id` 才指定話題；不傳就不指定，只傳 `reply_to` 也不會自動補 | 〔原始碼〕〔模擬〕 |
| 其他發送 | `ask_user`、語音、進度訊息、提醒都不指定話題，`ask_user` 也沒有對應參數 | 〔原始碼〕，`ask_user` 另有〔模擬〕 |
| 合批 | 依 bot 與 chat ID 合批，5 秒內沒有新訊息才送出，不分話題 | 〔原始碼〕〔模擬〕 |
| 未觸發緩衝 | 5 秒內同群組有訊息觸發，先前未 @ 的訊息會一併送出，不分話題 | 〔原始碼〕〔模擬〕 |
| 歷史 | `get_history`、`search_messages` 只依聊天室查；`get_history` 標 `[topic:<ID>]`，`search_messages` 不標 | 〔原始碼〕〔模擬〕 |
| 上下文 | 所有話題與群組的通知都送到同一個祕書 session | 〔原始碼〕 |
| 建立話題 | 沒有建立話題的工具 | 〔原始碼〕 |
| 官方版（未覆蓋強化版） | `server.ts` 沒有 `thread_id` 與合批處理 | 〔原始碼〕 |

## 離線模擬

要重跑或質疑模擬結果時讀本段。

- **做法**：外掛複製成兩份，**原版**只把 grammY 的 `apiRoot` 指向本機假 Bot API，**修正版**再加 `isMentioned` 排除 `forum_topic_created` 一行；各以獨立 `HOME`、假 token 啟動 `server.ts`，用 MCP stdio 收通知並呼叫工具；群組設 `requireMention: true`
- **資料**：update 自行構造，建立話題的服務訊息 ID 等於話題 ID，只驗外掛反應
- **限制**：發送只觀測請求參數，假 Bot API 一律回成功，不證明實際落點；結果表的情境同一版本各跑一次，時間差固定

| # | 情境 | 原版結果 |
|---|---|---|
| 1 | 話題 11 `@bot` | 送達，`thread_id` 為 11 |
| 2 | 話題 11、22 隔 1 秒先後 `@bot` | 合成一批，`thread_id` 只有 22 |
| 3 | 話題 11 未 @，2 秒後話題 22 `@bot` | 合成一批，`thread_id` 為 22，話題 11 那則也送給 AI |
| 4 | 話題 11、22 隔 7 秒先後 `@bot` | 分開送達，`thread_id` 正確 |
| 5 | 未 @，回覆對象是 **bot 建立**話題的服務訊息 | **送達** |
| 6 | 未 @，回覆對象是真人建立話題的服務訊息 | 不送達 |
| 7 | 未 @，沒有回覆對象 | 不送達 |
| 8 | 在 bot 建立的話題內真的回覆 bot、或 `@bot` | 送達 |
| 9 | `reply` 帶 `thread_id`／不帶／只帶 `reply_to` | 帶了才有 `message_thread_id` 參數，其餘沒有 |
| 10 | `ask_user` | 沒有 `message_thread_id` 參數 |

修正版只有情境 5 改為不送達，其餘與原版相同。

## 不用 @ 就被喚醒

評估誤觸發成立的條件與擋法時讀本段。

- **成因**：`isMentioned` 只要回覆對象的發送者是自己就視為點名，沒有排除 `forum_topic_created` 服務訊息〔原始碼〕
- **外掛端成立**：模擬 5、6、7〔模擬〕
- **Telegram 端**：話題內的一般訊息是否帶 `reply_to_message` 指向該服務訊息，真實群組未驗證。支持的證據是底層以話題 ID 為回覆對象〔官方〕，以及私訊話題的回報中桌面版確實如此、iOS 當時沒有帶〔回報〕
- **前提**：話題由該 bot 建立。外掛沒有建立話題的工具，只能以 bot token 直接呼叫 Bot API，且 bot 須有 `can_manage_topics`
- **影響範圍**：只影響該 bot 自己建立的話題；發話者仍受群組 `allowFrom` 限制

| 擋法 | 效果 | 限制 |
|---|---|---|
| 不給 bot `can_manage_topics`，話題由真人建立 | 消除前提 | 已由該 bot 建立的話題不受影響，要改由真人重建 |
| `isMentioned` 排除 `forum_topic_created` | 修正版情境 5 不再送達，情境 8 仍送達〔模擬〕 | 強化版或官方更新會覆蓋，適合回報上游 |
| skill 規則：`reply_to_message_id` 等於 `thread_id` 且正文沒有觸發字時不回 | 不回話 | AI 仍被喚醒、消耗 token，且靠 AI 遵守 |

## 風險與建議

| 風險 | 說明 |
|---|---|
| 回錯話題 | 5 秒內跨話題的訊息合批，`thread_id` 只有最後一則的，其餘要靠近期歷史以內容對回，超出 5 則或內容重複就對不回；真人建立的話題也會發生 |
| 內容混用 | 合批與歷史不分話題；上下文連群組也不分 |
| 回報遺失話題 | 需確認、長任務等跨回合回報要自己記住 `thread_id`，請求紀錄模版沒有這個欄位 |
| 按鈕等送到 General | `ask_user`、進度訊息等無法指定話題 |

- **預設不啟用**：一個群組談一個專案時用不到；多專案優先分群組，可避免合批與歷史混用
- **隔離分三種**：成員看得到什麼，分群組可隔離、話題不行；外掛的歷史與合批，分群組可隔離、話題不行；**AI 上下文兩者都隔離不了**，要隔離須用不同 bot 與不同 session〔推論〕
- **要啟用時**：話題由真人建立、bot 不給 `can_manage_topics`；回覆帶入站的 `thread_id`

## 待確認

- 真實群組話題內的一般訊息，`reply_to_message` 是否指向建立話題的服務訊息，各平台用戶端是否一致
- 只帶 `reply_to` 回覆話題內訊息時，Telegram 會放在該話題還是 General
- 沒啟用話題的超級群組，回覆串的入站 `message_thread_id` 是否有值；Bot API 的發送參數只列 forum 超級群組與啟用話題的私訊，此時把 `thread_id` 帶回是否會失敗
- 合批混話題的實際頻率

## 來源

- Telegram：[Forums](https://core.telegram.org/api/forum)、[Bot API](https://core.telegram.org/bots/api)
- 回報：[bugs.telegram.org/c/58238](https://bugs.telegram.org/c/58238/6)（私訊話題，iOS 12.2.4，標為已修正）
- 外掛：[官方 Telegram plugin](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/telegram)、[claude-telegram-supercharged](https://github.com/k1p1l0/claude-telegram-supercharged)
