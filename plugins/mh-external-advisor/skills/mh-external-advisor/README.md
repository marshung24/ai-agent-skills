# mh-external-advisor

> **版本**：2.4.0｜**更新日期**：2026-09-03

外部顧問：把另一個 AI CLI（Codex、Claude、Opencode 或 Antigravity）當顧問諮詢——非互動送出 prompt、取回回覆，並以明確 id 延續同一段對話，用於第二意見、交叉驗證、盲點檢查等需要異質觀點的場景。

## 內容

```
mh-external-advisor/
├── SKILL.md                 # 觸發守門 + 使用協定（路由器）
├── scripts/
│   ├── advisor-list.sh      # getter：列出已啟用的顧問與其呼叫式
│   ├── advisor-set.sh       # setter：設定啟用清單（耐久儲存）
│   ├── advisor-quota.sh     # 查各顧問的訂閱額度餘量（只查額度，不諮詢）
│   ├── advisor-throttle.sh  # 漏桶節流：查水位／取用額度／重置（扣桶由 ask-*.sh 內部完成）
│   ├── lib/enabled-io.sh    # getter/setter 共用：名稱驗證、支援掃描、設定檔讀取
│   ├── lib/throttle-io.sh   # 節流共用：身分解析、桶讀寫、目錄鎖、額度倍率
│   ├── ask-codex.sh         # 詢問 Codex（codex exec）
│   ├── ask-claude.sh        # 詢問 Claude（claude -p）
│   ├── ask-opencode.sh      # 詢問 Opencode（opencode run）
│   └── ask-agy.sh           # 詢問 Antigravity（agy -p）
├── references/
│   ├── detail.md            # 執行期參考：輸出契約、參數、exit code、疑難排解
│   └── autonomous-mode.md   # 自主模式執行辦法（啟動後才按需載入）
└── docs/
    ├── design.md            # 設計文件：架構、DECISION 記錄、驗證證據鏈
    └── internals.md         # 實作細節（維護用）：腳本內部行為、額度介面、底層指令
```

## 快速使用

```bash
# 1. 首次使用：設定你實際擁有的 AI（只需一次，寫入耐久設定檔）
scripts/advisor-set.sh codex claude

# 2. 取得可用顧問與呼叫式
scripts/advisor-list.sh

# 3. 依 getter 給的指令諮詢；延續同一段對話帶 -r <id>（id 取自輸出末行）
scripts/ask-codex.sh --scope explore "幫我看這段邏輯有沒有問題：…"
scripts/ask-codex.sh --scope unblock -r <id> "那如果併發呼叫呢？"
```

想確認顧問還剩多少訂閱額度：`scripts/advisor-quota.sh [<ai>...]`——走各 CLI 官方的非互動額度介面，只查額度、不諮詢、不消耗額度（opencode 無此介面）。

**顧問用哪個模型**：四支 adapter 皆不帶模型參數，一律走各 CLI 自身的預設模型。本 skill 的價值來自使用別種 AI 的能力與觀點，而非挑選特定模型；需要換模型時，請先以互動模式開啟該 CLI 調整其預設，之後的諮詢即沿用。

四支 `ask-*.sh` 介面相同（`--scope <explore|unblock|review> [-r <session_id>] [--] "<prompt>"`、末行印 id；`--scope` **必填**，缺它 exit 2；prompt 以 `-` 開頭時必加 `--`）。id 的嚴謹擷取（末行比對、exit code 與 `[warn]` 檢查）與其他細節見 [references/detail.md](references/detail.md)。

## 節流

每次諮詢在送出 prompt 前，由 `ask-*.sh` **內部**扣一次漏桶額度——不是選配步驟，跳不過。這是為了讓自主模式有一層不依賴呼叫端自我判斷的速率上限：其餘限制（該不該問、是不是同一個問題）都要 AI 自己判斷，只有這一層純粹數次數與看時鐘。

桶依 `(呼叫端 agent 的 PID, scope, 顧問)` 隔離——每支顧問的訂閱額度獨立計算，互不排擠；同一台機器上多個 agent 也互不干擾。

**預設**：容量 30、每次扣 10、每 60 秒回 1 單位——即連續 3 次後見底，之後每 10 分鐘回一次呼叫的量。額度餘量高時恢復更快（`>=70%` 間隔減半、`<40%` 加倍），但**容量不變**。

