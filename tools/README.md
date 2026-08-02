# tools/

> **版本**：4.1.0｜**更新日期**：2026-08-01

把本 repo 的 skills 安裝到各 AI agent。每個 skill 各自是一個 plugin，`install` 與 `remove` 會跳選單讓你挑；每個 agent 的安裝方式則是固定的，並在安裝前偵測另一種機制的殘留以免重複載入。

manifest 本身的設計見 [Marketplace 設定指南](../docs/marketplace-guide.md)。

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

預設從 manifest 各 entry 中第一個非 null 的 `repository` 推導出 GitHub HTTPS URL，不寫死在腳本裡。**用 HTTPS URL 而非 `owner/repo` 簡寫**：簡寫在 Claude Code 預設走 SSH clone，沒有金鑰的使用者會直接失敗（要另設 `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`）；HTTPS URL 兩家都收，也不依賴使用者的 SSH 設定。

> **開發時裝工作目錄的內容**：`SOURCE=$PWD tools/skills.sh install`。預設來源是 GitHub，改了工作目錄的檔案不會反映到 claude／codex，必須 commit 並 push 才拿得到。

### manifest 的幾個選擇

- **佈局是 `plugins/<name>/skills/<name>/`**：`source` 指向 `./plugins/<name>`，plugin root 底下就是合格的 `skills/`，所以**不需要 `skills` 欄位**。這樣各 agent 的快取只含該 plugin 的內容（實測 508K → 64K），不是整個 repo 複製 N 份。
- **每個 skill 都必須有自己的 entry**：**新增 skill 一定要同步加一個 entry**，否則使用者裝不到。`make validate` 雙向檢查（skill 沒 entry、entry 的 source 不存在，都會擋）。
- **每個 plugin 目錄自帶 `plugin.json`**：讓 agy 可以 `agy plugin install ./plugins/<name>` 單獨安裝——舊佈局做不到，當時 agy 只認 repo 根目錄那份，一裝就是全部。
- **不設 `version`**：省略時 Claude／Codex 以 git commit SHA 判定更新，push 完使用者 `update` 就拿得到；設了則會釘住版本字串，每次發布都要記得 bump。本 repo 的版本記在各 skill 的 README，不另立 plugin 層版本。
- **不設 `strict`（留預設 `true`）**：官方文件與 schemastore 對這個欄位的描述不一致——前者說「`plugin.json` 為權威，marketplace entry 可補充、兩者合併，manifest 本身可省略」，後者說「要求 plugin 目錄必須有 manifest」。本 repo 沒有 `.claude-plugin/plugin.json`，實測預設值下 4 個 skill 全數載入，以實作行為為準。
  > **DECISION**：曾評估寫成 `strict: false`（語意上更貼近「entry 即完整定義」），實測也可用，但 `false` 的代價是——日後若有人在 repo 補上 `.claude-plugin/plugin.json` 且其中宣告了元件，會直接判定衝突、plugin 載入失敗。相較之下留預設只在「Claude Code 改採 schemastore 那套描述」時才會出事，機率低得多，故不寫。
- **不必為 Codex 另備 manifest**：Codex 的 plugin manifest 位置是 `.codex-plugin/plugin.json`，但缺少時它會依 marketplace entry 自動生成一份放進快取（`~/.codex/plugins/cache/<marketplace>/<plugin>/`），無需在 repo 內自備。

### opencode 的跨 agent 重複

opencode 的全域 skills 來源有三處：`~/.config/opencode/skills/`、`~/.claude/skills/`、`~/.agents/skills/`（專案內另看 `.opencode/`、`.claude/`、`.agents/` 下的 `skills/`）。**它會吃到 claude 目錄下的東西**，是唯一的跨 agent 重複來源。

因此 `install opencode` 前多一道守衛：偵測 `~/.claude/skills/`、`~/.agents/skills/` 是否已有本 repo 的 skill，有就中止——那批 skill 早就載入了，再裝一次只會重複。`FORCE=1` 可略過並留下警告。點名 opencode 時擋下並回 rc=1；被全體掃到時只印略過、不計失敗。

`status` 也因此多一列 `共用／已掃到`，標出它實際從哪些別人的目錄載到 skill。

## 互動選單

`install` 與 `remove` 會跳**兩段**選單——先挑要處理哪幾家 agent，再挑哪幾個 skill。兩段共用同一組實作（`pick_list`／`pick_tui`／`pick_prompt`），只是餵入的清單與描述函式不同。

```
要安裝哪些 agent：↑↓ 移動．空白 勾選．a 全選／全不選．Enter 確認．q 取消

❯ [x] claude    marketplace  https://github.com/marshung24/ai-agent-skills.git
  [x] codex     marketplace  https://github.com/marshung24/ai-agent-skills.git
  [ ] agy       copy         ~/.gemini/skills
  [ ] opencode  copy         ~/.config/opencode/skills
```

接著是 skill 那段：

```
可安裝的 skill：↑↓ 移動．空白 勾選．a 全選／全不選．Enter 確認．q 取消

❯ [x] mh-agent-skills-builder  協助建立、修改和優化 Agent Skills，含設計方法論…
  [x] mh-code-review           程式碼審查（自我 review／PR review），依風險優…
  [ ] mh-external-advisor      外部 AI 顧問：非互動諮詢另一支 AI CLI（第二意見…
  [x] mh-humanizer-zh-tw       台灣正體 AI 寫作去痕：24 種核心模式＋5 種台灣補…
```

