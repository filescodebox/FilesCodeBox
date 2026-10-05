# 前端 W2 上传管线重构（行为等价）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 上传管线行为等价重构——`api/_xhr` 收口全部裸 XHR、通道决策纯函数化、队列状态机接管编排、Presign 弹窗 Promise 化消灭 setInterval 轮询、FileUpload 瘦身为装配层。

**Architecture:** 新增 `api/_xhr.ts`（xhrSend JSON 通道 + xhrRaw 裸请求两导出）、`composables/useUploadPlan.ts`（pickUploadPlan 决策树，单测钉死）、`composables/useUploadQueue.ts`（任务状态机+E2E 预加密+四通道编排+abort）、`composables/useFileDrop.ts`（window 拖拽/粘贴）、`components/upload/FileItemRow.vue`；FileUpload.vue 退化为 ~200 行装配，emit 契约不变。

**Tech Stack:** 同 W1（Vue 3.5 + TS + vitest node env + @ alias）。

**Spec:** `docs/specs/2026-10-06-frontend-architecture-design.md`（§6 + §10-W2）；计划：本文件。

## Global Constraints

- 同 W1：零新依赖；每任务一 commit；commit 前 typecheck+test 绿；`git status` 查并行会话；commit 风格 `refactor(scope): 中文描述`。
- **行为等价**（钉死现状），例外须在 commit message 列明。
- **emit 契约不变**：FileUpload `success: [{code, share_url, full_share_url, qr_code_data, e2e_key?}]`，home 零改动。

### 现状钉死要点（读自 FileUpload.vue/PresignUploadDialog.vue 原实现）

- 通道决策：单文件 >100MB → presign；多文件且总体积≤bodyCap 且每文件≤bodyCap → multi-direct；多文件其余 → multi-chunk；其余 → direct。bodyCap = `max(uploadSize−1MB, 0) || 8MB`。E2E 开启且任一文件 >100MB → 整体拒绝。
- E2E：单密钥 generateKeyB64，逐文件 encryptFile（状态 encrypting→pending），payload=密文；**决策用原始文件大小**（现状如此，密文可能略大不参与判定）。
- multi-direct 进度按字节均摊到各任务行；multi-chunk 逐文件顺序 chunkUploadFile（5MB 片、SHA-256 期望哈希、422 重传≤2）→ 绑定期 progress=100+prepare 文案 → multiBind 一次。
- presign 传**原始文件**（非密文）；结果映射 `{code: r.code, share_url: r.url, full_share_url: r.url, qr_code_data: r.url}`。
- 失败：未成功任务 status=error + ElMessage.error(msg)；成功 toast 单文件带文件名前缀、multi 单条。
- cancel(单文件直传)：abort 该任务 xhr → status=error+abort 文案；multi 进行中的取消仅标记（现状即如此，不中断共享控制器）。
- Presign 弹窗：内部重试 ≤2 次、秒传命中（initData.existed）直接出码、PUT 进度封顶 95%、取消=XHR abort+presignApi.abort+info toast。现状成败后 FileUpload 均立即关弹窗 → Promise 化后 resolve/reject 时自动 close（UX 等价，failed 态 UI 本就不可达）。

### 对 spec §6.4 的两处偏差（实现时确定，记入 commit）

1. `_xhr` 错误一律 `Error(message)`（各调用方与队列 catch 均只消费 e.message；{code,message} 形状是 axios 侧职责，不复制）。
2. `_xhr` 双导出：`xhrSend`（JSON+code 归一 0/200+解析 data）与 `xhrRaw`（presign PUT 裸二进制/自定义头/非 JSON 响应）。

---

### Task 1: `api/_xhr.ts` + 单测

**Files:** Create `src/api/_xhr.ts`、`src/api/__tests__/_xhr.spec.ts`

**Interfaces（Produces）:**
```ts
export interface XhrSendOptions {
  url: string
  method?: string        // 默认 POST
  form?: FormData
  timeout?: number       // 默认 300000
  signal?: AbortSignal
  onProgress?: (loaded: number, total: number) => void
}
/** JSON 通道：恒带 X-Requested-With；2xx+isOkCode(code 0|200) resolve 解析后 body，否则 reject Error(message||`HTTP n`) */
export function xhrSend<T>(opts: XhrSendOptions): Promise<{ code: number; message?: string; data?: T }>
export interface XhrRawOptions {
  url: string; method: string
  headers?: Record<string, string>
  body?: XMLHttpRequestBodyInit
  timeout?: number; signal?: AbortSignal
  onProgress?: (loaded: number, total: number) => void
}
/** 裸通道（presign PUT）：2xx resolve(void)，非 2xx reject Error(`... status`)；onerror 'Network error'；onabort 'Cancelled' */
export function xhrRaw(opts: XhrRawOptions): Promise<void>
```

