# docs/

本 repo 的設計與維護文件。使用說明在根目錄 [README.md](../README.md)，安裝工具的行為說明在 [tools/README.md](../tools/README.md)。

## 文件

| 文件 | 內容 | 什麼時候讀 |
|------|------|-----------|
| [Agent Skills 開發目標指南](./skills-development-guide.md) | 願景、設計原則、觸發限制、分階段路線圖 | 要寫或改一個 skill 時 |
| [Marketplace 設定指南](./marketplace-guide.md) | manifest 結構、四家 agent 的機制差異、欄位取捨、下架與遷移 | 要改 `.claude-plugin/marketplace.json`，或新增 skill 要發佈時 |
| [安裝工具說明](../tools/README.md) | 互動矩陣、環境變數、狀態碼、遺留偵測與實測行為 | 要改安裝工具、或使用者回報安裝失敗要排查時 |

## 文件分工

```
README.md              使用者：有哪些 skill／template、怎麼用
├── tools/README.md    使用者／維護者：安裝工具怎麼運作、環境變數、狀態碼
└── docs/
    ├── skills-development-guide.md   維護者：skill 本身怎麼設計
    └── marketplace-guide.md          維護者：怎麼把 skill 發佈出去
```

判準是**受眾**與**回答的問題**：

- 根 `README.md` 只回答「我要怎麼用」（兩類交付物：skills 與 templates），不解釋為什麼這樣設計
- `tools/README.md` 回答「這個工具做了什麼、為什麼這樣做」，包含 DECISION 註記
- `docs/` 回答「這個 repo 的規格與方法論」，與具體工具實作解耦——換掉 `skills.sh` 也不影響其內容

## 慣例

- 文件開頭標註版本與更新日期（`> **版本**：x.y.z｜**更新日期**：YYYY-MM-DD`）
- 所有關於各家 CLI 行為的敘述皆為**實測所得**，並在文中註明；CLI 升版需重驗
- 記錄取捨時用 `DECISION` 區塊寫明「選 A 捨 B 的理由」，避免後人「優化回去」
