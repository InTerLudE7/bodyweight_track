#!/usr/bin/env bash
set -euo pipefail

# === 可按需改动的变量 ===
OVERLEAF_REMOTE="${OVERLEAF_REMOTE:-origin}"   # Overleaf 远端名
GITHUB_REMOTE="${GITHUB_REMOTE:-github}"       # GitHub 远端名
OVERLEAF_LOCAL_BRANCH="${OVERLEAF_LOCAL_BRANCH:-overleaf}" # 本地用于对接 Overleaf 的分支名
DEV_ONLY_FILES=("Makefile" "sync_overleaf_github.sh")      # 这些文件不推到 Overleaf，但保留在 GitHub
# =======================

# 进入仓库根目录检查
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "❌ 请在 Git 仓库内运行"; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# 当前开发分支（你平时工作的分支）
DEV_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# 工作区如有未提交，先自动打包提交，避免丢改动
if ! git diff --quiet || ! git diff --cached --quiet; then
  git add -A
  git commit -m "chore: auto-commit before sync $(date +'%F %T')"
fi

echo "🔎 Fetch remotes…"
git fetch --all --prune

# 检测 Overleaf 远端默认分支（优先 master，其次 main）
detect_overleaf_upstream_branch() {
  if git ls-remote --exit-code --heads "$OVERLEAF_REMOTE" master >/dev/null 2>&1; then
    echo "master"
  elif git ls-remote --exit-code --heads "$OVERLEAF_REMOTE" main >/dev/null 2>&1; then
    echo "main"
  else
    # 如果 Overleaf 还没任何分支，默认用 master
    echo "master"
  fi
}
OVERLEAF_REMOTE_BRANCH="$(detect_overleaf_upstream_branch)"
echo "✅ Overleaf upstream: $OVERLEAF_REMOTE/$OVERLEAF_REMOTE_BRANCH"

# 确保存在本地 $OVERLEAF_LOCAL_BRANCH 分支，并与 Overleaf 远端跟踪
if git show-ref --verify --quiet "refs/heads/$OVERLEAF_LOCAL_BRANCH"; then
  git checkout -q "$OVERLEAF_LOCAL_BRANCH"
else
  # 若远端分支存在则跟踪它，否则从当前分支创建
  if git ls-remote --exit-code --heads "$OVERLEAF_REMOTE" "$OVERLEAF_REMOTE_BRANCH" >/dev/null 2>&1; then
    git checkout -b "$OVERLEAF_LOCAL_BRANCH" "$OVERLEAF_REMOTE/$OVERLEAF_REMOTE_BRANCH"
  else
    git checkout -b "$OVERLEAF_LOCAL_BRANCH" "$DEV_BRANCH"
  fi
fi

# 拉取 Overleaf 最新
git pull --rebase "$OVERLEAF_REMOTE" "$OVERLEAF_REMOTE_BRANCH" || true
T_OV="$(git log -1 --format=%ct 2>/dev/null || echo 0)"

# 回到开发分支
git checkout -q "$DEV_BRANCH"
T_DEV="$(git log -1 --format=%ct 2>/dev/null || echo 0)"

# 谁新用谁：如果 Overleaf 更新更“新”，把改动合入本地开发分支（偏向 theirs）
if [ "$T_OV" -gt "$T_DEV" ]; then
  echo "⬇️ Overleaf 比本地新，合并到 $DEV_BRANCH（冲突默认采用 theirs）"
  git merge -X theirs --no-edit "$OVERLEAF_LOCAL_BRANCH" || true
  # 把开发专属文件（Makefile/脚本等）强制保留为“ours”
  for f in "${DEV_ONLY_FILES[@]}"; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      git checkout --ours -- "$f" || true
      git add "$f" || true
    fi
  done
  git commit -m "sync: merge from Overleaf (prefer theirs); keep dev-only files" || true
else
  echo "⬆️ 本地比 Overleaf 新（或相同），稍后将以本地为准推送到 Overleaf"
fi

# 构建一个“干净”的 Overleaf 分支快照：等于 DEV_BRANCH，但删除开发专属文件并忽略之
echo "🧹 生成对 Overleaf 的干净分支快照…"
git checkout -q "$OVERLEAF_LOCAL_BRANCH"
git reset --hard "$DEV_BRANCH"

# 确保 .gitignore 存在，并把开发专属文件加入忽略（仅在 overleaf 分支）
touch .gitignore
changed_ignore=0
for f in "${DEV_ONLY_FILES[@]}"; do
  if ! grep -qxF "/$f" .gitignore; then
    echo "/$f" >> .gitignore
    changed_ignore=1
  fi
done
[ $changed_ignore -eq 1 ] && git add .gitignore

# 从索引中移除开发专属文件（保留工作区不必要，这里也删掉以免误传）
for f in "${DEV_ONLY_FILES[@]}"; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    git rm -f --cached "$f" || true
    rm -f "$f" || true
  fi
done

git commit -m "sync: strip dev-only files for Overleaf" || true

# 推送到 Overleaf（overleaf 本地分支 -> 远端 $OVERLEAF_REMOTE_BRANCH）
echo "🚀 Push to Overleaf: $OVERLEAF_REMOTE_BRANCH"
git push "$OVERLEAF_REMOTE" "$OVERLEAF_LOCAL_BRANCH:$OVERLEAF_REMOTE_BRANCH"

# 回到开发分支并推送到 GitHub
git checkout -q "$DEV_BRANCH"
echo "🚀 Push to GitHub: $DEV_BRANCH"
git push "$GITHUB_REMOTE" "$DEV_BRANCH"

echo "✅ 同步完成：Overleaf ←→ 本地（取较新），并推到 GitHub"

