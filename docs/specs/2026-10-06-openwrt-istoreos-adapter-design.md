# OpenWrt / iStoreOS 适配层设计（filescodebox/openwrt）

- 日期: 2026-10-06
- 状态: 已批准实施（用户拍板"你搞吧"）
- 先例: [fnos 适配层](../../../../fnos/)（库式调 core + 应用包打包 + Release 双挂）完全同构

## 1. 目标与非目标

**目标**：FilesCodeBox 以原生 OpenWrt 包（ipk）形态运行在 OpenWrt/iStoreOS 设备上：

- 单进程 Go 二进制（业务 + 前端静态资源同端口服务），procd 托管，开机自启
- 匿名口令分享全功能可用（依赖 redis-server 包，opkg 自动拉取）
- UCI（`/etc/config/filescodebox`）为常用配置面；高级配置支持 drop-in config.yaml
- x86_64（iStoreOS 主流）与 aarch64_generic（ARM SBC，rockchip/rk35xx）双架构 ipk
- CI/Release 与生态同构：本仓 Release 挂 ipk + 回挂 hub `openwrt-v*`

**非目标（v1 明确不做）**：

- LuCI 集成页（luci-app）：v1 通过 `http://<路由器IP>:12345` 直接访问；留 v2（需处理 core CSP 与 iframe 关系）
- p2pc sidecar（设备直传）：desktop 侧已有，路由器侧待 p2p 生态成熟
- iStore 软件中心官方上架（需向 linkease 提交仓库审核）：v1 交付可侧载 ipk（iStore「手动安装」/ opkg 直装）
- ghcr 容器镜像：原生包形态无镜像需求

## 2. 关键决策与依据

| 决策 | 选择 | 依据 |
|---|---|---|
| 仓库形态 | 独立仓 `filescodebox/openwrt`（fnos 同构） | go.mod 钉 core 正式 tag 独立构建；工作区 go.work 联编本地 core 开发 |
| 二进制 | `/usr/bin/filescodebox`，`bootstrap.BootstrapWithOptions` + `WithStaticDir` | core v0.13.0 tag 已含（已验证）；纯 Go sqlite（glebarez）→ `CGO_ENABLED=0` 静态交叉编译 |
| JWT 密钥 | 移植 fnos `ensureJWTSecret`：未配置时自动生成强密钥持久化到数据目录（0600） | core 安全基线缺 secret 拒启；路由器用户不应被迫手工生成 |
| 前端 | ipk 内置 dist（`/usr/share/filescodebox/www/`），CI 从 frontend 仓构建 | core SPA 回退同端口服务前端（文件优先+SPA 回退，bootstrap.go:1167）；frontend 仓无 dist Release 资产，故 CI 源码构建 |
| Redis | ipk `Depends: redis-server`（OpenWrt packages 官方源） | 匿名取件强依赖 Redis（core bootstrap:667 降级但 anonymous 域直接报错）；原生形态无 Docker；官方源包带 procd init |
| 配置面 | UCI 常用项 → init 脚本翻译成 `FCB_*` env（env 优先级高于 yaml）；`/etc/filescodebox/config.yaml` 存在则以 `--config` 传入（高级面） | core envBindings 全集已核实；OpenWrt 惯例 UCI 优先，同时保留 core 全量配置逃生口 |
| 数据目录 | UCI `data_dir` 默认 `/etc/filescodebox/data` | overlay 可持久；README 建议大容量场景指到数据盘（如 `/mnt/sda1/filescodebox`） |
| 打包 | 无 SDK ipk 组装：外层纯 tar.gz（内含 ./debian-binary + control.tar.gz + data.tar.gz） | OpenWrt 23.05 起 ipk 即纯 tar.gz（对官方 zlib ipk 实测核对）；且须强制 ustar/gnu 格式——macOS bsdtar 默认 pax 扩展头 opkg 不识别会整条跳过（实测踩坑） |
| 架构 | `x86_64` + `aarch64_generic` 两 ipk | iStoreOS x86 主流 + ARM SBC（rockchip）；Architecture 字段须匹配 opkg arch |

## 3. 系统布局（安装后）

```
/usr/bin/filescodebox                 Go 静态二进制(业务+前端同端口)
/usr/share/filescodebox/www/          前端 dist(index.html + assets/)
/etc/config/filescodebox              UCI 配置(conffile)
/etc/init.d/filescodebox              procd init
/etc/filescodebox/config.yaml         可选高级配置(用户创建,不入包)
/etc/filescodebox/data/               默认数据目录(SQLite+上传文件+JWT密钥,首启创建)
```

procd init：`procd_set_param respawn`（崩溃重启）+ stdout/stderr 进 syslog；`START=99`（晚于 redis 的 START）。

## 4. UCI 配置面（v1）

