<!-- 标题建议 type(scope): 摘要，与 commit message 同风格（如 feat(core): ...） -->

## 变更
<!-- 做了什么、动机是什么 -->

## 自测
- [ ] 本地测试通过（Go: `go test -race ./...`；frontend: `npm run typecheck && npm test`）
- [ ] 触及路由/契约：已改 contracts/idl/ 并重跑生成链（gen-model / gen-router / gen-openapi / gen-ts）
- [ ] 触及发版列车写入点（VERSION / go.mod 生态钉版 / manifest / tauri.conf.json）：确认走 `make train-bump`，未手改
