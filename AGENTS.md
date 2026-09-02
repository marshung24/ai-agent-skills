# ai-agent-skills — 專案 Agent 指令

## 專案資訊

- **專案定位**：AI Agent Skills 集合，同時是 Claude Code／Codex 共用的 plugin marketplace（`marshung24`）；內容是 Markdown 與 Bash，無應用程式碼
- **工作入口**：
  - 要知道 repo 交付什麼、使用者怎麼裝 → `README.md`
  - 不確定該讀哪份維護文件 → `docs/README.md`（文件索引，每份都標了「什麼時候讀」）
  - 要改 `.claude-plugin/marketplace.json`、新增或下架 skill → `docs/marketplace-guide.md`
  - 要改安裝工具的行為、或安裝失敗要排查 → `tools/README.md`
  - 要寫或改某個 `SKILL.md` 本身 → `docs/skills-development-guide.md`
- **主分支**：`main`
- **測試指令**：不適用：repo 內無測試框架也無測試檔，`Makefile` 只有 `status`／`install`／`update`／`remove`／`validate`／`help` 六個目標，且無 `.github/workflows`
- **其他必跑檢查**：`make validate`（離線驗證 manifest 欄位、每個 plugin 有 `skills/<name>/SKILL.md`、`source` 指向存在的目錄、skill↔entry 雙向對應，並跑 `claude plugin validate --strict` 與各 plugin 的 `agy plugin validate`）；改到 `tools/*.sh` 或任何 `scripts/*.sh` 時另跑 `bash -n <檔>`
- **產生物**：不適用：`.claude-plugin/marketplace.json` 是手寫 SSOT，repo 內無 codegen、vendor 快照或 lock 檔
- **需授權的命令**：`make install`／`make update`／`make remove`（會改動本機各 agent 的 skills 目錄與 marketplace 註冊）；`plugins/mh-external-advisor/.../scripts/ask-*.sh`（以免互動核可旗標呼叫外部 AI CLI，prompt 內容會外送第三方並消耗訂閱額度）
- **PR 規範**：repo 內無 PR 指南——Body 至少含 Summary、變更項目、Test Plan（指令與結果）

## 工作規範

- 只改任務範圍內的內容，保留無關的既有變更；沿用 repo 既有架構與慣例。
- 🚫 不在「主分支」上作業，一律開 feature／fix 分支。
- 🚫 未經本次對話授權，不得 push、開或合 PR、推 tag、執行〈需授權的命令〉。改寫已推送的分支只能用 `--force-with-lease`。
- 🚫 不得手改〈產生物〉：改來源、再生、與來源同一個 commit。
- 🚫 不得提交憑證、token、私鑰或個資。
- Commit 用 Conventional Commits `type(scope): 中文摘要`（feat／fix／docs／refactor／test／chore），依變更目的拆，只含本案內容；🚫 不寫 AI 署名或 `Co-Authored-By`。
- 發現 repo 的 README 或其指向文件不符漸進式披露（指路只丟路徑沒說何時該讀、細節塞在第一層、同一命題在多份文件各寫一份）時，**向使用者提出建議**；🚫 不自行改寫，那超出任務範圍。
- 任何時點改了東西，重跑受影響的檢查。

## 結案流程

**啟動條件**：使用者要求結案、交付或發 PR。一般修改、調查、唯讀諮詢不觸發，也不自行 commit／push／發 PR。

1. **確認完成**：對照使用者本次要求或指定的 Issue AC 逐項核對，兩者皆無則以本次對話的明確要求為準，🚫 不擴張範圍或補建 AC。確認人在本案分支，diff 與未追蹤檔只含本案改動。
2. **跑測試與檢查**：「測試指令」與適用的「其他必跑檢查」全數成功才算過。🚫 無測試不等於通過——回報查證依據與未驗證風險，🚫 不代換命令。
3. **自我 review 並修正**：審本案全部改動（staged／unstaged／untracked）——正確性、安全性、資料風險、需求不符、效能退化、可維護性。有修正就摘要，並重跑受影響的檢查。
4. **顧問 review 並修正**：交給使用者指定的「外部顧問」。它自行讀檔，只給**審查範圍**與**副作用邊界**（例：「相對 `origin/<主分支>` 的本次改動，唯讀」）；🚫 不備 diff、不給檢查清單、不預設結論、不限定角度與方法——要的是它的觀點。意見逐項判斷，🚫 不照單全收；有修正就摘要，並重跑受影響的檢查。未指定顧問先問，使用者明示略過才可繼續並在 PR 註記，🚫 不得以自我 review 充當。
5. **提交並同步主線**：先 commit 到工作樹乾淨，`git fetch` 後 rebase 至最新「主分支」，fetch 失敗即停。衝突解完重看 diff、重跑受影響的檢查。主線帶進本案相依範圍的改動時（無衝突也算），重做第 3 步，必要時連第 4 步。
6. **Push 與發 PR**：對最終 HEAD 重跑測試與檢查、工作樹乾淨才 push。PR base 為「主分支」，標題用 Conventional Commits，Body 依「PR 規範」；建立後核對 base／head、標題、Body、連結。
7. **worktree 收尾**：只處理本次自建的 worktree。先查 staged／unstaged／untracked 與未 push commit，有值得保留的先問使用者；分支已推、PR 已開才移除。

> 每案結案都要發 PR；🚫 RD 不自行合併，上線前由管理者合併。