```
config main 'main'
    option enabled '1'                    # 停用开关(init 检查)
    option port '12345'                   # → FCB_SERVER_PORT
    option host '0.0.0.0'                 # → FCB_SERVER_HOST
    option data_dir '/etc/filescodebox/data'  # → FCB_DATA_PATH / FCB_DATABASE_DB_NAME / FCB_STORAGE_PATH
    option open_upload '1'                # → FCB_OPEN_UPLOAD
    option admin_password ''              # → FCB_ADMIN_PASSWORD(空=默认 admin123,文档强制建议修改)
    option base_url ''                    # → FCB_SERVER_BASE_URL(presign 直下需要)

config redis 'redis'
    option enabled '1'                    # 关闭=匿名取件不可用(降级)
    option host '127.0.0.1'               # → FCB_REDIS_HOST
    option port '6379'                    # → FCB_REDIS_PORT
    option password ''                    # → FCB_REDIS_PASSWORD
```

固定注入（不可配）：`FCB_SERVER_MODE=release`、`FCB_PRODUCTION=1`、`FCB_DATABASE_DRIVER=sqlite`、`TZ`。
高级项（S3/OIDC/联邦/mcp…）走 `/etc/filescodebox/config.yaml` 或 `/etc/init.d/filescodebox` 自定义 env——UCI 面保持小。

## 5. ipk 控制文件

- `control`：`Package: filescodebox` / `Version: <semver>-1` / `Depends: libc, redis-server` / `Architecture: x86_64|aarch64_generic` / `Section: net`
- `conffiles`：`/etc/config/filescodebox`
- `postinst`（真机环境守卫 `[ -z "$IPKG_INSTROOT" ]`）：enable redis + filescodebox，未启动则 start（装完即用）
- `prerm`：stop filescodebox；卸载**不删数据**（`/etc/filescodebox/` 保留，文档注明清除路径）

## 6. 仓库结构与 CI

```
openwrt/
├─ cmd/filescodebox/main.go       ensureJWTSecret + BootstrapWithOptions + 优雅退出
├─ configs/config.yaml            模板(供用户复制为 drop-in 参考;不随 ipk 安装)
├─ openwrt/
│  ├─ filescodebox.init           procd init(UCI→env 翻译)
│  ├─ filescodebox.config         UCI 默认值
│  └─ filescodebox.postinst/.prerm
├─ scripts/build-ipk.sh           <goos arch 版本> → dist 树 → ipk(ar 组装)
├─ scripts/build-frontend.sh      frontend 仓 → npm build → dist(本地/CI共用)
├─ .github/workflows/ci.yml       vet+test+amd64 构建+ipk 组装+docker openwrt rootfs opkg 安装冒烟
├─ .github/workflows/release.yml  tag v* → 双架构 ipk → 本仓 Release + 回挂 hub openwrt-v*(OPENWRT_PAT, continue-on-error)
├─ Makefile / README.md / LICENSE(Apache-2.0) / .gitignore
```

- CI 冒烟：`docker run --platform linux/amd64 openwrt/rootfs` 镜像内 `opkg install ./filescodebox_*.ipk` → `/etc/init.d/filescodebox start`（容器内 redis 可装则真启，否则断言降级启动日志）→ `wget -qO- http://127.0.0.1:12345/ping`。redis-server 装不上（源不可达等）时冒烟降级为"安装+启动+ping"断言。
- Release 产物：`filescodebox_<ver>-1_x86_64.ipk`、`filescodebox_<ver>-1_aarch64_generic.ipk`；回挂 hub 与 desktop/fnos 完全同构（PAT 未配置 CI 放行失败、本地 `gh release upload` 兜底）。
- 版本注入：`-ldflags -X github.com/filescodebox/kit/version.{Version,BuildCommit,BuildTime}`（kit/version 惯例）。

## 7. 依赖钉版

- `github.com/filescodebox/core v0.13.0`（当前正式列车，server v0.14.0 同源）
- `github.com/filescodebox/kit v0.3.0`（version 注入）
- frontend：release 时构建 `main` 分支（frontend 未打 tag，Release notes 记录解析 commit SHA；frontend 发版后改为钉 tag——记入债务）

## 8. hub 接线

- `go.work`：+`./openwrt`
- `scripts/setup.sh`：+openwrt 块（`SETUP_OPENWRT=0` 可跳过），注释七→八模块
- hub `Makefile`：`test` 目标 +`./openwrt/...`
- hub `AGENTS.md`：生态仓库表、目录现状、依赖方向图（openwrt ─► core，同 fnos 位）、setup 旗标、常用命令
- org 门面：description/topics/homepage 同其余仓（中文+英文一句、topics 含 file-sharing、homepage 指 hub）

## 9. 风险与已知约束

- **RAM**：Go server + redis 建议 ≥512MB 内存设备（iStoreOS x86/ARM SBC 均满足；纯路由器 soc 不适用——文档写明）
- **overlay 容量**：默认数据目录在 overlay 上，大量文件须改 `data_dir` 指数据盘（README 置顶提示）
- **redis-server 包名**：已实证——22.03.7/23.05.6 官方源均为 `redis-server 6.2.6`（Depends 自动拉取，附带 libatomic1）；双基线容器冒烟全绿（安装→自启→/ping→Redis initialized）
- **iStoreOS 版本基线**：基于 OpenWrt 22.03/23.05，opkg 控制格式无差异；`libc` 依赖名两代一致
- **core 升级**：go.mod 钉正式 tag，跟随列车发版（fnos 同款节奏）
