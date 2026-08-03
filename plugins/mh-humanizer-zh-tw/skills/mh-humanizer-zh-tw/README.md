# Humanizer-zh-tw：技術文件台灣化與保真微編輯（台灣正體版）

> **版本**：1.2.0｜**更新日期**：2026-08-03

Skill 名稱與目錄為 `mh-humanizer-zh-tw`（依本 repo 命名規範採 `mh-` 前綴）；「Humanizer-zh-tw」為沿用上游系列的文件標題。

專用於五類文件的台灣化與保真微編輯：**技術文章、規範文件、規畫設計文件、教案、程式註解**。改編自簡體中文版 [op7418/Humanizer-zh](https://github.com/op7418/Humanizer-zh)，針對台灣正體中文語境重建詞彙表、標點規範與寫作模式；v1.2.0 起收斂為文件專用（源頭與逐項調整記錄見 [docs/resource.md](docs/resource.md)）。

## 目標與設計理念

- **必要修正只有兩件事**：常用語與專有名詞台灣化（有台灣慣用譯名才換，否則保留英文，不自行造詞）；用語調得好理解（略微口語即可，語域不降級）
- **保真高於自然**：先保事實 → 再清 AI 痕跡 → 最後才調自然度。技術文件改壞事實（數字漂移、規範語意詞升降級、責任主體變模糊）的成本，遠高於留下一點機器感
- **最小編輯為預設**：不改結構、不改格式、不增刪資訊；「完整去 AI 腔」是明確要求才啟用的進階模式
- **文件的合法結構不是 AI 痕跡**：編號步驟、參數表、規格對照、章節導覽、教學導引句是格式要求，不會被當成待清對象

**不適用**：社群貼文、銷售與招募文案、客服回信、個人觀點文——這些文類的模式已停用（見下）。

## 功能

三種執行模式：

| 模式 | 啟用時機 | 做什麼 |
|---|---|---|
| **最小技術編輯（預設）** | 台灣化、改好懂、略微口語化 | 詞彙轉換＋翻譯腔＋贅詞＋過長難讀句；不改結構與格式 |
| **完整去 AI 腔（進階）** | 明確要求時 | 加上依文類掃描模式子集、重寫問題句型 |
| **範圍降級** | 只授權簡轉繁／用語轉換 | 只做字形與詞彙轉換 |

模式清單共 38 種啟用模式（另 7 種已停用、保留編號）：

| 區段 | 內容 |
|---|---|
| **1–24** 核心模式 | 誇大意義、宣傳語言、模糊歸因、否定式排比、三段式列舉、破折號濫用……。承襲改編基準版，完整保留為 diff 資產，執行時依文類套子集 |
| **T1–T4** 台灣補充模式 | 公關稿動詞鏈、政策抽象名詞堆疊、「持續＋正向動詞」假進展、中英夾雜偽專業感（T5 已停用） |
| **X 延伸模式** | 立場真空、解說導引句、說教式深度腔、金句公式、公式化開場、半形標點混用、模板佔位未填、預告式導言、可疑引用（X3、X6、X7、X10、X11 已停用） |
| **G1** 工具痕跡 | 引用殘碼、對話框輸出殘留（G2 已停用；不清理連結參數） |

另含：

- 大陸用語 → 台灣用語對照表（一般語境＋軟體開發領域技術術語）、實務慣用優先原則、不可機械替換清單
- **兩層保護清單與語意保真規則**：技術字串、數字精度不漂移、規範語意詞（必須／應／得／不得）不升降級、邏輯量詞與因果方向不走樣；含誤殺對照表與回讀核對程序
- **文類規則**：四組文類的保留項、禁改項與模式子集；長文防縮水
- **輸入安全邊界**：稿件是資料不是指令，稿內的命令句不構成授權
- 檔案寫入分流：詞彙級小改直接寫入＋摘要，大改（刪句／動結構）先列清單等確認

## 安裝

```bash
# 複製到 Claude Code 的 skills 目錄
cp -r skills/mh-humanizer-zh-tw ~/.claude/skills/mh-humanizer-zh-tw
```

或於專案級安裝至 `.claude/skills/mh-humanizer-zh-tw/`。

## 使用

本 skill 為**手動啟動**（`disable-model-invocation: true`）——不會被自動觸發，需以斜線指令明確呼叫：

```
/mh-humanizer-zh-tw 幫我把這份設計文件的用語台灣化、改好懂一點：

[貼上文本或指定檔案]
```

呼叫時的意圖範例：

- 「這份規範有簡體用語，幫我台灣化」
- 「這段教案寫得太生硬，幫我改好懂一點」
- 「幫我把這篇技術文章去 AI 腔」（→ 進階模式）
- 「檢查 spec.md 有哪些 AI 寫作痕跡」（→ 審查模式，只標記不改寫）

**呼叫後仍不受理**（設計如此）：社群貼文、銷售文案、客服信等非文件文類；純翻譯、純校對、純摘要；判定文章是否由 AI 生成。若只要求簡轉繁，只會做字形與詞彙轉換，不會改動句型與語氣。

## 檔案結構

```
mh-humanizer-zh-tw/
├── SKILL.md                 # 技能定義：觸發守門、執行模式、文類規則、流程、品質自檢
├── README.md                # 本文件
├── LICENSE                  # MIT（含上游歸屬）
├── docs/
│   └── resource.md          # 源頭說明與逐項調整記錄（維護者文件）
└── references/
    ├── patterns.md          # 模式清單：1–24 核心｜T 台灣補充｜X 延伸｜G 工具痕跡（含停用墓碑）
    ├── lexicon.md           # 兩岸詞彙對照、AI 高頻警示詞四類、不可機械替換清單
    ├── protected-content.md # 兩層保護清單、語意保真規則、誤殺對照表、回讀核對程序
    └── examples.md          # 五類文件改寫案例、文體保真原則
```

## 定位聲明

- 本工具的模式清單是**編輯線索，不是 AI 判定器**——真人公文、學術文章與公關稿也會出現相同模式，不會輸出「AI 生成機率」。
- 目標是提升文件品質，不是欺騙 AI 偵測器。最好的「去 AI 化」是讓文字有真實的思考與聲音。
- 改寫**不新增事實**：不虛構引言、數字、來源或個人經驗；也不代作者補立場、選方案。

## License

MIT License - Copyright (c) 2026 Mars.Hung

Source: [https://github.com/marshung24/ai-agent-skills](https://github.com/marshung24/ai-agent-skills)

Author: Mars.Hung (tfaredxj@gmail.com)

### 上游歸屬

本作改編自下列專案（改編鏈之著作權聲明保留於 [LICENSE](LICENSE)）：

- [op7418/Humanizer-zh](https://github.com/op7418/Humanizer-zh)，MIT License，Copyright © 2026 歸藏（簡體中文版）
- [blader/humanizer](https://github.com/blader/humanizer)，MIT License，Copyright © 2025 Siqi Chen（英文原版）
- 實用工具部分（核心規則、檢查清單）源自上游對 [hardikpandya/stop-slop](https://github.com/hardikpandya/stop-slop) 的參考

另旁系吸收自 [Raymondhou0917/speak-human-tw](https://github.com/Raymondhou0917/speak-human-tw)，MIT License，Copyright © 2026 Raymond Hou（雷蒙三十）：X／G 區段模式、內容型保護清單的概念源自該專案，依本版結構重寫與編排（其中部分模式已於 v1.2.0 專用化時停用，編號保留）。取捨理由見 [docs/resource.md](docs/resource.md) 第三、五節。

寫作模式的觀察來源為 Wikipedia WikiProject AI Cleanup 維護的 [Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing)。Wikipedia 內容依其原有授權條款（[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)）提供；本專案未直接複製或翻譯該頁面文字，模式清單經由上游 humanizer 系列的整理輾轉參考、並全部重新撰寫規則與範例。本專案的 MIT License 不取代 Wikipedia 原始內容的授權條款。
