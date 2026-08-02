# PR Review 工作流程

## 適用情境

- 使用者要求 review 某個 GitHub PR
- 使用者要求查看 PR 的問題或品質
- 使用者要求幫忙輸出 review comments 或整體 review 結論

## 輸入來源

1. **PR metadata**：`gh pr view <PR>`（標題、描述、作者、base branch）
2. **PR diff**：`gh pr diff <PR>`（完整變更）
3. **本地上下文**：必要時讀取本地對應檔案補充理解
4. **已有 review**（可選）：`gh api repos/{owner}/{repo}/pulls/<PR>/comments` — 僅在使用者要求「避免重複評論」或「看已有人提過什麼」時才讀取，首輪 review 不需要

## 讀 PR 的順序

1. 先看 PR 標題與描述，理解改動意圖
2. 看 diff 的檔案清單，掌握影響範圍
3. 從高風險檔案開始讀（API 路由、認證、資料庫操作、金額計算）
4. 再看輔助檔案（設定、測試、文件）

### 大型 PR 策略

若 PR diff 超過 500 行或涉及 20+ 個檔案：
1. 先列出檔案清單，標註高風險檔案
2. 優先 review 高風險檔案（API、auth、DB、金額）
3. 告知使用者範圍偏大，建議分批 review 或聚焦特定模組
4. 避免一次讀入全部 diff 導致上下文溢出

## 執行步驟

1. `gh pr view <PR>` 讀取 PR 資訊
2. `gh pr diff <PR>` 讀取完整 diff
3. 必要時補讀本地對應檔案上下文
4. 依審查優先序 🔴🟡🟢 全面檢查
5. **輸出 findings 報告（預設止步於此）**
6. 使用者明確要求後，才代發行內留言或提交結論

## 預設先分析原則

- **預設行為**：分析並產出 findings 報告與建議文案
- **使用者明確要求後才執行**：
  - 代發 inline review comments（`gh api`）
  - 提交正式 review（`gh pr review`）
- 理由：避免未經確認就在 PR 上留下公開留言

## 結論判定

| 條件 | Review 結論 |
|------|------------|
| 有 🔴 findings | `REQUEST_CHANGES` |
| 僅 🟡，但數量多或嚴重度接近 🔴 | `REQUEST_CHANGES` |
| 僅 🟡，數量少且非關鍵 | `COMMENT` |
| 僅 🟢 或無問題 | `APPROVE` |

**REQUEST_CHANGES 應主要保留給**：行為回歸、安全漏洞、明確邏輯缺陷、高機率造成維運事故的問題。

## 輸出規範

- 完整 🔴🟡🟢 檢查，🟡 門檻較保守（避免偏好升格為阻擋）
- 明確區分 blocking findings 與 non-blocking suggestions
- 語氣適合公開留言（對事不對人、肯定優點再提改進）
- 不確定是否為問題時，用「確認：...？」提問而非直接斷言
- 以本次 PR 範圍為主，不擴張到無關模組
- 附帶建議的 review decision + 理由

---

## Findings 報告模板

```markdown
## Blocking findings
- 🔴 [檔案:行號] 問題描述 — 原因 — 建議修正

## Non-blocking suggestions
- 🟡 [檔案:行號] 問題描述 — 建議
- 🟢 [檔案:行號] 問題描述 — 可選優化

## Review decision
建議 APPROVE / REQUEST_CHANGES / COMMENT

理由說明
```

> 若無任何 finding，直接輸出 `APPROVE` + 理由即可。

---

## GitHub 操作參考

使用者明確要求代發 review 時，依以下操作。

### 何時用 Inline Comment vs 總結

| 情況 | 使用方式 |
|------|---------|
| 特定程式碼行有問題（🔴🟡） | Inline comment（標註具體行號） |
| 架構層或多檔案交互問題，無法對應單一行號 | 放在 review summary，不硬發 inline comment |
| 整體架構或設計建議 | 總結 comment |
| 只有 🟢 或無問題 | 直接提交 APPROVE，不需逐條留言 |

### 發送行內留言（Inline Review Comment）

```bash
# 取得 PR 最新 commit（API 必填參數）
COMMIT=$(gh pr view <PR_NUMBER> --json headRefOid --jq '.headRefOid')

# 發送行內留言
gh api repos/{owner}/{repo}/pulls/<PR_NUMBER>/comments \
  -f body="🔴 **問題描述**

原因說明

**建議修正**：
具體修正方案" \
  -f path="src/Services/OrderService.php" \
  -f commit_id="$COMMIT" \
  -F line=42 \
  -f side="RIGHT"
```

多行留言（問題橫跨多行時）：加上 `-F start_line` 指定起始行

```bash
gh api repos/{owner}/{repo}/pulls/<PR_NUMBER>/comments \
  -f body="留言內容" \
  -f path="src/Services/OrderService.php" \
  -f commit_id="$COMMIT" \
  -F start_line=38 \
  -F line=42 \
  -f side="RIGHT"
```

**注意事項**：
- `-F line=42` 用大寫 `-F` 傳遞數字，小寫 `-f` 會導致 API 錯誤
- `path` 是相對於 repo 根目錄的檔案路徑
- `side` 通常用 `RIGHT`（修改後的版本）
- 多行留言：`start_line` 為起始行、`line` 為結束行

**代發邊界規則**：
- 只有能精準對應到單一檔案/行號的 finding 才發 inline comment
- 架構層或多檔案交互問題 → 放在 review summary，不硬發 inline comment
- 若 finding 缺少對應行號，不要猜測行號硬發

### 提交審查結論

```bash
# 核准
gh pr review <PR_NUMBER> --approve --body "LGTM — 未發現 blocking issue。"

# 要求修改
gh pr review <PR_NUMBER> --request-changes --body "發現 N 個需修正的問題，已在 inline comment 中標註。

重點：
- [問題 1 摘要]
- [問題 2 摘要]

修正後請重新請求 review。"

# 僅留言（不阻擋合併）
gh pr review <PR_NUMBER> --comment --body "整體可合併，有 N 個建議供參考，已在 inline comment 中標註。"
```

### 對話留言（非 Review Comment）

```bash
gh pr comment <PR_NUMBER> --body "留言內容"
```

> `gh pr comment` 是對話留言，不是 review comment。Review comment 需用 `gh api`。

### 禁止事項

- **不直接 merge PR**：review 後由作者或維護者合併
- **不主動 review**：除非使用者要求
- **不刪除已有的 review comment**