- [x] Step 1 写失败测试（node 环境装 FakeXHR 到 globalThis：捕获 open/setRequestHeader/send，手工触发 onload/onerror/onabort/progress）——用例：code0 归一 OK / code 业务失败 reject(message) / HTTP500 reject / X-Requested-With 恒带 / progress 回调 / signal abort→'Cancelled' / xhrRaw 2xx OK+自定义头 / xhrRaw 404 reject
- [x] Step 2 跑测确认 FAIL → 实现 → PASS
- [x] Step 3 typecheck+test 绿 → commit `feat(api): 新增 _xhr 封装（xhrSend+xhrRaw），统一 CSRF 头/进度/中断/成功码归一`

### Task 2: api 层接线（消灭 3 处裸 XHR）

**Files:** Modify `src/api/share.ts`（新增 uploadFile）、`src/api/multifile.ts`（multiDirect 改 xhrSend）、`src/api/request.ts`（guestSubmit 改 xhrSend）

**Interfaces:**
```ts
// share.ts 新增（字段与 FileUpload 内联 XHR 逐一对应）
shareApi.uploadFile(file: File, opts: {
  expire_value: number; expire_style: string
  require_auth: boolean; password?: string
  encrypted: boolean          // e2e && 密文存在时由调用方传 true
  custom_code?: string        // 登录且非空时由调用方传
}, onProgress?: (loaded: number, total: number) => void, signal?: AbortSignal
): Promise<{ code: string; url: string; share_url?: string; full_share_url?: string; qr_code_data?: string }>
// multifile.multiDirect / request.guestSubmit 签名不变，内部换 xhrSend
```
- [x] Step 1 三处改写（删本地 XHR 块）；microbehavior 修正记 commit：老内联直传只认 code===200，xhrSend 归一 0|200（对齐 axios 拦截器家规）
- [x] Step 2 typecheck+test 绿 → commit `refactor(api): uploadFile/multiDirect/guestSubmit 收口 _xhr，消灭 3 处裸 XHR`

### Task 3: `composables/useUploadPlan.ts` + 单测

**Files:** Create `src/composables/useUploadPlan.ts`、`src/composables/__tests__/useUploadPlan.spec.ts`

**Interfaces:**
```ts
export type UploadChannel = 'direct' | 'presign' | 'multi-direct' | 'multi-chunk'
export function pickUploadPlan(input: {
  count: number; totalBytes: number; maxFileBytes: number
  bodyCap: number; presignThreshold: number
}): UploadChannel
// count<=0 throw；count===1: maxFileBytes>threshold?'presign':'direct'；
// count>1: totalBytes<=bodyCap && maxFileBytes<=bodyCap ? 'multi-direct' : 'multi-chunk'
```
- [x] Step 1 失败测试（4 分支+等值边界+count0 throw）→ 实现 → PASS
- [x] Step 2 commit `feat(upload): 通道决策抽纯函数 pickUploadPlan（单测钉死）`

### Task 4: PresignUploadDialog Promise 化

**Files:** Modify `src/components/upload/PresignUploadDialog.vue`

**Interfaces（Produces）:** `defineExpose({ open(file: File, options: { expire_value: number; expire_style: string; require_auth: boolean; password?: string }): Promise<PresignCompleteData> })`；props/emit 全删；内部 file/options 改 ref；PUT 段换 `xhrRaw`（initData.headers + Content-Type，进度 95% 封顶）；成功 resolve+close，终失败 reject+close，取消 reject+close；保留内部重试≤2 与秒传快路径。
- [x] Step 1 改写（模板不动，script 换 expose 模式；watch(visible) 删除）
- [x] Step 2 typecheck 绿（暂无消费方——FileUpload 仍用旧 props 会红：本 task 与 Task 6 之间 FileUpload 处于中间态，允许先改 dialog 再改 FileUpload，但 typecheck 必须在 Task 6 后补验；本 task 提交前用临时 `vue-tsc` 单文件确认 dialog 自身无错）
- [x] Step 3 commit `refactor(upload): PresignUploadDialog Promise 化（open()→Promise），消灭调用方轮询`

### Task 5: `composables/useUploadQueue.ts` + 单测

**Files:** Create `src/composables/useUploadQueue.ts`、`src/composables/__tests__/useUploadQueue.spec.ts`

