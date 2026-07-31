# AI Agent Skills

個人開發的 AI Agent Skills 集合，遵循 [Agent Skills 規格](https://agentskills.io/specification)。

支援 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)、[Codex CLI](https://github.com/openai/codex)、[Antigravity](https://antigravity.google/docs/cli)、[opencode](https://opencode.ai) 等支援 Agent Skills 標準的 AI 編碼工具。

## Skills

### Development

| Skill | 說明 |
|-------|------|
| [mh-code-review](skills/mh-code-review/) | 程式碼審查（自我 review / PR review），依風險優先序檢查，支援 GitHub PR 操作 |

### Tooling

| Skill | 說明 |
|-------|------|
| [mh-agent-skills-builder](skills/mh-agent-skills-builder/) | 協助建立、修改和優化 Agent Skills，含設計方法論、多種範本與最佳實踐 |
| [mh-external-advisor](skills/mh-external-advisor/) | 外部 AI 顧問：非互動諮詢另一支 AI CLI（第二意見／交叉驗證），以明確 id 延續對話。⚠️ 以免互動核可旗標執行，僅限 sandbox／受控環境 |

### Writing

| Skill | 說明 |
|-------|------|
| [mh-humanizer-zh-tw](skills/mh-humanizer-zh-tw/) | 台灣正體 AI 寫作去痕：24 種核心模式＋5 種台灣補充模式、詞彙表與改寫範例 |

## Installation

本 repo 是 Claude Code／Codex 共用的 **plugin marketplace**（`marshung24`，plugin 名 `mars-skills`）——這兩家一次安裝取得全部 skills，後續 `update` 即可跟上更新。agy 與 opencode 沒有可用的發佈機制，改用複製方式，repo 附的 `make` 工具可一併處理。

### Claude Code

```
/plugin marketplace add https://github.com/marshung24/ai-agent-skills.git
/plugin install mars-skills@marshung24
```

> 這裡用完整 HTTPS URL 而非 `marshung24/ai-agent-skills` 簡寫：簡寫預設以 SSH clone，沒有 SSH 金鑰會直接失敗（要另設 `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`）。repo 附的 `make` 工具也是用 HTTPS URL，兩邊一致。

### Codex CLI

```bash
codex plugin marketplace add https://github.com/marshung24/ai-agent-skills.git
codex plugin add mars-skills@marshung24
```

### Antigravity（agy）與 opencode

這兩家不走 marketplace，直接把 skills 複製進它們的使用者級目錄即可。

- **agy** 的 plugin 機制其實可用，但只收本機目錄、不吃 Git URL，也無法發佈 catalog——換不到複製沒有的好處，所以本 repo 的工具對它只走複製。
- **opencode** 沒得選：它的 plugin 是 JS/TS 模組，不承載 skills，skills 一律靠目錄掃描。它還會**順便掃 `~/.claude/skills/`**，所以那裡若已有這批 skill，opencode 就已經吃得到了，不必再裝一次。

```bash
git clone https://github.com/marshung24/ai-agent-skills.git
cd ai-agent-skills
make install-agy        # → ~/.gemini/skills/
make install-opencode   # → ~/.config/opencode/skills/
```

### 用 make 一次處理四家

clone 之後，repo 附的 Makefile 可統一驅動四家：

```bash
make status          # 各家現況；有殘留才會多列出來
make install         # 四家一次裝對
make install-codex   # 只處理指定 agent
make update          # 更新
make remove          # 移除（連另一種機制的殘留一起清）
make validate        # 離線驗證 manifest 與 skills 結構
```

安裝方式是**每個 agent 固定的**，沒有 `METHOD` 可選：claude／codex 走 marketplace 並從 GitHub 安裝，agy／opencode 走複製。`install` 動手前會先印出解析後的計畫。開發時要裝工作目錄的內容加 `SOURCE=$PWD`。

> 兩種機制若同時存在，同一個 skill 會**重複載入**。因此安裝前會偵測另一種機制的殘留（舊版工具裝的、手動複製的），偵測到即中止並提示如何處理；確定要並存才加 `FORCE=1`。`remove` 一律兩邊都清。

細節見 [tools/README.md](tools/README.md)。

## 手動安裝（不使用 make 工具時）

### Skills 安裝路徑

所有 agent 都遵循 [Agent Skills 標準](https://agentskills.io/specification)，安裝路徑如下：

| Agent | 用戶級（全域） | 專案級 |
|-------|---------------|--------|
| Claude Code | `~/.claude/skills/<skill>/` | `.claude/skills/<skill>/` |
| Codex CLI | `~/.codex/skills/<skill>/` | `.agents/skills/<skill>/` |
| Gemini CLI | `~/.gemini/skills/<skill>/` | `.gemini/skills/<skill>/` |

> Codex CLI 用戶級路徑由 `$CODEX_HOME` 決定，預設為 `~/.codex`。
> Codex 和 Gemini 也都支援 `~/.agents/skills/`（用戶級）與 `.agents/skills/`（專案級）作為共用路徑。

### 安裝單一 skill

將 skill 資料夾複製到對應 agent 的目錄：

```bash
# Claude Code
cp -r skills/mh-code-review ~/.claude/skills/

# Codex CLI
cp -r skills/mh-code-review ~/.codex/skills/

# Gemini CLI
cp -r skills/mh-code-review ~/.gemini/skills/
```

### 多 Agent 共用（symlink）

如果同時使用多個 agent，可以將 skill 安裝在一處，再用 symlink 共用，避免重複複製：

```bash
# 1. 以 Claude Code 為主要安裝位置
cp -r skills/mh-code-review ~/.claude/skills/

# 2. 其他 agent 透過 symlink 共用
ln -s ~/.claude/skills/mh-code-review ~/.codex/skills/mh-code-review
ln -s ~/.claude/skills/mh-code-review ~/.gemini/skills/mh-code-review
```

或以 `.agents/skills/` 作為共用中心（Codex 和 Gemini 原生支援）：

```bash
# 1. 安裝到共用路徑
cp -r skills/mh-code-review ~/.agents/skills/

# 2. Claude Code 透過 symlink 引用
ln -s ~/.agents/skills/mh-code-review ~/.claude/skills/mh-code-review
```

> **注意**：symlink 的相對路徑是相對**連結所在目錄**解析，與執行時的工作目錄無關，因此 `ln -s ../../.claude/skills/<skill> ~/.codex/skills/<skill>` 是安全的，整個家目錄搬移後也仍然有效。絕對路徑則相反——家目錄路徑一變就斷。兩種都可用，擇一即可。

## Contributing

歡迎提交新的 skill！請參考 [template/SKILL.md](template/SKILL.md) 作為起始範本。

### 命名慣例

- 資料夾名稱使用 `mh-` 前綴 + `kebab-case`（例：`mh-code-review`）
- `SKILL.md` 中的 `name` 欄位須與資料夾名稱一致

### Skill 結構

```
skills/mh-<name>/
├── SKILL.md          # 核心指令（必要，< 500 行 / ~5000 tokens）
├── references/       # 參考文件（選用，按需載入）
├── scripts/          # 輔助腳本（選用）
├── assets/           # 範本、圖片、資料檔（選用）
└── docs/             # 設計文件（選用）
```

## References

- [Agent Skills 開發目標指南](docs/skills-development-guide.md) — 願景、設計原則、觸發限制、分階段路線圖
- [Agent Skills Specification](https://agentskills.io/specification)
- [Claude Docs - Agent Skills](https://platform.claude.com/docs/zh-TW/agents-and-tools/agent-skills/overview)

## License

[MIT](LICENSE)
