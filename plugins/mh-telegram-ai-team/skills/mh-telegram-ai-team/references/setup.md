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
- 帳號安全評估
- 拒寫設定
- 排查

## 流程總覽

引導時以本表為 checklist，一列一項；大步驟編號對應 `check-setup.sh` 輸出。**值都寫死在表內，🚫 不現場判斷、不改預設**；「問」欄寫「否」者一律不問，直接照值做。

| # | 項目 | 誰做 | 固定值與完成判準 | 問 | 不成立時 |
|---|---|---|---|---|---|
| 1.1 | 現況檢查 | AI | 跑 `check-setup.sh`，並查前提、衝突與缺件（含 session 的瀏覽器工具 Claude in Chrome、Playwright）；已完成項標 ✅，其餘併入 1.2 | 否 | 腳本跑不了 → ⚠️，逐項改人工檢查 |
| 1.2 | 整體授權 | 使用者 | 依「整體授權」說明並取得一次同意 | 是否同意 | 不同意 → 改逐步手動、AI 給指令 |
| 2.1 | 有無 Telegram 帳號 | 使用者 | 有；token 有效或 Web 已登入即視為有 | 偵測不到才問 | 無 → 引導用手機 app 註冊（Web／Desktop 不能），完成後接 2.2 |
| 2.2 | 瀏覽器協作 | AI | 依〈瀏覽器協作〉直接試 Chrome、再試 Playwright，缺的依 1.2 補裝；能開 Telegram Web 且使用者看得到、能操作 | 無法確認看得到視窗才問 | 仍不可用 → 之後改逐步手動，視為完成 |
| 2.3 | 登入 Telegram Web | 使用者 | AI 偵測到已登入；沿用既有登入 | 未登入才請登入 | 手動流程 → ⏭️ 不需登入；驗證碼與密碼只由使用者輸入，QR 不截圖 |
| 2.4 | username | AI 引導 | 沿用已設者（非暱稱；暱稱選填） | 未設才問要用什麼 | 不設 → ⚠️ 他方無法 `@` 負責人 |
| 2.5 | user ID | AI | 取自已登入帳號本人（非聊天對象、不從既有名單反推），於 8.2 一併確認 | 否 | 取不到 → 7.2 改走配對 |
| 3.1 | 有無現成 bot | 使用者 | 沿用已確認的 bot，且 token 沒有其他主機或容器在用 → 跳 3.3 | 偵測不到或無法確認才問 | 無 → 3.2；token 在別處使用 → 停用該處或另建 |
| 3.2 | 建立 bot | AI | 名稱依〈帳號與 bot〉「bot 命名」推定；bot 已建 | 否（使用者可自行指定） | 被占用 → 換名重試，仍失敗才問 |
| 3.3 | 隱私模式 | AI | `Disable`（強化版收錄上下文的必要條件）；已在群組者移出再加入；寫 token 後以腳本複核 | 否 | ⚠️ 不擋私訊 |
| 3.4 | 加入群組權限 | AI | 允許；寫 token 後以腳本複核 | 否 | 已關 → 直接開；改不了 → ⚠️ |
| 3.5 | Bot-to-Bot | AI | 開啟（本 skill 選定值；群組互通至少一方要開） | 否 | 進不了 iframe → 請使用者手動；找不到 → ⚠️ |
| 4.1 | 祕書目錄 | AI | `~/secretary`（本 skill 選定值），非 git repo；含 `data/backlog/requests/` | 否 | 在 repo 內 → 問替代路徑 |
| 4.2 | 指令檔與執行期授權 | AI | `AGENTS.md`＝collaboration.md〈登錄檔〉的載入規則（須含 `data/` 宣告）＋assets/agents-policy.md 三段；`CLAUDE.md` 一行 `@AGENTS.md`；未知授權寫「未設定」 | 否 | 寫不進 → ⚠️ 並給內容請使用者貼 |
| 4.3 | alias | AI | `claude-tg`（本 skill 選定值），不帶跳過權限的旗標 | 否 | 已有同名且內容不同 → 不覆蓋，問 |
| 4.4 | 交接檔 | AI | `HANDOFF.md` 內容依〈祕書目錄〉「交接」，不含 token 與 ID | 否 | — |
| 5.1 | 前置工具 | AI | `bun` 必要；`git`、`jq`、`curl` 供安裝與檢查；缺的依 1.2 直接補裝 | 否 | `bun` 裝不了 → 擋 5.2 起；其餘 → ⚠️ 未檢查 |
| 5.2 | 官方 plugin | AI | 已安裝 | 否 | 失敗 → 擋相依項，依〈排查〉 |
| 5.3 | 強化版 | AI | 1.2 已同意，已套用 | 否 | 失敗或不同意 → 明示本 skill 必要能力未就緒，擋相依項 |
| 5.4 | Mini App | AI | `.env` 有 `TELEGRAM_MINIAPP=off`，保留其他設定 | 否 | ⚠️ |
| 5.5 | 啟用範圍 | AI | 全域停用、只在祕書目錄啟用；單一接收 session | 否 | 全域啟用 → 停用 |
| 5.6 | 選用功能與環境變數 | AI | 一律不設：`TELEGRAM_ACCESS_MODE`、`TELEGRAM_EXTRA_BOT_TOKENS`、`TELEGRAM_WEBHOOK`、`TELEGRAPH_ENABLED`、`TELEGRAM_STATE_DIR`、語音 API 金鑰；不裝轉錄工具、不用 supervisor 與常駐模式、不建 `commands.json` 與排程；其餘鍵沿用強化版預設 | 否 | 已有 → ⚠️ 列出，不動 |
| 6.1 | 寫 token | AI | 寫入 `.env`（600），腳本驗證有效；不 export；寫完警告，收尾提醒 `/revoke` 換新並更新 `.env` | 否 | 無效 → 重寫；寫不進 → 給隱藏輸入指令 |
| 7.1 | 授權名單 | AI | 改寫前先看既有 `allowFrom`、`admins` 有沒有他人 | 有他人才問是否為共同負責人 | 是 → 記入 `internal.md`；不是 → 移除 |
| 7.2 | 存取設定 | AI | 啟動前先處理既有接收端，再寫 `access.json`（600）並確認 JSON 可解析（壞檔 server 會退回 `pairing`）：`dmPolicy=allowlist`；`allowFrom`、`admins` 只有 2.5 的負責人與 7.1 確認的共同負責人；`mentionPatterns ["\\B@all\\b"]`；`limits` 為 `messagesPerMinute` 5、`messagesPerHour` 60、`tokensPerDay` 2000000（每人，本 skill 選定值）；`autoTranscribe=false`（否則陌生人語音在授權檢查前就會下載轉錄）；`autoApproveTools=[]`；`groups={}`；其餘鍵不寫，沿用上游預設 | 否 | 沒有 user ID → 啟動後請負責人私訊取碼，配對後立即切回 `allowlist` |
| 8.1 | 登錄檔擬稿 | AI | 依 [internal-setup.md](internal-setup.md) 帶入已知資料（含可選項）；必要欄位查不到標「待確認」，可選欄位查不到留空 | 否 | — |
| 8.2 | 登錄檔定版 | 使用者確認、AI 寫 | `internal.md` 必要欄位已填、權限 600；負責人身分（含 user ID）一併確認 | 內容對不對 | 略過 → ⚠️ 負責人與未列名者只會得到「收到！」（已列為討論者不受影響） |
| 9.1 | 歷史保存上限 | AI | 跑 `tune-history.sh --apply`：5000 則／140 天／超過 500MB 縮到 2000 則（本 skill 選定值；清理策略，非即時上限） | 否 | ⚠️ |
| 9.2 | 執行紀錄 | — | 不掛（前提未實測） | 否 | ⏭️ |
| 9.3 | 工作區盤點 | — | 不做，負責人日後要求才做 | 否 | ⏭️ |
| 10 | 切換 session | 使用者 | 設定都完成後才啟動：新終端機執行 `claude-tg`，首句「讀 HANDOFF.md 接續」；已有正確的接收 session 則不重開 | 請執行指令 | MCP 失敗快取 → 〈排查〉 |
| 11 | 必要驗證 | 雙方；收發與 session 內工具類在接收 session、讀檔或 shell 檢查在建置 session | 〈驗證〉必要，每個勾選框一項；能自動驗的不問 | 需使用者發訊息才請 | 收發或安全項不過 → 〈排查〉；沒條件測 → ⚠️ 未驗證，不得標為已驗證 |
| 12 | 加入群組 | 使用者、AI 引導；查群組 ID 在建置 session，`group add`、登錄與自介在接收 session | `internal.md` 已定版才做；先與使用者確認目標群組；bot 尚未入群者請使用者先加入，加完才查群組 ID（或由使用者提供、自行設定），依〈群組與授權〉「補設群組」完成；一律需 @、不限發話者（群內成員都進得來，怎麼回由回應等級決定）、不啟用話題、bot 不給管理員與 `can_manage_topics` | 要加哪個群組 | 不加 → ⏭️ 未設定，收尾列入「未設定」清單，之後隨時可補 |
| 13 | 帳號安全評估 | AI | 1–12 都完成或略過後才做；先印一行警告再依〈帳號安全評估〉全部偵測完，一次提交清單（現況與建議） | 否 | 偵測不到 → 標「未確認」；使用者要略過 → ⏭️ |
| 14.1 | 拒寫設定 | — | 預設不設；依〈拒寫設定〉提醒一次，使用者要求才設 | 否 | ⏭️ |
| 14.2 | 事後清理 | AI | 曾讓 AI 接觸 token 或密碼者，已提醒清 session、快照並自行重設（提醒送達即完成） | 否 | 沒接觸過 → ⏭️ |
| 14.3 | 登出 Telegram Web | AI | 只對本次建置登入的 Web session 提醒登出；沿用使用者原有登入者 → ⏭️ | 否 | — |
| 14.4 | 刪交接檔 | AI | 全部完成或明確略過才刪；列出略過、未設定與警告 | 否 | 仍有待續項 → 保留 |

