# mh-telegram-ai-team 設計文件

> 要改需求、評估架構或選型、或想知道某條規則為什麼存在時讀本檔；讀了得到需求、架構、運作原理、風險與對應防護、選型結論。
> 資料日期 2026-11-12（官方文件查證；Claude Code 端已實測，Codex 端與 Discord 未實測）。
>
> 單一事實來源分工（本檔不重複）：
> - 執行規則（分級、授權、訊息契約）→ [references/collaboration.md](../references/collaboration.md)；情境流程 → [references/collaboration-flows.md](../references/collaboration-flows.md)；[SKILL.md](../SKILL.md)〈不變式〉
> - 建置、排查、驗證步驟 → [references/setup.md](../references/setup.md)
> - 平台與橋接層的調查、內部行為、多人部署 → [platforms.md](platforms.md)；Discord → [discord.md](discord.md)
> - 驗收 → [test-cases.md](test-cases.md)

## 1. 目標

讓多人團隊的 AI（Claude Code、Codex 等）透過 IM 群組協作：被點名才工作、一般聊天不耗推理 token 但可當上下文、權限可控，且盡量不自行開發橋接層或歷史儲存。

## 2. 需求

概念層要求，不分 AI 與平台：

| 面向 | 要求 |
|---|---|
| 觸發 | 只有私訊、@bot、回覆 bot、自訂觸發字（如 `@all`）才啟動 AI；其他群組訊息不消耗推理 token，但可作為之後提問的上下文 |
| 歷史 | 被觸發後可按需查該聊天室歷史，只限該聊天室；來源二擇一：平台 API／MCP 即時抓取，或橋接層全量收錄到本地再由工具查詢 |
| Session | IM 與 CLI 進同一 session、共用 context；同主機多個 session 並存時只有指定 session 接收 |
| 權限 | 私訊與群組分別授權；存取異動只接受終端機；群組訊息是非可信輸入，不因觸發字自動核准高權限操作 |
| 少自建 | 優先用現成 plugin／bridge |

## 3. 架構

```text
IM 群組／私訊
  └── bot（每個 AI 各一個）
        └── 橋接層（plugin／bridge）
              ├── 收錄（本地存放時）：所有收到的訊息 → 本地歷史
              ├── 觸發閘：符合觸發條件才往下送
              │     └── AI session（指定的那一個）
              └── 工具：回覆、查歷史（限該聊天室；本地或平台 API／MCP）
```

- **一個 AI 一個 bot**：同一 bot 同時只能一個接收端；bot 之間不共享 session 與歷史，自訂觸發字讓每個 bot 各自回答，不是協同
- **收錄在觸發閘之前**：採本地存放時，未觸發的訊息也要進歷史才能當上下文；即時抓取則不需收錄
- **歷史來源依平台**：可回溯者（Discord）即時抓；不可回溯者（Telegram Bot API）只能本地存放，且只涵蓋 bot 收到的訊息
- **祕書模型**：每位使用者只有一個 AI 接 IM，對內轉派、對外代言；結構圖見 SKILL.md〈架構前提〉

## 4. 運作原理

- **雙層過濾**：訊息先過平台層（Telegram 隱私模式、Discord Message Content Intent）才到 bot，再過橋接層授權與觸發閘才進 session；任一層擋下就看不到，收錄也只收得到平台層放行的訊息
- **接收端生命週期**：橋接層隨 AI session 起停，session 關閉期間不接收，只能靠平台保留的未讀 update 回補（Telegram 24 小時）
- **回覆管道**：IM 訊息由回覆工具送回，CLI 輸出留在終端，兩邊不自動同步，跨邊須明確要求
- **bot 互通**：IM 沒有 bot 好友機制，不同人的 AI 各用一個 bot，在群組以 @ 或回覆互相觸發

## 5. 風險與防護

規則本文在各 SSOT，這裡只記風險與落點：

