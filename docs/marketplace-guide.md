# Marketplace 設定指南

> **版本**：2.1.0｜**更新日期**：2026-08-01

本 repo 如何同時作為 Claude Code／Codex 的 plugin marketplace 發佈，以及各家 agent 的行為差異。所有結論皆為實測所得，升版需重驗。

**適用對象**：要維護本 repo 的 manifest、或想把自己的 skills 集合做成 marketplace 的人。

---

## TL;DR

| 項目 | 內容 |
|------|------|
| **manifest** | `.claude-plugin/marketplace.json`（Claude Code 與 Codex 共用同一份） |
| **粒度** | 一個 skill ＝ 一個 plugin |
| **佈局** | `plugins/<name>/skills/<name>/SKILL.md`，`source` 指向 `./plugins/<name>` |
| **哪幾家吃 marketplace** | 只有 Claude Code 與 Codex；agy 與 opencode 走複製 |
| **驗證** | `make validate`（七項，含 `claude plugin validate --strict`） |

---

## 四家 agent 的機制對照

| Agent | 有 marketplace？ | 讀哪份 manifest | 本 repo 採用 |
|-------|-----------------|----------------|-------------|
| Claude Code | ✅ 完整 | `.claude-plugin/marketplace.json` | marketplace |
| Codex CLI | ✅ 沿用 Claude 格式 | 同上（另接受 `agents/plugins/api_marketplace.json`） | marketplace |
| Antigravity（agy） | ⚠️ 來源註冊在 CLI 內部 | 根目錄 `plugin.json` | copy |
| opencode | ❌ 無 | — | copy |

**agy 的 ⚠️**：它的 binary 內含 marketplace 來源註冊表（install handler／link generator），`plugin install` 也接受 `plugin@marketplace`，但第三方**無法用 manifest 發佈自己的 catalog**。加上它只收本機目錄、不吃 Git URL，走 plugin 換不到複製沒有的好處，因此本 repo 對它只走複製。

**opencode 的 ❌**：它的 plugin 是 JS/TS 模組（掛 hook、加 tool），不承載 skills。skills 一律靠目錄掃描。

---

## manifest 結構

```jsonc
{
  "$schema": "https://json.schemastore.org/claude-code-marketplace.json",
  "name": "marshung24",              // marketplace 識別名，使用者以 <plugin>@<name> 安裝
  "owner": { "name": "...", "url": "..." },
  "description": "...",
  "renames": { "mars-skills": null },  // 已下架的舊 plugin，見「下架與遷移」
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
agy plugin install ./plugins/mh-code-review    # components: ["skills"]，1 processed
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

省略時 Claude Code 以 **git commit SHA** 當版本，push 完使用者 `update` 就拿得到。設了則會釘住該字串，每次發布都要記得 bump，忘記就等於停止發佈。

實測（`SOURCE=$PWD`、只改工作區不 commit）：

```
✔ mars-skills is already at the latest version (61e2d14ce042).   ← 沒更新
# commit 之後
✔ Plugin updated from 61e2d14ce042 to 759b7269d5d8. Restart to apply changes.
```

**開發時要注意**：Claude Code 比的是 commit SHA，未 commit 的改動不會生效。Codex 對本機來源的判準不同（VERSION 欄是 `local`），重跑 `plugin add` 就會覆蓋快取，不必 commit。

### 不設 `strict`

官方文件與 schemastore 對這個欄位的描述**不一致**：

| 來源 | 對預設值 `true` 的描述 |
|------|----------------------|
| 官方文件 | `plugin.json` 為權威，marketplace entry 可補充、兩者合併；**manifest 本身可省略** |
| schemastore | 要求 plugin 目錄**必須有** manifest |

本 repo 沒有 `.claude-plugin/plugin.json`，實測預設值下 skill 全數載入——以實作行為為準。

> **DECISION**：曾評估寫成 `strict: false`（語意上更貼近「entry 即完整定義」），實測也可用，但代價是——日後若有人補上 `.claude-plugin/plugin.json` 且其中宣告了元件，會直接判定衝突、plugin 載入失敗。相較之下留預設只在「Claude Code 改採 schemastore 那套描述」時才會出事，機率低得多，故不寫。

### 用 HTTPS URL 而非 `owner/repo` 簡寫

`owner/repo` 簡寫在 Claude Code **預設走 SSH clone**，沒有 SSH 金鑰的使用者會直接失敗（需另設 `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`）。完整 HTTPS URL 兩家都收，也不依賴使用者的 SSH 設定，因此 README 與工具一律用它。

---

## 下架與遷移

移除一個 entry 不會讓使用者機器上的安裝自動消失。兩家行為不同，**codex 那側是隱形陷阱**：

| | 移除 entry 後 |
|---|---|
| **Claude Code** | 支援 `renames`。`plugin list` 仍列出，但標註 `Note: Removed from the "<marketplace>" marketplace`；`plugin details` 查不到；`plugin uninstall` 可正常移除 |
| **Codex** | **不認識 `renames`**。`plugin list` 直接看不到它，但 `config.toml` 仍有 `enabled = true`、快取還在，**執行期照樣載入全部 skill**。`plugin remove` 仍可移除 |

所以 manifest 保留：

```json
"renames": { "mars-skills": null }
```

`null` 表示該 plugin 已移除。Claude Code 會據此給提示；Codex 忽略這個未知欄位（實測不影響解析）。

`tools/skills.sh` 也以此為單一事實來源：從 `renames` 的 key 取得「已下架但可能還裝著」的名單，並且

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
| `agy plugin validate` | 驗根目錄 plugin.json |

另可用官方 JSON Schema 驗證（本 repo 目前 0 錯）：

```bash
curl -sL -o /tmp/mp.json https://json.schemastore.org/claude-code-marketplace.json
python3 -c "import json,jsonschema;jsonschema.Draft202012Validator(json.load(open('/tmp/mp.json'))).validate(json.load(open('.claude-plugin/marketplace.json')))"
```

> `renames` 目前不在 schemastore 的 schema 裡（schema 較舊），但因為它沒有設 `additionalProperties: false`，仍可通過；`claude plugin validate --strict` 也接受。

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

所以**改 manifest 就等於改工具行為**，不需要同步改腳本。`install` 與 `remove` 會跳兩段選單（先挑 agent、再挑 skill），`update` 則一律全做。

## 相關文件

- [tools/README.md](../tools/README.md) — 安裝工具的行為與設計
- [Agent Skills 開發目標指南](./skills-development-guide.md) — skill 本身怎麼寫
- [Claude Code：建立與發佈 plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces)
- [Claude Code：Plugins reference](https://code.claude.com/docs/en/plugins-reference)
- [Agent Skills Specification](https://agentskills.io/specification)
