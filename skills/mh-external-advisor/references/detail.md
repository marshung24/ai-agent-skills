# mh-external-advisor 細節

## 輸出契約

四支腳本對呼叫端暴露一致介面（內部實作各異；agy 與「id 缺失」為明示例外）：

| 項目 | 內容 |
|------|------|
| stdout | AI 回覆純文字；成功且取得 id 時最後一行為 `[External Advisor <AI名> session_id: <id>]`（AI 名＝codex/claude/opencode/agy），未取得 id 時該行缺席（stderr 印 `[warn]`） |
| stderr | 警告／錯誤（含失敗時的 CLI stderr 末幾行，供診斷） |
| exit 0 | 成功 |
| exit 2 | 參數錯誤（缺 prompt、`-r` 的 id 為空字串等——空 id 常見於上一輪擷取失敗，若放行會靜默開新重送，故必擋） |
| exit 3 | resume 失敗。涵蓋範圍：codex/claude/opencode＝resume 路徑上 CLI 任何非零結束（含 id 失效與暫時性錯誤，看 stderr 區分）；agy＝僅「id 不存在」（前置檢查）。**有效但屬別段的 id 皆無法偵測**，會靜默接錯脈絡（防範靠呼叫端簿記，見 SKILL.md 多段對話規則） |
| exit 1 | 執行失敗且無回覆 |
| exit 127 | 缺依賴（CLI 未安裝或缺 `jq`；opencode 另含「偵測不到免互動旗標」——旗標名版本相依，見底層指令節） |

- 成功但未取得 id 時：stdout 無 `[External Advisor ...]` 行，stderr 印 `[warn] 未取得 ...，本段對話無法延續`——呼叫端據此得知不可延續。警語內文各腳本依其 id 名稱而異（thread_id / session_id / conversation id），判斷一律認 `[warn]` 前綴，勿比對全文。

擷取 id 範例：

```bash
err=$(mktemp)
out=$(scripts/ask-codex.sh "問題" 2>"$err")
rc=$?
# 先 tail -n1 只看最後一行再比對——回覆內容本身可能引用同格式字樣（如請顧問
# review 本 skill 時），逐行比對會誤抓出多筆
id=$(printf '%s' "$out" | tail -n1 | sed -n 's/^\[External Advisor .* session_id: \(.*\)\]$/\1/p')
# 有效 id 的判準是三者同時成立：rc=0、stderr 無 [warn]、末行比對有值——
# 缺 [warn] 檢查時，「id 缺席且回覆末行剛好是同格式字樣」會誤抓假 id 去 resume
grep -q '^\[warn\]' "$err" && id=""
[ "$rc" -eq 0 ] && [ -n "$id" ] && scripts/ask-codex.sh -r "$id" "追問"
rm -f "$err"
```

## 參數

```
ask-codex.sh    [-r <thread_id>]       [--] "<prompt>"
ask-claude.sh   [-r <session_id>]      [--] "<prompt>"
ask-opencode.sh [-r <session_id>]      [--] "<prompt>"
ask-agy.sh      [-r <conversation_id>] [--] "<prompt>"
```

- `-r <id>`：延續指定對話；省略則開新
- `<prompt>`：命令列參數優先；無參數時僅在 stdin 非 TTY 才讀（互動誤用不會掛住）
- **prompt 以 `-` 開頭時必加 `--`**（結束腳本自身的選項解析，四支皆適用）：`ask-codex.sh -- "-r 是什麼？"`；走 stdin 則無此問題
- **agy 特例**：headless 不印 id 且不認自產 UUID，id 由「磁碟偵測」取得——主路徑查 `~/.gemini/antigravity-cli/cache/last_conversations.json`（cwd → 最後 conversation id 對照表）並以 `brain/<id>` mtime 驗證，fallback 掃 `brain/` 新增目錄；`-r` 的 id 先驗 brain 目錄存在，不存在即 exit 3（agy 對無效 id 會靜默開新，無法靠結束碼偵測）。儲存位置為版本相依實作細節，agy 升版後需重驗。

## resume 失敗行為

帶 `-r <id>` 但延續失敗（id 失效等）時，腳本 **exit 3 並停止，不自動改開新對話重送**。呼叫端應先看 stderr：若是暫時性錯誤（網路/CLI 問題），同 id 重試即可、別急著放棄該段；確認 id 確實失效且 prompt 無重複執行疑慮後，再不帶 `-r` 重送開新。

**agy 例外**（同 exit code 表）：agy 只有「前置檢查發現 id 不存在」才 exit 3；通過前置檢查後的執行失敗一律 exit 1，且 brain 目錄存在只證明本地資料在，無法完全排除底層靜默開新——agy 的 resume 保證比其他三支弱。

## 底層指令

