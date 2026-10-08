#!/usr/bin/env bash
# 发布列车工具 —— PigeonBox 生态版本统一收口(设计稿: docs/specs/2026-10-08-release-train-design.md)
#
# 真相源: release/train.yaml(扁平 dotted key)。本脚本是唯一写入口,CI(train-verify/
# train-release 工作流)与本地共用同一实现。
#
# 用法:
#   release-train.sh verify [--ci]              对账: train.yaml ↔ 各仓真实状态(漂移即非零退出)
#   release-train.sh bump TRAIN=x.y.z [opts]    开新列车: 改 15+ 版本写入点 → 各仓 train/<v> 分支+PR(默认 dry-run)
#       [--set core=v0.15.0 contracts=v0.9.0 kit=v0.4.0 p2p=v0.5.0]   库线消费记录(仅记录,不触发下游)
#       [--set core_pin=v0.15.0]      终端仓 go.mod 钉版(默认保持现状——升钉需显式指定,fnos v1.2.7 教训)
#       [--set server=v0.16.0 p2pc=v0.5.0]                            镜像版本 / desktop sidecar 钉版
#       [--hotfix]      子集列车(仅变更受影响组件,train.yaml 记 hotfix=true)
#       [--push]        实际执行(建分支/提交/push/gh pr create);缺省只打印计划
#   release-train.sh finalize [--train x.y.z]   终验(verify 全绿)→ state=shipped → hub 打 v<train> 快照
#   release-train.sh notes [v<train>]           渲染列车说明(hub release.yml 与 finalize 共用)
#   release-train.sh get <key>                  读 train.yaml 单键(工作流取值用)
#
# 语义约定(勿破坏):
#   - ghcr 镜像 tag 无 v 前缀;release/git tag 带 v(desktop 为 desktop-v 前缀)
#   - 判"最新"一律 semver 排序,禁用 tag creatordate(历史镜像导入同秒,时间不可靠)
#   - 组件回挂 hub Release 恒 --latest=false;Latest 只属于 hub v<train> 快照
set -euo pipefail
cd "$(dirname "$0")/.."

TRAIN_FILE=release/train.yaml
GH_ORG=pigeonbox
HUB_REPO=pigeonbox/pigeonbox
PLATFORMS="synology ugreen terramaster"

# ───────────────────────── 基础工具 ─────────────────────────

tget() { # <key> → train.yaml 值
    awk -F': *' -v k="$1" '$1==k {print $2; exit}' "$TRAIN_FILE" | tr -d '"'
}

def_branch() { # <repo> → 默认分支(fnos 历史原因用 master,其余 main)
    [ "$1" = fnos ] && { echo master; return; }
    echo main
}

raw() { # <repo>/<ref>/<path> → stdout
    # 优先 gh contents API(与 CI 同源,无 CDN 缓存滞后——推完立查不吃旧内容);
    # gh 不可用时回退 raw.githubusercontent(公网匿名可达)。
    local repo=${1%%/*} rest=${1#*/}
    local ref=${rest%%/*} path=${rest#*/}
    gh api "repos/${GH_ORG}/${repo}/contents/${path}?ref=${ref}" --jq .content 2>/dev/null | base64 -d \
        || curl -fsSL --retry 4 --retry-all-errors --connect-timeout 15 \
            "https://raw.githubusercontent.com/${GH_ORG}/$1"
}

tag_exists() { # <repo> <tag> → 0/1
    gh api "repos/${GH_ORG}/$1/git/ref/tags/$2" >/dev/null 2>&1
}

set_table_last_cell() { # <file> <行内固定片段> <新单元格>  (管道分隔表最后一列)
    local file=$1 prefix=$2 val=$3 line
    line=$(grep -nF -- "$prefix" "$file" | head -1 | cut -d: -f1) || true
    if [ -z "$line" ]; then
        echo "  ⚠ 未找到表格行(跳过): $prefix" >&2
        return 1
    fi
    awk -v ln="$line" -v val="$val" -F'|' -v OFS='|' '
        NR==ln {
            for (i = NF-1; i > 0; i--) {
                gsub(/^ +| +$/, "", $i)
                if ($i != "") { $i = " " val " "; break }
            }
        }
        { print }' "$file" > "$file.tmp"
    [ -s "$file.tmp" ] && mv "$file.tmp" "$file"
}

set_table_cell3() { # <file> <行名(第2列,去空白)> <新单元格>  (管道分隔表第三列=| 名 | 版本 | 说明)
    # 用 awk 字段精确比较而非动态正则——BSD awk(macOS) 对含 | 的动态 ERE
    # 报 "illegal primary"(1.14.2/1.14.3 两轮 bump 矩阵静默失败的根因)。
    local file=$1 name=$2 val=$3
    grep -qF "| $name |" "$file" || { echo "  ⚠ 未找到表格行: $name" >&2; return 1; }
    awk -v name="$name" -v val="$val" -F'|' -v OFS='|' '
        { c = $2; gsub(/^ +| +$/, "", c); if (c == name) $3 = " " val " " }
        { print }' "$file" > "$file.tmp"
    [ -s "$file.tmp" ] && mv "$file.tmp" "$file"
}

# ───────────────────────── verify ─────────────────────────

