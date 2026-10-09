.PHONY: setup update build test vet lint smoke smoke-full docker compose-up compose-down nas-check nas-sync train-verify train-bump train-finalize clean

# PigeonBox umbrella —— 一次 clone 拉齐全部模块并统一构建。
# 模块仓库(contracts/core/server/frontend/fnos/openwrt/p2p/kit + NAS 打包四仓
# synology/qnap/ugreen/terramaster)由 scripts/setup.sh 拉入本目录,
# go.work 联编本地改动(打包四仓纯 shell 不参与);各模块亦可独立构建(go.mod 均为正式版本依赖)。

SERVER_IMAGE ?= pigeonbox-server:dev

## 全流程:拉模块 → 全仓测试 → 构建 server 二进制
all: setup test build

setup:            ## 拉齐/更新十二个模块仓库(幂等;SETUP_<名>=0 可跳过任一)
	./scripts/setup.sh

update: setup

build:            ## workspace 联编 Go 模块(产物 bin/)
	go build -o bin/ ./contracts/... ./core/... ./server/... ./p2p/... ./kit/...
	@echo "✓ build OK → bin/"

test:             ## 全仓 Go 测试 + 前端双仓(typecheck+core 单测)
	go test ./contracts/... ./core/... ./server/... ./fnos/... ./openwrt/... ./qnap/... ./p2p/... ./kit/...
	cd frontend-core && ([ -d node_modules ] || npm ci) && npm run typecheck && npm test
	cd frontend && ([ -d node_modules ] || npm ci) && npm run typecheck

vet:
	go vet ./contracts/... ./core/... ./server/... ./fnos/... ./openwrt/... ./qnap/... ./p2p/... ./kit/...

lint:             ## golangci-lint 各 Go 模块（CI 同款门禁；本地提交前建议跑，防 lint 溜进 CI）
	@command -v golangci-lint >/dev/null || { echo "golangci-lint 未安装: brew install golangci-lint"; exit 1; }
	for m in contracts core server fnos openwrt qnap p2p kit; do echo "── $$m"; (cd $$m && golangci-lint run ./...); done
	@echo "✓ lint OK"

smoke: build      ## 本地起 server 并跑冒烟(健康检查/admin 登录;全量断言见 scripts/smoke-full.sh)
	cd server && mkdir -p data logs && (PB_JWT_SECRET=$$(openssl rand -hex 32) \
	  go run ./cmd/server --config ./configs/config.yaml & echo $$! > /tmp/fcb.pid; \
	  sleep 8; \
	  curl -sf http://localhost:12345/live && \
	  curl -sf -X POST http://localhost:12345/admin/login -H 'Content-Type: application/json' \
	    -d '{"username":"admin","password":"admin123"}' | head -c 80 && echo "" && \
	  echo "✓ smoke OK"; kill $$(cat /tmp/fcb.pid) 2>/dev/null; true)

smoke-full:       ## 全能力真机冒烟(39 项断言;独立端口/临时数据目录/临时 Redis,跑完即清理)
	bash scripts/smoke-full.sh

docker:           ## 本地构建双镜像: server(纯后端) + frontend(nginx 静态+反代)
	docker build -f server/Dockerfile -t $(SERVER_IMAGE) .
	docker build -f frontend/Dockerfile -t ghcr.io/pigeonbox/frontend:latest frontend/

compose-up:       ## docker compose 起前后端分离栈(默认拉 ghcr 镜像;BUILD=1 本地构建;NGINX=1 加反代)
	docker compose up -d $${BUILD:+--build} $${NGINX:+--profile nginx}

compose-down:
	docker compose --profile nginx down

nas-check:         ## NAS 打包三仓共享资产漂移校验(对 deploy/nas/ 模板;qnap 已切原生不消费)
	bash deploy/nas/sync.sh check --all

nas-sync:          ## hub 模板物化到 NAS 打包三仓(改模板后跑;CI 有漂移门禁兜底)
	bash deploy/nas/sync.sh sync --all

train-verify:      ## 发布列车对账:train.yaml ↔ 全生态真实状态(漂移即失败;CI 同款 train-verify 工作流)
	bash scripts/release-train.sh verify

train-bump:        ## 开新列车: make train-bump TRAIN=1.15.0 [--set core=v0.15.0 ...](默认 dry-run,加 ARGS=--push 实际执行)
	bash scripts/release-train.sh bump TRAIN=$(TRAIN) $(ARGS)

train-finalize:    ## 列车终验并出 hub v<train> Latest 快照(verify 全绿前置)
	bash scripts/release-train.sh finalize

clean:
	rm -rf bin/
