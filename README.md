# AI Agent Skills

個人開發的 AI Agent Skills 集合，遵循 Agent Skills 規格（只有要自行開發 skill、或查跨 agent 相容性時，才需要讀[規格本文](https://agentskills.io/specification)）。

這個 repo 提供兩類可獨立使用的東西：

| 交付物 | 適合你，如果…… | 怎麼用 |
|--------|----------------|--------|
| [Skills](#skills) | 想替 Claude Code、Codex、Antigravity 或 opencode 加上特定能力 | 安裝 `plugins/` 底下需要的那幾個 |
| [Templates](#templates) | 想替自己的專案立一份多家 agent 共用的工作規範 | 複製 `templates/AGENTS.md` 去改 |

Templates 是一般 Markdown 檔，不是 skill，也不經安裝流程。

## Skills

支援 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)、[Codex CLI](https://github.com/openai/codex)、[Antigravity](https://antigravity.google/docs/cli)（`agy`）、[opencode](https://opencode.ai)。本 repo 同時是 Claude Code／Codex 共用的 **plugin marketplace**（`marshung24`），**每個 skill 各自是一個 plugin**，可以只裝需要的那幾個。

| Skill | 說明 |
|-------|------|
| [mh-agent-skills-builder](plugins/mh-agent-skills-builder/skills/mh-agent-skills-builder/) | 協助建立、修改和優化 Agent Skills，含設計方法論、多種範本與最佳實踐；手動啟動 |
| [mh-code-review](plugins/mh-code-review/skills/mh-code-review/) | 程式碼審查（自我 review / PR review），依風險優先序檢查，支援 GitHub PR 操作 |
| [mh-external-advisor](plugins/mh-external-advisor/skills/mh-external-advisor/) | 外部 AI 顧問：非互動諮詢另一支 AI CLI（第二意見／交叉驗證），以明確 id 延續對話。⚠️ 以免互動核可旗標執行，僅限 sandbox／受控環境 |
| [mh-humanizer-zh-tw](plugins/mh-humanizer-zh-tw/skills/mh-humanizer-zh-tw/) | 技術文件台灣化與保真微編輯（技術文章、規範、規畫設計、教案、程式註解）：詞彙台灣化、好懂化微調、語意保真；完整去 AI 腔為進階模式（38 種啟用模式） |

怎麼選：要一次管好四家、或日後要 `update`／`remove` → 用 repo 附的工具；只用 Claude Code／Codex 且不想 clone → 直接跳到〈自己動手〉的 marketplace 那段。

### 安裝：用 repo 附的工具（make）

```bash
git clone https://github.com/marshung24/ai-agent-skills.git
cd ai-agent-skills
make install
```

```bash
make status          # 各家現況；有殘留才會多列出來
make install         # 跳出 agent × skill 矩陣，逐格勾選
make update          # 更新（全做）
make remove          # 同一個矩陣，起始全空
make validate        # 離線驗證 manifest 與 skills 結構
```

安裝方式是**每個 agent 固定的**：claude／codex 走 marketplace 並從 GitHub 安裝，agy／opencode 走複製。要重新評估這個切法、或想知道四家的機制差異，讀 [Marketplace 設定指南](docs/marketplace-guide.md)〈四家 agent 的機制對照〉。

`install` 與 `remove` 會跳出 **agent × skill 的二維矩陣**——畫面就是現況，改成什麼就同步成什麼（勾起來是裝、取消是移除），按鍵依畫面下方提示，確定後會先印出逐 agent 的增減再執行。

> claude／codex **預設從 GitHub 安裝**，此模式下工作目錄裡未 push 的修改不會生效；要測本機改動得加 `SOURCE=$PWD` 改用工作目錄當來源。

> **重複載入的防線**：兩種機制並存時同一個 skill 會載入兩次，因此安裝前會偵測另一種機制的殘留（舊版工具裝的、手動複製的），偵測到即中止並提示如何處理；確定要並存才加 `FORCE=1`。`remove` 一律兩邊都清。另外 opencode 會**順便掃 `~/.claude/skills/`**，那裡若已有這批 skill，它就已經吃得到了，不必再裝一次。

這套工具只管 Skills，不會安裝或驗證 `templates/`。要查變數、狀態碼、矩陣完整按鍵，或安裝失敗要排查時，讀 [tools/README.md](tools/README.md)。

### 安裝：自己動手（不使用 make 工具時）

不想 clone、或要自行控制安裝目錄與 symlink 時。

**Claude Code／Codex：走 marketplace**

以下以 `mh-code-review` 為例，換成上表其他 skill 名即可。

```
/plugin marketplace add https://github.com/marshung24/ai-agent-skills.git
/plugin install mh-code-review@marshung24
```

```bash
codex plugin marketplace add https://github.com/marshung24/ai-agent-skills.git
codex plugin add mh-code-review@marshung24
```

> 用完整 HTTPS URL 而非 `marshung24/ai-agent-skills` 簡寫：簡寫在 Claude Code 預設以 SSH clone，沒有 SSH 金鑰會直接失敗（要另設 `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`）。

**agy／opencode：手動複製**

這兩家不支援 marketplace，只能靠目錄掃描；機制差異見〈用 repo 附的工具〉指的那份 Marketplace 設定指南。

| Agent | 使用者級 skills 目錄 |
|-------|---------------------|
| Antigravity（agy） | `~/.gemini/skills/<skill>/` |
| opencode | `~/.config/opencode/skills/<skill>/`（受 `$XDG_CONFIG_HOME` 影響） |

專案級：agy 看 `.gemini/skills/`，opencode 另看 `.opencode/`、`.claude/`、`.agents/` 底下的 `skills/`。

```bash
cp -r plugins/mh-code-review/skills/mh-code-review ~/.gemini/skills/
```

agy 另可用 `agy plugin install ./plugins/<name>` 單獨安裝某個 skill（每個 plugin 目錄都自帶 `plugin.json`）。

兩家都要就裝一份、另一家用 symlink 指過去，避免重複複製：

```bash
ln -s ~/.gemini/skills/mh-code-review ~/.config/opencode/skills/mh-code-review
```

> **注意**：symlink 的相對路徑是相對**連結所在目錄**解析，與執行時的工作目錄無關，因此 `ln -s ../../../.gemini/skills/<skill> ~/.config/opencode/skills/<skill>` 是安全的，整個家目錄搬移後也仍然有效。絕對路徑則相反——家目錄路徑一變就斷。兩種都可用，擇一即可。

> opencode 的掃描路徑不只上表這一處（另含 `~/.claude/skills/`、`~/.agents/skills/`），那些位置若已有這批 skill 就不必再複製一份。

> 手動複製沒有 `make install` 的殘留偵測：同一個 skill 若又以別的方式裝過（例如 `agy plugin install`），會重複載入，得自己留意。

## Templates

| 範本 | 說明 |
|------|------|
| [templates/AGENTS.md](templates/AGENTS.md) | 專案根目錄 `AGENTS.md` 的萬用起手式：專案資訊欄位、工作規範，以及結案流程（跑測試、自我 review、外部顧問 review、同步主線、發 PR） |

它不是 skill，不經 marketplace，也不被 `make install`／`make validate` 碰到——複製到目標專案、依該專案的真實資訊填完才算數。

### 套用到你的專案

```bash
cp templates/AGENTS.md <專案>/AGENTS.md
```

接著編輯該檔：

1. 填滿〈專案資訊〉每個 `<...>`；查不到的欄位寫「不適用：理由」，不留空、不猜
2. 刪掉檔頭的範本說明與所有 `<!-- -->` 註解
3. 條文與該 repo 既有規範衝突時，以 repo 規範為準就地改寫，不另開例外段落
4. 刪掉與該專案無關的條文——這份檔每個 session 都佔 context

`AGENTS.md` 是 Codex、agy 與 opencode 共通的專案指令檔；**Claude Code 不讀它、只讀 `CLAUDE.md`**，因此在專案根目錄補一個 symlink，四家共用同一份：

```bash
cd <專案> && ln -s AGENTS.md CLAUDE.md
```

> symlink 用相對路徑（相對**連結所在目錄**解析），專案整個搬移或 clone 到別處都仍有效。

## 維護與貢獻

### 新增或修改 Skill

```
plugins/mh-<name>/           # 一個 plugin＝一個 skill，marketplace 的 source 指向這層
├── plugin.json              # agy 用；讓它可以單獨安裝這個 skill
└── skills/mh-<name>/        # 各家 agent 掃描的位置
    ├── SKILL.md             # 核心指令（必要，< 500 行 / ~5000 tokens）
    ├── references/          # 參考文件（選用，按需載入）
    ├── scripts/             # 輔助腳本（選用）
    ├── assets/              # 範本、圖片、資料檔（選用）
    └── docs/                # 設計文件（選用）
```

- 目錄名用 `mh-` 前綴 + `kebab-case`；`SKILL.md` 的 `name` 欄位須與目錄同名
- **新增 skill 必須同步加一個 marketplace entry**，否則使用者裝不到；`make validate` 會雙向檢查。動手前先讀 [Marketplace 設定指南](docs/marketplace-guide.md)〈新增一個 skill 要做什麼〉
- 六份 SKILL.md 範本依 skill 的形狀擇一，選擇條件見 [mh-agent-skills-builder 的範本路由表](plugins/mh-agent-skills-builder/skills/mh-agent-skills-builder/SKILL.md#範本)

### 修改 Templates

`templates/AGENTS.md` 自身即 SSOT。改的時候維持它對任何專案都成立——不要寫進特定組織、特定 repo 或本機環境才有的規則。

### 文件

要開發 skill、改 manifest、或理解安裝工具的行為時，先開 [文件索引](docs/README.md) 依工作類型選文件——那張表列了每份文件的內容與**什麼時候讀**，不必憑檔名猜。

## References

- 要確認 `SKILL.md` 的通用格式與跨 agent 相容性 → [Agent Skills Specification](https://agentskills.io/specification)
- 要確認 Claude Code 特有的載入行為與限制 → [Claude Docs - Agent Skills](https://platform.claude.com/docs/zh-TW/agents-and-tools/agent-skills/overview)

## License

[MIT](LICENSE)