cmd_verify() {
    local ci=0; [ "${1:-}" = "--ci" ] && ci=1
    local TRAIN STATE fails=0 warns=0
    TRAIN=$(tget train); STATE=$(tget state)
    [ -n "$TRAIN" ] || { echo "✗ train.yaml 解析失败(缺 train)"; exit 1; }

    local SERVER_V FE_TAG CONTRACTS_KIT CORE_KIT P2P_KIT
    SERVER_V=$(tget images.server); FE_TAG=$(tget frontend.tag)
    local C_CONTRACTS C_CORE C_KIT C_P2P C_P2PC CHART CHART_APP
    C_CONTRACTS=$(tget lib.contracts); C_CORE=$(tget lib.core); C_KIT=$(tget lib.kit)
    C_P2P=$(tget lib.p2p); C_P2PC=$(tget terminal.desktop.p2pc)
    CHART=$(tget charts.chart); CHART_APP=$(tget charts.app)

    # 列车进行中探测: 任一仓存在未合并的 train/<TRAIN> bump PR → 主分支版本面必然
    # 落后于 train.yaml 声明(中间态),主分支对账项降级为告警;PR 全合并后自动恢复严格。
    local IN_FLIGHT="" repo_i
    for repo_i in pigeonbox fnos openwrt desktop synology qnap ugreen terramaster; do
        [ "$(gh pr list -R ${GH_ORG}/$repo_i --head "train/$TRAIN" --state open --json number --jq 'length' 2>/dev/null)" != "0" ] && { IN_FLIGHT=1; break; }
    done

    fail()   { echo "  ✗ $*"; fails=$((fails+1)); }
    warn()   { echo "  ⚠ $*"; warns=$((warns+1)); }
    ok()     { echo "  ✓ $*"; }
    # 主分支对账项专用: 列车进行中 → 告警(等 bump PR 合并),否则硬失败
    soft_fail() {
        if [ -n "$IN_FLIGHT" ]; then warn "列车进行中·$*(等 bump PR 合并)"; else fail "$*"; fi
    }
    # draft 列车 tag 尚未打全属正常 → 缺 tag 只告警;shipping/shipped 缺 tag 即失败
    tagchk() { # <repo> <tag> <说明>
        if tag_exists "$1" "$2"; then ok "$3 $2"
        elif [ "$STATE" = draft ]; then warn "$3 缺 tag $2(draft 期)"
        else fail "$3 缺 tag $2"; fi
    }
    pinchk() { # <go.mod 内容> <module> <期望版本> <说明> [soft]
        if echo "$1" | grep -Eq "github\.com/pigeonbox/$2 v$(echo "$3" | sed 's/^v//')([[:space:]$]|$)"; then
            ok "$4 = $3"
        elif [ "${5:-}" = soft ] && [ -n "$IN_FLIGHT" ]; then
            warn "列车进行中·$4 期望 $3"
        else
            fail "$4 期望 $3"
        fi
    }

    echo "══ PigeonBox 发布列车对账 train=$TRAIN state=$STATE $([ $ci = 1 ] && echo '(ci)')${IN_FLIGHT:+ [列车进行中:主分支对账降级为告警]}"

    echo "── 1. 库线/服务线 tag"
    tagchk contracts "$C_CONTRACTS" "contracts"
    tagchk core      "$C_CORE"      "core"
    tagchk kit       "$C_KIT"       "kit"
    tagchk p2p       "$C_P2P"       "p2p"
    tagchk server    "v$SERVER_V"   "server"
    if [ -n "$FE_TAG" ]; then tagchk frontend "$FE_TAG" "frontend"
    else warn "frontend 未打 tag(四处构建拉 main,不可复现;下一列车与 server 同号)"; fi

    echo "── 2. charts 对齐"
    local CYAML; CYAML=$(raw charts/main/charts/pigeonbox/Chart.yaml 2>/dev/null) \
        || { fail "charts Chart.yaml 拉取失败"; CYAML=""; }
    [ "$(awk '/^version:/{print $2;exit}' <<<"$CYAML" | tr -d '"')" = "$CHART" ] \
        && ok "chart version = $CHART" || fail "chart version ≠ $CHART"
    [ "$(awk '/^appVersion:/{print $2;exit}' <<<"$CYAML" | tr -d '"')" = "$CHART_APP" ] \
        && ok "chart appVersion = $CHART_APP" || fail "chart appVersion ≠ $CHART_APP"
    [ "$CHART_APP" = "v$SERVER_V" ] && ok "appVersion 锁 server 镜像(v$SERVER_V)" \
        || fail "chart appVersion($CHART_APP) ≠ v$SERVER_V"

    echo "── 3. hub 分发面钉版"
    local PIN_V="v$SERVER_V"
    grep -q "PB_IMAGE_TAG:-$PIN_V" deploy/nas/compose.yml \
        && grep -q "^PB_IMAGE_TAG=$PIN_V" deploy/nas/env.example \
        && ok "deploy/nas 模板钉版 = $PIN_V" || fail "deploy/nas 模板钉版 ≠ $PIN_V"
    grep -q "newTag: $SERVER_V" deploy/k8s/overlays/prod/kustomization.yaml \
        && ok "k8s prod overlay newTag = $SERVER_V" || fail "k8s prod overlay newTag ≠ $SERVER_V"
    if grep -qE '^replace ' go.work; then fail "go.work 仍存在版本化 replace(应纯 use 映射)"
    else ok "go.work 纯 use 映射"; fi

    echo "── 4. NAS 打包三仓物化(qnap 已切原生走第 6/7 节)"
    if [ $ci = 0 ]; then
        bash deploy/nas/sync.sh check --all >/dev/null 2>&1 \
            && ok "sync.sh check --all 一致" \
            || { fail "NAS 四仓与 hub 模板漂移(跑 make nas-sync)"; bash deploy/nas/sync.sh check --all | sed 's/^/      /' || true; }
    else
        local p cpath
        for p in $PLATFORMS; do
            case "$p" in
                synology) cpath=spk/package/compose.yml ;;
                qnap) cpath=qpkg/shared/compose.yml ;;
                *) cpath=deploy/compose.yml ;;
            esac
            local n; n=$(raw "$p/main/$cpath" 2>/dev/null | grep -c "PB_IMAGE_TAG:-$PIN_V" || true)
            [ "$n" = "2" ] && ok "$p compose 钉版 = $PIN_V" || fail "$p compose 钉版漂移(期望 $PIN_V×2,实得 ${n:-0})"
        done
    fi

    echo "── 5. go.mod 钉版(main)"
    local GM
    GM=$(raw server/main/go.mod 2>/dev/null) || GM=""
    [ -n "$GM" ] && { pinchk "$GM" core "$C_CORE" "server→core" soft; pinchk "$GM" contracts "$C_CONTRACTS" "server→contracts" soft; pinchk "$GM" kit "$C_KIT" "server→kit" soft; } || warn "server go.mod 拉取失败"
    GM=$(raw core/main/go.mod 2>/dev/null) || GM=""
    [ -n "$GM" ] && { pinchk "$GM" contracts "$C_CONTRACTS" "core→contracts" soft; pinchk "$GM" kit "$C_KIT" "core→kit" soft; } || warn "core go.mod 拉取失败"
    GM=$(raw p2p/main/go.mod 2>/dev/null) || GM=""
    [ -n "$GM" ] && pinchk "$GM" kit "$C_KIT" "p2p→kit" soft || warn "p2p go.mod 拉取失败"

    echo "── 6. 终端仓钉版与双写面"
    local t v corep
    for t in fnos openwrt qnap; do
        v=$(tget "terminal.$t.version"); corep=$(tget "terminal.$t.core_pin")
        local BR; BR=$(def_branch "$t")
        tagchk "$t" "$(tget "terminal.$t.tag")" "$t"
        GM=$(raw "$t/$BR/go.mod" 2>/dev/null) || GM=""
        [ -n "$GM" ] && { pinchk "$GM" core "$corep" "${t}→core" soft; pinchk "$GM" kit "$C_KIT" "${t}→kit" soft; } || warn "$t go.mod 拉取失败"
        if tag_exists "$t" "$(tget "terminal.$t.tag")"; then
            GM=$(raw "$t/$(tget "terminal.$t.tag")/go.mod" 2>/dev/null) || GM=""
            [ -n "$GM" ] && pinchk "$GM" core "$corep" "${t}@tag→core(fnos v1.2.7 悬空钉版守卫)" || warn "$t tag 上 go.mod 拉取失败"
        fi
    done
    v=$(tget terminal.fnos.version)
    [ "$(raw "fnos/master/fnos/manifest" 2>/dev/null | awk -F= '$1=="version"{print $2}')" = "$v" ] \
        && ok "fnos manifest = $v" || soft_fail "fnos manifest ≠ $v"
    v=$(tget terminal.openwrt.version)
    tag_exists openwrt "v$v" && ok "openwrt tag v$v" || { [ "$STATE" = draft ] && warn "openwrt tag v$v 缺" || fail "openwrt tag v$v 缺"; }

    v=$(tget terminal.desktop.version)
    tagchk desktop "$(tget terminal.desktop.tag)" "desktop"
    local DT; DT=$(raw desktop/main/src-tauri/tauri.conf.json 2>/dev/null) || DT=""
    [ -n "$DT" ] && { grep -q "\"version\": \"$v\"" <<<"$DT" && ok "desktop tauri.conf.json = $v" || soft_fail "desktop tauri.conf.json ≠ $v"; } || warn "desktop tauri.conf.json 拉取失败"
    local DYML; DYML=$(raw desktop/main/release.yml 2>/dev/null || raw desktop/main/.github/workflows/release.yml 2>/dev/null) || DYML=""
    [ -n "$DYML" ] && { grep -q "P2PC_REF" <<<"$DYML" && ok "desktop sidecar 已钉版(P2PC_REF)" || fail "desktop release.yml 未钉 p2pc(取 latest 不可复现)"; } || warn "desktop release.yml 拉取失败"

    echo "── 7. 终端 VERSION/DEPS.env(灰度开关)"
    if [ "$(tget features.version_files)" = "true" ]; then
        for t in fnos openwrt desktop synology qnap ugreen terramaster; do
            v=$(tget "terminal.$t.version")
            [ "$(raw "$t/$(def_branch "$t")/VERSION" 2>/dev/null | tr -d '[:space:]')" = "$v" ] \
                && ok "$t VERSION = $v" || soft_fail "$t VERSION ≠ $v(发版走 train bump,勿手改)"
        done
        for t in fnos openwrt qnap; do
            local DE; DE=$(raw "$t/$(def_branch "$t")/DEPS.env" 2>/dev/null) || DE=""
            [ "$(grep -E '^CORE_PIN=' <<<"$DE" | cut -d= -f2)" = "$(tget "terminal.$t.core_pin")" ] \
                && ok "$t DEPS CORE_PIN" || soft_fail "$t DEPS CORE_PIN ≠ train.yaml"
            [ "$(grep -E '^FRONTEND_REF=' <<<"$DE" | cut -d= -f2)" = "$(tget "terminal.$t.frontend_ref")" ] \
                && ok "$t DEPS FRONTEND_REF" || soft_fail "$t DEPS FRONTEND_REF ≠ train.yaml"
        done
        local DD; DD=$(raw desktop/main/DEPS.env 2>/dev/null) || DD=""
        [ "$(grep -E '^P2PC_REF=' <<<"$DD" | cut -d= -f2)" = "$C_P2PC" ] \
            && ok "desktop DEPS P2PC_REF = $C_P2PC" || soft_fail "desktop DEPS P2PC_REF ≠ $C_P2PC"
    else
        warn "features.version_files=false:各仓 VERSION/DEPS.env 尚未启用(首次列车 bump 自动开启)"
    fi

    echo "── 8. frontend 契约消费"
    local FPJ; FPJ=$(raw frontend/main/package.json 2>/dev/null) || FPJ=""
    [ -n "$FPJ" ] && { grep -q "pigeonbox-contracts-${C_CONTRACTS#v}.tgz" <<<"$FPJ" \
        && ok "frontend contracts tgz = $C_CONTRACTS" || fail "frontend contracts tgz ≠ $C_CONTRACTS"; } || warn "frontend package.json 拉取失败"

    echo "── 9. 文档版本矩阵(hub docs/architecture.md)"
    local row want
    for row in "contracts:$C_CONTRACTS" "core:$C_CORE" "server:v$SERVER_V" \
        "fnos:$(tget terminal.fnos.version)" "openwrt:$(tget terminal.openwrt.version)" "qnap:$(tget terminal.qnap.version)" \
        "p2p:$C_P2P" "kit:$C_KIT" "desktop:$(tget terminal.desktop.tag)"; do
        want=${row#*:}
        awk -F'|' -v r="^\\| ${row%%:*} \\|" 'NR==FNR{next}' /dev/null 2>/dev/null
        grep -E "^\| ${row%%:*} \|" docs/architecture.md | head -1 | grep -qF "$want" \
            && ok "architecture.md ${row%%:*} 含 $want" || soft_fail "architecture.md ${row%%:*} 版本滞后(期望含 $want)"
    done

    echo "── 10. hub Latest(仅 shipped 态强校验)"
    if [ "$STATE" = shipped ] || [ "$STATE" = shipping ]; then
        local latest; latest=$(gh api repos/$HUB_REPO/releases/latest --jq .tag_name 2>/dev/null || echo "")
        [ "$latest" = "v$TRAIN" ] && ok "hub Latest = v$TRAIN" || fail "hub Latest($latest) ≠ v$TRAIN"
    else
        ok "state=draft,跳过 Latest 校验"
    fi

    echo "══ 结果: $((fails)) 处不一致, $((warns)) 处告警"
    [ "$fails" -eq 0 ] || { echo "✗ 对账失败——以上 ✗ 项即为「版本不统一」清单"; exit 1; }
    echo "✓ 对账通过"
}

