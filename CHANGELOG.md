# Changelog

各模块仓独立发版；本文件记录工作区级的重要变更（格式参考 Keep a Changelog）。

## [Unreleased]

### Added
- **真·S3 预签名直传直下**（core）：存储后端为 s3 时 `presign.Init` 直接签发对象存储
  预签名 PUT URL（`meta.Scheme=s3`），上传流量不过服务器；`Complete` 向 S3 核实对象
  真实存在并以实际大小落库（服务器未接触内容，秒传指纹依赖客户端预计算哈希）。
  下载侧新增 `download.s3_direct_download`（env `FCB_DOWNLOAD_S3_DIRECT`，默认关）：
  开启后文件下载 302 到短时效预签名 GET。**注意**：浏览器直传/直下需在对象存储桶上
  配置 CORS 允许站点来源；local/webdav 后端自动回退自家中转，行为不变。
- **存储后端点亮**（core）：S3 / WebDAV 真实读写全链路（opendal 驱动：minio-go / gowebdav），
  `StorageService` 按配置类型分派；本地盘路径行为零改动。
- **在线切换存储后端**（core）：管理端切换/保存走「SSRF 校验 → 认证级 Probe → 热重载 → 持久化」，
  重启后从 `system_configs.runtime_storage` 恢复（env > DB > yaml）；`StorageInfo` 新增
  `effective` 字段展示实际生效后端。
- **presign 直传接入存储分派**（core）：直传落盘跟随当前激活后端（此前硬编码本地盘）。
- **首启引导**：`/api/config` 返回真实 `initialized`；前端新增 `/setup` 初始化页（含 i18n）。
- **开源合规件**：7 仓 MIT LICENSE；CONTRIBUTING / SECURITY / CHANGELOG / ROADMAP / 双语 README。
- **API Key 体系**（core）：`fcb_sk_` 前缀用户级 API Key（SHA256 存储/per-Key 限流/审计归因/
  一键吊销/临期通知），`/api/v1` 组 JWT|API Key 双认证，管理端总开关与热更新。
- **多文件分享 + zip 打包**（core/frontend）：单/多文件统一子表模型，`/api/v1/share/multi-direct|multi-bind`，
  下载侧对流式 zip（不落盘、防 Zip Slip、重名去重）。
- **寄件码/反向收件**（core/frontend）：分享者建链接、访客投递、到件通知（对齐 Gokapi file requests）。
- **端到端加密分享**（frontend）：WebCrypto 客户端加密（≤100MB），密钥走 `#fragment`，服务器零知识。
- **通知渠道**：SMTP 邮件落地（notify 域多渠道）。
- **MCP Server 实装**（core）：`POST /api/v1/mcp` JSON-RPC 8 工具（分享/查询/管理/清理）。
- **`fcb` CLI**（server）：分享/取件/管理命令行（基于 API Key）。
- **可选 ClamAV 病毒扫描**（core，fail-open 接线）。
- **OIDC 单点登录 / Range 断点续传(206) / 自定义取件码 / NAS 本地文件免上传导入**（core/frontend）。
- **`/share/metadata` 元数据端点**（core）：查询不扣次数、不要密码，text 分享不外泄内容。
- **openapi.json 运行时生成**（core）：启动时由运行时路由表生成契约级骨架规范，
  根治手工快照漂移与容器 404；frontend 移除 openapi.json/api.gen.ts 死链（无消费方）。
- **管理端本地文件管理**（core/frontend）：`/admin/local-files` 列表/删除/生成提取码
  （root 索引+白名单相对路径三层防穿越）。
- **文档站**（hub）：docs-site VitePress（内容 @include 引 docs/ 真相源）。

### Changed
- `core/bootstrap`：StorageService 改为进程内单例（此前 3 处各建实例，在线切换无法生效）。
- `core/app/admin`：`SystemConfig` 新增 `runtime_storage` 段（存储域经接口读写，本域只持久化）；
  `UpdateConfig` 对该段做防御性合并。
- opendal `Operator.New`：s3/webdav 参数缺失时返回错误（不再静默回退 fs）。
- `core`: chunk `CompleteUpload` 恒 500 修复（`UpdateChunkCompleted` 缺 `.Model()` 致 GORM
  "Table not set"）——v0.6.0 镜像带此缺陷，**分片用户请升级 ≥ server 0.6.1 / fnos 0.2.4**。
- 镜像 tag 口径：ghcr tag 为无 `v` 前缀形态（`0.6.4`）；chart 0.2.7 起对 AppVersion/显式
  image.tag 统一剥 `v`（此前默认安装渲染出不存在的 `:v0.6.4`）。
- charts CI：push 事件下 ct 安装冒烟曾 0 秒空跑，改为显式 helm 安装 + rollout + helm test。
- fnOS 镜像内置默认配置（`configs/config.yaml`）：裸 `docker run` 开箱可用
  （此前无 env 时匿名上传被拒、存储路径为空）；应用包模式行为不变（env 覆盖）。

### Removed（假开关清理：未实现的能力不再暴露配置键）
- `upload.max_save_seconds`、`download.enable_concurrent_download` / `max_concurrent_downloads`
  （从未实现；全局过期上限用 `upload.max_save_seconds_cap`）。
- `user.require_email_verify`（无验证码流程；注册 email 为普通必填字段）。
- `ui.theme/background/page_explain/show_admin_addr/opacity/notify_*`（仅 `ui.robots_text` 实际消费；
  主题系统实装时按新形状回归）。
- `observability.tracing.*` 与 `FCB_TRACING_ENABLED`（OTel 未实装）。
- onedrive 存储类型空壳常量。残留旧键的存量配置可无损升级（viper 忽略未知键）。

### 升级说明
- 新增直接依赖：`github.com/minio/minio-go/v7`、`github.com/studio-b12/gowebdav`（core）。
- 局域网对象存储/WebDAV（NAS 场景）需 `security.ssrf.allow_private_networks: true`（既有机制）。
- 存量部署（`storage.type=local`）行为不变；详细设计见
  [docs/design/2026-10-03-storage-lightup-and-onboarding.md](docs/design/2026-10-03-storage-lightup-and-onboarding.md)。

## [0.2.0] - 2026-10-02

- 单体拆分为 contracts / core / server / frontend / filecodebox-fnos / charts 多仓。
- 安全基线：分享密码修复、失败锁定、下载令牌、SSRF 校验、魔数检测、文件名消毒、审计接线。
- 管理端站点配置 DB 持久化（`system_configs` 单行写穿）。

## [0.1.0] - 2026-07

- Go 重写版首发布（对照 Python 原版 vastsa/FileCodeBox 的功能面）。
