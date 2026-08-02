# 漸進式披露範本

參考資料多，但每次任務只需其中一部分。重點是用明確載入規則控制讀取，不是靠連結暗示。

結構：
```
skill-name/
├── SKILL.md        # 守門 + 分流 + 載入規則（觸發時載入，< 500 行 / ~5000 tokens）
├── references/     # 詳細內容（依載入規則讀取）
└── assets/         # 範本、圖片、資料檔（按需載入）
```

> 拆檔不一定省 token。3 個 50 行小檔不如 1 個 150 行合併檔 — 每次 Read 都有工具 overhead。依實際讀取路徑合併 references，不是純主題切分。

## SKILL.md

```markdown
---
name: mh-data-analysis
description: 分析資料並產生報告。當用戶查詢財務、銷售或產品資料時使用。一般資料庫操作或非分析型查詢不適用。
---

# 資料分析

## 載入規則

先判斷任務類型，不要預設讀所有 references：
- 財務相關（收入、支出、請款、ARR）→ 讀 [references/finance.md](references/finance.md)
- 銷售相關（機會、管道、市場、行銷）→ 讀 [references/sales.md](references/sales.md)
- 產品相關（API 使用、需求規畫）→ 讀 [references/product.md](references/product.md)
- 無法判斷類型 → 先詢問使用者

## 基本用法

\`\`\`sql
SELECT * FROM sales.opportunities LIMIT 10
\`\`\`
```

## 子檔案

開頭加目錄，讓 AI 知道完整範圍：

```markdown
# 財務資料

## 目錄
- 收入表
- ARR 計算

## 收入表

表名：`finance.revenue`

| 欄位 | 類型 | 說明 |
|------|------|------|
| date | DATE | 交易日期 |
| amount | DECIMAL | 金額 |
```

## 重點

1. **載入規則用明確文字寫**，不只放連結。連結是索引，載入條件是指令
2. 加入前置檢查（先判斷輸入種類、先確認是否有資料），避免空跑
3. references 依讀取路徑合併，不是純主題切分
4. 子檔案開頭加目錄，讓 AI 知道完整範圍
5. 使用相對路徑連結 `[text](path/file.md)`