- **引導**：依 checklist 一項一項來，🚫 不整批做完再一次總結、不一次丟多個問題或多項步驟
  1. 開始時印整份 checklist 與各項狀態（上表逐列照印，不合併、不省略；11 展開成細項；已完成的直接標 ✅）
  2. 每項依序：印出要做的項目 → 檢查並印出狀態 → 需要時才詢問使用者，一次一個問題（風險、選項與預設值在該項才講）→ 處理，邊做邊講解 → 回報處理完畢 → 下一項。「問」欄為「否」者直接照值做，🚫 不問
  3. 不需要使用者的項目照樣逐項印出，自動往下做，不停下等回覆；停下時只停在一項
  4. 輪到使用者的項目（註冊、驗證碼與密碼、QR 登入、切換 session 等）：明確提醒怎麼做，需要指令就給可直接貼上的完整指令，🚫 不含真 token；使用者回覆後先自行驗證該項，再標完成
  5. 使用者拒絕或做不到的項目標 ⏭️ 略過並記原因，接著做不相依的下一項；收尾時列出略過與警告
  - 每項輸出形狀：

    ```text
    ## 👉 <編號> <項目名稱>（<已完成數>/<總數>）
    要做的：<一句話>
    狀態：<檢查結果>
    請你：<一個問題或一個動作，附完整指令；不需要使用者則寫「不需要，自動處理」>
    完成：<處理結果；下一項：<編號> <名稱>>
    ```

    「請你」不需要使用者回應時，同一則接著印「完成」並進入下一項；需要時停在「請你」，收到回覆並驗證後才印「完成」。狀態標記：✅ 完成、👉 目前、⬜ 未做、⏭️ 略過、⚠️ 警告
