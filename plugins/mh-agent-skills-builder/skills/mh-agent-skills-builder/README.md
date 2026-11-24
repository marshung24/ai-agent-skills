# mh-agent-skills-builder

> **版本**：1.1.1｜**更新日期**：2026-08-03

協助建立、修改和優化 Claude Agent Skills，含多種範本與最佳實踐。

本 skill 為**手動啟動**（`disable-model-invocation: true`），以 `/mh-agent-skills-builder` 呼叫。

## 安裝

依使用的 agent 擇一：

**Claude Code**（對話中輸入）

```
/plugin marketplace add https://github.com/marshung24/ai-agent-skills.git
/plugin install mh-agent-skills-builder@marshung24
```

**Codex**

```bash
codex plugin marketplace add https://github.com/marshung24/ai-agent-skills.git
codex plugin add mh-agent-skills-builder@marshung24
```

**Antigravity（agy）**

```bash
agy plugin install https://github.com/marshung24/ai-agent-skills/tree/main/plugins/mh-agent-skills-builder
```

**opencode**

```bash
git clone https://github.com/marshung24/ai-agent-skills.git
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills"
cp -r ai-agent-skills/plugins/mh-agent-skills-builder/skills/mh-agent-skills-builder "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills/"
```

裝完重開 session 生效。

要更新時，各家指令見[根 README 的安裝說明](https://github.com/marshung24/ai-agent-skills#安裝逐一安裝到各-agent)。

## 使用

```
/mh-agent-skills-builder 幫我建一個把會議逐字稿整理成待辦清單的 skill
```

其他呼叫時的意圖範例：

- 「檢查這個 SKILL.md 的 description 會不會誤觸發」
- 「這份 SKILL.md 太長，幫我拆到 references」

## 參考資料

- [Claude Docs - Agent Skills](https://platform.claude.com/docs/zh-TW/agents-and-tools/agent-skills/overview)
- [Agent Skills Specification](https://agentskills.io/specification)
- [Anthropic Skills](https://github.com/anthropics/skills)

## License

MIT License - Copyright (c) 2026 Mars.Hung

Source: [https://github.com/marshung24/ai-agent-skills](https://github.com/marshung24/ai-agent-skills)

Author: Mars.Hung (tfaredxj@gmail.com)