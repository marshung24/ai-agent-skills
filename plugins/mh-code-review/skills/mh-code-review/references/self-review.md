# 自我 Review 工作流程

## 適用情境

- RD 邊開發邊要求 AI 幫忙 review 當前修改
- 使用者要求看 local diff / staged diff / 某一批修改風險
- 使用者要求審核特定 commit 或 branch 的改動
- 使用者要求「幫我做自我 review」、「幫我看這次改動有沒有問題」

## 輸入來源

1. **使用者指定範圍**：只看指定的檔案或 diff 範圍
2. **未指定範圍**：同時蒐集 `git diff --cached`（staged）與 `git diff`（unstaged），合併為完整的本地變更
3. **特定 commit**：`git show <commit>` 或 `git diff <commit>~1 <commit>`
4. **特定 branch**：`git diff main...<branch>`（與主分支比較）
5. 若以上都空或無法取得 diff，回報「沒有可 review 的變更」
4. **同檔去重**：同一檔案同時出現在 staged/unstaged 時，以完整工作樹狀態整體理解，不重複回報同一風險
5. **大範圍變更**：若 diff 檔案數或行數過大，先告知使用者並建議縮小範圍（指定檔案或模組）
6. **補讀相依檔案**：diff 不足以判斷時，才讀取相關上下文

## 執行步驟

1. 依輸入來源規則取得變更 diff（指定範圍 or staged+unstaged）
2. 依 `review-framework.md`〈錨定決策範圍與完成判準〉固定審查對象、完成判準與審查範圍
3. 依審查優先序（行為回歸→安全→邏輯→架構→可維護→效能）掃描
4. 聚焦 🔴 高風險項目
5. 若無 🔴，掃描 🟡 中風險
6. 輸出 findings

## Checklist 適用性

自我 review 使用檢查清單時，以下項目可跳過：
- **PR 範圍**（改動與 PR description 一致、是否混入不相關改動、是否已 rebase）→ 僅適用 PR review
- **部署風險**中的「前後端同步部署」「revert 安全性」→ 通常在 PR review 階段才需確認
- **部署風險**中的「DB migration」「環境變數」→ 開發階段即可檢查，建議保留

## 輸出規範

- **語氣**：工程化、直接，可立即銜接修改
- **🟡 門檻**：見 `review-framework.md`〈兩種模式的門檻差異〉自我 review 欄；一律標示為非阻擋
- **配額**：需新增工作的 finding 一輪最多 3 項，見 `review-framework.md`〈一輪最多三項〉
- **🟢**：通常省略，除非特別值得一提
- **無問題時**：明確說「未發現 blocking issue」，可補充殘餘風險或測試缺口
- **行為**：只報告，不操作 git / gh

## Findings 轉工程建議

每個 finding 的必填欄位與缺漏處理，見 `review-framework.md`〈每個 finding 的最小證據〉。

好的 finding 範例：
```
🔴 `FIX-NOW` [src/Services/OrderService.php:142]
$order->delete() 直接硬刪除
- 觸發路徑：使用者於訂單列表刪除任一筆已產報表的訂單
- 可觀測後果：ReportService 查詢該 order 取得 null，報表頁 500
- 建議修正：改用 soft delete，或先確認無下游依賴
- 反向自證：若報表僅供當下檢視、訂單刪除後不再被引用，硬刪是對的
```

不好的 finding 範例：
```
🟡 這段程式碼可以更好  ← 太模糊，無法行動
```

---

## 輸出模板

```markdown
## Review 結果

### 審查錨定
審查對象：… ｜ 完成判準：…（來源：…）｜ 審查範圍：…

### 🔴 高風險
- 🔴 `FIX-NOW`／`BLOCK/RETURN` [檔案:行號] 問題描述
  - 觸發路徑：…
  - 可觀測後果：…
  - 建議修正：…
  - 反向自證：…

### 🟡 建議
- 🟡 `FIX-NOW`／`SCHEDULE` [檔案:行號] 問題描述
  - 觸發路徑：…
  - 可觀測後果：…
  - 建議修正：…
  - 反向自證：…

### Open questions
- 資訊不足無法確認的假設或疑慮（僅在有疑慮時列出）

### 殘餘風險 / 測試缺口
- 尚未驗證的風險或建議補充的測試

### ✅ 整體評估
簡短結論（若無問題，明確說「未發現 blocking issue」）
```

### 區塊使用規則

| 區塊 | 何時出現 |
|------|---------|
| 審查錨定 | 永遠出現（完成判準未知時寫明未知與採用的最低基準） |
| 🔴 高風險 | 有 blocking issue 時 |
| 🟡 建議 | 有非阻擋建議時 |
| Open questions | 有無法確認的假設時（可選） |
| 殘餘風險 / 測試缺口 | 有未覆蓋的風險時（可選） |
| ✅ 整體評估 | 永遠出現 |
