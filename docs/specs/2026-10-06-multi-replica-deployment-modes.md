# 部署模式拆分：多副本 public + 单实例 admin + 单机 standalone（2026-10-06）

状态：已拍板实施（波次一 core + 波次二 chart；波次三 Kitex 预留不排期）

## 1. 背景与目标

- 公开服务（上传/下载/分享）有多副本横向扩容需求；管理配置面必须保持全局单写者。
- 单机部署（fnos / desktop / docker-compose 单机）必须零回归——默认形态与历史完全一致。
- 服务间通信评估结论：**本拆分的通信本质是"共享数据层 + 配置变更广播"，不存在请求路径上的跨进程调用**，v1 不引入 RPC；Kitex（thrift 协议与 contracts IDL 同源，CloudWeGo 同族）作为预留升级路径，触发条件见 §6。

## 2. 运行模式（`deployment.mode` / env `FCB_DEPLOY_MODE`）

| | standalone（默认） | public（可 N 副本） | admin（全局 1 实例） |
|---|---|---|---|
| 公开面路由（share/chunk/presign/anonymous/user/preview/qrcode/notify 公开端点） | ✅ | ✅ | ❌（gate 404） |
| 管理面路由（admin/storage/maintenance/ratelimit/setup//version//api/v1/mcp） | ✅ | ❌（gate 404） | ✅ |
| 后台任务（过期清理/janitor/API Key 临期通知） | ✅ | ❌ | ✅ |
| DB 迁移（AutoMigrate/版本化） | ✅ | ❌（强制关闭，防多副本迁移竞态） | ✅ |
| system_configs | 读写（现状） | 只读 + 订阅失效 | 唯一写者 + 变更广播 |
| Redis pubsub | 不需要 | 订阅 `fcb:config:changed` | 发布 |

非 standalone 模式硬约束（fail-fast / 自动降级）：

- `database.driver` 必须为 mysql/postgresql（SQLite 单写者，多进程共享必锁）。
- Redis 未配置：**public/admin 拒绝启动**（fail-fast——配置广播失效 + 取件码映射/presign 会话/限流计数跨实例分裂，静默运行的后果比启动失败严重；2026-10-06 起，此前为警告启动）。standalone 无此要求：进入单机内存模式（匿名取件/直传会话存进程内 TTL KV）。
- `federation.enabled=true` 自动降级为 false 并告警（联邦节点身份是进程级 Ed25519 密钥，多副本语义未定义）。

## 3. 路由拆分实现

- `gen/router/register.go` 的 `GeneratedRegister` 是按组调用 `xxx.Register(r)` 的薄组合（生成物，勿改）。bootstrap 新增 `registerGeneratedRoutes(h)` 按模式挑选组注册：
  - public：share_anonymous / presign / notify / common / health / qrcode / chunk / user / share / preview
  - admin：ratelimit / setup / storage / admin / maintenance / health / common
- 混合组处理：notify 组同时含公开 `/notifies/active` 与管理 `/admin/notifies`（生成物注册在同一组），health 组含公开探针与管理 `/version`。因此 public 模式叠加一个**部署门卫中间件**（全局链最早段）：对 `/admin*`、`/setup*`、`/version`、`/api/v1/mcp` 一律 404 JSON——未注册组收到干净 404（而非 SPA 回退），混合组中已注册的管理路由被物理拦截。守卫测试断言门卫清单 ⊇ 实际注册的管理面路径（自愈防漂移）。
- `customizedRegister` 手写路由按 `ServesPublicPlane()/ServesAdminPlane()` 分段注册（standalone 两者恒真）。要点：
  - `/api/config`、静态 SPA、`/readyz` 两面都注册（admin 实例自持一个可用的管理控制台 SPA）。
  - `/api/v1/user/refresh|logout|check-auth` 两面都注册（前端 auth store 是同一份 bundle，admin 控制台启动时调 check-auth）。
  - `/openapi.json`：public 模式注册但合并后的 spec 需剥离管理面路径（与门卫一致）。

## 4. 配置变更广播

管理端三处持久化点（`UpdateConfig` / `UpdateUserSettings` / `SaveRuntimeStorage`）末尾调用注入的 `OnConfigPersisted` 钩子；bootstrap 在 admin 模式下将其接线为 Redis 发布：`INCR fcb:config:revision` + `PUBLISH fcb:config:changed`。

public 副本订阅侧（`applyPropagatedConfig`）依次：

1. `adminApp.Default().InvalidateRuntimeConfig()`（丢弃内存缓存，下次读库）
2. `RestoreAdminSettings()`（重读 system_configs → overlay 全局 conf + 会话时长副作用）
3. `restoreRuntimeStorage()` + `bootstrapStorage.Reload(ConfigFromConf(...))`（存储后端在线切换同步到副本；域服务持有同一 `*StorageService` 指针，Reload 原地生效——与管理端本进程切换同机制）
4. `applyNotifyConfig`（Webhook/SMTP mailer 重建）+ OIDC service 重建（与管理端保存钩子同构）

可靠性：pubsub 触发即时生效；另有 30s 周期比对 revision 兜底订阅断线丢消息。standalone 模式整套机制不启动（行为与历史一致）。

## 5. 部署拓扑

- chart：`server.replicas > 1` 时渲染双 Deployment——`*-server`（public，N 副本，公网 Ingress 指向）+ `*-server-admin`（admin，1 副本，独立 ClusterIP Service；可选独立 Ingress，默认关，建议挂 IP 白名单/内网）。`=1` 时维持现状单 Deployment（standalone）。
- 管理端访问：独立 Ingress（白名单/VPN）或 `kubectl port-forward`；公网入口永远指 public。
- 215（compose 单机）不变更，维持 standalone。
- 存储后端：多副本必须 S3 兼容或共享 PV；local 后端副本本地盘不共享。

## 6. 波次三（预留）：Kitex

触发条件：把重传输面（上传/下载）从元数据面再拆分、出现真正的请求路径跨进程调用时。届时：

- contracts IDL 为 thrift v0.13——Kitex 原生协议，模型层零重写，补 service 块 + 并存一条 kitex 生成链；
- 2026-10-05 否决 gRPC 的"双 IDL"理由被消解，CloudWeGo 同族生态一致；
- 调用方经现有窄接口适配器（`mcp.ShareAPI` / `request.ShareGateway` 模式）切换 in-process ↔ RPC client 无感。

federation 多副本语义（一逻辑节点心跳归 admin vs 多副本不支持）拍板为：**多副本暂不支持 federation**（§2 自动降级）。

## 7. 多副本就绪核对单

- [x] 分片会话 DB 化（`model.UploadChunk`），无需粘性会话
- [x] 限流 `rate_limit.use_redis` / 锁定 / 匿名取件码 / presign 会话 / JWT 黑名单已在 Redis 共享
- [x] 迁移只在 admin 执行；后台任务只在 admin 执行
- [x] admin 配置内存缓存带广播失效 + revision 对账
- [ ] 部署侧：mysql/pg + Redis 必配、S3/共享 PV、公网入口只指 public（chart 模板保证）
