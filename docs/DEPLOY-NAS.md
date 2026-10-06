# NAS 部署（飞牛 / OpenWrt·iStoreOS / 群晖 / 威联通 / 绿联 / 铁威马）

FilesCodeBox 在 NAS 上的六种交付形态。除飞牛/OpenWrt 为原生单进程适配层外，其余四平台为**官方镜像的 docker-compose 编排壳**（零 Go 代码），行为与 Docker Compose 部署（`docs/DEPLOY-COMPOSE.md`）完全一致：双容器免 Redis（core v0.14.0 起单机内存模式全功能）、JWT 密钥首启自动生成持久化、默认关闭开放注册、默认端口 `12345`。

| 平台 | 形态 | 系统要求 | 安装入口 |
|---|---|---|---|
| 飞牛 fnOS | fpk 应用包（fnos 仓） | fnOS（应用中心） | [filescodebox/fnos](https://github.com/filescodebox/fnos/releases) |
| OpenWrt / iStoreOS | ipk / apk 原生包（openwrt 仓） | OpenWrt 22.03+ / 25.12+ | [filescodebox/openwrt](https://github.com/filescodebox/openwrt/releases) |
| 群晖 DSM | SPK 套件（synology 仓） | **DSM 7.2+** 且已装 Container Manager 24.0.2+ | [filescodebox/synology](https://github.com/filescodebox/synology/releases) |
| 威联通 QTS | QPKG 应用（qnap 仓） | QTS 5.0+ 且已装 Container Station 3 | [filescodebox/qnap](https://github.com/filescodebox/qnap/releases) |
| 绿联 UGOS Pro | compose 导入部署包（ugreen 仓） | UGOS Pro（Docker 应用可用） | [filescodebox/ugreen](https://github.com/filescodebox/ugreen/releases) |
| 铁威马 TOS | compose 导入部署包（terramaster 仓） | TOS 5/6/7（Docker 应用可用） | [filescodebox/terramaster](https://github.com/filescodebox/terramaster/releases) |

所有应用包随各自组件仓发版，并统一回挂[生态主仓 Releases](https://github.com/filescodebox/filescodebox/releases)（`fnos-v*` / `openwrt-v*` / `synology-v*` / `qnap-v*` / `ugreen-v*` / `terramaster-v*` tag）。

## 群晖 DSM（SPK）

1. 套件中心 → **手动安装** → 上传 `filescodebox_<版本>.spk`；未签名包提示「发布者无法验证」，确认继续（DSM 7.x 无信任级别设置，属预期）
2. 向导三步：**端口**（默认 12345）、**数据目录**（默认 `/volume1/docker/filescodebox`，建议放 docker 共享文件夹下）、**管理员密码**（留空=默认 admin/admin123）
3. 装完自动启动，访问 `http://NAS的IP:12345`（或套件详情页「打开」）

- 配置集中在 `数据目录/.env`，改完在套件中心**停用→启用**生效
- 升级套件自动对齐镜像版本；卸载默认保留数据目录
- 数据目录属主需为 uid 1000（安装时自动处理；异常时 SSH 执行 `sudo chown -R 1000:1000 <数据目录>`）

## 威联通 QTS（QPKG）

1. App Center → 设置 → 勾选**允许安装没有有效数字签名的应用**（社区包一次性设置）
2. App Center 右上角**手动安装** → 上传对应架构的 `FilesCodeBox_<版本>_<架构>.qpkg`（x86_64 / arm_64）
3. 装完自动启动（后台等待 Container Station 就绪），主菜单/桌面点图标直达；默认 `admin/admin123`，装完先改

- 配置在存储卷根 `filescodebox/.env`；App Center 图标端口自动跟随 `.env` 的端口
- 数据在卷根 `filescodebox/` 目录，**卸载应用保留**（QPKG 卸载只删安装目录）

## 绿联 UGOS Pro / 铁威马 TOS（compose 项目导入）

1. 下载部署包 zip 解压（绿联提供 ghcr 原版与 `ghcr.nju.edu.cn` 加速版两份编排）
2. 打开 Docker 管理器 → **项目** → 创建/添加：
   - 绿联：项目名 `filescodebox`（小写）→ 粘贴 compose YAML → 部署
   - 铁威马：项目路径选数据卷 → 配置来源「你的电脑」上传 yml（或粘贴）→ **验证 YAML** → 应用
3. 访问 `http://NAS的IP:12345`，默认 `admin/admin123`，装完先改

- 端口/数据目录/管理员密码在导入前直接改 YAML（绿联默认数据目录 `/volume1/docker/filescodebox/data`，铁威马建议改到数据卷如 `/Volume1/Docker/filescodebox/data`）
- 升级 = 改 YAML 里两处镜像 tag → 重新部署；数据目录不动
- 铁威马注意保留端口 22/80/443/8181/5050（默认 12345 合规）；两平台都建议把 Docker 应用设为开机自启

## ghcr 镜像拉取（国内网络）

四平台编排均从 ghcr.io 拉官方镜像（public 可匿名）。直连失败时的通用兜底：

- 镜像前缀替换：`ghcr.io/filescodebox/server` → `ghcr.nju.edu.cn/filescodebox/server`（绿联包已内置加速版编排）
- 离线导入：任意外网机器 `docker pull` + `docker save` 出 tar，上传 NAS 后在各家 Docker 界面导入镜像，再启动应用

## 与 Docker Compose 部署的关系

四平台壳内的编排与生态主仓 `docker-compose.yml` 同源裁剪（去 redis、绑 0.0.0.0、`.env` 由安装器生成）；高级配置（Redis、S3/网盘存储、反代、联邦）直接参考环境变量文档（`docs/ENVIRONMENT_VARIABLES.md`）在 `.env` 追加即可。绿联 UPK 应用中心形态与铁威马 TOS 7 官方应用包为二期路线（见各自仓库 `upk/`、`tos7/` 目录说明）。
