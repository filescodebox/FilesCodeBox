# OpenWrt / iStoreOS 适配层设计（pigeonbox/openwrt）

- 日期: 2026-10-06
- 状态: 已批准实施（用户拍板"你搞吧"）
- 先例: [fnos 适配层](../../../../fnos/)（库式调 core + 应用包打包 + Release 双挂）完全同构

## 1. 目标与非目标

**目标**：PigeonBox 以原生 OpenWrt/iStoreOS 包形态运行在路由器/NAS 设备上：

- 单进程 Go 二进制（业务 + 前端静态资源同端口服务），procd 托管，开机自启
- 匿名口令分享全功能可用（依赖 redis-server 包，包管理器自动拉取）
- UCI（`/etc/config/pigeonbox`）为常用配置面；高级配置支持 drop-in config.yaml
- **双格式双架构**：opkg 系（22.03/23.05，现行 iStoreOS）发 `.ipk`；apk3 系（OpenWrt 25.12+，opkg→apk 迁移后）发 `.apk`；各含 x86_64 / aarch64_generic（ipk 另出 aarch64_cortex-a53 变体供 iStore 官方源收录）
- CI/Release 与生态同构：本仓 Release 挂双格式包 + 回挂 hub `openwrt-v*`

**非目标（v1 明确不做）**：

- ~~LuCI 集成页（luci-app）~~ → **v0.3.0 已交付**（用户真机反馈后补）：LuCI 入口页（服务→PigeonBox 文件快递柜：procd 状态/端口/数据目录 + 新窗口打开按钮）。iframe 内嵌被否——core 安全基线全局下发 `X-Frame-Options: SAMEORIGIN`，LuCI(:80) 内嵌 :12345 属跨源必被浏览器拦，故为状态页+新窗口形态；menu.d/acl.d/view.js 三件套随双格式包分发，postinst/post-install 重启 rpcd 接 ACL（用户重登 LuCI 可见）。**v0.3.1 修复**: 状态数据源不能用 luci getInitList（iStoreOS 构建只返回 index/stop/enabled 无 running 字段，真机实测恒显未运行），换 ubus service list 取 instances[*].running；并增 启动/停止/重启 按钮（file.exec 限定 /etc/init.d/pigeonbox，ACL write.file 限路径授权）；真机 Playwright 端到端验证启停闭环全绿。**v0.4.0 两笔**: ① 配置表单(form.Map 直绑 UCI:端口/监听地址/数据目录/匿名上传/管理员密码/对外 URL/Redis;onafterapply 自动重启服务生效;真机改端口 12345↔12346 双向闭环验证); ② core v0.13.1 跟随(env-only auto_migrate 零值门控致全新安装缺 notifies 表 500,CI 冒烟补 /notifies/active 断言)。**v0.4.1**: 升 core v0.13.2——分享链接 0.0.0.0 修复(base_url 空时 bootstrap 曾静态拼 server.host:port=监听地址,真机弹窗 0.0.0.0 链接;改为中间件按请求 Host 头注入 ctx+share/presign 域 ResolveBase 三级解析:配置>请求来源>相对路径;显式 base_url 部署行为不变;真机验证:分享弹窗返回真实 LAN 地址,取件页可见内容)
- p2pc sidecar（设备直传）：desktop 侧已有，路由器侧待 p2p 生态成熟
- ~~iStore 软件中心官方上架~~ → **2026-10-07 已提交官方收录**：linkease/istore-repo PR #810（官方第三方收录通道 = fork 后对 `pending` 分支发 PR；ipk 放 `bin/packages/<arch>/nas/`、apk 放 `bin/apks/<arch>/nas/`；**aarch64 的 ipk 架构名须为 aarch64_cortex-a53** 而 apk 为 aarch64_generic——release 矩阵已固化该变体（v0.4.2 起五产物）；PR Validate 已过，待 linkease 审核合并后进入 iStore 官方源。合并前用户可 iStore「手动安装」/ opkg、apk 直装（README 三步）
- ghcr 容器镜像：原生包形态无镜像需求

## 2. 关键决策与依据

