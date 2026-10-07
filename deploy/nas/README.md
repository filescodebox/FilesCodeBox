# NAS 打包模板真相源（deploy/nas/）

[filescodebox/synology](https://github.com/filescodebox/synology) · [qnap](https://github.com/filescodebox/qnap) · [ugreen](https://github.com/filescodebox/ugreen) · [terramaster](https://github.com/filescodebox/terramaster) 四仓 **90% 内容同源**（编排/env/图标/回挂模式各四份），且永绑同一发版列车。本目录是共享资产的**唯一真相源**，四仓只是物化结果——不合并仓库（各仓独立 CI/发版/用户入口不变），用「模板 + 同步 + 漂移门禁」消除四处手改。

## 文件

| 文件 | 作用 |
|---|---|
| `compose.yml` | 四仓共享编排模板。首行 `#__NAS_PLATFORM_HEADER__` 占位，物化时替换为各平台说明；其余内容四仓逐字一致（镜像钉版默认值也在这里） |
| `env.example` | 四仓逐字一致的 .env 模板 |
| `sync.sh` | 同步/校验引擎（见下） |
| `gen-icons.sh` | 品牌图标派生器（macOS sips/qlmanage，极少变动，再生成依据存档） |

四仓各自的**平台专属内容不入本目录**：包格式壳（SPK 的 INFO/scripts/WIZARD、QPKG 的 cfg/routines/服务脚本、zip 打包脚本）、生命周期测试（`tests/run-tests.sh`）、平台 README。

## sync.sh

```sh
bash deploy/nas/sync.sh check --all            # 工作区四仓全量校验(hub 检出内,离线)
bash deploy/nas/sync.sh sync  --all            # 模板 → 四仓物化
bash deploy/nas/sync.sh check --platform ugreen --dir ../ugreen   # 单仓(ugreen 额外校验 ghcr 加速版=compose 的镜像源替换)
```

模板来源：优先脚本同目录（hub 检出内），否则抓 `raw.githubusercontent.com/filescodebox/filescodebox/main/deploy/nas/`——**适配器 CI 因此可以只带自身仓库跑漂移门禁**：

- 四仓 `ci.yml` 的 lint job 各有一步「共享资产与 hub 模板对齐」：拉取本脚本对自身仓 `check`，模板一动、未同步的仓全部变红，杜绝"改了三处漏一处"。
- 同步统一用本脚本，禁止手改四仓的 compose/env.example（改了 CI 会红）。

## 发版列车（scripts/nas-release-train.sh）

跟随 server/frontend 新镜像版本时，**一条命令走完四处**：

```sh
bash scripts/nas-release-train.sh v0.16.0 --push   # 默认 dry-run,加 --push 实际执行
```

动作：改模板钉版 → hub 提交推送 → `sync --all` 物化四仓 → 各仓提交 `chore: 钉镜像 vX` → 各仓 patch 版本 +1 打 tag 推送 → CI 自动组包 + 本仓 Release + hub `*-v*` 回挂。会顺带改写 synology README 里的字面版本号；完成后打印四条 Actions 链接与人工跟进清单。

## 约定

- 模板改动（编排行为/默认值/注释）→ hub 提交 → `sync --all` → 四仓各自提交（可随下次发版列车），**不要**绕过模板直接改仓内文件。
- 平台专属逻辑永远只改对应仓；hub 模板只放"四仓必须一致"的内容。
