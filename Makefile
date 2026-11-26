# Makefile — 本 repo 的 skills 安裝／移除／更新入口
#
# 實際邏輯在 tools/skills.sh；本檔只提供好記的進入點與參數轉發。
# 直接呼叫腳本的用法見 `tools/skills.sh --help`；本檔的用法見 `make help`。
#
# repo 佈局：plugins/<name>/skills/<name>/，一個 plugin＝一個 skill。
#
# install 與 remove 在互動終端會跳出 agent × skill 的二維勾選矩陣：畫面即現況，
# 改成什麼就同步成什麼（勾起來是裝、取消是移除）。指定 SKILLS 則跳過矩陣並維持
# 只加不減。update 不跳矩陣（更新本來就該全做）。
# 非互動情境（CI、pipe、< /dev/null）一律視為全部，不會停在等輸入。
# 安裝方式則是 per-agent 固定的，沒有選項：
#   claude／codex ─ marketplace：兩家吃同一份 .claude-plugin/marketplace.json，
#                   且能直接吃 Git URL；來源預設為 manifest 的 repository
#   agy         ─ plugin：從 GitHub 子目錄 URL 逐 skill 安裝，無 marketplace
#   opencode    ─ copy：直接複製進該 agent 的使用者級 skills 目錄
#
# 另一種機制的殘留（舊版工具裝的、手動複製的）仍會被同時載入而重複，
# 故 install 前會偵測並擋下（FORCE=1 可略過），remove 一律兩邊都清。

TOOL  := tools/skills.sh
AGENTS := claude codex agy opencode

# 預設值由 tools/skills.sh 決定；此處僅在使用者指定時轉發，避免在兩處各寫一份預設
ifdef SKILLS
export SKILLS
endif
ifdef FORCE
export FORCE
endif

# 不帶目標時印說明，而非誤觸安裝——安裝會改動使用者的 agent 設定，不該是預設行為
.DEFAULT_GOAL := help

.PHONY: help status install remove update validate source

# `make source <github|local|status>`：第二個目標當參數，宣告為空目標；為此 status 規則在 source 時不定義
SOURCE_CALL := $(filter source,$(firstword $(MAKECMDGOALS)))
ifneq ($(SOURCE_CALL),)
SOURCE_MODE := $(word 2,$(MAKECMDGOALS))
ifneq ($(SOURCE_MODE),)
$(eval $(SOURCE_MODE):;@:)
endif
endif

# 目標後的 `## 說明` 由 help 自動擷取，新增目標不必回頭改說明（避免兩處不同步）
ifeq ($(SOURCE_CALL),)
status:   ## 顯示安裝現況（含另一種機制的殘留）
	@$(TOOL) status
endif

install:  ## 安裝到所有 agent
	@$(TOOL) install

update:   ## 更新已安裝的內容
	@$(TOOL) update

remove:   ## 移除（全部移除時連 marketplace 一起註銷）
	@$(TOOL) remove

source:   ## 切換或查看 marketplace 來源：make source [github|local|status]
	@$(TOOL) source $(SOURCE_MODE)

validate: ## 離線驗證 manifest 與 skills 結構，不動任何 agent 設定
	@$(TOOL) validate

help:     ## 顯示本說明
	@printf '用法：make <目標> [變數=值]\n\n'
	@printf '目標：\n'
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) \
		| sed -E 's/:[^#]*##[[:space:]]*/\t/' \
		| sort \
		| awk -F'\t' '{ printf "  %-10s %s\n", $$1, $$2 }'
	@printf '\n涵蓋的 agent：$(AGENTS)\n'
	@printf '  install／remove 會跳矩陣，直接在格子上逐 agent 取捨，不需要另外指定\n'
	@printf '\n變數：\n'
	@printf '  %-10s %s\n' SKILLS '只處理指定的 skill（只加不減）；不設＝跳矩陣'
	@printf '  %-10s %s\n' FORCE  '1 ＝略過「另一種機制留有殘留」的偵測（會造成 skill 重複載入）'
	@printf '\n範例：\n'
	@printf '  %-46s %s\n' 'make status'                                   '看各家現況（有殘留才會多列出來）'
	@printf '  %-46s %s\n' 'make install'                                  '跳矩陣：逐 agent、逐 skill 勾選'
	@printf '  %-46s %s\n' 'make remove'                                   '同一個矩陣，起始全空'
	@printf '  %-46s %s\n' 'make install SKILLS=mh-code-review'            '指定就不跳矩陣，且只加不減'
	@printf '  %-46s %s\n' 'make update'                                   '全做，不跳矩陣'
	@printf '  %-46s %s\n' 'make source local'                            'claude／codex 改從工作目錄安裝與更新'
	@printf '  %-46s %s\n' 'make source github'                           '切回 GitHub（網址見 .env）'
	@printf '  %-46s %s\n' 'make source'                                  '看目前來源（同 make source status）'