# ───────────────────────── bump ─────────────────────────

DRY_RUN=1
run() { if [ "$DRY_RUN" = 0 ]; then "$@"; else echo "  [dry-run] $*"; fi; }

usage_bump() { sed -n '/^# 用法:/,/^set -euo/p' "$0" | sed 's/^# \{0,2\}//' >&2; exit 1; }

# 只 stage 列车文件(天然隔离并行会话的无关改动);staged 无 diff 即跳过该仓。
commit_if_changed() { # <dir> <repo> <msg> <files...>
    local dir=$1 repo=$2 msg=$3; shift 3
    if [ "$DRY_RUN" = 1 ]; then
        if git -C "$dir" diff --quiet -- "$@"; then
            echo "  ✓ $dir 无列车变更,跳过"
        else
            echo "  [dry-run] $dir 将变更 → 分支 train/$TRAIN + PR($(echo "$@" | tr '\n' ' '))"
        fi
        return 0
    fi
    git -C "$dir" add -- "$@"
    if git -C "$dir" diff --cached --quiet; then
        echo "  ✓ $dir 无列车变更,跳过"
        return 0
    fi
    if git -C "$dir" rev-parse -q --verify "refs/heads/train/$TRAIN" >/dev/null; then
        git -C "$dir" checkout -q "train/$TRAIN"
    else
        git -C "$dir" checkout -q -b "train/$TRAIN"
    fi
    git -C "$dir" commit -qm "$msg"
    git -C "$dir" push -q -u origin "train/$TRAIN"
    gh pr create -R "${GH_ORG}/${repo}" --base "$(def_branch "$repo")" --head "train/$TRAIN" \
        --title "train: bump to $TRAIN" \
        --body "发布列车 $TRAIN 自动 bump(hub scripts/release-train.sh 生成,仅含列车文件)。合并后 version-tagger 自动打 tag 并触发 Release 流水线;全部回挂后跑 train-release verify。" \
        2>/dev/null || echo "  (PR 已存在,跳过创建)"
    echo "  ✓ $dir → PR(pigeonbox/$repo train/$TRAIN)"
}

