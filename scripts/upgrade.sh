#!/usr/bin/env bash
# 升级规程（workbuddy2api-panel / fork 主线）
#   预检 → 备份(镜像/配置/状态) → rebase 上游 → 构建 → 部署 → 冒烟 → 失败自动回滚
#
# 用法:
#   ./scripts/upgrade.sh              # 完整升级（有更新才动）
#   ./scripts/upgrade.sh --dry-run    # 只体检 + 列上游新提交，不改任何东西
#   ./scripts/upgrade.sh --no-push    # 升级但最后不推 fork
#
# 兜底原则：
#   1. 预检不过（工作树脏/仓库异常）→ 立即退出，生产零影响
#   2. rebase 失败 → git rebase --abort，生产零影响
#   3. 构建失败 → 直接退出，旧容器照常跑（新镜像没生成）
#   4. 部署后冒烟不过 → 自动把旧镜像 retag 回 latest 并重建容器，再复验
#   5. 全流程日志落 upgrade-logs/upgrade-<ts>.log，失败原因写清楚
set -uo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0; PUSH=1; DEPLOY_ONLY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --no-push) PUSH=0 ;;
    --deploy-only) DEPLOY_ONLY=1 ;;
    *) echo "未知参数: $a"; exit 2 ;;
  esac
done

TS=$(date +%Y%m%d-%H%M%S)
LOGDIR=upgrade-logs
mkdir -p "$LOGDIR"
LOG="$LOGDIR/upgrade-$TS.log"
exec > >(tee -a "$LOG") 2>&1

IMAGE="wb2api-panel-wb2api:latest"
ROLLBACK_TAG="wb2api-panel-wb2api:rollback-$TS"
HEALTH="http://127.0.0.1:12585/healthz"
STATUS_URL="http://127.0.0.1:12585/status"
PANEL_CONTAINER="workbuddy2api-panel"

say()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { say "❌ 失败: $*"; say "日志: $LOG"; exit 1; }
ok()   { say "✅ $*"; }

api_key() { python3 -c "import json;print(json.load(open('config.json'))['api_key'])"; }

