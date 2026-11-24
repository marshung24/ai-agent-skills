# tools/

> **版本**：6.0.0｜**更新日期**：2026-11-24

把本 repo 的 skills 安裝到各 AI agent。每個 skill 各自是一個 plugin，`install` 與 `remove` 會跳選單讓你挑；每個 agent 的安裝方式則是固定的，並在安裝前偵測另一種機制的殘留以免重複載入。

只有要改 manifest、plugin 佈局、欄位取捨或下架 plugin 時，才需要讀 [Marketplace 設定指南](../docs/marketplace-guide.md)——本檔只講工具怎麼用這份 manifest，不重述它的設計理由。

## 安裝方式（per-agent 固定，沒有選項）

| Agent | 方式 | 讀哪份 manifest／裝到哪 | 來源型態 |
|-------|------|------------------------|---------|
| Claude Code | `marketplace` | `.claude-plugin/marketplace.json` | 本機路徑、`owner/repo`、Git URL |
| Codex CLI | `marketplace` | 同一份 manifest | 本機路徑、`owner/repo[@ref]`、Git URL |
| Antigravity（agy） | `plugin` | 各 plugin 目錄的 `plugin.json`；裝到 `~/.gemini/config/plugins/` | 本機路徑、`owner/repo`、GitHub URL |
| opencode | `copy` | `${XDG_CONFIG_HOME:-~/.config}/opencode/skills/` | — |

**為什麼這樣切**：

- **claude／codex 走 marketplace** — 兩家吃同一份 manifest，能註冊本 repo 為 marketplace，安裝與更新都交給各家 CLI 處理。
- **agy 走 plugin** — 它不能註冊第三方 marketplace，但 `agy plugin install` 收本機目錄與 GitHub 子目錄 URL，可逐 skill 安裝。GitHub 來源固定取 `main` 分支；它沒有 `plugin update`，更新就是重裝（會取代舊內容）。安裝、更新、移除與執行期載入皆已實測（1.5.15）。
- **opencode 走 copy** — 它的 plugin 是 JS/TS 套件，不吃本 repo 的 manifest；設定檔的 `skills` 可指向 HTTP 目錄，但要另外維護 `index.json`。

因為每個 agent 只有一種方式，**沒有 `METHOD` 這個變數**。

### marketplace 來源

預設從 manifest 各 entry 中第一個非 null 的 `repository` 推導出 GitHub HTTPS URL，不寫死在腳本裡。**用 HTTPS URL 而非 `owner/repo` 簡寫**：簡寫在 Claude Code 會先試 SSH、不通才改 HTTPS，走哪條隨使用者的 SSH 設定而變；HTTPS URL 兩家都收，行為固定。

> **開發時裝工作目錄的內容**：`SOURCE=$PWD tools/skills.sh install`。預設來源是 GitHub，改了工作目錄的檔案不會反映到 claude／codex／agy，必須 commit 並 push 才拿得到。

### manifest 的幾個選擇

- **佈局是 `plugins/<name>/skills/<name>/`**：`source` 指向 `./plugins/<name>`，plugin root 底下就是合格的 `skills/`，所以**不需要 `skills` 欄位**。這樣各 agent 的快取只含該 plugin 的內容（實測 508K → 64K），不是整個 repo 複製 N 份。
- **每個 skill 都必須有自己的 entry**：**新增 skill 一定要同步加一個 entry**，否則使用者裝不到。`make validate` 雙向檢查（skill 沒 entry、entry 的 source 不存在，都會擋）。
- **每個 plugin 目錄自帶 `plugin.json`**：讓 agy 可以用 `agy plugin install` 單獨安裝（本機 `./plugins/<name>` 或 GitHub 子目錄 URL）——舊佈局做不到，當時 agy 只認 repo 根目錄那份，一裝就是全部。
- **不設 `version`**：省略時 Claude 以 git commit SHA 判定更新、Codex 一律顯示 `local`，兩家都是 push 完使用者 `update` 就拿得到；設了則會釘住版本字串，每次發布都要記得 bump。本 repo 的版本記在各 skill 的 README，不另立 plugin 層版本。
- **不設 `strict`（留預設 `true`）**：官方文件與 schemastore 對這個欄位的描述不一致——前者說「`plugin.json` 為權威，marketplace entry 可補充、兩者合併，manifest 本身可省略」，後者說「要求 plugin 目錄必須有 manifest」。本 repo 沒有 `.claude-plugin/plugin.json`，實測預設值下 skill 全數載入，以實作行為為準。
  > **DECISION**：曾評估寫成 `strict: false`（語意上更貼近「entry 即完整定義」），實測也可用，但 `false` 的代價是——日後若有人在 repo 補上 `.claude-plugin/plugin.json` 且其中宣告了元件，會直接判定衝突、plugin 載入失敗。相較之下留預設只在「Claude Code 改採 schemastore 那套描述」時才會出事，機率低得多，故不寫。