- **切換後分工**：步驟 10 之後，只有必須在接收 session（帶 `--channels`）做的才交給它，其餘留在建置 session；`HANDOFF.md` 只寫接收 session 的任務與進度，建置 session 的項目不進該檔
  - **接收 session**：11 中需經 Telegram 收發或 session 內才能做的驗證（入站與回覆、未授權者、IM 改設定被拒、群組觸發、`get_history` 工具可用）、12 的 `group add`、`external.md` 登錄與自介；做完更新 `HANDOFF.md` 並告知使用者
  - **建置 session**：11 中讀檔或 shell 即可的檢查（腳本、`allowFrom`／`admins`、poller、環境變數）、12 的群組 ID 查詢（Telegram Web）、13、14；13 前置依其列，14.4 刪交接檔由它收尾
  - 無獨立建置 session（逐步手動、無瀏覽器工具）：由接收 session 接手全部
- **整體授權**（項目 1.2，整個流程只問一次）：說明 checklist 與固定值、強化版 `install.sh` 摘要（AI 先下載讀完：覆蓋範圍、對外連線與執行的程式）、要補裝的工具（含瀏覽器 MCP）、未授權者的訊息仍會存入本機歷史、授權不能取代而仍會跳出的確認（Claude Code 權限、目錄信任、瀏覽器、sudo），以及敏感資訊風險——token、手機號、裝置與 IP 可能經頁面、截圖或指令紀錄送到模型供應商並留在本機紀錄，取得 token 者可接管 bot
  - 涵蓋：照表完成建置所需的全部 AI 代操作，含在新加群組發自介、接觸敏感資訊、取 token 寫檔、存取設定（視為終端機指示）、帳號安全的唯讀偵測；換頁面、工具或步驟不重問。切換 session 後，使用者要求依 `HANDOFF.md` 接續即沿用；使用者隨時可喊停或改自己做
  - 不涵蓋：註冊、驗證碼與密碼、QR 登入由使用者本人做；負責人身分與登錄內容由使用者確認；拒寫、重設憑證、清理紀錄由使用者決定；建置以外的刪除或對外動作；Telegram 執行期授權
