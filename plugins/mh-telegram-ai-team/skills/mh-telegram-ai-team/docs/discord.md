# Discord 調查

評估改用或並用 Discord 時讀本檔；讀了得到 Discord 平台限制、Claude Code 與 Codex 兩端的候選橋接層、觸發與歷史機制，以及與本 skill 現行規範的差距。本 skill 目前只實作 Telegram，選型結論見 [design.md](design.md)，Telegram 端對照見 [platforms.md](platforms.md)。

- **資料日期**：2026-11-12 依官方文件、專案 README 與部分原始碼查證
- **實測範圍**：**全部未實測**，「支援」皆為文件或原始碼判斷
- **數字會變**：上限、速率、stars 等數字引用前回原始來源確認

## 目錄

- 候選元件
- 平台限制
- 觸發
- 歷史
- Session 與部署
- 設定範例
- 與現行規範的差距
- 待確認
- 來源

## 候選元件

比較橋接層成熟度時讀本段。

| 項目 | Claude Code | Codex |
|---|---|---|
| 橋接層 | 官方 Discord channel plugin（[`external_plugins/discord`](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/discord)） | [Openclaw-Metis/codex-discord-mcp](https://github.com/Openclaw-Metis/codex-discord-mcp) |
| 成熟度 | Anthropic 官方；channels 為 research preview，方案限制同 Telegram（見 platforms.md〈元件與成熟度〉） | 第三方，MIT，0 stars，最後 commit 2026-07-11 |
| 模式 | Claude Code channel plugin，存取設定走 `/discord:access` | Discord bot＋Codex CLI／MCP，存取設定走 `codex-discord-mcp access` |
| 本地訊息資料庫 | 不需要 | 不需要 |
| 為 `@everyone` 文字觸發 fork | 不需要 | 不需要 |

## 平台限制

和 Telegram 比較平台層差異時讀本段。依官方文件。

| 項目 | Discord | Telegram 對照 |
|---|---|---|
| bot 費用 | 免費 | 免費 |
| 伺服器人數上限 | 2,500 萬 | 群組 200,000 |
| bot 發訊速率 | 每 bot 50 請求／秒，各路由動態限流 | 每群組 20 則／分硬上限 |
| 讀全部訊息 | 需 Message Content Intent；100 個伺服器以上或 1 萬名可見使用者以上才需審核 | 關隱私模式或設為管理員 |
| 歷史 | `Get Channel Messages` 每次 1–100 則、可分頁回溯 | Bot API 無歷史 |
| 檔案 | 預設 20 MiB／檔（新舊文件 20MB／10MB 不一致） | 上傳 50MB、下載 20MB |
| bot 互通 | 官方未說明；需自行以 `author.bot` 過濾（推論） | Bot-to-Bot Communication Mode |

- **對團隊規模不構成卡點**：免費、人數上限與 intent 審核門檻都遠高於團隊規模
- **主要差異**：Discord 有原生歷史 API、發訊速率寬鬆得多；Telegram 的歷史與速率限制是現行方案最大的平台卡點

## 觸發

設計觸發規則、或判斷 `@everyone` 是否可靠時讀本段。

| 觸發方式 | Claude Code | Codex |
|---|---|---|
| 私訊 | 依存取設定 | 依 DM policy |
| @bot | 支援 | 支援 |
| 回覆 bot | 支援 | 支援 |
| `@everyone` | `mentionPatterns` 文字比對 | `mention-pattern add` 文字比對 |
| 一般訊息 | 不觸發（mention gate） | 不觸發（mention gate） |

Codex 端 `src/discord.ts` 的 `isMentioned()` 判斷順序（原始碼查證）：

1. `message.mentions.has(this.client.user, { ignoreEveryone: true })`：直接 @bot
2. 回覆 bot：依被回覆訊息的作者或近期發送訊息 ID
3. 對 `message.content` 套用 `access.mentionPatterns` 正規表示式

`src/cli.ts` 實作 `access mention-pattern list|add|remove`、`src/types.ts` 有 `mentionPatterns?: string[]`、`src/state.ts` 載入該設定，因此不需 fork。

`@everyone` 的限制：

- **文字不等於原生提及**：文字比對讓輸入 `@everyone` 的訊息觸發 AI，但不保證該訊息具備 Discord 認定的有效群體提及；要嚴格只認原生提及，兩端都需改用 `message.mentions.everyone` 判斷，屬原始碼層級調整
- **會通知成員**：`@everyone` 是 Discord 原生通知機制，非專為 AI 設計
- **一則多觸發**：兩個 bot 都設規則時，同一則訊息會啟動兩個 agent，各自回答
- **🚫 不用 `--no-mention` 取代觸發字**：會讓一般訊息也觸發 AI

## 歷史

評估歷史查詢能力時讀本段。

- **按需讀取**：兩端都以 `fetch_messages` 工具呼叫 Discord API 讀近期訊息（Codex 端為 MCP 工具），不需預先複製到本地資料庫
- **加入前的訊息讀得到**：不同於 Telegram 只能從 bot 開始收錄後累積
- **限制**：受頻道權限、分頁、API 限流與工具實作限制；不等於跨頻道全文搜尋
- **不保證永久**：已刪除或失去權限的訊息通常無法回溯
- **前提**：bot 需 Message Content Intent 與 Read Message History 權限，另需發訊權限

## Session 與部署

規劃多人使用時讀本段。

- **Session 延續**：Claude Code 端沿用 Claude Code session；Codex 端為 Codex CLI session，設 `CODEX_RESUME_BY_CHANNEL=true` 可依頻道恢復
- **bot 身分不等於執行環境**：兩個 bot 身分不會自動得到每人獨立的執行環境；每人要用自己的訂閱與 workspace 時，仍需各自的 plugin／bot instance、token、路由與授權，🚫 不把多人映射到同一個可寫 session 或工作目錄
- **其餘部署考量**：與 Telegram 相同者見 platforms.md〈多人部署考量〉

## 設定範例

PoC 時參考；格式以安裝版本為準，未實跑。`CHANNEL_ID` 換成實際值。

Claude Code（在接 Discord 的 session 內）：

```text
/discord:access set mentionPatterns '["(^|\\s)@everyone\\b"]'
```

Codex：

```bash
codex-discord-mcp access allow-channel CHANNEL_ID                 # 允許頻道，保留需 mention 的門檻
codex-discord-mcp access mention-pattern add '(^|\s)@everyone\b'  # @everyone 文字觸發
codex-discord-mcp access mention-pattern list                     # 檢查規則
export CODEX_RESUME_BY_CHANNEL=true                                # 可選：依頻道延續 session
codex-discord-mcp bot
```

## 與現行規範的差距

改用或並用前須處理的已知落差。

| 項目 | 差距 |
|---|---|
| 歷史查詢範圍 | Discord 文件只要求限於「被授權的頻道」，弱於 SKILL.md〈不變式〉「查歷史只限觸發的聊天室」；兩端實作是否攔截未查 |
| bot 迴圈 | 平台無 bot 互通規範，防迴圈需靠橋接層或自行以 `author.bot` 過濾；兩端是否內建去重、限速未查 |
| 觸發字 | 現行 `@all` 在 Discord 對應為 `@everyone`，帶通知副作用（〈觸發〉） |
| skill 內容 | SKILL.md、setup.md、collaboration.md 的設定、工具名與觸發守門均以 Telegram 為前提 |

## 待確認

| 項目 | 現況 |
|---|---|
| bot 間互相觸發 | 官方規範未找到 |
| 檔案上限 | 新舊文件 20MB／10MB 不一致 |
| Developer Policy | 原文直接抓取被擋，未讀 |
| `fetch_messages` 實際能力 | 可查頻道、分頁上限、Codex 執行環境能否實際呼叫該 MCP 工具 |
| 工具權限確認 | 兩端是否轉送到 Discord，未查 |

## 來源

- Discord：[Gateway](https://docs.discord.com/developers/events/gateway)、[Rate limits](https://docs.discord.com/developers/topics/rate-limits)、[Message](https://docs.discord.com/developers/resources/message)、[Server caps](https://support.discord.com/hc/en-us/articles/33694251638295-Discord-Account-Caps-Server-Caps-and-More)
- Claude Code：[官方 Discord plugin](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/discord)、[channels](https://code.claude.com/docs/en/channels)
- codex-discord-mcp：[repo](https://github.com/Openclaw-Metis/codex-discord-mcp)、[src/discord.ts](https://github.com/Openclaw-Metis/codex-discord-mcp/blob/main/src/discord.ts)、[src/cli.ts](https://github.com/Openclaw-Metis/codex-discord-mcp/blob/main/src/cli.ts)、[src/types.ts](https://github.com/Openclaw-Metis/codex-discord-mcp/blob/main/src/types.ts)、[src/state.ts](https://github.com/Openclaw-Metis/codex-discord-mcp/blob/main/src/state.ts)
