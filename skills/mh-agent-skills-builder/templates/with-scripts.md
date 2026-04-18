# 帶腳本範本

需要確定性操作、複雜邏輯封裝成腳本。

結構：
```
skill-name/
├── SKILL.md
└── scripts/
    ├── analyze.py
    ├── validate.py
    └── process.py
```

```markdown
---
name: mh-document-processing
description: 使用腳本處理文件。批次分析或轉換文件時使用。
---

# 文件處理

## 腳本

| 腳本 | 用途 |
|------|------|
| `scripts/analyze.py <input>` | 分析結構 |
| `scripts/validate.py <json>` | 驗證結果 |
| `scripts/process.py <in> <out>` | 執行轉換 |

## 流程

1. 分析：`python scripts/analyze.py doc.pdf > result.json`
2. 驗證：`python scripts/validate.py result.json`（失敗則修正重試）
3. 處理：`python scripts/process.py result.json output.pdf`

## 輸出格式

analyze.py：
\`\`\`json
{"fields": [...], "pages": 3, "type": "form"}
\`\`\`
```

## 腳本原則

- **解決問題，不推卸**：腳本應處理錯誤，不是丟給 Claude
- **明確輸出格式**：在 SKILL.md 說明腳本輸出結構
- **詳細錯誤訊息**：幫助 Claude 理解如何修正