- **敏感資訊只警告不中斷**：碰到前印一行 ⚠️（同類一次），不問、不等回覆，依整體授權繼續；工具做不到或平台要求核准時，只停該動作
- **不卡頓**：拒絕使用或使用不便比缺少功能嚴重。只有收發不通、安全邊界失守、授權範圍外的資料外洩才擋，其餘標 ⚠️ 警告一次就往下
- **檢查腳本**：Claude Code 端建置或排查開始時先跑 [scripts/check-setup.sh](../scripts/check-setup.sh)（`--offline` 不連外），已完成的跳過。`FAIL` 只擋它所屬步驟及相依步驟；`ASK` 在所屬步驟詢問；`WARN`／`INFO` 不擋。`PASS` 只代表該項觀測成立，腳本不涵蓋 username、Bot-to-Bot、〈帳號安全評估〉

## 祕書目錄

接 Telegram 的 session 只在祕書目錄啟動，本 skill 的資料也放這裡：部分環境讀寫工作目錄以外須額外授權，放在工作目錄內才穩定可用。

```text
~/secretary/                 # 預設路徑，可改；🚫 不得是 git repo（含 ID 與個資）
├── AGENTS.md                # 唯一宣告資料目錄與載入規則，內容見 collaboration.md〈登錄檔〉；執行期授權照 assets/agents-policy.md 的預設值寫入，不詢問
├── CLAUDE.md                # 只寫一行 @AGENTS.md，載入同一份內容
├── .claude/settings.json    # Claude Code：只在此啟用 telegram plugin；執行紀錄 hook 也放這
├── HANDOFF.md               # 建置交接檔，建置期間才有，見下方「交接」
└── data/                    # 資料目錄：internal.md、external.md、backlog/、workspaces.md（建檔用，見 internal-setup.md）
```

- **啟動**：Claude Code 由 AI 把 alias 寫入使用者的 shell 設定檔，例 `alias claude-tg='cd ~/secretary && claude --channels plugin:telegram@claude-plugins-official'`（已有同名者先問）；Codex 端把 bridge `config.json` 的工作目錄指向同一目錄
- **交接**（Claude Code）：建完祕書目錄與 alias 後，AI 在祕書目錄寫 `HANDOFF.md`（已定案的選擇、接收 session 要做的項目與狀態（分工見〈流程總覽〉「切換後分工」）、注意事項；🚫 不含 token 與 ID），接收 session 每完成一項就更新，並在設定都完成後請使用者於新終端機改用 alias 啟動，首句請 AI 讀 `HANDOFF.md` 接續；token 寫好前不啟動，以免留下 MCP 失敗快取。只在終端機回合依它接續，建置完成即刪
- **不搬的資料**：token（bridge 的 `.env`）、訊息歷史（`messages.db`）、執行紀錄（`runs.jsonl`）留在原位，不進祕書目錄
- **專案工作**：祕書不在本目錄改專案，依 collaboration.md〈承接與對內派工〉轉派該專案的 session
- **檢查**：`check-setup.sh` 以 `MH_TG_SECRETARY_DIR`（預設 `~/secretary`）為祕書目錄