- **不必為 Codex 另備 manifest**：Codex 的 plugin manifest 位置是 `.codex-plugin/plugin.json`，但缺少時它會依 marketplace entry 自動生成一份放進快取（`~/.codex/plugins/cache/<marketplace>/<plugin>/`），無需在 repo 內自備。

### 共用目錄的同名衝突

opencode 的全域 skills 來源有三處：`~/.config/opencode/skills/`、`~/.claude/skills/`、`~/.agents/skills/`（專案內另看 `.opencode/`、`.claude/`、`.agents/` 下的 `skills/`）。同名 skill 只載入一份，`~/.config/opencode/skills/` 優先，另外兩處的會被遮蔽。

codex 除自己的 `skills/` 外也掃 `~/.agents/skills/`，同名時與 plugin 版**並存**（plugin 版名為 `<plugin>:<skill>`）。

本工具不會裝到這些共用目錄，那裡的同名 skill 只可能是手動放的或別的工具裝的，所以**只提醒、不擋也不刪**：opencode 裝了就以自己的目錄為準；codex 會兩份都載入，`install` 時印一行 `[注意]`。`remove` 後若共用目錄仍有同名，兩家都印 `[注意]`。只看這些全域目錄，不含專案級目錄與設定檔 `skills` 指到的位置。

`status` 會多一列 `共用／已掃到`，標出它實際從哪些共用目錄載到 skill。

## 互動矩陣

`install` 與 `remove` 會跳出 **agent × skill 的二維勾選矩陣**：

```
要安裝哪些（粗體＝目前已裝）
↑↓←→ 移動．空白 切換該格．a 全部／r 整列／c 整欄

                           claude  codex  agy  opencode
❯ mh-agent-skills-builder  [ ]     [ ]    [ ]  [ ]
  mh-code-review           [x]     [ ]    [x]  [ ]
  mh-external-advisor      [ ]     [ ]    [ ]  [ ]
  mh-humanizer-zh-tw       [x]     [ ]    [ ]  [ ]

                           [u 還原]  [Esc 取消]  [Enter 確定]
```

> **DECISION**：安裝狀態本來就是 agent × skill 的二維資料。壓成一維清單就得補上「聚合成幾態」「預設勾選哪個方向」「執行前的差異預覽」等一連串補丁，而且會產生語意矛盾——取消勾選一個已裝的 skill 卻不會移除它。直接畫成格子則全部不需要：**畫面本身就是狀態**，改成什麼就同步成什麼。

**勾選框一律代表「應該裝著」**，兩個指令共用同一個意義，差別只在起始狀態：

| 指令 | 起始 | 直接 Enter 的效果 |
|------|------|------------------|
| `install` | 現況 | 無變化 |
| `remove` | 全空 | 清光全部（可再勾回想留下的） |

因此 `install` 天生就是差異更新：勾起來是裝、取消是移除。

### 按鍵

| 按鍵 | 行為 |
|------|------|
| `↑` `↓` `←` `→`（或 `k` `j` `h` `l`） | 移動游標；四邊皆環繞 |
| `空白` | 切換游標所在的那一格 |
| `a` | 全部：**有任一格未勾就全勾**，否則全不勾 |
| `r` | 整列（該 skill 的所有 agent），判準同上 |
| `c` | 整欄（該 agent 的所有 skill），判準同上 |
| `u` | 還原成進入矩陣時的狀態 |
| `Enter` | 確定 |
| `Esc`（或 `q`、`Ctrl-C`） | 取消，不動任何東西 |