| 决策 | 选择 | 依据 |
|---|---|---|
| 仓库形态 | 独立仓 `pigeonbox/openwrt`（fnos 同构） | go.mod 钉 core 正式 tag 独立构建；工作区 go.work 联编本地 core 开发 |
| 包格式双轨 | opkg 系 `.ipk`（v0.1.0 起）+ apk3 系 `.apk`（v0.2.0 起，用户纠偏后补） | OpenWrt 25.12+ 已 opkg→apk 迁移（rootfs 实测 apk-tools 3.0.5、`.adb` 索引）。**apk3 不读 apk2/ipk 结构**（实测 "file format is invalid or inconsistent"）；裁剪版 apk 无 mkpkg 子命令 → 打包用 `docker alpine:edge apk mkpkg`（自带完整 apk3）；签名走**全局选项** `apk --sign-key <key> mkpkg` 出包即签（`adbsign` 对未签名包报 UNTRUSTED 且静默写坏文件，勿用）；公钥 `keys/pigeonbox.pem` 入库 + 私钥 GH secret `APK_SIGN_KEY`；post-install 脚本（mkpkg `--script`）实测在 OpenWrt apk 上执行（装完自启与 ipk postinst 对齐）；/etc 为 apk 保护路径，UCI/init 升级安全 |
| 二进制 | `/usr/bin/pigeonbox`，`bootstrap.BootstrapWithOptions` + `WithStaticDir` | core v0.13.0 tag 已含（已验证）；纯 Go sqlite（glebarez）→ `CGO_ENABLED=0` 静态交叉编译 |
| JWT 密钥 | 移植 fnos `ensureJWTSecret`：未配置时自动生成强密钥持久化到数据目录（0600） | core 安全基线缺 secret 拒启；路由器用户不应被迫手工生成 |
| 前端 | ipk 内置 dist（`/usr/share/pigeonbox/www/`），CI 从 frontend 仓构建 | core SPA 回退同端口服务前端（文件优先+SPA 回退，bootstrap.go:1167）；frontend 仓无 dist Release 资产，故 CI 源码构建 |
| Redis | ipk `Depends: redis-server`（OpenWrt packages 官方源） | 匿名取件强依赖 Redis（core bootstrap:667 降级但 anonymous 域直接报错）；原生形态无 Docker；官方源包带 procd init。**勘误（2026-10-06）**：core main fa8636c 起单机内存模式（host 空=进程内 KV 全功能、重启丢映射），bump core 后 `Depends: redis-server` 可复议降级为持久化可选项（路由器小内存设备受益）；v0.1.0 钉 core v0.13.0 维持硬依赖 |
| 配置面 | UCI 常用项 → init 脚本翻译成 `PB_*` env（env 优先级高于 yaml）；`/etc/pigeonbox/config.yaml` 存在则以 `--config` 传入（高级面） | core envBindings 全集已核实；OpenWrt 惯例 UCI 优先，同时保留 core 全量配置逃生口 |
| 数据目录 | UCI `data_dir` 默认 `/etc/pigeonbox/data` | overlay 可持久；README 建议大容量场景指到数据盘（如 `/mnt/sda1/pigeonbox`） |
| 打包 | 无 SDK ipk 组装：外层纯 tar.gz（内含 ./debian-binary + control.tar.gz + data.tar.gz） | OpenWrt 23.05 起 ipk 即纯 tar.gz（对官方 zlib ipk 实测核对）；且须强制 ustar/gnu 格式——macOS bsdtar 默认 pax 扩展头 opkg 不识别会整条跳过（实测踩坑） |
| 架构 | `x86_64` + `aarch64_generic` 两 ipk | iStoreOS x86 主流 + ARM SBC（rockchip）；Architecture 字段须匹配 opkg arch |

## 3. 系统布局（安装后）

```
/usr/bin/pigeonbox                 Go 静态二进制(业务+前端同端口)
/usr/share/pigeonbox/www/          前端 dist(index.html + assets/)
/etc/config/pigeonbox              UCI 配置(conffile)
/etc/init.d/pigeonbox              procd init
/etc/pigeonbox/config.yaml         可选高级配置(用户创建,不入包)
/etc/pigeonbox/data/               默认数据目录(SQLite+上传文件+JWT密钥,首启创建)
```

procd init：`procd_set_param respawn`（崩溃重启）+ stdout/stderr 进 syslog；`START=99`（晚于 redis 的 START）。

## 4. UCI 配置面（v1）

```
config main 'main'
    option enabled '1'                    # 停用开关(init 检查)
    option port '12345'                   # → PB_SERVER_PORT
    option host '0.0.0.0'                 # → PB_SERVER_HOST
    option data_dir '/etc/pigeonbox/data'  # → PB_DATA_PATH / PB_DATABASE_DB_NAME / PB_STORAGE_PATH
    option open_upload '1'                # → PB_OPEN_UPLOAD
    option admin_password ''              # → PB_ADMIN_PASSWORD(空=默认 admin123,文档强制建议修改)
    option base_url ''                    # → PB_SERVER_BASE_URL(presign 直下需要)

config redis 'redis'
    option enabled '1'                    # 关闭=匿名取件不可用(降级)
    option host '127.0.0.1'               # → PB_REDIS_HOST
    option port '6379'                    # → PB_REDIS_PORT
    option password ''                    # → PB_REDIS_PASSWORD
```

