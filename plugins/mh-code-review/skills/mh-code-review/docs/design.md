# mh-code-review — 設計文件

> 記錄此 Skill 的設計背景、架構決策與驗收標準，供後續維護與擴充參考。

## 目錄

- [mh-code-review — 設計文件](#mh-code-review--設計文件)
  - [目錄](#目錄)
  - [背景與動機](#背景與動機)
  - [設計決策](#設計決策)
  - [架構概覽](#架構概覽)
    - [檔案結構](#檔案結構)
    - [各檔案職責與載入時機](#各檔案職責與載入時機)
    - [漸進式披露設計](#漸進式披露設計)
  - [雙模式設計](#雙模式設計)
    - [模式路由](#模式路由)
    - [模式比較](#模式比較)
    - [安全門檻](#安全門檻)
  - [與外部資源的關係](#與外部資源的關係)
    - [從原始指南吸收的內容](#從原始指南吸收的內容)
    - [刻意不搬進 SKILL.md 的內容](#刻意不搬進-skillmd-的內容)
  - [驗收標準](#驗收標準)
  - [待決事項](#待決事項)

---

## 背景與動機

原始來源：`AI助手-github-CodeReview指南.md`（個人參考文件），偏向 GitHub PR review 的 `gh` CLI 操作手冊。

團隊需求超出原始文件範圍：

1. **RD 自我 Review**：開發過程中即時檢查，快速回饋，可直接銜接修改
2. **GitHub PR Review**：正式的 Pull Request 審查，完整報告，可代發留言

兩者共用同一套「風險優先」審查核心，但輸入來源、輸出形式、嚴重度門檻不同，不能只用一份 checklist 硬套。

---

## 設計決策

| # | 決策 | 理由 |
|---|------|------|
| 1 | 名稱用 `mh-code-review`，不綁 GitHub | 需求覆蓋自我 review + PR review，不僅限 GitHub |
| 2 | 審查框架抽到 `review-framework.md` | 避免 SKILL.md 觸發時上下文過重 |
| 3 | 同一套風險框架 + 兩個 workflow | 不做兩個獨立 skill，共用核心、分流執行 |
| 4 | 自我 review 預設同時蒐集 staged + unstaged | 避免只取其一導致漏看另一半改動；使用者指定範圍時才縮限 |
| 5 | PR review 比自我 review 更克制 | REQUEST_CHANGES 門檻更高，避免偏好升格為阻擋 |
| 6 | 借力現有 `gh` CLI | 不重複寫工具手冊，skill 負責審查判準 |
| 7 | 預設先分析、後執行 | 代發 GitHub comments/review 必須由使用者明確要求 |
| 8 | 輸出模板合併進各 workflow 檔案 | 減少 Read 次數，模板本就分自我/PR 兩種 |
| 9 | SKILL.md 瘦身為純路由器 | 消除與 references 的重複內容，單一事實來源 |

---

## 架構概覽

### 檔案結構

```
.claude/skills/mh-code-review/
├── SKILL.md                          # 純路由器：判斷流程、載入規則、角色邊界、審查核心摘要
├── references/
│   ├── review-framework.md           # 共用：審查框架 + 檢查清單 + 術語表
│   ├── self-review.md                # 自我 review：workflow + 輸出模板
│   └── pr-review.md                  # PR review：workflow + 輸出模板 + gh API 操作
└── docs/
    └── design.md                     # 本文件
```

### 各檔案職責與載入時機

| 檔案 | 載入時機 | 內容摘要 |
|------|---------|---------|
| `SKILL.md` | 觸發時 | 模式路由、載入規則、角色邊界、審查核心一行摘要 |
| `review-framework.md` | 每次 review | 審查原則、優先序、嚴重度、blocking 判準、完整檢查清單、術語表 |
| `self-review.md` | 自我 review 時 | 輸入來源、執行步驟、findings 範例、輸出模板 |
| `pr-review.md` | PR review 時 | 讀 PR 順序、結論判定、輸出模板、gh API 操作、代發邊界規則 |

### 漸進式披露設計

```
第一層（SKILL.md，觸發時載入）：
  → 純路由 + 載入規則（不含重複的表格和步驟）

第二層（references/，按載入規則讀取）：
  → review-framework.md（每次）+ 1 個 workflow 檔案（依模式）
  → 每次 review 只需 2 次 Read
```

---

## 雙模式設計

### 模式路由

```
觸發守門（「review 意圖 + 審查對象」缺一不可）：
  啟動：review/審核 + 對象（diff/檔案/commit/branch/PR/未 commit 內容）
  不啟動：泛泛討論、除錯、設計建議、非審查的 PR 查詢
  缺對象：補問，不自動假設

判斷流程：
  1. 意圖涉及 PR review（PR、approve、request changes 等）
     a. 已提供 PR 編號或 URL → PR Review 模式
     b. 未提供 → 詢問使用者補充，不 fallback 到自我 review
  2. 要求審核 commit / branch → 自我 Review 模式（git show / git diff main...<branch>）
  3. 無 PR 相關意圖 → 自我 Review 模式
  4. 無法判斷 → 詢問使用者
```

### 模式比較

| 面向 | RD 自我 Review | GitHub PR Review |
|------|---------------|-----------------|
| 審查範圍 | staged + unstaged、指定檔案、特定 commit、特定 branch | PR 完整 diff |
| 審查深度 | 聚焦 🔴，🟡 門檻寬鬆 | 完整 🔴🟡🟢，🟡 門檻保守 |
| 輸出格式 | 終端 findings，工程化語氣 | findings 報告 → 確認後代發留言 |
| 行為 | 只報告 | 預設只分析，代發需使用者要求 |

### 安全門檻

PR review 預設止步於 findings 報告，不自動代發 GitHub review/comment。理由：避免未經確認就在 PR 上留下公開留言。

---

## 與外部資源的關係

| 資源 | 關係 |
|------|------|
| 原始指南（mars-private-notes） | 個人參考，不動；新 skill 提取其中的審查哲學與判準 |
| `gh` CLI / GitHub MCP | skill 負責審查判準，GitHub 工具負責操作能力，不重複 |

### 從原始指南吸收的內容
- risk-first 審查哲學
- 嚴重度分級（🔴🟡🟢）
- review 類型定義（APPROVE / REQUEST_CHANGES / COMMENT）
- checklist 主軸

### 刻意不搬進 SKILL.md 的內容
- `gh api` 指令細節 → 放 `gh-review-api.md`
- 工具操作手冊式描述 → 精簡後放 references
- 禮貌話術或短語表 → 省略

---

## 驗收標準

Skill 至少應能正確處理以下場景：

| # | 使用者輸入 | 預期行為 |
|---|-----------|---------|
| 1 | 「幫我 review 目前的改動」 | 自我 review，同時蒐集 staged + unstaged diff，輸出 findings |
| 2 | 「幫我看 staged diff 有沒有高風險」 | 自我 review，聚焦 🔴（使用者指定 staged） |
| 3 | 「review PR #47」 | PR review，列 findings（不自動代發） |
| 4 | 「幫我整理成 GitHub review comments」（已在 PR review 對話中） | PR review，代發行內留言 |
| 5 | 「這個 PR 要 approve 還是 request changes」 | PR review，輸出結論與理由 |
| 6 | 「幫我 review 這個 pull request」（未附 PR 編號） | 詢問使用者補充 PR 編號/URL，不 fallback 到自我 review |
| 7 | working tree clean，無任何 diff | 自我 review，回報「沒有可 review 的本地變更」 |
| 8 | 給了無效 PR 編號（如 PR 不存在） | PR review，回報 gh 錯誤並提示確認編號 |

若 skill 無法自動切換 workflow 或在邊界情況下行為異常，表示設計不完整。

---

## 待決事項

| 項目 | 狀態 | 說明 |
|------|------|------|
| Slash command | 不做 | 純靠 description 自動觸發 + 觸發守門即可 |
| 團隊客製 checklist | 不做 | 目前通用 checklist 已足夠 |
| gh-review-api 多行留言 | 可補充 | 單行留言已滿足基本需求，有需要時再補 `start_line` + `line` 範例 |
| 自我 review 測試 | 不做 | 不另行驗證 |
| Token 節省重構 | ✅ 完成 | 方案 C：SKILL.md 瘦身 + 6 檔合併為 3 檔，消除重複，每次 review 只需 2 次 Read |
| 觸發守門 | ✅ 完成 | 「review 意圖 + 審查對象」雙條件守門，排除泛泛討論與非審查 PR 查詢 |
| commit / branch 審核 | ✅ 完成 | self-review.md 輸入來源已擴充支援 `git show <commit>` 與 `git diff main...<branch>` |