| | 開新 | 延續 | 回覆欄位 | id 欄位 |
|---|---|---|---|---|
| codex | `codex exec --json … -` | `codex exec resume --json … <id> -` | `item.completed` 事件 `.item.text`（type=agent_message，取最後一則） | `thread.started` 事件 `.thread_id` |
| claude | `claude -p --output-format json …` | 加 `--resume <id>` | `.result` | `.session_id` |
| opencode | `opencode run <免互動旗標> --format json … -- "<prompt>"` | 加 `--session <id>` | `text` 事件 `.part.text`（依序串接） | 任一事件頂層 `.sessionID` |
| agy | `agy --dangerously-skip-permissions -p "<prompt>"` | 加 `--conversation <id>`（置於 `-p` 前） | stdout 純文字（無 JSON） | 磁碟偵測 `brain/` 新增目錄名 |

- codex/claude 的 prompt 走 stdin（codex 用 `-`），免長字串／特殊字元的引號轉義；opencode 的 `run` 以引數收 prompt，前置 `--` 分隔符防止以 `-` 開頭的 prompt 被誤解析為旗標；agy 的 `-p` 是**吃值旗標**（prompt 即其值），必須排在其他旗標之後、prompt 緊跟其後
- opencode 的 `<免互動旗標>` 由 `run --help` 動態偵測（舊名 `--dangerously-skip-permissions` 優先、次選 `--auto`，皆無則 exit 127）——旗標名版本相依且未知旗標不報錯，hardcode 會在升版後靜默失效，理由見設計取捨
- NDJSON 一律 slurp 整檔後在 jq 內取值（多行文字安全；**不可**對 jq 輸出行用 `tail`/`head` 取「最後一則」，會截斷多行回覆）
- NDJSON 逐行以 `fromjson? // empty` 容錯（會夾雜非 JSON 警告行）

## 背景執行與並行

- 免等待可用背景執行，但**每個呼叫的輸出必須獨立回收**（各自導向獨立檔案逐一解析，不可混流）——多個背景輸出交錯會讓 id 對應錯亂
- **agy 開新勿並行**：其 id 靠共用磁碟狀態偵測——主路徑以 cwd 查表，但 fallback 掃整個 `brain/`，故**同一使用者（同 state 目錄）下任何並行開新**都可能錯配，不限同 cwd；並行需求用 codex/claude/opencode（id 從各自行程輸出擷取，並行安全）

## 設計取捨（DECISION）

- **明確 id 而非 `--last`／`--continue`**：`--last` 只取「當前 cwd 最新一段」，多任務交錯或換目錄會誤接到無關 session；明確 id 天然綁定「這個任務」，且不受 cwd 影響。
- **stateless、不存 pointer 檔**：id 由呼叫端保存在自身對話脈絡。副作用是 `/clear` 後 id 自然遺失 → 免 hook／環境變數即達成「session 隨 Claude session 生命週期」。
- **resume 失敗不自動重送**（Codex review 指出）：prompt 可能含副作用指示，自動 fallback 開新重送有重複執行風險；exit 3 交由呼叫端決定。
- **保留免互動核可旗標**（codex/claude/agy 為 `--dangerously-*`；opencode 為版本相依，腳本以 `--help` 動態偵測公開旗標名——1.17.10 為 `--dangerously-skip-permissions`，約 1.17.12 起更名 `--auto`、舊名轉 hidden 相容別名）：本 workspace 定位為外部沙箱環境，諮詢型呼叫需免互動核可才能自動化；此 skill 若移作他用需重新評估。注意 opencode 對未知旗標不報錯（非嚴格解析），hidden 別名被上游移除時會靜默失去免互動核可——這是動態偵測而非 hardcode 的原因。
- **claude 用 `--output-format json` 而非 `stream-json`**：同步 wrapper 只需等最終結果、無 idle timeout 顧慮，單一 JSON 物件解析更簡單。

## 疑難排解

| 症狀 | 檢查 |
|------|------|
| exit 127 | 對應 CLI 或 `jq` 未安裝／不在 PATH；opencode 另可能是免互動旗標偵測失敗（升版更名），以 `opencode run --help` 確認 |
| exit 3 | 看 stderr 區分：暫時性錯誤 → 同 id 重試；id 確實失效 → 確認無重複執行疑慮後不帶 `-r` 重送 |
| 無回覆、exit 1 | 看 stderr 印的 CLI stderr／stdout 末段；確認 CLI 已登入 |
| resume 沒記得前文 | 確認帶的 `-r <id>` 是上一次輸出末行那個 id |
| resume 接到不相干脈絡 | 用了「有效但屬別段」的 id（script 偵測不到）；不確定歸屬就別延續，開新並附齊背景 |
| stdout 沒有 session_id 行 | 見 stderr 的 `[warn]`——本段對話無法延續 |
| 長時間無輸出（掛住） | 底層 CLI 網路停滯或卡死；wrapper 無 timeout，逾時由呼叫端管理。強殺後注意：prompt 可能已部分執行、id 未回收——重送前依「resume 失敗行為」的重複執行判準評估 |
