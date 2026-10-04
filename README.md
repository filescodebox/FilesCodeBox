# FilesCodeBox(umbrella) · 文件快递柜

[![License](https://img.shields.io/github/license/filescodebox/filescodebox)](LICENSE)
[![Tag](https://img.shields.io/github/v/tag/filescodebox/filescodebox)](https://github.com/filescodebox/filescodebox/tags)
[![Downloads](https://img.shields.io/github/downloads/filescodebox/filescodebox/total?label=%E5%AE%89%E8%A3%85%E5%8C%85%E4%B8%8B%E8%BD%BD)](https://github.com/filescodebox/filescodebox/releases)

高性能文件/文本匿名分享平台(**FilesCodeBox · 文件快递柜**)的**装配仓库**:本仓不含业务代码,只负责把各模块仓库拉齐成一个可开发、可构建、可部署的完整工作区。

> 🗂️ [组织主页](https://github.com/orgs/filescodebox)有生态总览与各形态(Docker / Kubernetes / 桌面 / NAS)快速开始。
> 拆分前的单仓库完整版本保留在 [legacy 分支](https://github.com/filescodebox/FileCodeBox/tree/legacy)(全量历史)。
> English overview: [README.en-US.md](README.en-US.md)

## 模块仓库

| 仓库 | 角色 | 版本 |
|------|------|------|
| [contracts](https://github.com/filescodebox/contracts) | 契约层:错误码 + Thrift 生成类型(纯类型,零业务依赖) | v0.2.1 |
| [core](https://github.com/filescodebox/core) | 业务核心库:11 个域服务 + repo/storage + `bootstrap.Bootstrap()` 库入口 | v0.8.0 |
| [server](https://github.com/filescodebox/server) | 独立部署应用:main 薄壳 + 配置模板 + Dockerfile(0.9.0 起纯后端) | v0.10.0 |
| [frontend](https://github.com/filescodebox/frontend) | Vue3 + TS + Vite + Element Plus(nginx 分离镜像,随 server 同版本发布) | - |
| [desktop](https://github.com/filescodebox/desktop) | 桌面客户端:Tauri 2 托盘常驻,连接任意 FilesCodeBox 服务器 | desktop-v1.2.0 |
| [fnos](https://github.com/filescodebox/fnos) | 飞牛 fnOS 应用适配(可选,`make setup` 默认拉取) | v1.2.0 |
| [p2p](https://github.com/filescodebox/p2p) | P2P 联邦注册中心:节点租约注册 + 口令联邦路由(可选,默认拉取) | v0.1.0 |
| [kit](https://github.com/filescodebox/kit) | 共享 Go 工具库:20 个零生态依赖通用包(retry/syncx/ratelimit 等) | v0.1.0 |
| [charts](https://github.com/filescodebox/charts) | Kubernetes Helm Chart:前后端分离双 Deployment | filecodebox-1.3.5 |

依赖方向(单向,CI 守护):`server / fnos / frontend ──► core ──► contracts`;`p2p`、`kit` 为零生态依赖叶子仓(desktop 经 HTTP API 连接,无构建期依赖)

## 快速开始

```bash
git clone https://github.com/filescodebox/filescodebox.git && cd filescodebox

make setup     # 拉齐模块仓库(幂等,重复执行=更新)
make test      # 全仓测试(Go 各模块 + 前端 typecheck)
make lint      # golangci-lint 各 Go 模块(CI 同款门禁)
make build     # workspace 联编
make smoke     # 起 server 跑冒烟(健康检查/admin登录/文本分享)
# bash scripts/smoke-full.sh   # 全能力真机冒烟(39 项断言,含临时 Redis)
```

纯 Docker 部署(详见 [docs/DEPLOY-COMPOSE.md](docs/DEPLOY-COMPOSE.md)):

```bash
cp .env.example .env          # 可选,全部项有安全默认
docker compose up -d          # ghcr 发布镜像;前端入口 http://localhost(FCB_HTTP_PORT,默认 80),API :12345
# BUILD=1 make compose-up     # 本地构建(需先 make setup)
# docker compose --profile nginx up -d   # 加 nginx 反代(须配 FCB_TRUSTED_PROXIES,见部署指南)
```

默认管理员 `admin / admin123`(生产务必以 `FCB_ADMIN_PASSWORD` 覆盖)。JWT 密钥留空时首启自动生成并持久化到 `./data/.jwt_secret`。

## 工作区布局(setup 后)

```
filescodebox/           ← 本仓(装配层:脚本/联编/编排)
├── go.work             # contracts+core+server+fnos+p2p+kit 本地联编
├── contracts/  core/  server/  frontend/  fnos/  p2p/  kit/   ← 独立 git 仓库(gitignore 掉)
└── data/               ← compose 数据卷
```

各模块仓库独立开发、独立 CI、独立发版;`server/Dockerfile` 的构建上下文恰好就是本目录,`make docker` 直接出完整镜像。

## 发版

打 `v*` tag 即自动构建多架构镜像推 ghcr(见各仓 `release.yml`):
`ghcr.io/filescodebox/server` · `ghcr.io/filescodebox/frontend`(与 server 同版本) · `ghcr.io/filescodebox/fnos`。
桌面安装包(desktop-v*)与飞牛应用包(fnos-v*)统一回挂[本仓 Releases](https://github.com/filescodebox/filescodebox/releases)。

## 原 README(产品功能/截图/API 说明)

见 [legacy 分支 README](https://github.com/filescodebox/FileCodeBox/blob/legacy/README.md)。

## License

[Apache-2.0](LICENSE)
