# 工具整合範本

封裝 API 或外部工具。

結構：
```
skill-name/
├── SKILL.md
└── references/
    └── ADVANCED.md   # 進階功能（可選）
```

```markdown
---
name: mh-api-integration
description: 整合 XXX API 進行資料操作。呼叫 XXX 服務時使用。
---

# XXX API

## 基本用法

\`\`\`python
from xxx import Client
client = Client(api_key="...")
result = client.query("...")
\`\`\`

## 常用操作

查詢：`client.search(keyword="...", limit=10)`

建立：`client.create(name="...", data={...})`

## 進階功能

批次操作、webhook → [references/ADVANCED.md](references/ADVANCED.md)

## 錯誤處理

- 401 → 檢查 API key
- 429 → 等待後重試
```

## 重點

1. 快速開始放最常用的範例
2. 常用操作分類列出
3. 進階功能用連結指向獨立檔案
4. 錯誤處理用表格呈現