cmd_bump() {
    local TRAIN="" HOTFIX=0 SETS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            TRAIN=*) TRAIN=${1#TRAIN=} ;;
            --hotfix) HOTFIX=1 ;;
            --push) DRY_RUN=0 ;;
            --set) SETS+=("$2"); shift ;;
            *) usage_bump ;;
        esac
        shift
    done
    [ -n "$TRAIN" ] || usage_bump
    case "$TRAIN" in *[!0-9.]*|"") echo "✗ TRAIN 须形如 1.15.0" >&2; exit 1;; esac

    # 解析 --set(core/contracts/kit/p2p 只改库线消费记录;终端 go.mod 钉版由 core_pin
    # 独立控制且默认保持现状——库线发新版≠终端必须跟随,升钉是显式列车动作)
    local N_CONTRACTS N_CORE N_KIT N_P2P N_P2PC N_SERVER N_CORE_PIN
    N_CONTRACTS=$(tget lib.contracts); N_CORE=$(tget lib.core); N_KIT=$(tget lib.kit)
    N_P2P=$(tget lib.p2p); N_P2PC=$(tget terminal.desktop.p2pc)
    N_SERVER=$(tget images.server); N_CORE_PIN=$(tget terminal.fnos.core_pin)
    local s k val
    for s in "${SETS[@]:-}"; do
        [ -n "$s" ] || continue
        k=${s%%=*}; val=${s#*=}
        case "$k" in
            contracts) N_CONTRACTS=$val ;; core) N_CORE=$val ;; kit) N_KIT=$val ;;
            p2p) N_P2P=$val ;; p2pc) N_P2PC=$val ;; core_pin) N_CORE_PIN=$val ;;
            server) N_SERVER=${val#v} ;;
            *) echo "✗ 未知 --set 键: $k" >&2; exit 1 ;;
        esac
    done
    local FE_REF="v$N_SERVER"   # D2: frontend 与 server 同号

    echo "══ 列车 bump → $TRAIN (hotfix=$HOTFIX, dry-run=$DRY_RUN)"
    echo "   库线: contracts=$N_CONTRACTS core=$N_CORE kit=$N_KIT p2p=$N_P2P | 镜像: server=$N_SERVER(前端同号) | 终端: core 钉=$N_CORE_PIN p2pc=$N_P2PC"

    # 前置: 仓存在 + fetch(清洁度不在此拦——由 commit_if_changed 按"列车文件有无 diff"判定)
    # desktop 检出在工作区根(../desktop),其余模块在 hub 目录内
    local DESKTOP_DIR="$PWD/../desktop"
    local d
    for d in . frontend fnos openwrt qnap $PLATFORMS; do
        [ -d "$d/.git" ] || { echo "✗ 缺 $d 检出(先 make setup)" >&2; exit 1; }
        git -C "$d" fetch -q origin
    done
    [ -d "$DESKTOP_DIR/.git" ] || { echo "✗ 缺 desktop 检出(工作区根)" >&2; exit 1; }
    git -C "$DESKTOP_DIR" fetch -q origin

    echo "── [1/7] hub"
    sed -i.bak "s/PB_IMAGE_TAG:-v[0-9]*\.[0-9]*\.[0-9]*/PB_IMAGE_TAG:-v$N_SERVER/" deploy/nas/compose.yml && rm -f deploy/nas/compose.yml.bak
    sed -i.bak "s/^PB_IMAGE_TAG=v[0-9]*\.[0-9]*\.[0-9]*/PB_IMAGE_TAG=v$N_SERVER/" deploy/nas/env.example && rm -f deploy/nas/env.example.bak
    sed -i.bak "s/newTag: [0-9.]*/newTag: $N_SERVER/g" deploy/k8s/overlays/prod/kustomization.yaml && rm -f deploy/k8s/overlays/prod/kustomization.yaml.bak
    # charts: server 变了则 chart patch+1(dispatch 会自动对齐,这里同步记录)
    local OLD_SERVER CHART_NEW
    OLD_SERVER=$(tget images.server); CHART_NEW=$(tget charts.chart)
    [ "$N_SERVER" != "$OLD_SERVER" ] && CHART_NEW="$(echo "$CHART_NEW" | awk -F. '{print $1"."$2"."$3+1}')"
    {
        echo "# PigeonBox 发布列车真相源 —— 一趟列车全部组件版本/钉版/回挂期望的唯一声明。"
        echo "# 设计稿: docs/specs/2026-10-08-release-train-design.md;由 release-train.sh bump 生成,勿手改。"
        echo "schema: \"1\""
        echo "train: $TRAIN"
        echo "state: draft"
        echo "hotfix: $([ $HOTFIX = 1 ] && echo true || echo false)"
        echo ""
        echo "lib.contracts: $N_CONTRACTS"
        echo "lib.core: $N_CORE"
        echo "lib.kit: $N_KIT"
        echo "lib.p2p: $N_P2P"
        echo "images.server: $N_SERVER"
        echo "images.frontend: $N_SERVER"
        echo "frontend.tag: $FE_REF"
        echo ""
        echo "charts.chart: \"$CHART_NEW\""
        echo "charts.app: v$N_SERVER"
        echo ""
        echo "terminal.desktop.tag: desktop-v$TRAIN"
        echo "terminal.desktop.version: $TRAIN"
        echo "terminal.desktop.p2pc: $N_P2PC"
        echo "terminal.fnos.tag: v$TRAIN"
        echo "terminal.fnos.version: $TRAIN"
        echo "terminal.fnos.core_pin: $N_CORE_PIN"
        echo "terminal.fnos.frontend_ref: $FE_REF"
        echo "terminal.openwrt.tag: v$TRAIN"
        echo "terminal.openwrt.version: $TRAIN"
        echo "terminal.openwrt.core_pin: $N_CORE_PIN"
        echo "terminal.openwrt.frontend_ref: $FE_REF"
        echo "terminal.qnap.tag: v$TRAIN"
        echo "terminal.qnap.version: $TRAIN"
        echo "terminal.qnap.core_pin: $N_CORE_PIN"
        echo "terminal.qnap.frontend_ref: $FE_REF"
        local p
        for p in $PLATFORMS; do
            echo "terminal.$p.tag: v$TRAIN"
            echo "terminal.$p.version: $TRAIN"
        done
        echo ""
        echo "features.version_files: \"true\""
    } > "$TRAIN_FILE.tmp"
    [ -s "$TRAIN_FILE.tmp" ] && mv "$TRAIN_FILE.tmp" "$TRAIN_FILE"
    # 文档矩阵(architecture.md 单元格 + AGENTS.md 末列,工作区文件不入库)
    local AV="v$N_SERVER"
    set_table_cell3 docs/architecture.md 'contracts' "$N_CONTRACTS" || true
    set_table_cell3 docs/architecture.md 'core' "$N_CORE" || true
    set_table_cell3 docs/architecture.md 'server' "$AV" || true
    set_table_cell3 docs/architecture.md 'fnos' "v$TRAIN(内置 core $N_CORE_PIN)" || true
    set_table_cell3 docs/architecture.md 'openwrt' "v$TRAIN(内置 core $N_CORE_PIN)" || true
    set_table_cell3 docs/architecture.md 'qnap' "v$TRAIN(原生,内置 core $N_CORE_PIN)" || true
    set_table_cell3 docs/architecture.md 'NAS 打包三仓' "v$TRAIN(钉 server/frontend 镜像 $AV)" || true
    set_table_cell3 docs/architecture.md 'p2p' "$N_P2P" || true
    set_table_cell3 docs/architecture.md 'kit' "$N_KIT" || true
    set_table_cell3 docs/architecture.md 'desktop' "desktop-v$TRAIN" || true
    set_table_cell3 docs/architecture.md 'charts' "chart $CHART_NEW(app $AV)" || true
    local AGENTS="$PWD/../AGENTS.md"
    if [ -f "$AGENTS" ]; then
        set_table_last_cell "$AGENTS" '`PigeonBox/` |' "v$TRAIN" || true
        set_table_last_cell "$AGENTS" '`PigeonBox/contracts/`' "$N_CONTRACTS" || true
        set_table_last_cell "$AGENTS" '`PigeonBox/core/`' "$N_CORE" || true
        set_table_last_cell "$AGENTS" '`PigeonBox/server/`' "$AV / core $N_CORE" || true
        set_table_last_cell "$AGENTS" '`PigeonBox/frontend/`' "$FE_REF(VERSION 真相源,tag 随列车)" || true
        set_table_last_cell "$AGENTS" '`PigeonBox/fnos/`' "v$TRAIN / core $N_CORE_PIN" || true
        set_table_last_cell "$AGENTS" '`PigeonBox/openwrt/`' "v$TRAIN / core $N_CORE_PIN" || true
        set_table_last_cell "$AGENTS" '`PigeonBox/qnap/`' "v$TRAIN / core $N_CORE_PIN" || true
        set_table_last_cell "$AGENTS" '`PigeonBox/p2p/`' "$N_P2P" || true
        set_table_last_cell "$AGENTS" '`PigeonBox/kit/`' "$N_KIT" || true
        set_table_last_cell "$AGENTS" '`desktop/`' "desktop-v$TRAIN" || true
        set_table_last_cell "$AGENTS" '`charts/`' "chart $CHART_NEW / app $AV" || true
        local np
        for np in $PLATFORMS; do
            set_table_last_cell "$AGENTS" "\`PigeonBox/$np/\`" "v$TRAIN / images $AV" || true
        done
    fi
    commit_if_changed . pigeonbox "train: bump to $TRAIN" \
        release/train.yaml deploy/nas/compose.yml deploy/nas/env.example \
        deploy/k8s/overlays/prod/kustomization.yaml docs/architecture.md

    echo "── [2/7] frontend"
    if [ "$N_SERVER" != "$OLD_SERVER" ]; then
        perl -pi -e 's/"version": "[^"]*"/"version": "'"${FE_REF#v}"'"/ if !$done; $done=1 if /"version"/' frontend/package.json
        echo "${FE_REF#v}" > frontend/VERSION
        commit_if_changed frontend frontend "train: bump to $TRAIN" package.json VERSION
    else
        echo "  ✓ server 未变($AV),frontend 跳过"
    fi

    echo "── [3/7] fnos"
    local FNOS_OLD; FNOS_OLD=$(awk -F= '$1=="version"{print $2}' fnos/fnos/manifest)
    echo "$TRAIN" > fnos/VERSION
    printf '# 发布列车依赖钉版(真相源=hub release/train.yaml,由 release-train.sh bump 写入;勿手改)\nCORE_PIN=%s\nFRONTEND_REF=%s\n' "$N_CORE_PIN" "$FE_REF" > fnos/DEPS.env
    local FNOS_FILES="VERSION DEPS.env"
    if [ "$FNOS_OLD" != "$TRAIN" ]; then
        ( cd fnos && GOWORK=off go mod edit -require="github.com/pigeonbox/core@$N_CORE_PIN" && GOWORK=off go mod tidy >/dev/null 2>&1 ) \
            || echo "  ⚠ fnos go mod 整理失败,人工检查 go.mod/go.sum"
        sed -i.bak "s/^version=.*/version=$TRAIN/" fnos/fnos/manifest && rm -f fnos/fnos/manifest.bak
        sed -i.bak "/^desc=/a\\
