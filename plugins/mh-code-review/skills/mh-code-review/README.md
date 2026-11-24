# mh-code-review

> **版本**：1.0.1｜**更新日期**：2026-11-24

程式碼審查（自我 review / PR review），依風險優先序檢查，支援 GitHub PR 操作。

## 安裝

依使用的 agent 擇一：

**Claude Code**（對話中輸入）

```
/plugin marketplace add https://github.com/marshung24/ai-agent-skills.git
/plugin install mh-code-review@marshung24
```

**Codex**

```bash
codex plugin marketplace add https://github.com/marshung24/ai-agent-skills.git
codex plugin add mh-code-review@marshung24
```

**Antigravity（agy）**

```bash
agy plugin install https://github.com/marshung24/ai-agent-skills/tree/main/plugins/mh-code-review
```

**opencode**

```bash
git clone https://github.com/marshung24/ai-agent-skills.git
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills"
cp -r ai-agent-skills/plugins/mh-code-review/skills/mh-code-review "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills/"
```

裝完重開 session 生效。

要更新時，各家指令見[根 README 的安裝說明](https://github.com/marshung24/ai-agent-skills#安裝逐一安裝到各-agent)。

## 使用

在對話中同時說出 **review 意圖**與**審查對象**就會啟動；只說「幫我看一下」不會啟動，缺對象時會反問：

- 「review 我未 commit 的改動」
- 「審核 feature/login 這個 branch」
- 「review PR #123」（或直接貼 PR URL；PR 操作需要 `gh` 已登入）

不會自行 merge PR。

## Docs

- [設計文件](docs/design.md) — 設計背景、架構決策與驗收標準

## License

MIT License - Copyright (c) 2026 Mars.Hung

Source: [https://github.com/marshung24/ai-agent-skills](https://github.com/marshung24/ai-agent-skills)

Author: Mars.Hung (tfaredxj@gmail.com)
