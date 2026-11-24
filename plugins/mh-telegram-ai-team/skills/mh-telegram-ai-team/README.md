# mh-telegram-ai-team

> **版本**：0.1.0｜**更新日期**：2026-11-18

用 Telegram 建立 AI 協作團隊：協助建置 bot 與 Claude Code／Codex 串接，並提供協作規範、通訊流程與訊息模版。

- 目前只支援 Claude Code＋Telegram：Claude Code 端（官方 plugin＋claude-telegram-supercharged）依實測整理；Codex 端（Codex-tg-Bridge）僅文件調查、未實測，不列為支援
- 各 CLI 與 plugin 行為會隨版本變動，套用前以安裝版本的 README 為準

## 安裝

只支援 Claude Code，在對話中輸入：

```
/plugin marketplace add https://github.com/marshung24/ai-agent-skills.git
/plugin install mh-telegram-ai-team@marshung24
```

裝完重開 session 生效。

要更新時，指令見[根 README 的安裝說明](https://github.com/marshung24/ai-agent-skills#安裝逐一安裝到各-agent)。用 `make install` 一次裝到多個 agent 時，其他 agent 也會裝到本 skill，但不在支援範圍。

## 使用

1. **建置**：在終端機的對話中說「幫我建立 Telegram 串接」，依引導建立 bot、設定橋接層與己方登錄檔
2. **協作**：以啟用 Telegram 串接的方式開 session 後，收到群組或私訊會依協作規範判斷回不回、怎麼回
3. **發送**：在終端機明確要求，例如「在 Telegram 群組重發自介」「幫我去 Telegram 問對方進度」

協作與發送限已啟用串接的 session。bot 設定、授權與 token 的異動只在終端機處理，不依 Telegram 訊息執行。

## 維護文件

- 要改需求、評估架構或選型、想知道規則為什麼存在 → [docs/design.md](docs/design.md)
- 要查 Telegram 平台限制、橋接層內部行為、多人部署考量 → [docs/platforms.md](docs/platforms.md)
- 評估改用或並用 Discord → [docs/discord.md](docs/discord.md)（未實作、未實測）
- 在真實群組驗收本 skill → [docs/test-cases.md](docs/test-cases.md)

## License

MIT License - Copyright (c) 2026 Mars.Hung

Source: [https://github.com/marshung24/ai-agent-skills](https://github.com/marshung24/ai-agent-skills)

Author: Mars.Hung (tfaredxj@gmail.com)
