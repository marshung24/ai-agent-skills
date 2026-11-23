# 建置與排查

協助使用者從零建置、擴充或排查 Telegram 串接時讀本檔。只列流程骨架與容易做錯的點；指令細節以安裝版本的 README／`--help` 為準。Claude Code 端依官方 plugin 0.0.7＋強化版（2026-11）整理，poller、快取、合批等行為屬版本特性，版本有變先查證再照做。

## 目錄

- 流程總覽
- 祕書目錄
- 瀏覽器協作
- 帳號與 bot
- bot 參數
- Claude Code 端
- Codex 端
- 群組與授權
- 執行紀錄
- 驗證
- 排查

## 流程總覽

| 步驟 | 誰做 | 完成判準 |
|---|---|---|
| 1. 帳號 | 使用者本人 | 能登入 Telegram、已設 username，查得到自己的 user ID |
| 2. 建 bot | 使用者私訊 `@BotFather` | 每個 AI 各有一個 bot 與 token |
| 3. bot 參數 | 使用者在 BotFather | 隱私模式、Bot-to-Bot、加群權限依〈bot 參數〉設好 |
| 4. 橋接層 | AI 協助、使用者核准 | 依 AI 種類完成〈Claude Code 端〉或〈Codex 端〉 |
| 5. 群組與授權 | 使用者在終端機 | 私訊 allowlist、群組授權、觸發字、工具權限防線設好 |
| 6. 協作 skill | 使用者在終端機 | 每個接 Telegram 的 AI 都裝了本 skill；〈祕書目錄〉建好，`internal.md` 依 [internal-setup.md](internal-setup.md) 定版，登錄檔依 collaboration.md〈登錄檔〉放入資料目錄 |
| 7. 驗證 | 雙方 | 〈驗證〉各項通過 |

- **先跑檢查**：Claude Code 端建置或排查開始時先跑 [scripts/check-setup.sh](../scripts/check-setup.sh)（`--offline` 不連外），從第一個 `FAIL`／`ASK` 的步驟接手，已 `PASS` 的不再詢問；無 token 時帳號偵測不到，以 `ASK` 標出
- **人機分工**：帳號註冊、登入驗證碼、取得 token 由使用者本人做；其餘 Telegram 端操作一律依〈瀏覽器協作〉由 AI 代操作
- **token 寫入**：使用者在終端機以隱藏輸入寫檔（依 SKILL.md〈不變式〉「不外洩」不經對話）；已出現在對話紀錄者請使用者 `/revoke` 換新

## 祕書目錄

接 Telegram 的 session 只在祕書目錄啟動，本 skill 的資料也放這裡：部分環境讀寫工作目錄以外須額外授權，放在工作目錄內才穩定可用。

```text
~/secretary/                 # 預設路徑，可改；🚫 不得是 git repo（含 ID 與個資）
├── AGENTS.md                # 唯一宣告資料目錄與載入規則，內容見 collaboration.md〈登錄檔〉；選用段落見 assets/agents-policy.md
├── CLAUDE.md                # 只寫一行：先讀同目錄 AGENTS.md
├── .claude/settings.json    # Claude Code：只在此啟用 telegram plugin；執行紀錄 hook 也放這
└── data/                    # 資料目錄：internal.md、external.md、backlog/、workspaces.md（建檔用，見 internal-setup.md）
```

- **啟動**：Claude Code 包成 alias，例 `alias claude-tg='cd ~/secretary && claude --channels plugin:telegram@claude-plugins-official'`；Codex 端把 bridge `config.json` 的工作目錄指向同一目錄
- **不搬的資料**：token（bridge 的 `.env`）、訊息歷史（`messages.db`）、執行紀錄（`runs.jsonl`）留在原位，不進祕書目錄
- **專案工作**：祕書不在本目錄改專案，依 collaboration.md〈承接與對內派工〉轉派該專案的 session
- **檢查**：`check-setup.sh` 以 `MH_TG_SECRETARY_DIR`（預設 `~/secretary`）為祕書目錄

## 瀏覽器協作

