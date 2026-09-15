#!/usr/bin/env bash
# post-install-check.sh — 安裝／更新本 skill 後的使用者設定自檢
#
# 用途：throttle.json 放在使用者家目錄，不隨 skill 一起更新。skill 版本前進後，
#       舊設定可能出現已失效的欄位；本鉤子在安裝流程末端檢查並修復那些欄位。
#
# I/O：無輸入；stdout 為自檢報告。結束碼一律 0——自檢結果不該讓一次安裝被判失敗。

set -uo pipefail
SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPTS_DIR/advisor-throttle-config.sh" check || true
exit 0
