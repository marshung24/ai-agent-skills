# Makefile — 本 repo 的 skills 安裝／移除／更新入口
#
# 實際邏輯在 tools/skills.sh；本檔只提供好記的進入點與參數轉發。
# 直接呼叫腳本的用法見 `tools/skills.sh --help`；本檔的用法見 `make help`。
#
# repo 佈局：plugins/<name>/skills/<name>/，一個 plugin＝一個 skill。
#
# install 與 remove 在互動終端會跳兩段 checkbox 選單——先挑 agent，再挑 skill；
# 在目標後加 -<agent> 會跳過 agent 那段，指定 SKILLS 會跳過 skill 那段。
# update 兩段都不跳（更新本來就該全做）。
# 非互動情境（CI、pipe、< /dev/null）一律視為全部，不會停在等輸入。
# 安裝方式則是 per-agent 固定的，沒有選項：
#   claude／codex ─ marketplace：兩家吃同一份 .claude-plugin/marketplace.json，
#                   且能直接吃 Git URL；來源預設為 manifest 的 repository
#   agy／opencode ─ copy：直接複製進該 agent 的使用者級 skills 目錄
#
# 另一種機制的殘留（舊版工具裝的、手動複製的）仍會被同時載入而重複，
# 故 install 前會偵測並擋下（FORCE=1 可略過），remove 一律兩邊都清。

TOOL  := tools/skills.sh
AGENTS := claude codex agy opencode

# 預設值由 tools/skills.sh 決定；此處僅在使用者指定時轉發，避免在兩處各寫一份預設
ifdef SKILLS
export SKILLS
endif
ifdef SOURCE
export SOURCE
endif
ifdef FORCE
export FORCE
endif

# 不帶目標時印說明，而非誤觸安裝——安裝會改動使用者的 agent 設定，不該是預設行為
.DEFAULT_GOAL := help

.PHONY: help status install remove update validate

# 目標後的 `## 說明` 由 help 自動擷取，新增目標不必回頭改說明（避免兩處不同步）
status:   ## 顯示安裝現況（plugin 與 copy 兩種方式一起列）
	@$(TOOL) status

install:  ## 安裝到所有 agent
	@$(TOOL) install

update:   ## 更新已安裝的內容
	@$(TOOL) update

remove:   ## 移除（plugin 模式連 marketplace 一起註銷）
	@$(TOOL) remove

validate: ## 離線驗證 manifest 與 skills 結構，不動任何 agent 設定
	@$(TOOL) validate

help:     ## 顯示本說明
	@printf '用法：make <目標> [變數=值]\n\n'
	@printf '目標：\n'
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) \
		| sed -E 's/:[^#]*##[[:space:]]*/\t/' \
		| sort \
		| awk -F'\t' '{ printf "  %-10s %s\n", $$1, $$2 }'
	@printf '\n限定單一 agent：在目標後加 -<agent>；省略時 install/remove 會跳選單讓你挑\n'
	@printf '  可用 agent：$(AGENTS)\n'
	@printf '  例：make install-claude / make remove-codex / make status-agy\n'
	@printf '  （help 與 validate 不分 agent）\n'
	@printf '\n變數：\n'
	@printf '  %-10s %s\n' SKILLS '只處理指定的 skill；不設＝install/remove 跳選單挑'
	@printf '  %-10s %s\n' SOURCE '覆寫 marketplace 來源；開發時裝工作目錄的內容用 SOURCE=$$PWD'
	@printf '  %-10s %s\n' FORCE  '1 ＝略過「另一種機制留有殘留」的偵測（會造成 skill 重複載入）'
	@printf '\n範例：\n'
	@printf '  %-46s %s\n' 'make status'                                   '看各家現況（有殘留才會多列出來）'
	@printf '  %-46s %s\n' 'make install'                                  '跳選單：先挑 agent，再挑 skill'
	@printf '  %-46s %s\n' 'make remove'                                   '同樣是兩段選單'
	@printf '  %-46s %s\n' 'make install-claude'                           '點名 agent，只剩 skill 那段選單'
	@printf '  %-46s %s\n' 'make install SKILLS=mh-code-review'            '兩段都指定，完全不跳選單'
	@printf '  %-46s %s\n' 'make update'                                   '全做，不跳選單'
	@printf '  %-46s %s\n' 'make install SOURCE=$$PWD'                      '開發時改裝工作目錄的內容'
	@printf '  %-46s %s\n' 'make remove-agy'                               'remove 會連另一種機制的殘留一起清'

# 單一 agent 的操作：make install-codex / make remove-agy / make status-claude …
# 用 pattern rule 避免為 4 agent × 4 動作寫 16 個目標
#
# DECISION: 這些目標刻意不列進 .PHONY——GNU make 對 .PHONY 目標會跳過隱含／pattern 規則比對，
#           列進去會讓 `make status-codex` 變成「Nothing to be done」。同名檔案不存在，
#           不列 .PHONY 也不會誤判為已是最新
install-%:
	@$(TOOL) install $*

remove-%:
	@$(TOOL) remove $*

update-%:
	@$(TOOL) update $*

status-%:
	@$(TOOL) status $*
