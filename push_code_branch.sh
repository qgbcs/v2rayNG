#!/usr/bin/env bash
# 一键把 v2rayNG 纯代码（含子模块源码，不含资源/二进制/SDK 缓存）
# 收集到单提交的 code 分支并强推 origin。
# 无变化时自动跳过；本脚本自身（*.sh）也会被收集进 code 分支。
# Windows 镜像更新：git fetch origin && git reset --hard origin/code
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

BRANCH="code"
COMMIT_MSG="v2rayNG 纯代码镜像（供开发参考）：Kotlin 源码 / Gradle / 构建与签名脚本 / 清单 / CI / 文档 + 子模块源码（AndroidLibXrayLite Go、hev-socks5-tunnel C）；不含资源、二进制、数据与 SDK 缓存"
WORKTREE="/tmp/v2rayNG-code-$$"

cleanup() {
    cd "$PROJECT_DIR" 2>/dev/null || cd / || true
    git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
    git worktree prune 2>/dev/null || true
}
trap cleanup EXIT

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add "$WORKTREE" "$BRANCH" >/dev/null
else
    git worktree add --orphan -b "$BRANCH" "$WORKTREE" >/dev/null
fi

# 白名单收集：源码/构建脚本/清单/CI/文档；--delete 清掉源里已删除的文件
rsync -a --delete --prune-empty-dirs \
  --filter='P .git' \
  --exclude='.git/' \
  --exclude='/.android-sdk' --exclude='/.gradle' --exclude='/.android' \
  --exclude='/out' --exclude='/libs' \
  --exclude='/V2rayNG/.gradle' --exclude='/V2rayNG/build' \
  --exclude='/V2rayNG/app/build' --exclude='/V2rayNG/app/libs' \
  --exclude='/V2rayNG/local.properties' --exclude='/apk_sign_apksigner.bak.py' \
  --include='*/' \
  --include='*.kt' --include='*.java' --include='*.kts' --include='*.py' --include='*.sh' \
  --include='*.rb' --include='*.md' --include='*.toml' --include='*.pro' \
  --include='*.yml' --include='*.yaml' --include='*.json' \
  --include='*.c' --include='*.h' --include='*.s' --include='*.mk' \
  --include='*.go' --include='*.mod' --include='*.sum' \
  --include='*.clang-format' --include='*.modulemap' \
  --include='AndroidManifest.xml' --include='gradle.properties' --include='gradle-wrapper.properties' \
  --include='gradlew' --include='gradlew.bat' --include='.gitmodules' --include='.gitignore' --include='.gitattributes' \
  --include='Makefile' --include='Android.mk' --include='Application.mk' --include='*.gradle' \
  --exclude='*' \
  ./ "$WORKTREE/"

cd "$WORKTREE"
git add -A
if git diff --cached --quiet; then
    echo "code 分支已是最新（$(git ls-files | wc -l) 个文件），无需推送。"
    exit 0
fi

if git rev-parse --verify -q HEAD >/dev/null; then
    git commit -q --amend --no-edit
else
    git commit -q -m "$COMMIT_MSG"
fi

echo "收集了 $(git ls-files | wc -l) 个代码文件，推送 $BRANCH 分支..."
git push --force origin "$BRANCH"
echo "完成：origin/$BRANCH -> $(git rev-parse --short HEAD)"
