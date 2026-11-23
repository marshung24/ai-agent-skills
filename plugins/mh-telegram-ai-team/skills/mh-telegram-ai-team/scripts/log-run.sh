#!/usr/bin/env bash
# Telegram 執行紀錄：Claude Code Stop hook，每次祕書處理完一則 Telegram 入站即追加一列 JSONL
#
# 輸入：stdin 為 Stop hook JSON（取 session_id、transcript_path、last_assistant_message）
# 輸出：追加到 ${MH_TG_RUNS_LOG:-~/.local/state/mh-telegram-ai-team/runs.jsonl}，stdout 不輸出
# 紀錄單位：transcript 中最後一則 Telegram 入站之後的所有 assistant 回應（合批時為最後一則的發話者）
# 依賴：jq；額度快照經 quota.sh（需 claude CLI，失敗記 null，不影響其餘欄位）
#
# 用法（只掛在接 Telegram 的 session，見 setup.md〈執行紀錄〉）：
#   "hooks":{"Stop":[{"hooks":[{"type":"command","command":"<本檔絕對路徑>"}]}]}
set -u

LOG="${MH_TG_RUNS_LOG:-$HOME/.local/state/mh-telegram-ai-team/runs.jsonl}"
CHANNEL_MARK='<channel source="plugin:telegram'

input="$(cat)"
transcript="$(jq -r '.transcript_path // empty' <<<"$input")"
session="$(jq -r '.session_id // empty' <<<"$input")"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# 等 transcript 落盤：Stop 時 transcript 可能尚未含最終回應，以 last_assistant_message 結尾比對，最多等 10 秒
last_msg="$(jq -r '.last_assistant_message // empty' <<<"$input")"
complete=null
if [ -n "$last_msg" ]; then
  complete=false
  for _ in $(seq 20); do
    if tail -n 50 "$transcript" | jq -se --arg m "$last_msg" '
        [ .[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text ]
        | last as $t | $t != null and $t != "" and ($m | endswith($t))' >/dev/null 2>&1; then
      complete=true; break
    fi
    sleep 0.5
  done
fi

# 本回合：最後一則 Telegram 入站起算；最後一個真人輸入不是 Telegram 入站（CLI 回合）就不記
run="$(jq -s --arg mark "$CHANNEL_MARK" '
  def text: .message.content | if type == "string" then . else (map(.text? // "") | join("")) end;
  [ to_entries[] | select(.value.type == "user" and ((.value.message.content | type) == "string" or ((.value.message.content | map(.type) | index("text")) != null))) ] as $inputs
  | ($inputs | last) as $lastin
  | if $lastin == null or (($lastin.value | text) | contains($mark) | not) then empty else
      ($lastin.value | text) as $tag
      | (.[$lastin.key + 1:] | map(select(.type == "assistant"))) as $asst
      # 同一次模型呼叫依內容區塊拆成多筆、各帶同一份 usage，須依 message.id 去重才不重複計
      | ($asst | unique_by(.message.id) | map(.message.usage // {})) as $u
      | ($asst | map(.message.content[]? | select(.type == "tool_use" and (.name | test("telegram.*reply")))) | map(.input)) as $replies
      | {
          received_at: ($tag | capture("ts=\"(?<v>[^\"]+)\"").v? // null),
          chat_id:     ($tag | capture("chat_id=\"(?<v>[^\"]+)\"").v? // null),
          message_id:  ($tag | capture("message_id=\"(?<v>[^\"]+)\"").v? // null),
          from_user:   ($tag | capture(" user=\"(?<v>[^\"]+)\"").v? // null),
          from_user_id:($tag | capture("user_id=\"(?<v>[^\"]+)\"").v? // null),
          batch_size:  (($tag | capture("batch_size=\"(?<v>[0-9]+)\"").v? // "1") | tonumber),
          usage: {
            source: "transcript",
            input_tokens:          ($u | map(.input_tokens // 0) | add // 0),
            output_tokens:         ($u | map(.output_tokens // 0) | add // 0),
            cache_creation_tokens: ($u | map(.cache_creation_input_tokens // 0) | add // 0),
            cache_read_tokens:     ($u | map(.cache_read_input_tokens // 0) | add // 0),
            model_calls:           ($u | length)
          },
          replies: ($replies | length),
          mentions_out: ([ $replies[] | (.text // "") | scan("@[A-Za-z0-9_]+") ] | unique)
        }
    end' "$transcript" 2>/dev/null)"
[ -n "$run" ] || exit 0

# 額度快照：取自 quota.sh 的 claude 各窗口剩餘百分比（不是 token 數）；查不到記 null
quota="$("$(dirname "$0")/quota.sh" --json claude 2>/dev/null | jq -c '.claude')"
[ -n "$quota" ] || quota=null

mkdir -p "$(dirname "$LOG")"
jq -c -n --argjson run "$run" --argjson quota "$quota" --arg session "$session" --argjson complete "$complete" \
  '{logged_at: (now | todate), session_id: $session} + $run + {transcript_complete: $complete, quota: $quota}' >>"$LOG"
exit 0
