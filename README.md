<div align="center">

<img src="https://raw.githubusercontent.com/pigeonbox/pigeonbox/main/docs/brand/logo.svg" width="112" alt="PigeonBox"/>

</div>

# PigeonBox(umbrella) · 文件快递柜

[![License](https://img.shields.io/github/license/pigeonbox/pigeonbox)](LICENSE)
[![Tag](https://img.shields.io/github/v/tag/pigeonbox/pigeonbox)](https://github.com/pigeonbox/pigeonbox/tags)
[![Downloads](https://img.shields.io/github/downloads/pigeonbox/pigeonbox/total?label=%E5%AE%89%E8%A3%85%E5%8C%85%E4%B8%8B%E8%BD%BD)](https://github.com/pigeonbox/pigeonbox/releases)

高性能文件/文本匿名分享平台(**PigeonBox · 文件快递柜**)的**装配仓库**:本仓不含业务代码,只负责把各模块仓库拉齐成一个可开发、可构建、可部署的完整工作区。

> 🗂️ [组织主页](https://github.com/orgs/pigeonbox)有生态总览与各形态(Docker / Kubernetes / 桌面 / NAS)快速开始。
> 拆分前的单仓库完整版本保留在 [legacy 分支](https://github.com/pigeonbox/PigeonBox/tree/legacy)(全量历史)。
> English overview: [README.en-US.md](README.en-US.md)

## 模块仓库

| 仓库 | 角色 | 版本 |
|------|------|------|
| [contracts](https://github.com/pigeonbox/contracts) | 契约层:错误码 + Thrift 生成类型(纯类型,零业务依赖) | v0.8.0 |
| [core](https://github.com/pigeonbox/core) | 业务核心库:16 个域服务 + repo/storage + `bootstrap.Bootstrap()` 库入口 | v0.14.4 |
| [server](https://github.com/pigeonbox/server) | 独立部署应用:main 薄壳 + 配置模板 + Dockerfile(0.9.0 起纯后端) | v0.15.3 |
| [frontend](https://github.com/pigeonbox/frontend) | Vue3 + TS + Vite + Element Plus(nginx 分离镜像,随 server 同版本发布) | 随 server 同 `v*` |
| [desktop](https://github.com/pigeonbox/desktop) | 桌面客户端:Tauri 2 托盘常驻,连接任意 PigeonBox 服务器,p2pc sidecar 设备直传 | desktop-v1.4.0 |
| [fnos](https://github.com/pigeonbox/fnos) | 飞牛 fnOS 应用适配(可选,`make setup` 默认拉取) | v1.2.7 |
| [openwrt](https://github.com/pigeonbox/openwrt) | OpenWrt/iStoreOS 原生包(ipk+apk 双格式):procd 托管+UCI 配置+LuCI 集成,单端口 12345 内置 Web 界面 | v1.14.0 |
| [synology](https://github.com/pigeonbox/synology) | 群晖 DSM 7.2+ 套件(SPK,noarch):Container Manager 编排,向导设端口/数据目录/管理员密码 | v0.1.0 |
| [qnap](https://github.com/pigeonbox/qnap) | 威联通 QTS 5+ 应用(QPKG,x86_64+arm_64):Container Station 编排,数据落卷根 | v0.1.0 |
| [ugreen](https://github.com/pigeonbox/ugreen) | 绿联 UGOS Pro 部署包:Docker→项目 compose 一键粘贴(含国内加速编排) | v0.1.0 |
| [terramaster](https://github.com/pigeonbox/terramaster) | 铁威马 TOS 5/6/7 部署包:Docker Manager 项目导入 | v0.1.0 |
| [p2p](https://github.com/pigeonbox/p2p) | P2P 联邦注册中心:节点租约注册 + 口令联邦路由 + 设备直传信令(可选,默认拉取) | v0.4.3 |
| [kit](https://github.com/pigeonbox/kit) | 共享 Go 工具库:28 个零生态依赖通用包(retry/syncx/singleflight/shutdown/workflow 等) | v0.3.1 |
| [charts](https://github.com/pigeonbox/charts) | Kubernetes Helm Chart:前后端分离双 Deployment | pigeonbox-2.0.1 |

依赖方向(单向,CI 守护):`server / fnos / openwrt / frontend ──► core ──► contracts`;`core`、`p2p` 按需消费 `kit`(kit 为零生态依赖地基层);`p2p` 为业务链零依赖叶子仓(desktop 经 HTTP API 连接,无构建期依赖)

## 快速开始

```bash
git clone https://github.com/pigeonbox/pigeonbox.git && cd pigeonbox

make setup     # 拉齐模块仓库(幂等,重复执行=更新)
make test      # 全仓测试(Go 各模块 + 前端 typecheck)
make lint      # golangci-lint 各 Go 模块(CI 同款门禁)
make build     # workspace 联编
make smoke     # 起 server 跑冒烟(健康检查/admin 登录;44 项全量断言见下一行)
# bash scripts/smoke-full.sh   # 全能力真机冒烟(44 项断言,含临时 Redis)
```

纯 Docker 部署(详见 [docs/DEPLOY-COMPOSE.md](docs/DEPLOY-COMPOSE.md)):

```bash
cp .env.example .env          # 可选,全部项有安全默认
docker compose up -d          # ghcr 发布镜像;前端入口 http://localhost:12345(FCB_API_PORT,默认 12345),前端镜像同时反代 API,server 不发布端口
# BUILD=1 make compose-up     # 本地构建(需先 make setup)
# docker compose --profile nginx up -d   # 加 nginx 反代(须配 FCB_TRUSTED_PROXIES,见部署指南;FCB_HTTP_PORT 默认 80 仅作用于此 profile)
```

默认管理员 `admin / admin123`(生产务必以 `FCB_ADMIN_PASSWORD` 覆盖)。JWT 密钥留空时首启自动生成并持久化到 `./data/.jwt_secret`。

## 工作区布局(setup 后)

```
pigeonbox/           ← 本仓(装配层:脚本/联编/编排)
├── go.work             # contracts+core+server+fnos+p2p+kit 本地联编
├── contracts/  core/  server/  frontend/  fnos/  p2p/  kit/          ← 独立 git 仓库(gitignore 掉)
├── synology/  qnap/  ugreen/  terramaster/   ← NAS 打包四仓(纯 shell,同样 gitignore)
└── data/               ← compose 数据卷
```

各模块仓库独立开发、独立 CI、独立发版;`server/Dockerfile` 的构建上下文恰好就是本目录,`make docker` 直接出完整镜像。

## 发版

打 `v*` tag 即自动构建多架构镜像推 ghcr(见各仓 `release.yml`):
`ghcr.io/pigeonbox/server` · `ghcr.io/pigeonbox/frontend`(与 server 同版本) · `ghcr.io/pigeonbox/fnos` · `ghcr.io/pigeonbox/p2p`。
桌面安装包(desktop-v*)与 NAS 应用包(fnos-v*/openwrt-v*/synology-v*/qnap-v*/ugreen-v*/terramaster-v*)统一回挂[本仓 Releases](https://github.com/pigeonbox/pigeonbox/releases)。

## 原 README(产品功能/截图/API 说明)

见 [legacy 分支 README](https://github.com/pigeonbox/PigeonBox/blob/legacy/README.md)。

## License

[Apache-2.0](LICENSE)
