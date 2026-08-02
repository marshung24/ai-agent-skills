# 工作流程範本

多步驟、需追蹤進度、有驗證步驟。

結構：
```
skill-name/
├── SKILL.md
└── scripts/      # 可選
```

```markdown
---
name: mh-form-processing
description: 處理 PDF 表單填充。填寫或修改 PDF 表單時使用。
---

# 表單處理

## 流程

- [ ] 1. 分析表單結構
- [ ] 2. 建立欄位映射
- [ ] 3. 驗證映射
- [ ] 4. 填充表單
- [ ] 5. 驗證輸出

### 1. 分析表單

\`\`\`bash
python scripts/analyze_form.py input.pdf
\`\`\`
輸出：`fields.json`

### 2. 建立映射

編輯 `fields.json`，填入欄位值。

### 3. 驗證

\`\`\`bash
python scripts/validate_fields.py fields.json
\`\`\`
失敗 → 修正，返回步驟 2

### 4. 填充

\`\`\`bash
python scripts/fill_form.py input.pdf fields.json output.pdf
\`\`\`

### 5. 驗證輸出

\`\`\`bash
python scripts/verify_output.py output.pdf
\`\`\`
驗證通過才算完成。
```

## 重點

1. 提供可複製的清單讓 Claude 追蹤進度
2. 每個步驟明確說明輸入/輸出
3. 加入驗證步驟和失敗處理
4. 使用「如果...則...」處理分支情況
