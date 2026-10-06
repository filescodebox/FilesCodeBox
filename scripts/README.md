# scripts/

装配仓(hub)级脚本。模块仓各自的工具在自己的仓里（如 `contracts/scripts/` 的 IDL 再生成）。

| 脚本 | 用途 | 说明 |
|---|---|---|
| `setup.sh` | 拉齐/更新八个模块仓（幂等），`make setup` 的实体 | 默认全拉 contracts/core/server/frontend/fnos/openwrt/p2p/kit；`SETUP_FNOS=0` / `SETUP_OPENWRT=0` / `SETUP_P2P=0` / `SETUP_KIT=0` 可分别跳过 |
| `smoke-full.sh` | 全能力真机冒烟（44 项断言，含临时 Redis） | 需先 `make build`，对运行中的 server 执行 |
| `e2e-api-key-smoke.sh` | API Key 全链路 e2e（创建/认证/限流/撤销） | 对运行中的 server 执行 |
| `e2e-chunk-upload.py` | 大文件分片上传 e2e（init/分片/complete/秒传） | Python3 标准库实现 |
| `e2e-s3-minio.sh` | MinIO S3 存储后端 e2e | 本地起 MinIO 容器后跑通 S3 读写与分享 |
| `export_config_from_db.{go,py}` | 从旧版 SQLite `key_values` 表导出配置为 YAML | **遗留迁移工具**：`key_values` 表已废弃（现行为 `system_configs` 单行 JSON，由 core 自动读写），仅用于迁移更早期部署的数据。Go 版需独立构建：`cd scripts && GOWORK=off go run export_config_from_db.go -db data/fileCodeBox.db` |
| `generate_favicon.sh` | 由 SVG 生成多尺寸 favicon | 前端/静态资源维护用 |
| `test_nfs_storage.sh` | NFS 存储后端连通性与读写测试 | 存储运维用 |

> 来源说明：`export_config_from_db.*`、`generate_favicon.sh`、`test_nfs_storage.sh` 收编自旧单体仓库（legacy/FileCodeBox），2026-10 迁入；`e2e-*` 与 `smoke-full.sh` 为本项目 2026-10-03 新写。
