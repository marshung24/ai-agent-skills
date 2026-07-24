# mh-external-advisor

> **版本**：1.6.0｜**更新日期**：2026-07-24

外部顧問：把另一個 AI CLI（Codex、Claude、Opencode 或 Antigravity）當顧問諮詢——非互動送出 prompt、取回回覆，並以明確 id 延續同一段對話，用於第二意見、交叉驗證、盲點檢查等需要異質觀點的場景。

## 內容

```
mh-external-advisor/
├── SKILL.md              # 觸發守門 + 使用協定（路由器）
├── scripts/
│   ├── ask-codex.sh      # 詢問 Codex（codex exec，明確 thread_id resume）
│   ├── ask-claude.sh     # 詢問 Claude（claude -p，明確 session_id resume）
│   ├── ask-opencode.sh   # 詢問 Opencode（opencode run，明確 session_id resume）
│   └── ask-agy.sh        # 詢問 Antigravity（agy -p，conversation id 磁碟偵測 + 明確 resume）
├── references/
│   └── detail.md         # 輸出契約、底層指令、設計取捨、疑難排解
└── docs/
    └── design.md         # 設計文件：架構、DECISION 記錄、驗證證據鏈
```

## 快速使用

```bash
# 開新對話
out=$(scripts/ask-codex.sh "幫我看這段邏輯有沒有問題：…")
# 從末行取 id（先 tail -n1 只看最後一行——回覆內容若引用同格式字樣才不會誤抓）
id=$(printf '%s' "$out" | tail -n1 | sed -n 's/^\[External Advisor .* session_id: \(.*\)\]$/\1/p')
# 延續同一段對話
scripts/ask-codex.sh -r "$id" "那如果併發呼叫呢？"
```

四支 `ask-*.sh` 介面相同（`[-r <id>] [--] "<prompt>"`、末行印 id；prompt 以 `-` 開頭時必加 `--`）；僅 agy 的 id 為磁碟偵測取得。嚴謹的 id 擷取（含 exit code 與 `[warn]` 檢查）與其他細節見 [references/detail.md](references/detail.md)。

## 需求

- `codex` / `claude` / `opencode` / `agy` CLI 已安裝、登入且在 PATH（只需安裝要用的那個）
- `jq`（四支皆需：codex/claude/opencode 解析 CLI 的 JSON 輸出；agy 解析 last_conversations.json 取 id）

## ⚠️ 安全前提：僅在安全環境或 Sandbox 中使用

四支腳本皆以免互動核可旗標呼叫底層 CLI（codex/claude/agy 為 `--dangerously-*`；opencode 旗標名版本相依，腳本以 `--help` 自動偵測），跳過互動核可與沙箱限制——這是非互動自動化的必要代價。代價是：**被諮詢的 AI 取得與執行使用者相同的檔案、程序、網路與憑證權限，存取範圍不限當前工作目錄**——可讀取 `$HOME`、SSH/cloud 憑證、其他 repo，可對外發送資料；一句含副作用指示的 prompt（或被讀取內容中的 prompt injection）就足以觸發。另注意固有外流面：prompt 與其引用的內容會送往被諮詢 AI 的服務端（第三方廠商），機密內容不應放入 prompt。

因此只有在**已隔離檔案系統、敏感憑證、網路與宿主控制介面**的環境才可視為安全：

- ✅ 獨立 sandbox / 拋棄式容器或 VM：不掛宿主控制介面（如 Docker socket）、不注入 production 或 cloud 憑證、網路受限或 allowlist
- ✅ workspace 可拋棄、或所有變更皆已提交版控（注意：版控只防檔案損毀，防不了資料外洩與外部 API 副作用）
- ❌ 宿主機；含未提交變更或敏感資料（金鑰、憑證）的目錄；掛有宿主控制介面或 production 憑證的容器

設計取捨的完整記錄見 [docs/design.md](docs/design.md) §5.5。

## License

MIT License - Copyright (c) 2026 Mars.Hung

Source: [https://github.com/marshung24/ai-agent-skills](https://github.com/marshung24/ai-agent-skills)

Author: Mars.Hung (tfaredxj@gmail.com)
