#!/bin/bash
# 拉齐/更新 FileCodeBox 工作区的五个模块仓库。
# 幂等:已存在则 git pull --ff-only。
set -e
cd "$(dirname "$0")/.."

clone_or_update() {
  local repo=$1 dir=$2 branch=$3
  if [ -d "$dir/.git" ]; then
    echo "⟳ 更新 $dir"
    git -C "$dir" pull --ff-only
  else
    echo "↓ 克隆 $repo → $dir"
    git clone -b "$branch" "https://github.com/filescodebox/$repo.git" "$dir"
  fi
}

clone_or_update contracts contracts main
clone_or_update core        core        main
clone_or_update server      server      main
clone_or_update frontend    frontend    main

# 飞牛 fnOS 应用适配层(go.work 已引用,默认拉取;SETUP_FNOS=0 可跳过,
# 但跳过后工作区内 go build 会因 go.work 缺目录而报错)
# 注: repo 2026-10-04 已由 filescodebox-fnos 改名 fnos(旧 URL 自动重定向),本地目录已同步为 fnos
if [ "${SETUP_FNOS:-1}" = "1" ]; then
  clone_or_update fnos fnos master
fi

# P2P 联邦注册中心(go.work 已引用,默认拉取;SETUP_P2P=0 可跳过)
if [ "${SETUP_P2P:-1}" = "1" ]; then
  clone_or_update p2p p2p main
fi

# kit 共享 Go 工具库(go.work 已引用,默认拉取;SETUP_KIT=0 可跳过)
if [ "${SETUP_KIT:-1}" = "1" ]; then
  clone_or_update kit kit main
fi

echo "✓ 工作区就绪:$(ls -d */ 2>/dev/null | tr -d '/' | tr '\n' ' ')"
