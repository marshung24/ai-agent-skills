# Humanizer-zh-tw：AI 寫作去痕工具（台灣正體版）

> **版本**：1.0.0｜**更新日期**：2026-07-26

Skill 名稱與目錄為 `mh-humanizer-zh-tw`（依本 repo 命名規範採 `mh-` 前綴）；「Humanizer-zh-tw」為沿用上游系列的文件標題。

去除文本中的 AI 生成痕跡，讓文字更自然、更像台灣人撰寫。改編自簡體中文版 [op7418/Humanizer-zh](https://github.com/op7418/Humanizer-zh)，針對台灣正體中文語境重建詞彙表、標點規範與寫作模式，並新增台灣特有的 AI 痕跡模式。

源頭與調整內容詳見 [docs/resource.md](docs/resource.md)。

## 功能

偵測並改寫 **24 種核心 AI 寫作模式**（誇大意義、宣傳語言、模糊歸因、否定式排比、三段式列舉、破折號濫用……；承襲改編基準版的上游模式，上游後續新增不自動同步，基準記錄見 [docs/resource.md](docs/resource.md)）＋ **5 種台灣補充模式**：

- **T1** 公關稿動詞鏈（攜手／串聯／深耕／打造……）
- **T2** 政策／計畫書抽象名詞堆疊（韌性／量能／動能／綜效……）
- **T3** 「持續＋正向動詞」假進展
- **T4** 中英夾雜的偽專業感
- **T5** 台灣口吻表面化（懶人包／小編／手刀收藏式偽在地化）

另含：

- 大陸用語 → 台灣用語對照表（一般語境＋軟體開發領域技術術語）
- 台灣繁中 AI 高頻警示詞四類（模板詞／公關腔／英文翻譯腔／陸式滲入，各類檢查方式不同）
- 台灣引號標點體例（「」『』《》〈〉）檢查
- 五維度品質自檢（具體性／結構自然度／用詞與在地性／語氣一致性／資訊密度與可信度；預設不輸出分數，要求評估時才輸出）
- 技術內容豁免清單與「只標記、不自動改」清單
- 範圍降級機制：只要求簡轉繁時不會擅自重寫

## 安裝

```bash
# 複製到 Claude Code 的 skills 目錄
cp -r skills/mh-humanizer-zh-tw ~/.claude/skills/mh-humanizer-zh-tw
```

或於專案級安裝至 `.claude/skills/mh-humanizer-zh-tw/`。

## 使用

```
/mh-humanizer-zh-tw 請幫我把這段文字去除 AI 腔：

[貼上文本]
```

或在對話中直接說：

- 「幫我把這篇改得更自然、更像台灣人寫的」
- 「這份文件有簡體用語跟 AI 腔，幫我台灣化並自然化」
- 「檢查 article.md 有哪些 AI 寫作痕跡」

**不會觸發的情境**（設計如此）：純簡轉繁、純翻譯、純校對、純摘要、判定文章是否由 AI 生成。若明確呼叫本 skill 但只要求簡轉繁，只會做字形與詞彙轉換，不會改動句型與語氣。

## 檔案結構

```
mh-humanizer-zh-tw/
├── SKILL.md                 # 技能定義：觸發守門、載入規則、流程、核心規則、品質自檢
├── README.md                # 本文件
├── LICENSE                  # MIT（含上游歸屬）
├── docs/
│   └── resource.md          # 源頭說明與逐項調整記錄（維護者文件）
└── references/
    ├── patterns.md          # 24 核心模式（台灣化）＋ T1–T5 台灣補充模式
    ├── lexicon.md           # 兩岸詞彙對照、AI 高頻警示詞四類、不可機械替換清單
    └── examples.md          # 完整改寫案例、作者聲音校準、評分維度細則
```

## 定位聲明

- 本工具的模式清單是**編輯線索，不是 AI 判定器**——真人公文、學術文章與公關稿也會出現相同模式，不會輸出「AI 生成機率」。
- 目標是提升寫作品質，不是欺騙 AI 偵測器。最好的「去 AI 化」是讓文字有真實的思考與聲音。
- 改寫**不新增事實**：不虛構引言、數字、來源或個人經驗。

## License

MIT License - Copyright (c) 2026 Mars.Hung

Source: [https://github.com/marshung24/ai-agent-skills](https://github.com/marshung24/ai-agent-skills)

Author: Mars.Hung (tfaredxj@gmail.com)

### 上游歸屬

本作改編自下列專案（改編鏈之著作權聲明保留於 [LICENSE](LICENSE)）：

- [op7418/Humanizer-zh](https://github.com/op7418/Humanizer-zh)，MIT License，Copyright © 2026 歸藏（簡體中文版）
- [blader/humanizer](https://github.com/blader/humanizer)，MIT License，Copyright © 2025 Siqi Chen（英文原版）
- 實用工具部分（核心規則、檢查清單、評分）源自上游對 [hardikpandya/stop-slop](https://github.com/hardikpandya/stop-slop) 的參考

寫作模式的觀察來源為 Wikipedia WikiProject AI Cleanup 維護的 [Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing)。Wikipedia 內容依其原有授權條款（[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)）提供；本專案未直接複製或翻譯該頁面文字，模式清單經由上游 humanizer 系列的整理輾轉參考、並全部重新撰寫規則與範例。本專案的 MIT License 不取代 Wikipedia 原始內容的授權條款。