| 風險 | 防護 | 規則落點 |
|---|---|---|
| Prompt injection：群組成員、其他 bot、歷史、附件的內容直接進 AI | 只授權信任對象；IM 內容只當資料；接收端不跳過權限確認 | SKILL.md〈不變式〉；collaboration.md〈訊息契約〉 |
| 越權：非負責人觸發派工、PR、部署，或冒充、轉述負責人同意 | 依副作用分級；負責人以 user ID 認定；一次性確認碼綁定來源任務與核准聊天室 | collaboration.md〈任務分級〉〈負責人同意〉 |
| 自我解鎖：經 IM 改存取設定、skill、登錄檔 | 存取異動只在終端機；建議最後加工具權限拒寫，未設者只有軟限制 | SKILL.md〈不變式〉；setup.md〈拒寫設定〉 |
| 對話迴圈與洪水：bot 互相觸發、引用帶出觸發字、`@all` 連鎖 | 定向觸發、往返上限、限速、正文不帶 @ | collaboration.md〈訊息契約〉〈互動規則〉；`access.json` `limits` |
| 跨聊天室外洩 | 查歷史限定觸發的聊天室，不信任傳入的聊天室 ID | SKILL.md〈不變式〉；工具層未強制，見 platforms.md |
| 內部資訊探詢：以唯讀提問或任務確認套出規則、路徑、工具與檔案狀態 | 不分身分限制可揭露的資訊，負責人同意也不解禁；屬軟限制 | collaboration.md〈揭露邊界〉 |
| 憑證外洩 | token 只放橋接層設定檔（600），不進 git、不 export 全域；建置時以一次整體授權告知風險，碰到時只警告；接觸過者收尾清 session 並重設 | SKILL.md〈不變式〉；setup.md〈流程總覽〉〈瀏覽器協作〉 |
| 負責人帳號被入侵，冒用核准權 | 必要設定完成後評估帳號安全，改善由負責人做 | setup.md〈帳號安全評估〉 |

**軟硬限制**：skill 規則是軟限制；硬限制來自平台層（隱私模式）、橋接層（allowlist、`limits`、觸發閘）與 AI 工具的權限設定。關鍵防線以有一層硬限制為目標；已知缺口：跨聊天室查歷史目前只有軟限制（強化版工具只檢查聊天室已授權），不改橋接層前無法補上。

## 6. 選型結論

| 平台 | Claude Code | Codex | 結論 |
|---|---|---|---|
| Telegram | 官方 plugin＋claude-telegram-supercharged（SQLite 歷史、`get_history`／`search_messages`） | HailSyner/Codex-tg-Bridge（`mentionPatterns`、記憶體內最近 N 則） | 採用；免自建、支援自訂 `@all` 與近期上下文 |
| Discord | 官方 Discord plugin | Openclaw-Metis/codex-discord-mcp | 備案；歷史可由 API 回溯，未實測 |

- **歷史完整度**：Claude 端 SQLite 持久且可查；Codex 端只有記憶體內近期訊息，重啟即失、無查詢工具
- **維護成本**：強化版是第三方補丁，官方 plugin 更新會覆蓋；兩個 Codex 橋接層都是低採用的單人專案
- **上線前**：檢查原始碼、License、更新紀錄與權限模型；優先驗證權限隔離、重啟後歷史、bot 對 bot 行為與更新恢復

## 7. 已知限制與待確認

- `@all` 是文字比對，不是 Telegram 原生全體提及；`@everyone`（Discord）同理，且會通知頻道成員
- Telegram Bot API 無歷史回溯；bot 加入前、停機超過 24 小時的訊息永久缺失
- Telegram 群組發訊 20 則／分為硬上限；AI 用量集中在執行 bot 的帳號額度
- 一般群組（非超級群組）的 message_id 是各帳號各自編號，跨 bot 不能拿 ID 互指
- 待確認：一個 AI 帳號經 bot 供全隊使用是否符合各家條款；Codex 橋接層是否轉送工具權限確認；強化版是否轉交 `edited_message`