## 瀏覽器協作

Telegram 端步驟（BotFather 對話、bot 參數、拉 bot 進群、查 ID）與設定檢查，優先由 AI 以下表瀏覽器工具在 Telegram Web（`web.telegram.org`）操作，使用者在旁接手人工步驟；帳號註冊除外（見〈帳號與 bot〉）。

- **測試可用性**：直接試，不先問。可用＝能開啟 Telegram Web，且使用者看得到、能操作該視窗
- **不可用**：依整體授權安裝 Playwright；裝完仍不可用或視窗看不到，改為 AI 給步驟、使用者手動，🚫 不卡在安裝

| 工具 | 適用 | 注意 |
|---|---|---|
| Claude in Chrome | 使用者已在自己的 Chrome 登入 Telegram Web | 沿用使用者登入狀態，免重新驗證；優先選用 |
| Playwright | 無 Chrome 擴充 | 未持久化 profile 時每次都要重新登入 |

- **交棒點**：登入（QR 或手機驗證碼）、2FA 密碼一律停手，請使用者在瀏覽器完成再繼續；🚫 不代輸入或索取驗證碼與密碼；登入 QR 等同登入憑證，🚫 AI 不截圖
- **敏感資訊**（建置全程適用）：依〈流程總覽〉「敏感資訊只警告不中斷」；最少讀取、輸出遮罩、不複述，避免整頁快照，token 優先在工具內直接寫進橋接層設定檔，且只准寫該檔（600）
- **事後清理**：AI 接觸過 token 或密碼者，收尾時如實彙整並建議使用者依序：(1) 清掉 AI 的 session／context，含本機對話紀錄檔與截圖（只清畫面或 context 不會刪除紀錄檔）；(2) 自行重設——token 用 `/revoke` 後以隱藏輸入換掉設定檔的舊值並重開接收 session，密碼在 Telegram 官方 app 更改。重設由使用者本人做，🚫 AI 不代做；換新後的值不再經 AI
- **查 ID**：群組 ID 可直接讀 Telegram Web 網址；個人與 bot ID 照〈帳號與 bot〉
- **Bot-to-Bot 開關**在 BotFather Mini App 內（iframe），操作前先確認工具能進入該框架，不行就改請使用者手動

## 帳號與 bot

- **帳號**：偵測不到才問；沒有就引導在手機裝 Telegram app（iOS／Android）以手機號註冊；Web、Desktop 不能註冊，註冊後再以 QR code 登入。每位負責人一個帳號
- **必查**：username 已設、user ID 已取得；查不到的標 ⚠️「未確認」，不擋其他項目
- **username**：應設（Telegram 設定的「使用者名稱」，非暱稱；暱稱選填），未設由 AI 引導設好，不設只警告；自介帶它，他方才能 `@` 負責人
- **一個 AI 一個 bot**：同一 token 同時只能有一個 poller，後到者會互踢或收不到；host 與容器、兩台主機也不能共用 token
- **bot 命名**：username 為 `<類 userid>_<類 bot 稱呼>_bot`，如 `alice_max_bot`；前者取負責人 username（沒有用 `u<user ID>`），後者取指令檔中 AI 的名字（沒有用 `ai`），符合 Telegram 規則並避開撞名即可。顯示名稱為「<AI 名字> 祕書」
- **token** 含開頭數字與冒號
- **ID 取得**：個人 ID 私訊 `@userinfobot`；群組 ID 把 `@getidsbot` 拉進群看完即移除，或看 Telegram Web 網址 `#` 後的負數（超級群組 `-100` 開頭，部分網址會缺前綴）；bot ID 用 token 呼叫 `getMe`

