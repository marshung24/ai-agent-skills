# tools/

> **版本**：2.0.0｜**更新日期**：2026-07-31

把本 repo 的 skills 安裝到各 AI agent。每個 agent 的安裝方式是固定的，並在安裝前偵測另一種機制的殘留以免重複載入。

## 安裝方式（per-agent 固定，沒有選項）

| Agent | 方式 | 讀哪份 manifest／裝到哪 | 來源型態 |
|-------|------|------------------------|---------|
| Claude Code | `marketplace` | `.claude-plugin/marketplace.json` | 本機路徑、`owner/repo`、Git URL |
| Codex CLI | `marketplace` | 同一份 manifest | 本機路徑、`owner/repo[@ref]`、Git URL |
| Antigravity（agy） | `copy` | `~/.gemini/skills/` | — |
| opencode | `copy` | `${XDG_CONFIG_HOME:-~/.config}/opencode/skills/` | — |

**為什麼這樣切**：

- **claude／codex 走 marketplace** — 兩家吃同一份 manifest，而且能直接吃 Git URL，安裝與更新都交給各家 CLI 處理，是真正可發佈給別人的途徑。
- **agy 走 copy** — 它的 plugin 機制**是可用的**（實測 `agy plugin install <目錄>` 會匯入 skills），但只收本機目錄、不吃 Git URL，也無法用 manifest 發佈 catalog（那組 marketplace 來源註冊在 CLI 內部）。走 plugin 換不到任何 copy 沒有的好處，卻多一層要維護的狀態，所以本工具對 agy 只走 copy。
- **opencode 走 copy** — 它沒得選：opencode 的 plugin 是 JS/TS 模組（掛 hook、加 tool），不承載 skills。skills 一律靠目錄掃描。

因為每個 agent 只有一種方式，**沒有 `METHOD` 這個變數**。

### marketplace 來源

預設從 manifest 的 `plugins[0].repository` 推導出 GitHub HTTPS URL，不寫死在腳本裡。**用 HTTPS URL 而非 `owner/repo` 簡寫**：簡寫在 Claude Code 預設走 SSH clone，沒有金鑰的使用者會直接失敗（要另設 `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`）；HTTPS URL 兩家都收，也不依賴使用者的 SSH 設定。

> **開發時裝工作目錄的內容**：`SOURCE=$PWD tools/skills.sh install`。預設來源是 GitHub，改了工作目錄的檔案不會反映到 claude／codex，必須 commit 並 push 才拿得到。

### manifest 的幾個選擇

- **skills 不需列舉**：claude／codex 都預設掃描 `source` 底下的 `skills/`，每個含 `SKILL.md` 的子目錄即一個 skill。新增 skill 不必改 manifest。
- **不設 `version`**：省略時 Claude／Codex 以 git commit SHA 判定更新，push 完使用者 `update` 就拿得到；設了則會釘住版本字串，每次發布都要記得 bump。本 repo 的版本記在各 skill 的 README，不另立 plugin 層版本。
- **不設 `strict`（留預設 `true`）**：官方文件與 schemastore 對這個欄位的描述不一致——前者說「`plugin.json` 為權威，marketplace entry 可補充、兩者合併，manifest 本身可省略」，後者說「要求 plugin 目錄必須有 manifest」。本 repo 沒有 `.claude-plugin/plugin.json`，實測預設值下 4 個 skill 全數載入，以實作行為為準。
  > **DECISION**：曾評估寫成 `strict: false`（語意上更貼近「entry 即完整定義」），實測也可用，但 `false` 的代價是——日後若有人在 repo 補上 `.claude-plugin/plugin.json` 且其中宣告了元件，會直接判定衝突、plugin 載入失敗。相較之下留預設只在「Claude Code 改採 schemastore 那套描述」時才會出事，機率低得多，故不寫。
- **不必為 Codex 另備 manifest**：Codex 的 plugin manifest 位置是 `.codex-plugin/plugin.json`，但缺少時它會依 marketplace entry 自動生成一份放進快取（`~/.codex/plugins/cache/<marketplace>/<plugin>/`），無需在 repo 內自備。

### opencode 的跨 agent 重複

opencode 的全域 skills 來源有三處：`~/.config/opencode/skills/`、`~/.claude/skills/`、`~/.agents/skills/`（專案內另看 `.opencode/`、`.claude/`、`.agents/` 下的 `skills/`）。**它會吃到 claude 目錄下的東西**，是唯一的跨 agent 重複來源。

因此 `install opencode` 前多一道守衛：偵測 `~/.claude/skills/`、`~/.agents/skills/` 是否已有本 repo 的 skill，有就中止——那批 skill 早就載入了，再裝一次只會重複。`FORCE=1` 可略過並留下警告。點名 opencode 時擋下並回 rc=1；被全體掃到時只印略過、不計失敗。

`status` 也因此多一列 `共用／已掃到`，標出它實際從哪些別人的目錄載到 skill。

## 遺留偵測

每個 agent 只走一種方式，但**另一種機制的殘留**仍可能存在——舊版工具裝的、手動複製的、從別處裝的。各家都會同時載入 plugin 與自己的 skills 目錄，殘留即重複載入。

- **`install` 前偵測並擋下**：

  ```
  ✗ claude：/home/mars/.claude/skills 已有本 repo 的 skill，中止以免重複載入
      remove 會把兩種機制一起清掉：tools/skills.sh remove claude
      或確定要並存：FORCE=1 ...
  ```

- **`remove` 一律兩邊都清**：marketplace 模式的 agent 連 skills 目錄裡的副本一起刪，agy 連殘留的 plugin 安裝一起移除。
- **`status` 只在真的有東西時才多印一列** `⚠遺留`：正常情況每個 agent 只有一列，出問題時才看得見。

