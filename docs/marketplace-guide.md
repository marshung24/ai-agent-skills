# Marketplace 設定指南

> **版本**：2.2.0｜**更新日期**：2026-11-24

本 repo 如何同時作為 Claude Code／Codex 的 plugin marketplace 發佈，以及各家 agent 的行為差異。所有結論皆為實測所得，升版需重驗。

**適用對象**：要維護本 repo 的 manifest、或想把自己的 skills 集合做成 marketplace 的人。

---

## TL;DR

| 項目 | 內容 |
|------|------|
| **manifest** | `.claude-plugin/marketplace.json`（Claude Code 與 Codex 共用同一份） |
| **粒度** | 一個 skill ＝ 一個 plugin |
| **佈局** | `plugins/<name>/skills/<name>/SKILL.md`，`source` 指向 `./plugins/<name>` |
| **哪幾家吃 marketplace** | 只有 Claude Code 與 Codex；agy 走 plugin，opencode 走複製 |
| **驗證** | `make validate`（七項，含 `claude plugin validate --strict`） |

---

## 四家 agent 的機制對照

| Agent | 有 marketplace？ | 讀哪份 manifest | 本 repo 採用 |
|-------|-----------------|----------------|-------------|
| Claude Code | ✅ 完整 | `.claude-plugin/marketplace.json` | marketplace |
| Codex CLI | ✅ 沿用 Claude 格式 | 同上（另接受 `.agents/plugins/` 下的 `marketplace.json`、`api_marketplace.json`） | marketplace |
| Antigravity（agy） | ⚠️ 只有官方的 | 根目錄 `plugin.json` | plugin |
| opencode | ❌ 官方文件未見 | — | copy |