## bot 參數

建置與排查時逐項查現值並與「建議」比對；值依 checklist 3.3–3.5，不符就直接改成建議值，查不到的標 ⚠️，不擋流程。

| 參數 | 位置 | 建議 | 注意 |
|---|---|---|---|
| 隱私模式 | BotFather `/setprivacy` | `Disable`（強化版收錄未 @ 的群組訊息當上下文的必要條件） | 改後**須把 bot 移出群組再加入**才生效；以 `check-setup.sh` 的結果確認 |
| Bot-to-Bot Communication Mode | BotFather Mini App（輸入框旁 Open）→ 選 bot → Bot Settings | 開啟（至少一方開即可互通） | `/mybots` 選單內**沒有**此項 |
| 加入群組 | `/setjoingroups` | 預設允許 | 關閉後他人無法拉此 bot 進群；以 `check-setup.sh` 的結果確認 |
| 換 token | `/revoke` | token 外洩時 | 換完要重寫橋接層設定檔 |

## Claude Code 端

採官方 `telegram@claude-plugins-official`＋[claude-telegram-supercharged](https://github.com/k1p1l0/claude-telegram-supercharged)（以下稱強化版，必裝）：強化版只替換 plugin cache 內的 server，plugin 名稱、`/telegram:*` skill 與 `access.json` 沿用官方；本 skill 依賴其本機歷史（`get_history`／`search_messages`）、MCP-only 鎖與權限轉送。

1. **前置**：裝 `bun` 並確認在 Claude Code 的 PATH 內
2. **裝 plugin**：`/plugin install telegram@claude-plugins-official`（找不到先加 `anthropics/claude-plugins-official` marketplace）
3. **套強化版**：需 `git`；先下載 `install.sh`，AI 讀後摘要，經〈流程總覽〉「整體授權」同意後執行；它 clone 到 `~/.claude/telegram-supercharged`，覆蓋 cache 最新版本目錄的 `server.ts` 等檔並備份為 `server.ts.official`
4. **關 Mini App**：AI 在 `~/.claude/channels/telegram/.env`（權限 600）寫入 `TELEGRAM_MINIAPP=off`，關閉強化版預設開啟的 Mini App（Agents Board，可檢視與控制本機所有 session）；🚫 不詢問使用者、不列選項，保留檔內其他設定
5. **指定單一 session 接收**：全域停用 plugin，只在祕書目錄的 `.claude/settings.json` 寫 `{"enabledPlugins":{"telegram@claude-plugins-official":true}}`。要執行紀錄時，同一份設定再加 hook（見〈執行紀錄〉）
6. **先設定再啟動**：依 checklist 6–9 寫好 token（`.env` 同名鍵以第一筆為準）、`access.json` 與登錄檔，最後以〈祕書目錄〉的 alias 啟動
7. **配對（取不到 user ID 才用）**：私訊 bot 取 6 碼 → 終端機 `/telegram:access pair <code>` → `/telegram:access policy allowlist`

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

存取設定一律在終端機做：首次建置由 AI 直接寫 `access.json`；之後用 `/telegram:access ...`（在接 Telegram 的那個 session 內執行）。

| 目的 | 做法 | 注意 |
|---|---|---|
| 加入群組，只收 @ 與回覆 | `group add <群組ID>` | 未加入的群組訊息直接丟棄，session 看不到 `chat_id`；同時登錄 `external.md`〈群組〉（collaboration.md〈登錄檔〉「群組寫入」） |
| 自訂觸發字 | `set mentionPatterns ["\\B@all\\b"]` | 全域設定、比對全文含引用；每個 bot 各設一次，立即生效 |
| 私訊授權 | `allow <ID>`；未知 ID 臨時切 `pairing` 配對後切回 `allowlist` | 群組授權不等於私訊授權 |

- **兩層名單**：`access.json` 管進不進得來，回應等級管進來後怎麼回；群組 🚫 不限發話者（名單留空，既有限制一律清空），靠回應等級把關（軟限制），能拉人進群者等於能讓其訊息進 AI
- **不用 `--no-mention`**：每則都觸發 AI，耗 token、易迴圈；要上下文靠隱私模式關閉＋歷史收錄
- **`allowFrom` 只放負責人**：強化版會把工具權限確認私訊給 `allowFrom` 每個人，放了別人等於讓他核准
- **`autoApproveTools` 只放唯讀工具**：清單內工具不經確認
- **限速用 `limits`**：在 `access.json` 頂層設 `limits`（`messagesPerMinute`／`messagesPerHour`／`tokensPerDay`，可用 `userLimits.<ID>` 逐欄覆寫），超限訊息在進 session 前丟棄，是防 AI 間迴圈的硬防線；同一套強化版內跨所有 bot 合計、無 per-bot 覆寫；不同負責人的部署各自計算，不共享額度。預設值依 checklist 7.2，要改由負責人在終端機指示、AI 代改 `access.json`（`/telegram:access set` 不支援），存檔即生效；Telegram 內 `/usage` 查用量。`admins` 不受限，只放負責人、🚫 不放其他 bot。未設或填 0 即不限
- **補設群組**：把 bot 加入群組後，給使用者兩種做法擇一——自己在祕書 session 執行 `/telegram:access group add <群組 ID>`，或把群組 ID 告訴 AI 由 AI 設定；ID 取法見〈帳號與 bot〉。設好後登錄 `external.md`〈群組〉，用途與專案不明寫「未設定」；接著告知使用者「將在該群組發自介，並請收到的人回自介」，再依 collaboration.md〈認識與更新〉發【認識】
- **話題（Topics）**：不主動啟用、不詢問，多專案優先分群組；既有話題不自行關閉，回覆帶入站的 `thread_id`。分群組可隔離歷史與合批，但隔離不了同一祕書 session 的上下文（理由見 docs/topics.md）
- **群組升級為超級群組 ID 會變**：以新 ID 重新 `group add`
- **AI 間互通**：雙方 bot 同群、至少一方開 Bot-to-Bot、雙方各自 `group add`；首次見面流程見 collaboration.md〈認識與更新〉

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

**必要**：不過回〈排查〉；沒有條件測的標「未驗證」，不擋。

- [ ] `check-setup.sh` 無 `FAIL`，且無「未檢查」（由 AI 補裝缺的工具後重跑；`exit 0` 只代表沒偵測到必要項失敗，其餘須實際收發）
- [ ] 強化版已套用：session 內有 `get_history` 工具
- [ ] 負責人私訊 bot 有入站、有回覆（已填 `internal.md` 者得到正常回答，未填者得到「收到！」）
- [ ] 未列入討論者發請求：只得到「收到！」，`backlog/requests/` 多一筆「未處理」，其他什麼都沒做
- [ ] 未授權者私訊不入站（需第二個帳號）
- [ ] `allowFrom`、`admins` 只有負責人
- [ ] 從 IM 要求改 `access.json`、`internal.md`（含子檔）或 `AGENTS.md`：AI 不做也不回
- [ ] 全機只有一個 server 持有 poller（Claude Code：`ps -A -ww -o pid= -o args= | grep '[b]un server.ts'`）；一般 shell 無 `TELEGRAM_` 環境變數

**有用到才驗**：未過只警告，不擋。

- [ ] 群組：@bot、回覆 bot、觸發字各觸發一次；不帶者不觸發；`limits` 已設
- [ ] 群組內請求需同意的事：「需確認」私訊到負責人、群組只見【待確認】；負責人在私訊同意後，結果回原群組
- [ ] 執行紀錄：@bot 一次後 `runs.jsonl` 多一列，`chat_id`、`usage` 有值
- [ ] AI 互通（互相認識不需開放；要進一步討論，先在 `AGENTS.md`「回應等級」把該群組或對方 bot 列為討論）：依 collaboration.md〈認識與更新〉由一方 `@all` 邀請自我介紹，對方以 `@邀請者` 回覆且雙方都入站；邀請會喚起所有 bot，第三個 bot 只在後續定向自介時不入站（完整驗收見 docs/test-cases.md TC-03）
- [ ] 機密：接觸過 token 或密碼者已建議事後清理
- [ ] 拒寫：有做〈拒寫設定〉者，上述 IM 改設定在工具層也被擋

## 帳號安全評估

負責人的 Telegram 帳號等於核准權：帳號被入侵，對方就能在 IM 以負責人身分同意請求。設定、驗證與加入群組（步驟 1–12）都完成或略過後做一次，🚫 不提前；在 Telegram Web 唯讀偵測，會看到手機號、裝置、IP 與聊天清單，先印一行警告。**全程只偵測並建議：不問使用者、不改設定、不強制、不中斷**，偵測完一次提交清單。

| 項目 | 偵測什麼 | 不合格的風險等級 |
|---|---|---|
| 兩步驟驗證（雲端密碼） | 是否啟用 | 高：攔到登入碼即可登入 |
| 登入中的裝置 | 數量與久未使用者；提醒使用者自行確認都認得 | 中：有不認得者視為高 |
| 可疑聊天帳號 | 分析聊天清單有無可疑帳號（只看清單，不開對話） | 高 |
| 復原信箱 | 是否已設 | 中：忘記密碼難復原 |
| 手機號碼 | 是否已設；提醒使用者自行確認正確 | 中：號碼失效會難以登入與復原 |
| 裝置鎖 | 是否有設 | 中：拿到裝置即可操作 |
| 群組邀請 | 隱私設定是否為「所有人」可加 | 低：易被拉入釣魚群 |

- **清單**：只在終端機提交，每項列現況、等級與建議，偵測不到列「未確認」；總評取不合格項的最高等級。🚫 不列手機號、IP、裝置明細與聊天內容
- **改善與收尾**：改善由使用者決定；為建置而登入的 Telegram Web，用完提醒使用者登出

## 拒寫設定

其他步驟都完成後才建議，不設不影響結案；AI 說明作用與副作用一次，由使用者決定，🚫 不提前寫入。

- **內容**：在 AI 工具的權限設定（如 Claude Code 祕書目錄 `.claude/settings.json` 的 `permissions.deny`）拒寫 `access.json`、`.env`、`settings.json`、本 skill 與 `internal.md`、`data/internal/`、祕書目錄的 `AGENTS.md`／`CLAUDE.md`
- **作用**：SKILL.md〈不變式〉只是軟限制，這層由工具擋下；不設時只靠軟限制與權限確認
- **副作用**：祕書 session 內的 `/telegram:access`（配對、`group add`、`set`）與建檔寫入會一併被擋，日後要改須暫時移除對應規則並重開 session
- **提早設的後果**：擋住配對、群組授權與 `internal.md` 建檔，故放最後

## 排查

| 現象 | 優先檢查 |
|---|---|
| bot 不回應 | session 有無帶 `--channels`；是否持有 poller；官方 plugin 剛更新 |
| `CONNECTION_CLOSED` | `bun` 不在 PATH 或 `.env` 缺 token |
| `Skipping connection (recent failure cached ...)` | 15 分鐘內有 session 連線失敗；刪 `~/.claude/mcp-needs-auth-cache.json` 對應項或等過期 |
| 409 Conflict | 另有 poller 持有同一 token：殘留 server、其他 session、其他主機或容器 |
| 清掉重複 server 後仍收不到，`getWebhookInfo` 的 `pending_update_count` > 0 | 留下的 server 搶輸 poller 後不會自動恢復；在該 session `/mcp` reconnect telegram 或重開 session；reconnect 後舊 server 可能成孤兒（父行程為 PID 1）續搶 poller，須手動結束（查積壓用 `getWebhookInfo`，🚫 不用 `getUpdates`，會搶走訊息） |
| 工具可用但收不到 | 該 server 為 MCP-only（強化版鎖檔 `data/telegram.lock` 被他人持有） |
| 群組沒反應 | 群組未 `group add`、群組名單非空、訊息沒 @ 或沒命中觸發字 |
| 收不到未 @ 的群組訊息 | 隱私模式未關，或關了沒重新進群 |
| `chat not found` | bot 不在群組或 ID 錯（含升級超級群組後 ID 變更） |
| 附件沒進 session | 附件未在 caption 帶觸發字，且未在併入時窗（強化版 5 秒）內被觸發 |
