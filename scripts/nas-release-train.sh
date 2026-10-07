#!/usr/bin/env bash
# NAS 打包四仓发版列车:跟随 server/frontend 新镜像时,一条命令走完"改模板 → 同步
# 四仓 → 各仓提交打 tag"——CI 自动组包 + 本仓 Release + hub `*-v*` 回挂。
#
# 用法: scripts/nas-release-train.sh <镜像tag> [--push] [--adapter < vX.Y.Z>]
#   默认 dry-run(只打印将执行的动作);--push 实际执行
#   --adapter 指定四仓新版本(默认各仓当前最新 tag 的 patch +1)
#
# 例: scripts/nas-release-train.sh v0.16.0 --push
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE_TAG="${1:?用法: nas-release-train.sh <镜像tag> [--push] [--adapter vX.Y.Z]}"
case "$IMAGE_TAG" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "镜像 tag 须形如 v0.16.0" >&2; exit 1 ;;
esac
PUSH=0
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --push) PUSH=1; shift ;;
        --adapter) ADAPTER="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

PLATFORMS="synology qnap ugreen terramaster"
run() {
    if [ "$PUSH" = "1" ]; then
        "$@"
    else
        echo "  [dry-run] $*"
    fi
}

echo "==> [1/4] 前置检查(列车要动的路径干净;ghcr 匿名 API 恒 401 不能探测,发布前自行确认 server 仓已出 ${IMAGE_TAG})"
# hub 只查列车将提交的 deploy/nas/(工作区内其他并行改动不拦列车)
if [ -n "$(git status --porcelain -- deploy/nas)" ]; then
    echo "hub deploy/nas/ 有未提交改动,先清理再跑列车" >&2
    exit 1
fi
for d in $PLATFORMS; do
    [ -d "$d/.git" ] || { echo "缺 $d 检出(先 make setup)" >&2; exit 1; }
    if [ -n "$(git -C "$d" status --porcelain)" ]; then
        echo "$d 有未提交改动,先清理再跑列车" >&2
        exit 1
    fi
done
echo "  ✓ 四仓+hub 工作树干净"

echo "==> [2/4] 改 hub 模板钉版 → ${IMAGE_TAG}"
if [ "$PUSH" = "1" ]; then
    sed -i.bak "s/FCB_IMAGE_TAG:-v[0-9]*\.[0-9]*\.[0-9]*/FCB_IMAGE_TAG:-${IMAGE_TAG}/" deploy/nas/compose.yml && rm -f deploy/nas/compose.yml.bak
    sed -i.bak "s/^FCB_IMAGE_TAG=v[0-9]*\.[0-9]*\.[0-9]*/FCB_IMAGE_TAG=${IMAGE_TAG}/" deploy/nas/env.example && rm -f deploy/nas/env.example.bak
    grep -h "FCB_IMAGE_TAG" deploy/nas/compose.yml deploy/nas/env.example | head -2
    git add deploy/nas
    git commit -m "chore(nas): 模板镜像钉版 ${IMAGE_TAG}(发版列车)"
else
    echo "  [dry-run] 将把 deploy/nas/{compose.yml,env.example} 的镜像默认值改为 ${IMAGE_TAG} 并提交"
fi

echo "==> [3/4] 同步四仓 + 各仓提交打 tag"
for p in $PLATFORMS; do
    [ "$PUSH" = "1" ] && bash deploy/nas/sync.sh sync --platform "$p" --dir "$p" >/dev/null
    if [ "$PUSH" = "1" ]; then
        # synology README 的字面版本号(配置表默认值 + ghcr 拉取示例)随列车改写
        sed -i.bak "s/FCB_IMAGE_TAG\` | \`v[0-9.]*\`/FCB_IMAGE_TAG\` | \`${IMAGE_TAG}\`/; s/server:${IMAGE_TAG%.*}\.[0-9]*/server:${IMAGE_TAG}/g; s/frontend:${IMAGE_TAG%.*}\.[0-9]*/frontend:${IMAGE_TAG}/g" \
            "$p/README.md" 2>/dev/null && rm -f "$p/README.md.bak" || true
        VER=${ADAPTER:-$(git -C "$p" describe --tags --abbrev=0 | awk -F. '{print $1"."$2"."$3+1}')}
        git -C "$p" add -A
        git -C "$p" commit -qm "chore: 同步 hub 模板,钉镜像 ${IMAGE_TAG}"
        git -C "$p" tag "$VER"
        git -C "$p" push -q origin main "$VER"
        echo "  ✓ $p → ${VER}(Actions: https://github.com/filescodebox/$p/actions)"
    else
        echo "  [dry-run] $p: 将 sync 模板、提交并打 tag(当前 $(git -C "$p" describe --tags --abbrev=0) → patch+1)"
    fi
done

echo "==> [4/4] hub 模板提交推送"
run git push -q origin main

if [ "$PUSH" = "1" ]; then
    echo "✓ 列车发完。各仓 Release+hub 回挂由 CI 完成,完成后人工核对:"
    echo "  - 四仓 Release 资产与 hub ${PLATFORMS}-v* 回挂(gh release view)"
    echo "  - AGENTS.md 生态表四仓版本号"
else
    echo "✓ dry-run 结束。确认无误后加 --push 重跑。"
fi