```bash
# 查水位（唯讀，不查網路、不建任何檔案）
scripts/advisor-throttle.sh status --advisor codex

# 重置（被擋下但你確定要繼續時）
scripts/advisor-throttle.sh reset --advisor codex --scope explore
scripts/advisor-throttle.sh reset --all
```

桶空時 adapter 回 **exit 5 且 prompt 未送出**，stdout 是含 `retry_after_seconds` 的 JSON。等它恢復或用 `reset` 清掉都可以——`reset` 是給你用的，AI 被擋下後不得自行呼叫。

要調參數，建 `${XDG_CONFIG_HOME:-$HOME/.config}/mh-external-advisor/throttle.json`：

```json
{
  "version": 1,
  "scopes": {
    "default": { "capacity": 30, "cost": 10, "refill_seconds": 60 },
    "review":  { "refill_seconds": 90 }
  }
}
```

缺檔即用內建預設。每個欄位都必須是正整數，`0`、負數、小數或 `cost > capacity` 會**個別退回預設並在 stderr 印 `[warn]`**——設定寫錯不該讓所有諮詢停擺。完整欄位、結束碼與內部行為見 [references/detail.md](references/detail.md)〈節流〉。

用量記錄在 `${XDG_STATE_HOME:-$HOME/.local/state}/mh-external-advisor/quota/usage.log`，allow 與 deny 都記，**不含 prompt 內容**，超過 1MB 輪替。

## 需求

- `codex` / `claude` / `opencode` / `agy` CLI 已安裝、登入且在 PATH（只需安裝要用的那個）
- `jq`（各腳本皆需：解析 CLI 的 JSON 輸出與啟用清單設定檔）
- GNU `timeout`（僅 `advisor-quota.sh` 需要；macOS 安裝 coreutils 後為 `gtimeout`，腳本兩者皆認）

## 啟用清單

清單分三層，呼叫前三層都要過：

| 層 | 意義 | 事實來源 |
|---|---|---|
| **支援** | skill 內建哪些 adapter | `scripts/ask-*.sh`（放進去就是支援，無需登錄） |
| **啟用** | 使用者實際擁有並願意使用哪幾支 | `${XDG_CONFIG_HOME:-$HOME/.config}/mh-external-advisor/enabled.json` |
| **授權** | 逐次點名的那一支，或本次對話已啟動的自主模式 | 對話脈絡（不留存、不跨 session） |

```bash
scripts/advisor-set.sh codex claude   # 覆寫整份啟用清單
scripts/advisor-set.sh --add agy      # 加一支
scripts/advisor-set.sh --remove agy   # 移除一支
scripts/advisor-set.sh --clear        # 清空
scripts/advisor-list.sh               # 讀出啟用清單與呼叫式（rc=4 表示尚未設定）
```

安裝後**必須先跑一次 setter**，否則 `advisor-list.sh` 一律回 rc=4（尚未啟用），呼叫端會轉為引導使用者設定。設定檔位於 XDG config 目錄（未設 `XDG_CONFIG_HOME` 時為 `$HOME/.config`），與 skill 目錄分離，重裝不會被覆蓋。

## 授權模式

授權層有兩種形態，預設為**逐次授權**：使用者每次點名要問哪一支。

**自主模式**讓主 AI 在達成條件時自行呼叫顧問，不必逐次點名——由使用者說「啟動外部顧問自主模式」開啟、「停止外部顧問自主模式」關閉。啟動要兩個條件：指令出自使用者本人且在主對話中、七欄常駐授權齊備（作用域／指定顧問／指派範圍／副作用邊界／允許目的／預算／到期）。環境隔離不是啟動條件，未聲明時只在啟動確認中警告。啟動後主 AI 才按需載入〈自主模式執行辦法〉（觸發判定、預算、札記、採信、呼叫記錄、退場），未啟動時不讀。

自主模式**只取消逐次點名**，其餘守門一律不變：啟用清單、送出前的硬規則、採信原則、子 Agent 規則、`allowed-tools`（Bash 仍照常詢問）。狀態只存在該次對話，不落檔、不跨 session；context 壓縮後無法完整還原授權與預算即視為已停止。

新增一支 adapter：把可執行的 `ask-<name>.sh` 放進 `scripts/`（需支援 `--info` 自述）即完成，getter、setter 與文件皆無需修改。

`advisor-set.sh` 為 read-modify-write，**不可並行執行**（無鎖，交錯執行會互相覆蓋）。

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