**跳過條件**：在目標後加 `-<agent>`（如 `make install-claude`）跳過 agent 那段；指定 `SKILLS` 跳過 skill 那段；兩者都給就完全不跳。`update` 兩段都不跳——更新本來就該全做。

| 按鍵 | 行為 |
|------|------|
| `↑` `↓`（或 `k` `j`） | 移動 |
| `空白` | 勾選／取消該項 |
| `a` | 有任何未勾選就全選，否則全不選 |
| `Enter` | 確認；一個都沒選視同取消 |
| `q`／`Esc`／`Ctrl-C` | 取消，不動任何東西 |

預設全部勾選——最常見的意圖就是「全部」，Enter 直接過。skill 描述取自 manifest，不另寫一份。

> **DECISION**：不引入 `fzf`／`whiptail`／`dialog`。本 repo 目前只依賴 `jq` 與 `rsync`，為了一個選單多一個必裝的外部程式並不划算；純 bash + `tput` 自足且行為可控。代價是要自己處理游標與重畫——選單靠「游標上移 N 行再重畫」更新，任何一行折行都會讓行數對不上而畫壞，故每列都以 `fit()` 依**顯示寬度**截斷（CJK 算 2 欄，與 `pad()` 同一套判準）。中斷時以 `trap` 還原游標，避免使用者的終端一直看不到游標。

### 兩層退路

| 情境 | 行為 |
|------|------|
| 互動終端且 `tput` 可用 | checkbox 選單 |
| `TERM=dumb`、非 xterm 相容、或無 `tput` | 退回**編號輸入版**（`1,3` 或 `2 4`／`a`／`q`），仍可挑 |
| 非互動（CI、pipe、`< /dev/null`） | 不跳選單，視為全部 |

最後一層是關鍵：判準是 `[ -t 0 ]` 且 `/dev/tty` 可讀，缺一即視為全部——少了這道判斷，`make install < /dev/null` 會停在 `read` 等一個永遠不會來的輸入，把自動化流程弄壞。指定 `SKILLS` 時也不會多問一次。

> `update` 刻意不跳選單：「把裝著的都更新到最新」本來就是它唯一合理的意圖，未安裝者本就會被略過。

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
make install         # 四家；跳選單挑要裝哪些 skill
make remove          # 同樣會跳選單
make install SKILLS="mh-code-review mh-humanizer-zh-tw"   # 直接指定，略過選單
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
| `SKILLS` | 互動選單 | 只處理指定的 skill（空白分隔），略過選單；名稱拼錯回 rc=2。只影響 `install`／`remove`（以及 claude 與 copy 模式的逐項 `update`）——codex 的 `update` 只能整份刷新 marketplace 快照，沒有單一 plugin 的更新能力 |
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
- **`remove` 在本 repo 的 plugin 全數移除後才註銷 marketplace**：只移除其中幾個時會保留註冊，否則其餘還裝著的 plugin 會一起失效。若仍有已下架的舊 plugin 裝著也會保留——實測 `claude plugin marketplace remove` 會連帶移除該 marketplace 底下已安裝的 plugin。
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
| 未知 agent／子命令／skill 名 | rc=2 |
| 兩段選單串接（以 PTY 實測） | agent 段選 claude+codex、skill 段選一個，實際安裝結果相符；點名 agent 時正確跳過第一段 |
| checkbox 選單（以 PTY 實測） | ↑↓ 與 k/j 移動、空白勾選、`a` 全選／全不選、Enter、`q`／`Esc` 取消、全不選視同取消，皆正確；取消後確認未安裝任何東西 |
| 編號輸入版（`TERM=dumb`） | 正確退回，空白與逗號分隔、越界與非數字重問皆正確 |
| 非互動（`< /dev/null`、pipe） | 不跳選單、不卡住，視為全部 |

其他：

- **`make validate`**：另跑 `claude plugin validate --strict` 與逐 plugin 的 `agy plugin validate`，全過。另實測「`plugins/<name>/` 缺 `skills/<name>/SKILL.md`」會正確擋下並回 rc=1。
- **新佈局**：三家實測 `source: "./plugins/<name>"` 皆可載入（claude `Skills (1)`、codex 執行期看得到、agy `components: ["skills"]`）；快取由 508K 降為 56–72K。另實測「skills/ 下有目錄缺 SKILL.md」與「entry 路徑指向非 skill 目錄」皆正確擋下並回 rc=1。
- **manifest 本身**：`.claude-plugin/marketplace.json` 以官方 JSON Schema（`json.schemastore.org/claude-code-marketplace.json`）驗證無誤，`claude plugin validate --strict` 亦通過；Claude Code 實裝後 `claude plugin details` 列出 4 個 skill，Codex 移除並重加 marketplace 後仍正常解析。
- **agy 的 skills 目錄**：以兩個標記 skill 分別放進 `~/.gemini/skills` 與 `~/.gemini/antigravity-cli/skills`，再問 agy 看得到哪些——**兩處都載得到**。本工具用前者。

> agy 的 `plugin validate` 只認**根目錄**的 `plugin.json`，對只有 `.claude-plugin/plugin.json` 的 repo（例如 mattpocock/skills）會回報 `missing plugin.json`。這是 agy 的結構要求，不是 manifest 有問題。
>
> **GitHub 來源尚未實裝成功**：`.claude-plugin/`、`plugin.json`、`tools/`、`Makefile` 目前都還沒進 main，從 GitHub 裝會拿到 `marketplace root does not contain a supported manifest`（codex）／`Marketplace file not found`（claude）。兩家的 clone 本身都成功，代表來源形式沒問題，缺的只是 push。這批進 main 後需重跑一次 `install` 驗證。