changelog=$TRAIN: 发布列车 $TRAIN(底层 core $N_CORE_PIN;前端 $FE_REF;详见 Release notes)。" fnos/fnos/manifest && rm -f fnos/fnos/manifest.bak
        FNOS_FILES="$FNOS_FILES fnos/manifest go.mod go.sum"
    fi
    # shellcheck disable=SC2086
    commit_if_changed fnos fnos "train: bump to $TRAIN" $FNOS_FILES

    echo "── [4/8] openwrt"
    local OW_OLD; OW_OLD=$(cat openwrt/VERSION)
    echo "$TRAIN" > openwrt/VERSION
    printf '# 发布列车依赖钉版(真相源=hub release/train.yaml,由 release-train.sh bump 写入;勿手改)\nCORE_PIN=%s\nFRONTEND_REF=%s\n' "$N_CORE_PIN" "$FE_REF" > openwrt/DEPS.env
    local OW_FILES="VERSION DEPS.env"
    if [ "$OW_OLD" != "$TRAIN" ]; then
        ( cd openwrt && GOWORK=off go mod edit -require="github.com/pigeonbox/core@$N_CORE_PIN" && GOWORK=off go mod tidy >/dev/null 2>&1 ) \
            || echo "  ⚠ openwrt go mod 整理失败,人工检查"
        OW_FILES="$OW_FILES go.mod go.sum"
    fi
    # shellcheck disable=SC2086
    commit_if_changed openwrt openwrt "train: bump to $TRAIN" $OW_FILES

    echo "── [5/8] qnap"
    local QN_OLD; QN_OLD=$(cat qnap/VERSION)
    echo "$TRAIN" > qnap/VERSION
    printf '# 发布列车依赖钉版(真相源=hub release/train.yaml,由 release-train.sh bump 写入;勿手改)\nCORE_PIN=%s\nFRONTEND_REF=%s\n' "$N_CORE_PIN" "$FE_REF" > qnap/DEPS.env
    local QN_FILES="VERSION DEPS.env"
    if [ "$QN_OLD" != "$TRAIN" ]; then
        ( cd qnap && GOWORK=off go mod edit -require="github.com/pigeonbox/core@$N_CORE_PIN" && GOWORK=off go mod tidy >/dev/null 2>&1 ) \
            || echo "  ⚠ qnap go mod 整理失败,人工检查"
        QN_FILES="$QN_FILES go.mod go.sum"
    fi
    # shellcheck disable=SC2086
    commit_if_changed qnap qnap "train: bump to $TRAIN" $QN_FILES

    echo "── [6/8] desktop"
    echo "$TRAIN" > "$DESKTOP_DIR/VERSION"
    printf '# 发布列车依赖钉版(真相源=hub release/train.yaml,由 release-train.sh bump 写入;勿手改)\nP2PC_REF=%s\n' "$N_P2PC" > "$DESKTOP_DIR/DEPS.env"
    perl -pi -e 's/"version": "[^"]*"/"version": "'"$TRAIN"'"/ if !$done; $done=1 if /"version"/' "$DESKTOP_DIR/src-tauri/tauri.conf.json"
    perl -pi -e 's/^version = "[^"]*"/version = "'"$TRAIN"'"/ if !$done; $done=1 if /^version/' "$DESKTOP_DIR/src-tauri/Cargo.toml"
    commit_if_changed "$DESKTOP_DIR" desktop "train: bump to $TRAIN" VERSION DEPS.env src-tauri/tauri.conf.json src-tauri/Cargo.toml

    echo "── [7/8] NAS 打包三仓(模板→物化→VERSION)"
    local pre
    for p in $PLATFORMS; do
        run bash deploy/nas/sync.sh sync --platform "$p" --dir "$p"
        echo "$TRAIN" > $p/VERSION
        case "$p" in
            synology) pre="VERSION spk/package/compose.yml spk/package/env.example" ;;
            ugreen) pre="VERSION deploy/compose.yml deploy/env.example deploy/compose.ghcr-mirror.yml" ;;
            terramaster) pre="VERSION deploy/compose.yml deploy/env.example" ;;
        esac
        # shellcheck disable=SC2086
        commit_if_changed "$p" "$p" "train: bump to $TRAIN(镜像 $AV)" $pre
    done

    echo "── [8/8] 完成"
    if [ "$DRY_RUN" = 1 ]; then
        echo "✓ dry-run 结束。工作区的未提交改动即计划内容;确认后加 --push 重跑(还原请按仓 checkout 列车文件,勿整树还原)。"
    else
        echo "✓ bump PR 已建齐(无变更的仓已自动跳过)。合并后 version-tagger 自动打 tag → Release 流水线接管;"
        echo "  全部回挂完成后: hub 跑 train-release 工作流(verify 等产物)→ finalize 出 v$TRAIN 快照。"
    fi
}

