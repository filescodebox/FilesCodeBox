.PHONY: setup update build test vet lint smoke docker compose-up compose-down clean

# FileCodeBox umbrella —— 一次 clone 拉齐全部模块并统一构建。
# 模块仓库(contracts/core/server/frontend)由 scripts/setup.sh 拉入本目录,
# go.work 联编本地改动;各模块亦可独立构建(go.mod 均为正式版本依赖)。

SERVER_IMAGE ?= filecodebox-server:dev

## 全流程:拉模块 → 全仓测试 → 构建 server 二进制
all: setup test build

setup:            ## 拉齐/更新四个模块仓库(幂等)
	./scripts/setup.sh

update: setup

build:            ## workspace 联编三个 Go 模块(产物 bin/)
	go build -o bin/ ./contracts/... ./core/... ./server/...
	@echo "✓ build OK → bin/"

test:             ## 全仓 Go 测试 + 前端 typecheck
	go test ./contracts/... ./core/... ./server/...
	cd frontend && ([ -d node_modules ] || npm ci) && npm run typecheck

vet:
	go vet ./contracts/... ./core/... ./server/...

lint:             ## golangci-lint 三个 Go 模块（CI 同款门禁；本地提交前建议跑，防 lint 溜进 CI）
	@command -v golangci-lint >/dev/null || { echo "golangci-lint 未安装: brew install golangci-lint"; exit 1; }
	for m in contracts core server; do echo "── $$m"; (cd $$m && golangci-lint run ./...); done
	@echo "✓ lint OK"

smoke: build      ## 本地起 server 并跑冒烟(健康检查/登录/文本分享)
	cd server && mkdir -p data logs && (FCB_JWT_SECRET=$$(openssl rand -hex 32) \
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
	docker build -f frontend/Dockerfile -t ghcr.io/filescodebox/frontend:latest frontend/

compose-up:       ## docker compose 起前后端分离栈(默认拉 ghcr 镜像;BUILD=1 本地构建;NGINX=1 加反代)
	docker compose up -d $${BUILD:+--build} $${NGINX:+--profile nginx}

compose-down:
	docker compose --profile nginx down

clean:
	rm -rf bin/