> **DECISION**：還原／取消／確定固定以按鍵觸發，不做成可移動的焦點。焦點只用來指「哪一格」，方向鍵的意義才會單一——不必在格子與按鈕之間切換模式，空白鍵也才能只負責切換單格。畫面下方那一列是按鍵提示，不是可選取的按鈕。

粗體的格子代表**目前已裝**，與勾選狀態分開顯示——所以看得出「這格本來就有」還是「這次才勾的」。

### 執行前的差異

確定後先印出逐 agent 的增減，再實際執行：

```
install（差異更新）
  claude    +mh-agent-skills-builder +mh-external-advisor
  codex     +mh-agent-skills-builder +mh-code-review
  agy       （無變化）
  opencode  -mh-code-review
```

同一個 agent 若同時有增有減，**先移除再安裝**——兩者若同時發生，先清掉舊的可避免中間狀態出現重複載入。

### 退路

| 情境 | 行為 |
|------|------|
| 互動終端且畫得下 | 二維矩陣 |
| 終端太小／`TERM=dumb`／無 `tput` | 退回一維 skill 選單（套用到所有 agent） |
| 非互動（CI、pipe、`< /dev/null`） | 不跳，視為全部 |

判準是 `[ -t 0 ]` 且 `/dev/tty` 可讀，缺一即視為全部——少了這道判斷，`make install < /dev/null` 會停在 `read` 等一個永遠不會來的輸入。

> **`SKILLS=` 維持只加不減**。矩陣產出的是**完整的目標狀態**（每一格都明確勾或不勾），差異更新才有定義；`SKILLS=` 只給了一份正向清單，推導不出「其餘都要移除」。這樣既有腳本的行為完全不變，只有你在矩陣上明確看過全貌時才會發生移除。
>
> `update` 不跳矩陣：「把裝著的都更新到最新」本來就是它唯一合理的意圖，未安裝者本就會被略過。

## 遺留偵測

每個 agent 只走一種方式，但**另一種機制的殘留**仍可能存在——舊版工具裝的、手動複製的、從別處裝的。各家都會同時載入 plugin 與自己的 skills 目錄，殘留即重複載入（agy 1.5.15 實測：plugin 與 `~/.gemini/skills/` 的同名 skill 兩份都列出，且顯示同名）。

- **`install` 前偵測並擋下**：

  ```
  ✗ claude：/home/mars/.claude/skills 已有本 repo 的 skill，中止以免重複載入
      remove 會把殘留一起清掉：tools/skills.sh remove claude
      或確定要並存：FORCE=1 ...
  ```

- **`remove` 一律兩邊都清**：claude／codex／agy 連自己 skills 目錄裡的副本一起刪，互動矩陣也會列出；共用目錄除外，見〈共用目錄的同名衝突〉。
- **`status` 只在真的有東西時才多印一列** `⚠遺留`：正常情況每個 agent 只有一列，出問題時才看得見。

## 用法

