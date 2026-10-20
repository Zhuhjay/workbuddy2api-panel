#!/usr/bin/env bash
# 同步上游 misakano7545/workbuddy2api-panel 到本地 main（rebase 保持线性）。
# 用法:
#   ./scripts/sync-upstream.sh          # 只拉取+rebase，不推送
#   ./scripts/sync-upstream.sh --push   # 同步后推送到自己的 fork（origin）
set -euo pipefail
cd "$(dirname "$0")/.."

git fetch upstream main
git fetch mainline main

echo '=== 上游新增提交 ==='
if [ -z "$(git log --oneline HEAD..upstream/main)" ]; then
  echo '已是最新，无需同步'
  exit 0
fi
git log --oneline HEAD..upstream/main | head -30

git rebase upstream/main
echo '=== 同步完成，当前 HEAD ==='
git log --oneline -3

if [ "${1:-}" = "--push" ]; then
  git push origin main
  echo '已推送到 fork'
fi