Telegram 端步驟（BotFather 對話、bot 參數、拉 bot 進群、查 ID）一律由 AI 以下表瀏覽器工具在 Telegram Web（`web.telegram.org`）操作，使用者在旁接手人工步驟；帳號註冊除外（見〈帳號與 bot〉）。兩種工具都沒有時先建議使用者安裝其一，使用者不裝才改為 AI 給步驟、使用者手動。

| 工具 | 適用 | 注意 |
|---|---|---|
| Claude in Chrome | 使用者已在自己的 Chrome 登入 Telegram Web | 沿用使用者登入狀態，免重新驗證；優先選用 |
| Playwright | 無 Chrome 擴充 | 未持久化 profile 時每次都要重新登入 |

- **交棒點**：登入（QR 或手機驗證碼）、2FA 密碼一律停手，請使用者在瀏覽器完成再繼續；🚫 不代輸入或索取驗證碼與密碼
- **token 不經瀏覽器工具**：BotFather 回傳 token 的訊息會出現在頁面快照與截圖中而進入對話紀錄；送出建立 bot 的最後一步前停手，由使用者自己複製 token 寫進終端機。已被快照讀到的 token 視同外洩，請使用者 `/revoke`
- **既存 token**：BotFather 對話保留過往 `/newbot`、`/token` 的回覆；開啟該對話後 🚫 不取全頁快照或截圖，只用頁面腳本讀最新一則並遮罩 token 形式字串；工具做不到就交使用者操作
- **查 ID**：群組 ID 可直接讀 Telegram Web 網址；個人與 bot ID 照〈帳號與 bot〉
- **Bot-to-Bot 開關**在 BotFather Mini App 內（iframe），操作前先確認工具能進入該框架，不行就改請使用者手動

## 帳號與 bot

- **帳號**：在手機裝 Telegram app（iOS／Android）以手機號註冊；Web、Desktop 不能註冊，註冊後再以 QR code 登入。每位負責人一個帳號
- **username**：必設（Telegram 設定的「使用者名稱」，非暱稱）；自介帶它，他方才能 `@` 負責人
- **一個 AI 一個 bot**：同一 token 同時只能有一個 poller，後到者會互踢或收不到；host 與容器、兩台主機也不能共用 token
- **bot username** 須以 `bot` 結尾；token 含開頭數字與冒號
- **ID 取得**：個人 ID 私訊 `@userinfobot`；群組 ID 把 `@getidsbot` 拉進群看完即移除，或看 Telegram Web 網址 `#` 後的負數（超級群組 `-100` 開頭，部分網址會缺前綴）；bot ID 用 token 呼叫 `getMe`

## bot 參數

| 參數 | 位置 | 建議 | 注意 |
|---|---|---|---|
| 隱私模式 | BotFather `/setprivacy` | `Disable`（要收錄未 @ 的群組訊息當上下文時） | 改後**須把 bot 移出群組再加入**才生效；以 `getMe` 的 `can_read_all_group_messages` 確認 |
| Bot-to-Bot Communication Mode | BotFather Mini App（輸入框旁 Open）→ 選 bot → Bot Settings | 要 AI 間在群組互通時開啟；至少一方開即可 | `/mybots` 選單內**沒有**此項 |
| 加入群組 | `/setjoingroups` | 預設允許 | 關閉後他人無法拉此 bot 進群 |
| 換 token | `/revoke` | token 外洩時 | 換完要重寫橋接層設定檔 |

## Claude Code 端