## 用法

```bash
make status          # 各家現況；有殘留才會多列出來
make install         # 四家一次裝對
make install SOURCE=$PWD          # 開發時改裝工作目錄的內容
make install-claude               # 單一 agent：install|remove|update|status -<agent>
make remove
make update
make validate        # 離線驗證，不需註冊
```

或直接呼叫：

```bash
tools/skills.sh <install|remove|update|status|validate> [claude|codex|agy|opencode ...]
```

### 環境變數

| 變數 | 預設 | 說明 |
|------|------|------|
| `SOURCE` | manifest 的 `repository` | 覆寫 marketplace 來源；開發時用 `SOURCE=$PWD` 裝工作目錄的內容 |
| `FORCE` | 空 | `1` ＝略過遺留偵測 |

沒有 `METHOD`——每個 agent 只有一種方式。`SOURCE` 只對 claude／codex 有意義，agy／opencode 走 copy，來源恆為 repo 本身。

## `status` 的狀態碼

copy 方式逐 skill 標示：

| 碼 | 意義 |
|----|------|
| `✓一致` | 實體目錄，內容與 repo 相同 |
| `≠有差異` | 實體目錄，與 repo 不同 |
| `→<目標>` | symlink，附指向 |
| `✗斷鏈` | symlink 指向不存在的目標 |
| 不列出 | 未安裝 |

## 行為約定

- **CLI 未安裝不算失敗**：四家不一定都在用，缺哪家就略過哪家，結束碼仍為 0。真正的失敗（指令非零、被衝突擋下、symlink 受阻）才回 1。
- **成功時吞掉 CLI 輸出**：各家 CLI 的雜訊沒有閱讀價值；失敗時才把該指令的完整輸出縮排印到 stderr 供診斷。
- **copy 模式不寫穿 symlink**：目的地若是 symlink 就略過並報錯——直接 `rsync` 會穿透寫進連結目標（多半是另一個 agent 的副本）。
- **copy 模式只動 repo 有的名稱**：第三方 skill 一律不碰。刪除前另有路徑守衛（兩段路徑非空、basename 須等於 skill 名），避免變數為空時 `rm -rf` 退化成刪整個 skills 目錄。
- **`remove` 連 marketplace 一起註銷**：這個 marketplace 只為本 plugin 存在，留著是殘留設定。
- **`remove` 是冪等的**：claude／codex 對「移除不存在的東西」都回非零，故一律先判斷是否真的裝了；agy 的 uninstall 本身即冪等。乾淨環境跑 `remove` 回 0，不該報錯。
- **`update` 對本機註冊的 codex marketplace 會略過**：判準取自 codex 自己的 `marketplace list --json`（`sourceType`），不是本次的 `SOURCE`——兩者可能不一致（用 `SOURCE=$PWD` 裝好後直接跑 `update`，預設來源是 GitHub）。以 SOURCE 判斷會誤跑 `upgrade`，換來一個「is not configured as a Git marketplace」的誤報失敗。
- **名稱不寫死**：marketplace 名與 plugin 名一律用 `jq` 從 `marketplace.json` 讀取，改名只需改 manifest。

## 已驗證

以隔離的假 `HOME`（含獨立 `CODEX_HOME`）實測，除另註明外皆以 `SOURCE=$PWD` 為來源：

| 情境 | 結果 |
|---|---|
| 乾淨環境 `remove` | rc=0，四家全印略過、無 ✗（冪等） |
| `install` | 四家全 ✔，rc=0 |
| `status`（乾淨） | 每個 agent 各一列，無遺留列 |
| `status`（製造遺留） | claude 多 `copy ⚠遺留`、agy 多 `plugin ⚠遺留`、opencode 多 `共用 已掃到` |
| `remove`（有遺留） | 連 claude 的 copy 副本與 agy 的殘留 plugin 一起清，rc=0 |
| 連續 `remove` | 第二次仍 rc=0 |
| 遺留擋下 `install claude` | rc=1 並給出 remove／FORCE 兩條出路 |
| `FORCE=1` | 放行並留警告 |
| `install opencode`（claude 目錄有東西） | 跨 agent 守衛擋下，rc=1 |
| `update` | rc=0；codex 未註冊時正確略過 |
| 未知 agent／子命令 | rc=2 |

其他：

- **`make validate`**：另跑 `claude plugin validate` 與 `agy plugin validate` 兩家自己的驗證器，五項全過。
- **manifest 本身**：`.claude-plugin/marketplace.json` 以官方 JSON Schema（`json.schemastore.org/claude-code-marketplace.json`）驗證無誤，`claude plugin validate --strict` 亦通過；Claude Code 實裝後 `claude plugin details` 列出 4 個 skill，Codex 移除並重加 marketplace 後仍正常解析。
- **agy 的 skills 目錄**：以兩個標記 skill 分別放進 `~/.gemini/skills` 與 `~/.gemini/antigravity-cli/skills`，再問 agy 看得到哪些——**兩處都載得到**。本工具用前者。

> agy 的 `plugin validate` 只認**根目錄**的 `plugin.json`，對只有 `.claude-plugin/plugin.json` 的 repo（例如 mattpocock/skills）會回報 `missing plugin.json`。這是 agy 的結構要求，不是 manifest 有問題。
>
> **GitHub 來源尚未實裝成功**：`.claude-plugin/`、`plugin.json`、`tools/`、`Makefile` 目前都還沒進 main，從 GitHub 裝會拿到 `marketplace root does not contain a supported manifest`（codex）／`Marketplace file not found`（claude）。兩家的 clone 本身都成功，代表來源形式沒問題，缺的只是 push。這批進 main 後需重跑一次 `install` 驗證。