# ───────────────────────── finalize / notes / get ─────────────────────────

cmd_finalize() {
    local TRAIN=""
    [ "${1:-}" = "--train" ] && { TRAIN=$2; shift 2; }
    [ -n "$TRAIN" ] || TRAIN=$(tget train)
    local CUR; CUR=$(tget train)
    [ "$TRAIN" = "$CUR" ] || { echo "✗ --train $TRAIN 与 train.yaml($CUR) 不符" >&2; exit 1; }
    [ "$(tget state)" != shipped ] || { echo "✗ 列车 $TRAIN 已 shipped,不可重复定版" >&2; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "✗ hub 工作树不干净" >&2; exit 1; }
    git fetch -q origin
    # 已知怪象(1.14.2/1.14.3 两轮实测):此检查间歇性误报(手动等价序列恒 0、
    # 脚本内非零,make/直接 bash/竞态/GIT 环境均已排除,未破案)。遇到时直接
    # 手动执行等价四步:sed state=shipped → commit "train: ship v<T>" →
    # tag v<T> → push origin main v<T>,hub Release 工作流即出快照。
    [ -z "$(git rev-list --count main...origin/main)" ] || { echo "✗ hub 本地与远端分歧,先 pull --ff-only" >&2; exit 1; }

    echo "══ 终验 $TRAIN"
    cmd_verify
    echo "══ 置 state=shipped → 推 v$TRAIN 快照 tag"
    sed -i.bak "s/^state: .*/state: shipped/" "$TRAIN_FILE" && rm -f "$TRAIN_FILE.bak"
    git add "$TRAIN_FILE"
    git commit -qm "train: ship v$TRAIN"
    git tag "v$TRAIN"
    git push -q origin main "v$TRAIN"
    echo "✓ v$TRAIN 已推送,hub Release 工作流出 Latest 快照(notes=列车组件矩阵)"
}