**agy 的 ⚠️**：`plugin@marketplace` 目前只認官方的 `antigravity-plugins-official`（[官方說明](https://antigravity.google/docs/marketplace?tab=cli)），第三方不能註冊自己的 marketplace。但 `agy plugin install` 可直接吃 GitHub URL，接 `/tree/main/plugins/<name>` 就只裝一個。更新靠重跑 install，沒有 `plugin update`。本 repo 的安裝工具就是這樣裝；來源與分支的細節讀 [tools/README.md](../tools/README.md)〈安裝方式〉。

**opencode 的 ❌**：它的 plugin 是 JS/TS 套件（從 npm 或 Git 安裝），不吃本 repo 的 manifest。skills 靠目錄掃描，或由設定檔的 `skills` 指向本機目錄或 HTTP 目錄。後者要自備 `index.json`，所以本 repo 現有的 GitHub repo／tree／raw 目錄不能直接當來源；1.18.30 實測下載後腳本會失去執行權限，且 `version` 不變就不更新。[官方 Skills 文件](https://opencode.ai/docs/skills/)有格式與同名優先序，要改走 HTTP 時讀它。

---

## manifest 結構

```jsonc
{
  "$schema": "https://json.schemastore.org/claude-code-marketplace.json",
  "name": "marshung24",              // marketplace 識別名，使用者以 <plugin>@<name> 安裝
  "owner": { "name": "...", "url": "..." },
  "description": "...",
  "plugins": [
    {
      "name": "mh-code-review",              // plugin 名，本 repo 慣例＝skill 名
      "source": "./plugins/mh-code-review",  // 相對 marketplace 根目錄；底下有 skills/<name>/
      "description": "...",
      "category": "engineering",
      "keywords": ["..."],
      "author": { "name": "...", "url": "..." },
      "homepage": "...",
      "repository": "https://github.com/marshung24/ai-agent-skills",
      "license": "MIT"
    }
  ]
}
```

### 必填欄位

| 層級 | 欄位 | 說明 |
|------|------|------|
| 頂層 | `name`、`owner`、`plugins` | `owner` 內只有 `name` 必填 |
| entry | `name`、`source` | 其餘皆選填 |

`source` 為字串時**必須以 `./` 開頭**，且相對於 marketplace 根目錄（含 `.claude-plugin/` 的那層），不是 `.claude-plugin/` 本身。也可以是物件形式指向 `github`／`url`／`git-subdir`／`npm`。

---

## 一個 skill 一個 plugin

佈局是每個 plugin 各自一個目錄，底下再放標準的 `skills/<name>/`：

```
plugins/mh-code-review/
├── plugin.json                      # agy 用
└── skills/mh-code-review/SKILL.md   # 各家掃描的位置
```

manifest 只要指到 plugin 目錄，不需要 `skills` 欄位——plugin root 底下就是合格的 `skills/`，預設掃描即可：

```json
{ "name": "mh-code-review", "source": "./plugins/mh-code-review" }
```

### 為什麼不是共用 `source: "./"`

共用根目錄也可行（`anthropics/skills` 就是這樣，配合 `skills: ["./skills/<name>"]` 限定範圍），但每個 entry 都會把**整個 repo** 複製進快取。實測本 repo 是 508K，裝四個約 2MB，而且會隨 `docs/`、`tools/` 成長而放大。

改成一個目錄一個 plugin 後，快取只含該 plugin 的內容：

| | 快取／plugin |
|---|---|
| `source: "./"` | 508K（整個 repo） |
| `source: "./plugins/<name>"` | 56–72K |

這也是 `anthropics/claude-plugins-official` 的做法（`./plugins/<name>`，276 個 entry 中 53 個用相對路徑）。

### 順帶讓 agy 也能單選

每個 plugin 目錄自帶 `plugin.json` 後，agy 可以單獨安裝某一個 skill：

```bash
agy plugin install ./plugins/mh-code-review
agy plugin install https://github.com/marshung24/ai-agent-skills/tree/main/plugins/mh-code-review
```

這是舊佈局做不到的——當時 agy 只認 repo 根目錄那一份 `plugin.json`，一裝就是全部。

### ⚠️ `source` 不能指向 skill 目錄本身

實測過三種寫法，`source: "./plugins/<name>/skills/<name>"`（不論 `skills` 欄位怎麼寫、寫不寫）在 **Claude Code 可用但 Codex 完全載不到**：

| `source` | `skills` | Claude | Codex |
|---|---|---|---|
| skill 目錄 | `["./skills/<name>"]` | ✅ | ❌ |
| skill 目錄 | 不寫 | ✅ | ❌ |
| skill 目錄 | `["./"]` | ✅ | ❌ |
| **plugin 目錄** | **不寫** | ✅ | ✅ |

Codex 的預設掃描只認 `<plugin root>/skills/<name>/SKILL.md` 這個形狀（binary 內的字串是 `failed to stat skills root`）。`source` 指向 skill 目錄後 `SKILL.md` 就躺在 plugin root，底下沒有 `skills/`。Claude Code 之所以可以，是它額外支援「plugin root 直接放一個 `SKILL.md`」——**那是它獨有的**，不是共通行為。

## 幾個欄位的取捨

### 不設 `version`

省略時 Claude Code 對 Git 來源以 **git commit SHA** 當版本，push 完使用者 `update` 就拿得到。設了則會釘住該字串，每次發布都要記得 bump，忘記就等於停止發佈。

**開發時要注意**（`make source local`）：Claude Code 對本機目錄同樣以 HEAD 的 commit SHA 當版本，未 commit 的改動拿不到，commit 後 `make update` 再 `/reload-plugins`。Codex 讀的是安裝時的快取（VERSION 欄是 `local`），要重跑 `plugin add`（`make update` 會代做）才會覆蓋，不必 commit。

### 不設 `strict`

官方文件與 schemastore 對這個欄位的描述**不一致**：

| 來源 | 對預設值 `true` 的描述 |
|------|----------------------|
| 官方文件 | `plugin.json` 為權威，marketplace entry 可補充、兩者合併；**manifest 本身可省略** |
| schemastore | 要求 plugin 目錄**必須有** manifest |

本 repo 沒有 `.claude-plugin/plugin.json`，實測預設值下 skill 全數載入——以實作行為為準。

> **DECISION**：曾評估寫成 `strict: false`（語意上更貼近「entry 即完整定義」），實測也可用，但代價是——日後若有人補上 `.claude-plugin/plugin.json` 且其中宣告了元件，會直接判定衝突、plugin 載入失敗。相較之下留預設只在「Claude Code 改採 schemastore 那套描述」時才會出事，機率低得多，故不寫。

### 用 HTTPS URL 而非 `owner/repo` 簡寫

`owner/repo` 簡寫在 Claude Code 會先試 SSH、不通才改 HTTPS，走哪條隨使用者的 SSH 設定而變（設 `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` 可固定走 HTTPS）。完整 HTTPS URL 兩家都收，行為固定，因此 README 與工具一律用它。

---

## 下架與遷移

移除一個 entry 不會讓使用者機器上的安裝自動消失。兩家行為不同，**codex 那側是隱形陷阱**：

| | 移除 entry 後 |
|---|---|
| **Claude Code** | 支援 `renames`。`plugin list` 仍列出；本機來源實測 Version 變 `unknown`、沒有 Removed 提示，Git 來源未驗證；`plugin uninstall` 可正常移除 |
| **Codex** | **不認識 `renames`**。`plugin list` 直接看不到它，但 `config.toml` 仍有 `enabled = true`、快取還在，**執行期照樣載入全部 skill**。`plugin remove` 仍可移除 |

所以下架一個 entry 時，manifest 要同時補上：

```json
"renames": { "<舊 plugin 名>": null }
```

`null` 表示該 plugin 已移除。Claude Code 認得這個欄位（提示與否見上表）；Codex 忽略這個未知欄位（實測不影響解析）。目前沒有需要追蹤的下架 plugin，故 manifest 不寫這個欄位。

`tools/skills.sh` 也以此為單一事實來源：從 `renames` 的 key 取得「已下架但可能還裝著」的名單（沒有這個欄位時名單為空，偵測整段略過），並且

- `status`：偵測到就多印一列 `⚠遺留`（codex 那側改讀 `config.toml`，因為 `plugin list` 看不到）
- `install`：偵測到就擋下（舊 plugin 一裝就是全部 skill，必然與新的重疊）
- `remove`：一併清除，且**必須在註銷 marketplace 之前執行**——一旦註銷，`claude plugin list` 就查不到舊 plugin，偵測會靜默失效

---

## 驗證

```bash
make validate
```

| 檢查 | 為什麼需要 |
|------|-----------|
| marketplace.json 必要欄位 | 缺了各家會直接拒絕 |
| 每個 `plugins/<name>/` 都有 `skills/<name>/SKILL.md` | 缺了不會被任何 agent 掃描到，卻不會有任何錯誤 |
| 每個 `plugins/<name>/` 都有 `plugin.json` | 缺了只影響 agy 的單獨安裝，故僅警告 |
| entry 的 `source` 指向存在的目錄 | 打錯路徑不會報錯，只會裝到空的 plugin |
| 每個 skill 都有 entry | 新增 skill 卻沒發佈，使用者裝不到 |
| `claude plugin validate --strict` | 官方驗證器，權威性高於上面的欄位檢查；`--strict` 連拼錯的欄位名也會擋 |
| `agy plugin validate` | 驗各 plugin 目錄的 plugin.json |

另可用官方 JSON Schema 驗證（本 repo 目前 0 錯）：

```bash
curl -sL -o /tmp/mp.json https://json.schemastore.org/claude-code-marketplace.json
python3 -c "import json,jsonschema;jsonschema.Draft202012Validator(json.load(open('/tmp/mp.json'))).validate(json.load(open('.claude-plugin/marketplace.json')))"
```

> 若寫了 `renames`：它目前不在 schemastore 的 schema 裡（schema 較舊），但因為沒有設 `additionalProperties: false`，仍可通過；`claude plugin validate --strict` 也接受。

---

## 新增一個 skill 要做什麼

1. 建立 `plugins/<name>/skills/<name>/SKILL.md`（結構見 [Agent Skills 開發目標指南](./skills-development-guide.md)）
2. 建立 `plugins/<name>/plugin.json`（`name` 與 `description` 兩個欄位即可，供 agy 單獨安裝）
3. 在 `.claude-plugin/marketplace.json` 的 `plugins` 加一個 entry：`name` 用該 skill 名，`source` 指向 `./plugins/<name>`
4. 在根 `README.md` 的 Skills 表格加一列
5. `make validate` 確認佈局不變式與 entry 覆蓋都過
6. commit 並 push——Claude Code 以 commit SHA 判版，沒進 default branch 就發佈不出去

---

## 安裝工具怎麼對應這個佈局

`make`／`tools/skills.sh` 完全由 manifest 與佈局推導，沒有寫死任何名稱：

| 推導項目 | 來源 |
|---------|------|
| marketplace 名 | `.name` |
| 各 plugin 名 | `.plugins[].name` |
| 已下架的舊 plugin | `.renames` 的 key |
| GitHub 來源 | 各 entry 第一個非 null 的 `.repository` |
| skill 清單 | `plugins/*/` 底下有 `skills/<name>/SKILL.md` 者 |
| 選單裡的描述 | 各 entry 的 `.description` |

所以**改 manifest 就等於改工具行為**，不需要同步改腳本。`install` 與 `remove` 會跳 agent × skill 矩陣（終端畫不下時退回只挑 skill 的選單），`update` 不跳選單、只更新已安裝的。

## 相關文件

- 要改安裝工具的行為、或安裝失敗要排查時 → [tools/README.md](../tools/README.md)
- 要設計或改寫某個 `SKILL.md` 時 → [Agent Skills 開發目標指南](./skills-development-guide.md)

外部規格：

- 要建立或發佈另一個 marketplace 時 → [Claude Code：建立與發佈 plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces)
- 要查證 plugin manifest 的欄位語意時 → [Claude Code：Plugins reference](https://code.claude.com/docs/en/plugins-reference)
- 要確認 `SKILL.md` 的通用格式時 → [Agent Skills Specification](https://agentskills.io/specification)