# ---------- 0. 预检 ----------
say "=== [1/7] 预检 ==="
git rev-parse --git-dir >/dev/null 2>&1 || die "不是 git 仓库"
[ -z "$(git status --porcelain)" ] || die "工作树不干净，先提交或清理: $(git status --short | head -3)"
command -v docker >/dev/null || die "无 docker"
sudo docker compose config -q || die "compose 配置无效"
OLD_HEAD=$(git rev-parse --short HEAD)
OLD_IMG_ID=$(sudo docker images -q "$IMAGE" 2>/dev/null || true)
[ -n "$OLD_IMG_ID" ] || die "找不到当前镜像 $IMAGE（拒绝在无镜像状态下升级）"
PREV_TOTAL=$(curl -s --max-time 10 "$STATUS_URL" -H "Authorization: Bearer $(api_key)" | python3 -c "import json,sys;print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo 0)
say "当前 HEAD=$OLD_HEAD 镜像=${OLD_IMG_ID:0:12} 账号总数=$PREV_TOTAL"

say "--- 拉取上游 ---"
git fetch upstream main || die "fetch 上游失败"
NEW_HEAD=$(git rev-parse --short upstream/main)
AHEAD=$(git rev-list --count "$OLD_HEAD..upstream/main" 2>/dev/null || echo 0)
# 只统计上游相对我们基底的新提交
BASE=$(git merge-base HEAD upstream/main)
AHEAD_BASE=$(git rev-list --count "$BASE..upstream/main")
say "上游 tip=$NEW_HEAD，相对合并基点新增 $AHEAD_BASE 条"
if [ "$DEPLOY_ONLY" = "0" ] && [ "$AHEAD_BASE" -eq 0 ] && [ "$(git rev-list --count HEAD..upstream/main)" -eq 0 ]; then
  ok "已是最新，无需升级"; exit 0
fi
git log --oneline "$BASE..upstream/main" | head -20

if [ "$DRY_RUN" = "1" ]; then
  say "--- DRY RUN：以下为将要执行的步骤，未做任何改动 ---"
  say "1) 备份镜像 → $ROLLBACK_TAG，备份 config.json / data/state.json"
  say "2) git rebase upstream/main（失败自动 abort）"
  say "3) docker compose build（失败不影响生产）"
  say "4) docker compose up -d + 冒烟（healthz/账号数/真实调用/双端口）"
  say "5) 冒烟失败 → 自动回滚 $ROLLBACK_TAG"
  exit 0
fi

# ---------- 1. 备份 ----------
say "=== [2/7] 备份 ==="
sudo docker tag "$IMAGE" "$ROLLBACK_TAG" || die "镜像备份失败"
cp config.json "config.json.bak-$TS" || die "配置备份失败"
[ -f data/state.json ] && sudo cp data/state.json "data/state.json.bak-$TS"
git tag -f "pre-upgrade-$TS" >/dev/null 2>&1 || true
ok "镜像 → $ROLLBACK_TAG；config.json.bak-$TS；pre-upgrade-$TS"

# ---------- 2. rebase ----------
say "=== [3/7] rebase 上游 ==="
if [ "$DEPLOY_ONLY" = "1" ]; then
  say "(--deploy-only) 跳过 rebase，直接基于当前 HEAD 部署"
elif ! GIT_EDITOR=true git rebase upstream/main; then
  git rebase --abort 2>/dev/null || true
  die "rebase 冲突，已 abort（生产未动，HEAD 仍是 $OLD_HEAD）"
fi
NEW_LOCAL=$(git rev-parse --short HEAD)
ok "rebase 完成 HEAD=$NEW_LOCAL"

# ---------- 3. 构建 ----------
say "=== [4/7] 构建 ==="
APP_VER="$(git rev-parse --short HEAD)"
if grep -q '^APP_VERSION=' .env 2>/dev/null; then
  sed -i "s|^APP_VERSION=.*|APP_VERSION=$APP_VER|" .env
else
  echo "APP_VERSION=$APP_VER" >> .env
fi
say "APP_VERSION=$APP_VER"
if ! sudo docker compose build; then
  git reset --hard "pre-upgrade-$TS" >/dev/null 2>&1
  die "构建失败，已回滚代码到 $OLD_HEAD（生产未动）"
fi
ok "构建成功"

# ---------- 4. 部署 ----------
say "=== [5/7] 部署 ==="
UP_FAILED=0
sudo docker compose up -d || UP_FAILED=1
[ "$UP_FAILED" = "1" ] && say "容器启动命令失败，将走回滚流程"

wait_health() { # 最多 90s：healthz 必须回 200/503 且带 service 标识
  for i in $(seq 1 45); do
    body=$(curl -s --max-time 3 "$HEALTH" 2>/dev/null || true)
    if echo "$body" | grep -q '"service":"workbuddy2api"'; then
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$HEALTH")
      [ "$code" = "200" ] || [ "$code" = "503" ] || continue
      say "healthz=$code body=$body"; return 0
    fi
    sleep 2
  done
  return 1
}

smoke() {
  # 1) healthz 存活
  wait_health || { say "❌ healthz 未就绪"; return 1; }
  # 2) /status 可用 + 账号数不塌
  total=$(curl -s --max-time 8 "$STATUS_URL" -H "Authorization: Bearer $(api_key)" \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo -1)
  say "账号总数: $total（升级前 $PREV_TOTAL）"
  [ "$total" -ge 1 ] || { say "❌ /status 账号数为 0 或不可读"; return 1; }
  if [ "$PREV_TOTAL" -gt 0 ] && [ "$total" -lt $((PREV_TOTAL - 2)) ]; then
    say "❌ 账号数掉太多（$PREV_TOTAL → $total）"; return 1
  fi
  # 3) 双端口都通
  for p in 12585 12584; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$p/healthz")
    [ "$c" = "200" ] || [ "$c" = "503" ] || { say "❌ 端口 $p 不可达 ($c)"; return 1; }
  done
  # 4) 真实调用
  model=$(curl -s --max-time 10 "http://127.0.0.1:12585/v1/models" -H "Authorization: Bearer $(api_key)" \
    | python3 -c "
import json,sys
ids=[m['id'] for m in json.load(sys.stdin).get('data',[])]
print(next((i for i in ids if i.startswith('cn:')), ids[0] if ids else ''))" 2>/dev/null || echo "")
  [ -n "$model" ] || { say "❌ 模型目录为空"; return 1; }
  say "冒烟模型: $model"
  resp=$(curl -s --max-time 90 "http://127.0.0.1:12585/v1/chat/completions" \
    -H "Authorization: Bearer $(api_key)" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"system\",\"content\":\"健康检查\"},{\"role\":\"user\",\"content\":\"只回两个字：正常\"}],\"max_tokens\":128}" 2>/dev/null)
  echo "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ch=d.get('choices') or []
assert ch, 'no choices: '+str(d)[:200]
print('回复 OK')" || { say "❌ 真实调用失败: $(echo "$resp" | head -c 300)"; return 1; }
  return 0
}

say "=== [6/7] 冒烟 ==="
if [ "$UP_FAILED" = "0" ] && smoke; then
  ok "冒烟全部通过"
  say "=== [7/7] 收尾 ==="
  if [ "$PUSH" = "1" ]; then
    git push --force-with-lease origin main && ok "已推 fork" || say "⚠️ 推 fork 失败（不影响线上，稍后手动 git push）"
  fi
  # 保留最近 5 个回滚镜像 / 备份，其余清理
  sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^wb2api-panel-wb2api:rollback-' \
    | sort | head -n -5 | xargs -r -n1 sudo docker rmi >/dev/null 2>&1 || true
  ls -1t config.json.bak-* 2>/dev/null | tail -n +6 | xargs -r rm -f || true
  ok "升级完成：$OLD_HEAD → $NEW_LOCAL（回滚点 $ROLLBACK_TAG）"
  say "回滚命令：sudo docker tag $ROLLBACK_TAG $IMAGE && sudo docker compose up -d --force-recreate"
  exit 0
fi

# ---------- 5. 自动回滚 ----------
say "=== 冒烟失败 → 自动回滚 ==="
sudo docker tag "$ROLLBACK_TAG" "$IMAGE" || die "回滚镜像 retag 失败，手动介入！"
sudo docker compose up -d --force-recreate || die "回滚重建容器失败，手动介入！"
if wait_health && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:12585/healthz")" != "000" ]; then
  git reset --hard "pre-upgrade-$TS" >/dev/null 2>&1
  say "❌ 升级失败已回滚，线上恢复旧版本（代码也已回退 $OLD_HEAD）"
  say "失败原因见上方日志；排查后用 --no-push 重试或人工修复"
  exit 1
fi
die "回滚后仍不健康，需要人工介入（镜像 $ROLLBACK_TAG 仍在）"