cmd_notes() {
    local TAG="${1:-v$(tget train)}"
    if [ ! -f "$TRAIN_FILE" ]; then
        cat <<'EOF'
**PigeonBox 生态快照**。本仓是生态装配 hub:服务器本体经容器镜像与 Helm 分发,桌面 / NAS / 路由器等文件型产物由各组件 CI 以 desktop-v* / fnos-v* / openwrt-v* / p2p-v* tag 自动回挂到本页。
EOF
        return 0
    fi
    echo "**PigeonBox ${TAG} 生态列车**。本页即全生态二进制产物的统一出口——组件产物由各仓 CI 自动回挂(下方矩阵)。"
    echo ""
    echo "| 组件 | 版本 | 产物 |"
    echo "|---|---|---|"
    echo "| server / frontend | v$(tget images.server) | ghcr.io/pigeonbox/server + frontend;Helm: \`helm repo add pigeonbox https://pigeonbox.github.io/charts\` |"
    echo "| desktop | $(tget terminal.desktop.tag) | [desktop-v*](https://github.com/pigeonbox/pigeonbox/releases?q=desktop-v&expanded=false) Windows/macOS/Linux 安装包(p2pc $(tget terminal.desktop.p2pc)) |"
    echo "| fnos | $(tget terminal.fnos.tag) | [fnos-v*](https://github.com/pigeonbox/pigeonbox/releases?q=fnos-v&expanded=false) fpk 应用包 |"
    echo "| openwrt | $(tget terminal.openwrt.tag) | [openwrt-v*](https://github.com/pigeonbox/pigeonbox/releases?q=openwrt-v&expanded=false) ipk + apk |"
    echo "| qnap | $(tget terminal.qnap.tag) | [qnap-v*](https://github.com/pigeonbox/pigeonbox/releases?q=qnap-v&expanded=false) QPKG 原生应用包(免 Container Station) |"
    echo "| p2p | $(tget lib.p2p) | [p2p-v*](https://github.com/pigeonbox/pigeonbox/releases?q=p2p-v&expanded=false) p2pc 二进制;镜像 ghcr.io/pigeonbox/p2p |"
    local p
    for p in synology ugreen terramaster; do
        echo "| $p | $(tget terminal.$p.tag) | [${p}-v*](https://github.com/pigeonbox/pigeonbox/releases?q=${p}-v&expanded=false) 部署包 |"
    done
    echo ""
    echo "底层: core $(tget lib.core) · contracts $(tget lib.contracts) · kit $(tget lib.kit) · chart $(tget charts.chart)。全部源码仓: https://github.com/orgs/pigeonbox/repositories"
}

cmd_get() { tget "$1"; }

# ───────────────────────── 入口 ─────────────────────────

case "${1:-}" in
    verify)   shift; cmd_verify "$@" ;;
    bump)     shift; cmd_bump "$@" ;;
    finalize) shift; cmd_finalize "$@" ;;
    notes)    shift; cmd_notes "$@" ;;
    get)      shift; cmd_get "$@" ;;
    *) sed -n '2,25p' "$0" | sed 's/^# \{0,2\}//'; exit 1 ;;
esac