**Interfaces:**
```ts
export type UploadTaskStatus = 'pending' | 'encrypting' | 'uploading' | 'binding' | 'success' | 'error'
export interface UploadTask {
  id: string; file: File; payload: File
  status: UploadTaskStatus; progress: number; statusText: string; error: string
}
export function useUploadQueue(opts: {
  settings: ShareSettings
  t: (key: string) => string
  bodyCap?: () => number                 // 默认 () => 8*1024*1024
  presignThreshold?: number              // 默认 100MB
  chunkSize?: number                     // 默认 5MB
  presign?: (file: File, settings: ShareSettings) => Promise<PresignCompleteData>
}): {
  tasks: Ref<UploadTask[]>
  isUploading: ComputedRef<boolean>      // anyUploading 等价
  canStart: ComputedRef<boolean>
  addFiles(files: File[] | FileList): void
  remove(id: string): void               // abort 本任务（若有）
  cancel(id: string): void               // uploading→error+abort 文案（multi 进行中仅标记=现状）
  start(): Promise<ShareResult | null>   // E2E 预加密→pickUploadPlan→执行；失败任务标 error；成功返回结果（含 e2e_key）
  dispose(): void                        // abort 全部（卸载用）
}
```
内部：ElMessage 直接用（现状即如此）；decision 用原始大小；E2E_MAX=100MB；uuid 用 crypto.randomUUID 兜底。
- [x] Step 1 失败测试（vi.mock `@/api/share`/`@/api/multifile`/`element-plus`/`@/utils/e2e`）：direct 成功映射 / presign 分支走 opts.presign / multi-direct 2 文件 / multi-chunk 逐文件 chunk+multiBind 一次 / E2E 超限拒绝零 API 调用 / E2E 加密顺序+e2e_key 进结果 / 失败标 error+ElMessage.error
- [x] Step 2 实现 → PASS → commit `feat(upload): useUploadQueue 队列状态机（E2E 预加密+四通道编排+abort）`

### Task 6: useFileDrop + FileItemRow + FileUpload 瘦身

**Files:** Create `src/composables/useFileDrop.ts`、`src/components/upload/FileItemRow.vue`；Modify `src/components/upload/FileUpload.vue`（重写）

**Interfaces:**
```ts
// useFileDrop
export function useFileDrop(opts: { onFiles: (files: File[] | FileList) => void }): { isDragging: Ref<boolean> }
// window dragover/dragleave/drop/paste 四监听，onScopeDispose 清理；语义=现状（dragover types 含 Files 才高亮；drop 有文件才 preventDefault；paste 收集 kind==='file'，成功 toast 现状硬编码串保留、W3 i18n 清欠登记）
// FileItemRow
props: { task: UploadTask }  emits: (remove|cancel): [id: string]
// 模板=现 file-item 块平移（formatFileSize 已全局、getFileType 随迁为组件私有）
```
FileUpload 重写要点：`useFileDrop({ onFiles: queue.addFiles })`；el-upload 仅保留点击选择（on-change → addFiles([raw])，删残留 uploadRef）；`handleUploadAll` = `validate()` → `queue.start()` → outcome 则 `emit('success', outcome)`；`onBeforeUnmount(() => queue.dispose())`；样式仅留容器/按钮，列表与设置样式随 FileItemRow/ShareSettingsForm 走。
- [x] Step 1 建 useFileDrop + FileItemRow
- [x] Step 2 重写 FileUpload（目标 ≤250 行）
- [x] Step 3 typecheck+test+vite build 绿 → commit `refactor(upload): FileUpload 瘦身为装配层（useFileDrop+useUploadQueue+FileItemRow），909→~200 行`

### Task 7: 终验（四通道+E2E 往返+取消冒烟）

- [x] `npm run typecheck && npm run test && npm run build` 全绿
- [x] 本地 server（FCB_OPEN_UPLOAD=true）+ dev 浏览器冒烟：①单文件直传→弹窗 ②双小文件→multi-direct ③双 5MB 文件（总>8MB）→chunk+bind（服务端 local 接受分片则实测，被 enableChunk 拦则记录转 unit 覆盖为准）④E2E 加密单文件分享→取件页带 key 解密验证 ⑤multi 上传中点取消→任务标 error 不崩 ⑥home emit 契约回归（成功弹窗三 tab）
- [x] 勾选计划、更新记忆、汇报

## Self-Review 记录

- Spec 覆盖：§6.1→Task3、§6.2→Task5+6、§6.3→Task4、§6.4→Task1+2；§10-W2 验收清单→Task7（presign 真通道需 S3，本地以 unit+E2E 加密往返替代并注明）。
- 类型一致：UploadTask/ShareSettings/ShareResult 命名跨 Task 5/6 一致；xhrSend 返回 ApiResponse 形状与各 api 文件既有类型吻合。
- 占位符：无。偏差两处（Error 载荷、xhrRaw 拆分）已在 Global Constraints 声明。
