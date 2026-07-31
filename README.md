# AI Agent Skills

個人開發的 AI Agent Skills 集合，遵循 [Agent Skills 規格](https://agentskills.io/specification)。

支援 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)、[Codex CLI](https://github.com/openai/codex)、[Gemini CLI](https://github.com/google-gemini/gemini-cli) 等支援 Agent Skills 標準的 AI 編碼工具。

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
