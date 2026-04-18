# 條件分支範本

同一 skill 有多種情境，需先判斷再執行。

結構：
```
skill-name/
├── SKILL.md
└── scripts/      # 可選
```

```markdown
---
name: mh-document-editing
description: 編輯文件內容。當用戶需要建立新文件或修改現有文件時使用。一般文字討論不適用。
---

# 文件編輯

## 觸發守門

### 最小成立條件
使用者明確要求建立或編輯文件，且提供文件類型或路徑。

### 啟動條件
- 直接啟動：「建一個新的 docx」「修改 report.docx」
- 補問後啟動：「幫我弄一個文件」→ 補問文件類型與用途

### 不啟動
- 「這份文件寫得如何」→ 內容 review，不是編輯
- 「幫我看文件格式」→ 格式檢查，不是編輯

## 判斷流程

1. 建立新文件？ → 執行「建立流程」
2. 編輯現有文件？ → 執行「編輯流程」

---

## 建立流程

從零開始建立。

1. 使用 docx-js 建立文件結構
2. 填入內容
3. 匯出為 .docx

\`\`\`javascript
const doc = new Document();
// ...建立內容
\`\`\`

---

## 編輯流程

修改現有文件。

1. 解壓：`python scripts/unpack.py doc.docx unpacked/`
2. 修改 `unpacked/word/document.xml`
3. 驗證：`python scripts/validate.py unpacked/`
4. 打包：`python scripts/pack.py unpacked/ output.docx`
```

## 重點

1. **先守門再分流**：開頭先判斷是否符合 skill 啟動條件，不符合則不進入
2. 資訊不足時先補問，不自動假設
3. 確認啟動後，用判斷清單引導選擇正確流程
4. 每個流程用分隔線區隔
5. 說明每個流程的適用情況
6. 流程間可以共用腳本