固定注入（不可配）：`PB_SERVER_MODE=release`、`PB_PRODUCTION=1`、`PB_DATABASE_DRIVER=sqlite`、`TZ`。
高级项（S3/OIDC/联邦/mcp…）走 `/etc/pigeonbox/config.yaml` 或 `/etc/init.d/pigeonbox` 自定义 env——UCI 面保持小。

## 5. ipk 控制文件

- `control`：`Package: pigeonbox` / `Version: <semver>-1` / `Depends: libc, redis-server` / `Architecture: x86_64|aarch64_generic` / `Section: net`
- `conffiles`：`/etc/config/pigeonbox`
- `postinst`（真机环境守卫 `[ -z "$IPKG_INSTROOT" ]`）：enable redis + pigeonbox，未启动则 start（装完即用）
- `prerm`：stop pigeonbox；卸载**不删数据**（`/etc/pigeonbox/` 保留，文档注明清除路径）

## 6. 仓库结构与 CI

```
openwrt/
├─ cmd/pigeonbox/main.go       ensureJWTSecret + BootstrapWithOptions + 优雅退出
├─ configs/config.yaml            模板(供用户复制为 drop-in 参考;不随包安装)
├─ keys/pigeonbox.pem          apk 签名公钥(用户预置到 /etc/apk/keys/ 即免 --allow-untrusted)
├─ openwrt/
│  ├─ pigeonbox.init           procd init(UCI→env 翻译)
│  ├─ pigeonbox.config         UCI 默认值
│  ├─ pigeonbox.postinst/.prerm      ipk 控制脚本
│  └─ pigeonbox.post-install         apk post-install 脚本(行为与 postinst 对齐)
├─ scripts/build-ipk.sh           → ipk(纯 tar.gz 外层,ustar/gnu 强制)
├─ scripts/build-apk.sh           → apk3(mkpkg 经 docker alpine:edge;APK_SIGN_KEY 可选签名)
├─ scripts/build-frontend.sh      frontend 仓 → npm build → dist(本地/CI共用)
├─ .github/workflows/ci.yml       vet+test+amd64 构建+双格式组装+两代 rootfs 容器安装冒烟
├─ .github/workflows/release.yml  tag v* → 双格式双架构 → 本仓 Release + 回挂 hub openwrt-v*(OPENWRT_PAT, continue-on-error)
├─ Makefile / README.md / LICENSE(Apache-2.0) / .gitignore
```

- CI 冒烟双轨：`x86-64-23.05.6` 内 `opkg install`（ipk）+ `x86-64-25.12.5` 内 `apk add`（apk；CI 构建未签名 → `--allow-untrusted`，发布产物签名、受信安装已实测），均断言 /ping + logread `Redis initialized`。rootfs 镜像**须显式 `/sbin/init` 起引导**（默认 Cmd 空会秒退）。
- Release 产物：`pigeonbox_<ver>-1_{x86_64,aarch64_generic}.ipk` + `pigeonbox_<ver>-r0_{x86_64,aarch64_generic}.apk`（签名）；回挂 hub 与 desktop/fnos 完全同构（PAT 未配置 CI 放行失败、本地 `gh release upload` 兜底）。
- 版本注入：`-ldflags -X github.com/pigeonbox/kit/version.{Version,BuildCommit,BuildTime}`（kit/version 惯例）。

## 7. 依赖钉版

- `github.com/pigeonbox/core v0.13.0`（当前正式列车，server v0.14.0 同源）
- `github.com/pigeonbox/kit v0.3.0`（version 注入）
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
- **iStoreOS 版本基线**：基于 OpenWrt 22.03/23.05，opkg 控制格式无差异；`libc` 依赖名两代一致。apk3 线面向 OpenWrt 25.12+（iStoreOS 未来 apk 代际同用）
- **apk3 格式**：`.adb` 索引、ADB 包体,与 apk2/ipk 零兼容(实测);签名信任=公钥预置 `/etc/apk/keys/*.pem`;25.12 源 redis-server=6.2.14(已实测自动拉取)
- **core 升级**：go.mod 钉正式 tag，跟随列车发版（fnos 同款节奏）
