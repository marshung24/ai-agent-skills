---
name: mh-agent-skills-builder
description: 協助建立、修改和優化 Agent Skills。當用戶需要建立新的 skill、修改現有 skill、詢問 skill 結構、SKILL.md 格式、YAML 前置資料寫法、description 設計、觸發守門設計、或漸進式披露寫法時使用。
---

# Agent Skills 建構指令

## 建立新 Skill

1. 建目錄：`~/.claude/skills/mh-<name>/`（用戶級）或 `.claude/skills/mh-<name>/`（專案級）
2. 建 `SKILL.md`
3. 建 `README.md`（必須包含版權與來源資訊，格式見下方）

### README.md 必要內容

每個 skill 的 `README.md` 必須包含以下 License 區塊：

```markdown
## License

MIT License - Copyright (c) <year> Mars.Hung

Source: [https://github.com/marshung24/ai-agent-skills](https://github.com/marshung24/ai-agent-skills)

Author: Mars.Hung (tfaredxj@gmail.com)
```

`<year>` 替換為建立年份。

## YAML 規範

必填：
- `name`：最多 64 字，小寫+數字+連字號，必須 `mh-` 前綴，須與目錄名一致，禁用 "anthropic"/"claude"
- `description`：最多 1024 字，第三人稱，說明功能+使用時機

選用：
- `license`：授權說明（如 `Complete terms in LICENSE.txt`）
- `metadata`：任意鍵值對（作者、版本等，如 `author: Mars.Hung`）
- `compatibility`：最多 500 字，環境需求（產品、套件、網路）
- `allowed-tools`：預核准工具清單（實驗性，如 `Bash(git:*) Read`）

## Description 設計

三段式結構：`[核心功能]。當用戶[高信號使用時機]時使用。[能力邊界/不適用情境]。`

核心原則：
- description 負責正向匹配，SKILL.md 守門負責負向排除與補問
- 只放高信號場景，不要把所有近義詞、動作詞塞進去
- description 的能力範圍必須和實際 workflow/工具能力一致

> 反模式清單、「適合寫/不適合寫」對照表、設計步驟展開：[BEST-PRACTICES.md](BEST-PRACTICES.md)

## 觸發守門設計

**何時需要守門**：功能詞與日常用語重疊、有多模式分流、操作有副作用（寫入外部系統）。功能單一且不會與日常對話混淆的 skill（如 PDF 提取、格式轉換）可以不設守門。

三層啟動分類：

| 層級 | 條件 | 行為 |
|------|------|------|
| 直接啟動 | 意圖明確 + 對象明確 | 進入 skill |
| 補問後啟動 | 有意圖但缺對象 | 補問，不自動假設 |
| 不啟動 | 泛泛討論 / 不符合 skill 範疇 | 走一般對話 |

設計步驟：1. 定義最小成立條件 → 2. 列高信號觸發句 → 3. 列應排除的相似句 → 4. 收斂成 description + 守門規則

需要守門的 skill，建議在所選範本開頭加入守門區塊（見[範本](#範本)說明）。

> 啟動條件設計展開版、常見誤觸發案例：[BEST-PRACTICES.md](BEST-PRACTICES.md)

## 目錄結構

簡單：`SKILL.md` 單檔

複雜（標準目錄名依 [Agent Skills 規格](https://agentskills.io/specification)）：
- `SKILL.md` - 觸發時載入（建議 < 500 行且 < ~5000 tokens）
- `references/` - 參考文件（按需載入）
- `scripts/` - 可執行腳本
- `assets/` - 範本、圖片、資料檔

## SKILL.md 的角色與 Token 經濟性

- SKILL.md 是路由器（守門 → 分流 → 載入規則），不是知識庫
- 與 references 不重複內容（單一事實來源）
- 連結可作為導航索引，但載入條件要用明確文字寫出
- SKILL.md 超過 100 行時，檢查是否有內容該下沉到 references

> Token 經濟性方法論、A/B 對照範例、檢查清單：[BEST-PRACTICES.md](BEST-PRACTICES.md)

## 範本

根據情境選擇範本：

| 類型 | 適用情境 | 範本 |
|------|----------|------|
| 基礎 | 內容簡單，一個檔案能說清楚 | [basic.md](templates/basic.md) |
| 漸進式披露 | 參考資料多，但每次任務只需其中一部分 | [progressive-disclosure.md](templates/progressive-disclosure.md) |
| 工作流程 | 任務有固定步驟順序，需追蹤進度並驗證 | [workflow.md](templates/workflow.md) |
| 工具整合 | 封裝特定 API 或工具的使用方式 | [tool-integration.md](templates/tool-integration.md) |
| 帶腳本 | 某些操作需精確執行，不能讓 AI 自由發揮 | [with-scripts.md](templates/with-scripts.md) |
| 條件分支 | 同一 skill 要處理多種不同情境 | [conditional.md](templates/conditional.md) |

功能詞與日常用語重疊、有多模式分流、或操作有副作用的 skill，建議在所選範本開頭加入守門區塊：

```markdown
## 觸發守門

### 最小成立條件
[缺什麼就不該啟動]

### 啟動條件
- 直接啟動：[意圖 + 對象都明確]
- 補問後啟動：[有意圖但缺對象]

### 不啟動
- [相似但不屬於 skill 的情境]

### 前置驗證（選用）
[在載入 references 前，先做便宜檢查]
```

## 撰寫規則

詳見 [BEST-PRACTICES.md](BEST-PRACTICES.md)

核心：
- SKILL.md 是路由器，詳細內容放 references
- 與 references 不重複（單一事實來源）
- 參考檔案保持一級深度（不嵌套）
- 術語一致
- 交付前跑 BEST-PRACTICES.md 的邊界一致性 checklist

## 除錯

| 症狀 | 檢查方向 |
|------|---------|
| 沒被觸發 | description 是否缺高信號場景或對象 |
| 常誤觸發 | description 是否過寬、是否缺負面邊界、是否把低信號動作詞當主關鍵字 |
| 進 skill 後走錯流程 | SKILL.md 是否缺守門與補問邏輯 |
