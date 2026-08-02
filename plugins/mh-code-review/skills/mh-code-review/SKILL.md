---
name: mh-code-review
description: 程式碼審查（code review / 代碼審核 / 程式審核）。當用戶明確要求 review/審核程式碼改動，且審查對象是目前改動、未 commit 的內容、staged/unstaged diff、特定檔案、commit、branch，或已提供 GitHub pull request 編號/URL 時使用。支援自我 review 與 PR review；一般寫法討論、除錯、設計建議不適用。
---

# Code Review

## 觸發守門

本 skill 需要「review 意圖 + 審查對象」才啟動：

**啟動條件**（符合任一，每條都滿足意圖 + 對象）：
- review / 審核 / 代碼審查 / 程式審查 + 明確審查對象（diff / 檔案 / commit / branch / PR）
- 審核/review + 未 commit 的內容（未提交、還沒 commit、local 改動等）
- review / 審核 / 檢查風險 + staged diff / unstaged / local diff
- 審核/review + 特定 commit 或 branch
- PR 動作詞（approve / request changes 等）+ PR 編號或 URL
- GitHub / GitLab PR URL

**缺對象時**：補問審查對象，不自動假設

**不啟動**（走一般程式討論）：
- 泛泛的「看一下」「這樣可以嗎」「好不好」，未搭配 review / diff / PR 詞彙
- 含 PR 關鍵字但動詞是查資訊（什麼時候 merge、列出 PR）而非審查
- 除錯、解釋程式、設計建議

---

## 判斷流程

```
觸發守門 → 判斷流程 → 載入規則
```

1. 使用者意圖涉及 PR review（提及 PR、pull request、GitHub review、approve、request changes 等）？
   - 已提供 PR 編號或 URL → 執行 **PR Review**
   - 未提供 → 詢問使用者補充 PR 編號或 URL，不 fallback 到自我 review
2. 使用者要求審核特定 commit 或 branch → 執行 **自我 Review**（以 `git show` 或 `git diff main...<branch>` 取得 diff）
3. 無 PR 相關意圖 → 執行 **自我 Review**
4. 無法判斷 → 詢問使用者
5. 若使用者在同一對話中承接前一步 findings（如「幫我整理成 comments」），沿用既有 findings，不重跑完整 review

## 載入規則

- 每次 review 都讀 `references/review-framework.md`（審查框架 + 檢查清單）
- 自我 review：**先執行 `git diff`** 確認有變更，無變更時直接回報、不載入 references → 有變更時讀 `references/self-review.md`
- PR review：讀 `references/pr-review.md`（workflow + 輸出模板 + gh API 操作，全部合併於此）
- 自我 review 不讀 pr-review 相關，反之亦然

---

## 角色邊界

**負責**：辨識 review 情境、選擇正確的輸入來源與輸出形式、以 finding 為主體回報、依風險優先序審查，沒問題就 LGTM 不硬找問題

**不負責**：直接 merge PR、未經要求主動 review、用風格 nitpick 取代風險導向審查

## 審查核心（摘要）

先看行為回歸 / 安全 / 邏輯（🔴），再看架構 / 維護性 / 效能（🟡🟢）。PR review 的阻擋門檻要保守。

> 完整審查框架、嚴重度定義、檢查清單：[references/review-framework.md](references/review-framework.md)

---

## 自我 Review

適用：RD 開發過程中即時檢查當前修改。聚焦 🔴，🟡 門檻寬鬆，只報告不操作 git/gh。

> 完整流程、輸入規則、輸出模板：[references/self-review.md](references/self-review.md)

---

## PR Review

適用：審查 GitHub Pull Request。完整 🔴🟡🟢 檢查，預設止步於 findings 報告，代發需使用者明確要求。

> 完整流程、結論判定、輸出模板、gh API 操作：[references/pr-review.md](references/pr-review.md)