採官方 `telegram@claude-plugins-official`＋[claude-telegram-supercharged](https://github.com/k1p1l0/claude-telegram-supercharged)（以下稱強化版，必裝）：強化版只替換 plugin cache 內的 server，plugin 名稱、`/telegram:*` skill 與 `access.json` 沿用官方；本 skill 依賴其本機歷史（`get_history`／`search_messages`）、MCP-only 鎖與權限轉送。

1. **前置**：裝 `bun` 並確認在 Claude Code 的 PATH 內
2. **裝 plugin**：`/plugin install telegram@claude-plugins-official`（找不到先加 `anthropics/claude-plugins-official` marketplace）
3. **套強化版**：需 `git`；先下載 `install.sh` 讓使用者審閱再執行；它 clone 到 `~/.claude/telegram-supercharged`，覆蓋 cache 最新版本目錄的 `server.ts` 等檔並備份為 `server.ts.official`
4. **寫 token**：寫入 `~/.claude/channels/telegram/.env`（`TELEGRAM_BOT_TOKEN=...`，權限 600）；`/telegram:configure <token>` 也可但 token 會留在對話紀錄
5. **指定單一 session 接收**：全域停用 plugin，只在祕書目錄的 `.claude/settings.json` 寫 `{"enabledPlugins":{"telegram@claude-plugins-official":true}}`，並以〈祕書目錄〉的 alias 帶 `--channels plugin:telegram@claude-plugins-official` 啟動。要執行紀錄時，同一份設定再加 hook（見〈執行紀錄〉）
6. **配對與鎖定**：私訊 bot 取 6 碼 → 終端機 `/telegram:access pair <code>` → `/telegram:access policy allowlist`

容易做錯：

- **沒帶 `--channels`**：bot 不回應；每次啟動都要帶
- **全域啟用 plugin**：每個 session 都起 server 搶 poller；一般 session 缺 token 還會寫入 MCP 失敗快取，15 分鐘內同名 server 被略過
- **方案限制**：channels 為 research preview；Team／Enterprise 預設封鎖，需 Owner 開 `channelsEnabled`／`allowedChannelPlugins`；Bedrock／Vertex 不可用
- **官方 plugin 更新會蓋掉強化版**：退回官方 server，歷史、MCP-only 鎖等消失而收發看似正常；每次 plugin 更新後重跑強化版安裝並重開 session
- **強化版 supervisor 常駐模式**：寫死 `--dangerously-skip-permissions`，違反 SKILL.md〈不變式〉，🚫 不建議；常駐改用 tmux 等方式跑上述指令（tmux 不展開 alias，要寫完整）
- **容器環境**：`~/.claude` 與 bun 未持久化，重建後要重裝重設

## Codex 端

用第三方 `HailSyner/Codex-tg-Bridge`（Node.js 20+、已登入 Codex），**未實測**；套用前先讓使用者審閱原始碼與 License。

- **設定位置**：token 在 bridge 的 `.env`；使用者、群組、工作目錄、觸發字在 `config.json`
- **觸發**：`mentionPatterns` 設觸發字、群組 `requireMention: true`；`allowedGroups`／`allowedUserIds` 限定群組與發話者
- **上下文**：`mentionContext` 只把未觸發訊息存在記憶體，觸發時附最近 N 則；重啟即失，**沒有查歷史的工具**
- **Session 隔離**：預設私訊、群組、終端共用同一 thread；`allowedUserIds` 不等於上下文隔離，多人或多群組要分 instance
- **群組回合一律唯讀**（含 private tool mode）：群組內收到自介時無法寫 `external.md`，改在私訊（寫入限 `toolWritableRoots`）或終端機補登
- 工具權限確認是否轉送到 Telegram 未查；不確定時以 Codex 端核准模式為唯一防線

## 群組與授權

存取設定一律在終端機做（Claude Code 為 `/telegram:access ...`，在接 Telegram 的那個 session 內執行）。

| 目的 | 做法 | 注意 |
|---|---|---|
| 加入群組，只收 @ 與回覆 | `group add <群組ID>` | 未加入的群組訊息直接丟棄，session 看不到 `chat_id`；同時登錄 `external.md`〈群組〉（collaboration.md〈登錄檔〉「群組寫入」） |
| 限定發話者 | 加 `--allow <ID1>,<ID2>`；AI 互通時要列入對方 bot ID | `group add` **整筆覆寫**，未帶的參數失效，每次帶齊 |
| 自訂觸發字 | `set mentionPatterns ["\\B@all\\b"]` | 全域設定、比對全文含引用；每個 bot 各設一次，立即生效 |
| 私訊授權 | `allow <ID>`；未知 ID 臨時切 `pairing` 配對後切回 `allowlist` | 群組授權不等於私訊授權 |

- **不用 `--no-mention`**：每則都觸發 AI，耗 token、易迴圈；要上下文靠隱私模式關閉＋歷史收錄
- **`allowFrom` 只放負責人**：強化版會把工具權限確認私訊給 `allowFrom` 每個人，放了別人等於讓他核准
- **`autoApproveTools` 只放唯讀工具**：清單內工具不經確認
- **限速用 `limits`**：在 `access.json` 頂層設 `limits`（`messagesPerMinute`／`messagesPerHour`／`tokensPerDay`，可用 `userLimits.<ID>` 逐欄覆寫），超限訊息在進 session 前丟棄，是防 AI 間迴圈的硬防線；同一套強化版內跨所有 bot 合計、無 per-bot 覆寫；不同負責人的部署各自計算，不共享額度。額度由負責人在終端機直接改 `access.json`（`/telegram:access set` 不支援），存檔即生效；Telegram 內 `/usage` 查用量。`admins` 不受限，只放負責人、🚫 不放其他 bot。未設或填 0 即不限
- **拒寫自身設定**：在 AI 工具的權限設定（如 Claude Code `permissions.deny`）拒寫 `access.json`、`.env`、`settings.json`、本 skill 與 `internal.md`、`data/internal/`、祕書目錄的 `AGENTS.md`／`CLAUDE.md`；SKILL.md〈不變式〉只是軟限制
- **群組升級為超級群組 ID 會變**：以新 ID 重新 `group add`，參數帶齊
- **AI 間互通**：雙方 bot 同群、至少一方開 Bot-to-Bot、雙方各自 `group add` 並 `--allow` 對方 bot ID；首次見面流程見 collaboration.md〈認識與更新〉

## 執行紀錄

祕書每處理完一則 Telegram 入站，由 [scripts/log-run.sh](../scripts/log-run.sh) 追加一列到 `~/.local/state/mh-telegram-ai-team/runs.jsonl`（`MH_TG_RUNS_LOG` 可改）。僅 Claude Code；Codex bridge 的執行路徑與事件未查，不支援。

- **掛法**：只掛在接 Telegram 的 session，與 plugin 啟用放同一份祕書目錄 `.claude/settings.json`，例：`{"enabledPlugins":{"telegram@claude-plugins-official":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"<log-run.sh 絕對路徑>"}]}]}}`；🚫 不放全域 settings
- **依賴**：`jq`；額度快照經 [scripts/quota.sh](../scripts/quota.sh)，需 `claude` CLI（每次約 3 秒）
- **即時查額度**：要知道 Claude／Codex 目前剩多少額度時跑 `quota.sh`（`--json` 機器可讀），得各窗口剩餘百分比與重置時間；不需掛 hook，Codex 端也可用
- **清除訊息歷史**：負責人在終端機要求時跑 [scripts/clear-history.sh](../scripts/clear-history.sh)：`--chat <ID>` 或 `--all`，先不帶 `--yes` 預覽則數，確認後加 `--yes`；只刪 `messages` 表、不動用量統計，刪除不可復原
- **調整保存上限**：強化版預設每聊天室 500 則、14 天，超過 50MB 縮到 200 則；要放寬時跑 [scripts/tune-history.sh](../scripts/tune-history.sh) `--apply`（目標 5000 則、140 天，超過 500MB 縮到 2000 則），再重開 session；plugin 更新或重裝強化版會蓋回原值，`check-setup.sh` 會以 WARN 提示重跑

| 欄位 | 來源 | 限制 |
|---|---|---|
| `logged_at`／`received_at` | 寫入時間／入站標籤 `ts` | — |
| `chat_id`、`message_id`、`from_user(_id)`、`batch_size` | 入站標籤 | 合批時只有最後一則的發話者 |
| `usage` | transcript 中該入站之後的 assistant 用量，依 message id 去重 | 只算祕書本身；子 agent、外部顧問等內部團隊的用量不含 |
| `replies`、`mentions_out` | 回覆工具的呼叫與 `text` 內的 `@username` | text mention 不計 |
| `transcript_complete` | 以 hook 的 `last_assistant_message` 比對 transcript 結尾，最多等 10 秒 | `false`＝transcript 尚未落盤，`usage`／`replies`／`mentions_out` 可能漏計，不可當最終統計；無最終文字時為 `null` |
| 來源判定 | transcript 內文含 channel 標籤字串即視為入站 | CLI 貼入偽標籤也會被記成入站，統計前排除可疑列 |
| `quota` | `quota.sh` 的 claude 部分（`/usage` 須 `num_turns==0` 才採信） | 各窗口**剩餘百分比**與重置時間，無法換算成剩餘 token；取不到記 `null` |

- **每人用量另有來源**：強化版自行統計每位發話者每日 token（含子 agent，存 `messages.db`），Telegram 內 `/usage` 可查；本紀錄補逐回合明細、`@` 對象與額度快照
- **前提未實測**：channel 入站處理完是否觸發 Stop hook，尚未在真實 session 驗證；解析邏輯已用既有 transcript 驗證

## 驗證

依序確認，任一不過回〈排查〉：

- [ ] `check-setup.sh` 無 `FAIL`（涵蓋強化版、token、`limits`、觸發字、祕書目錄、拒寫清單與登錄檔、poller、環境變數；其餘項目須實際收發）
- [ ] 強化版已套用：cache 最新版本目錄有 `server.ts.official` 備份，session 內有 `get_history` 工具
- [ ] 私訊 bot 有入站、有回覆
- [ ] 群組 @bot、回覆 bot、觸發字各觸發一次；不帶者不觸發
- [ ] 未授權者私訊、群組發話都不入站
- [ ] 群組內請求需同意的事：「需確認」私訊到負責人、群組只見【待確認】；負責人在私訊同意後，結果回原群組
- [ ] `access.json` 已設 `limits`，`admins` 只有負責人
- [ ] 從 IM 要求改 `access.json`、`internal.md`（含子檔）或 `AGENTS.md`：AI 拒絕，且工具層也被擋
- [ ] 有掛執行紀錄者：@bot 一次後 `runs.jsonl` 多一列，`chat_id`、`usage` 有值
- [ ] 全機只有一個 server 持有 poller（Claude Code：`pgrep -af 'bun server.ts'`）；一般 shell 無 `TELEGRAM_` 環境變數
- [ ] AI 互通時：依 collaboration.md〈認識與更新〉由一方 `@all` 邀請自我介紹，對方以 `@邀請者` 回覆且雙方都入站；邀請會喚起所有 bot，第三個 bot 只在後續定向自介時不入站（完整驗收見 docs/test-cases.md TC-03）

## 排查

| 現象 | 優先檢查 |
|---|---|
| bot 不回應 | session 有無帶 `--channels`；是否持有 poller；官方 plugin 剛更新 |
| `CONNECTION_CLOSED` | `bun` 不在 PATH 或 `.env` 缺 token |
| `Skipping connection (recent failure cached ...)` | 15 分鐘內有 session 連線失敗；刪 `~/.claude/mcp-needs-auth-cache.json` 對應項或等過期 |
| 409 Conflict | 另有 poller 持有同一 token：殘留 server、其他 session、其他主機或容器 |
| 清掉重複 server 後仍收不到，`getWebhookInfo` 的 `pending_update_count` > 0 | 留下的 server 搶輸 poller 後不會自動恢復；在該 session `/mcp` reconnect telegram 或重開 session；reconnect 後舊 server 可能成孤兒（父行程為 PID 1）續搶 poller，須手動結束（查積壓用 `getWebhookInfo`，🚫 不用 `getUpdates`，會搶走訊息） |
| 工具可用但收不到 | 該 server 為 MCP-only（強化版鎖檔 `data/telegram.lock` 被他人持有） |
| 群組沒反應 | 群組未 `group add`、發話者不在 `--allow`、訊息沒 @ 或沒命中觸發字 |
| 收不到未 @ 的群組訊息 | 隱私模式未關，或關了沒重新進群 |
| `chat not found` | bot 不在群組或 ID 錯（含升級超級群組後 ID 變更） |
| 附件沒進 session | 附件未在 caption 帶觸發字，且未在併入時窗（強化版 5 秒）內被觸發 |