```bash
make status          # 各家現況；有殘留才會多列出來
make install         # 跳出 agent × skill 矩陣，逐格勾選
make remove          # 同一個矩陣，起始全空
make install SKILLS="mh-code-review mh-humanizer-zh-tw"   # 略過矩陣，只加不減
make install SOURCE=$PWD          # 開發時改裝工作目錄的內容
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
| `SKILLS` | 互動選單 | 只處理指定的 skill（空白分隔），略過選單；名稱拼錯回 rc=2。只影響 `install`／`remove`（以及 claude、agy 與 copy 模式的逐項 `update`）——codex 的 Git 來源 `update` 例外，`marketplace upgrade` 會整份刷新，連已安裝的快取一起 |
| `SOURCE` | manifest 的 `repository` | 覆寫 marketplace／plugin 來源；開發時用 `SOURCE=$PWD` 裝工作目錄的內容。agy 不記錄來源，用 `SOURCE` 裝的要帶同樣的 `SOURCE` 才會從同一處更新 |
| `FORCE` | 空 | `1` ＝略過遺留偵測 |

沒有 `METHOD`——每個 agent 只有一種方式。`SOURCE` 對 claude／codex／agy 有意義；opencode 走 copy，來源恆為 repo 本身。

## `status` 的狀態碼

plugin 與 copy 方式逐 skill 標示，比對對象是工作目錄：

| 碼 | 意義 |
|----|------|
| `✓一致` | 實體目錄，內容與 repo 相同 |
| `≠有差異` | 實體目錄，與 repo 不同 |
| `→<目標>` | symlink，附指向 |
| `✗斷鏈` | symlink 指向不存在的目標 |
| `✗缺檔` | agy 登記為已安裝，但檔案不在 |
| 不列出 | 未安裝 |

## 行為約定

- **CLI 未安裝不算失敗**：四家不一定都在用，缺哪家就略過哪家，結束碼仍為 0。真正的失敗（指令非零、被衝突擋下、symlink 受阻）才回 1。
- **成功時吞掉 CLI 輸出**：各家 CLI 的雜訊沒有閱讀價值；失敗時才把該指令的完整輸出縮排印到 stderr 供診斷。
- **copy 模式不寫穿 symlink**：目的地若是 symlink 就略過並報錯——直接 `rsync` 會穿透寫進連結目標（多半是另一個 agent 的副本）。
- **copy 模式只動 repo 有的名稱**：第三方 skill 一律不碰。刪除前另有路徑守衛（兩段路徑非空、basename 須等於 skill 名），避免變數為空時 `rm -rf` 退化成刪整個 skills 目錄。
- **`remove` 在本 repo 的 plugin 全數移除後才註銷 marketplace**：只移除其中幾個時會保留註冊，否則其餘還裝著的 plugin 會一起失效。若仍有已下架的舊 plugin 裝著也會保留——實測 `claude plugin marketplace remove` 會連帶移除該 marketplace 底下已安裝的 plugin。
- **`remove` 是冪等的**：claude 對「移除不存在的東西」回非零、codex 與 agy 回 0，故一律先判斷是否真的裝了。乾淨環境跑 `remove` 回 0，不該報錯。
- **`update` 對 codex 分來源處理**：Git 來源跑 `marketplace upgrade`；本機來源不能 upgrade，改為逐一重跑 `plugin add` 覆蓋快取，已停用的略過（`plugin add` 會重新啟用它）。判準取自 codex 自己的 `marketplace list --json`（`sourceType`），不是本次的 `SOURCE`——兩者可能不一致（用 `SOURCE=$PWD` 裝好後直接跑 `update`，預設來源是 GitHub）。以 SOURCE 判斷會誤跑 `upgrade`，換來一個「is not configured as a Git marketplace」的誤報失敗。
- **名稱不寫死**：marketplace 名與 plugin 名一律用 `jq` 從 `marketplace.json` 讀取，改名只需改 manifest。

## 安裝後自檢

`install`／`update` 跑完後，對本次真的裝上或更新到的每個 skill，若 `plugins/<name>/skills/<name>/scripts/post-install-check.sh` 存在且可執行就呼叫一次。

> 讀本節的時機：某個 skill 有「放在使用者家目錄、不隨 skill 一起更新」的設定，而 skill 版本前進後舊設定可能失效。

這是**約定，不是特例**——安裝器不認得任何特定 plugin，只看那個檔在不在，要用的 skill 自己提供。

- **逐 skill 只跑一次**，不隨 agent 數重複：這類設定是 per-user 的，裝到四家 agent 也只有一份。
- **結束碼一律吞掉**，不併入整體結果：安裝本身成功與否，不該由使用者設定的檢查結果決定。
- **`remove` 不跑**：設定留著是刻意的，重裝後還要用。
- **安裝沒成功就不跑**：任一步驟失敗、或每家 agent 都因缺 CLI 被略過時整個跳過——沒裝成任何東西卻改了使用者設定，是使用者無從預期的副作用。守門看的是整體結果，未逐 skill 追蹤成敗：後者要把狀態穿進 `run`／`copy_*`／`marketplace_*` 整條鏈，代價遠大於它擋掉的情境。

目前只有 `mh-external-advisor` 用它，檢查節流設定 `throttle.json` 有沒有已失效的欄位。

## 已驗證

以隔離的假 `HOME`（含獨立 `CODEX_HOME`）實測，除另註明外皆以 `SOURCE=$PWD` 為來源：

| 情境 | 結果 |
|---|---|
| 乾淨環境 `remove` | rc=0，四家全印略過、無 ✗（冪等） |
| `install` | 四家全 ✔，rc=0 |
| `status`（乾淨） | 每個 agent 各一列，無遺留列 |
| `status`（製造遺留） | claude、codex 與 agy 多 `copy ⚠遺留`、opencode 多 `共用 已掃到` |
| `remove`（有遺留） | 連 claude、codex 與 agy 的 copy 副本一起清，rc=0；第三方 skill 不動 |
| 連續 `remove` | 第二次仍 rc=0 |
| 遺留擋下 `install claude` | rc=1 並給出 remove／FORCE 兩條出路 |
| `FORCE=1` | 放行並留警告 |
| `install opencode`（共用目錄有同名 skill） | 照裝，以自己的目錄為準，rc=0 |
| `install codex`（`~/.agents/skills` 有同名 skill） | 全部照裝、印 `[注意]`，rc=0；`remove` 不刪該處、印 `[注意]` |
| 點名的 agent 沒裝 CLI | 略過、rc=0，不跑安裝後自檢 |
| `update` | rc=0；codex 未註冊時正確略過，本機來源會覆蓋快取；agy／opencode 只更新已安裝的 |
| 未知 agent／子命令／skill 名 | rc=2 |
| 二維矩陣（以 PTY 實測） | 起始狀態正確反映現況；`a`／`r`／`c` 在「有未勾」時皆為先全勾；同一 agent 增減並存正確；還原／取消／確定三鈕皆正確（取消後狀態未變） |
| 編號輸入版（`TERM=dumb`） | 正確退回，空白與逗號分隔、越界與非數字重問皆正確 |
| 非互動（`< /dev/null`、pipe） | 不跳選單、不卡住，視為全部 |

其他：

- **`make validate`**：另跑 `claude plugin validate --strict` 與逐 plugin 的 `agy plugin validate`，全過。另實測「`plugins/<name>/` 缺 `skills/<name>/SKILL.md`」會正確擋下並回 rc=1。
- **新佈局**：實測 `source: "./plugins/<name>"` 可用（claude `Skills (1)`、codex 執行期看得到；agy 1.5.15 執行期看得到）；快取由 508K 降為 56–72K。另實測「skills/ 下有目錄缺 SKILL.md」與「entry 路徑指向非 skill 目錄」皆正確擋下並回 rc=1。
- **manifest 本身**：`.claude-plugin/marketplace.json` 以官方 JSON Schema（`json.schemastore.org/claude-code-marketplace.json`）驗證無誤，`claude plugin validate --strict` 亦通過；Claude Code 實裝後 `claude plugin details` 每個 plugin 列出 1 個 skill，Codex 移除並重加 marketplace 後仍正常解析。
- **agy 的 skills 目錄**：以兩個標記 skill 分別放進 `~/.gemini/skills` 與 `~/.gemini/antigravity-cli/skills`，再問 agy 看得到哪些——**兩處都載得到**。本工具只用前者偵測與清除殘留副本。

> agy 的 `plugin validate` 認 plugin 根目錄、`.antigravity-plugin/` 或 `.gemini-plugin/` 內的 `plugin.json`（1.5.15 實測），對只有 `.claude-plugin/plugin.json` 的 repo（例如 mattpocock/skills）會回報 `missing plugin.json`。這是 agy 的結構要求，不是 manifest 有問題。
>
> GitHub 來源：claude、codex、agy 三家都已在無登入憑證的隔離環境實裝成功。
