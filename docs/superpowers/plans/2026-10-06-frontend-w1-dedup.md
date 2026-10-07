# 前端 W1 纯去重（零行为变化）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消灭 frontend 前端的纯重复代码（formatFileSize×12+、formatDate 两族×10、导航双套、设置表单双份、成功弹窗内联、TextShare 硬编码中文），行为不变。

**Architecture:** 新建 `utils/format.ts`（唯一格式化实现）、`config/menu.ts`（导航单一数据源）、`components/layout/{TopNav,UserMenu}`、`components/share/{ShareSettingsForm,ShareResultDialog}`、`composables/useShareSettings`；存量文件删除本地重复改为 import。

**Tech Stack:** Vue 3.5 + TS + Element Plus（按需）+ Pinia + vue-i18n + vitest（已有，零新依赖）。

**Spec:** `docs/specs/2026-10-06-frontend-architecture-design.md`（§5.1/§5.2/§7 + §10-W1）

## Global Constraints

- 零新 runtime 依赖；devDep 也不加。
- 零行为变化。**两处已批准的微修复**除外（commit message 注明）：①`toLocaleDateTime` 统一携带 Safari 空格日期 T 归一修复（admin/Dashboard 等页面此前 Safari 下显示 Invalid Date）；②非法日期串回退 fallback 而非显示 "Invalid Date"。
- 每任务一 commit；commit 前必须 `npm run typecheck && npm run test` 绿。
- commit 前置：`git -C PigeonBox/frontend status --short` 确认无并行会话未预期改动（工作区有并行会话惯例）。
- commit 风格对齐仓内惯例：`refactor(scope): 中文描述`。
- i18n：新文案必须 key 化，zh-CN 与 en-US 同 commit 补齐。
- 自有组件显式 import（unplugin 只解析 Element Plus，维持）。

---

### Task 1: `utils/format.ts` + formatFileSize 收敛（13 处）

**Files:**
- Create: `src/utils/format.ts`、`src/utils/__tests__/format.spec.ts`
- Modify（删本地 `formatFileSize`，加 `import { formatFileSize } from '@/utils/format'`）:
  `components/upload/FileUpload.vue:262`、`components/upload/PresignUploadDialog.vue:111`、`views/share/View.vue:207`（string 入参变体，内部 `Number()` 归一后调共用实现）、`views/user/Dashboard.vue:264`、`views/admin/{Files:309,Users:289,Storage:276,Dashboard:300,Maintenance:158,Moderation:105,LocalFiles:222,TransferLogs:125}.vue`、`views/user/Requests.vue:114`（名 formatSize，4 单位变体，一并收敛）

**Interfaces（Produces）:**
```ts
export function formatFileSize(bytes: number): string
// bytes<=0 或非有限数 → '0 B'；其余与原实现逐字节一致（k=1024，B..TB，两位小数）
```

- [x] Step 1 写失败测试 `format.spec.ts`：`0→'0 B'`、`512→'512 B'`、`2048→'2 KB'`、`5*1024*1024→'5 MB'`、`1.5*1024**3→'1.5 GB'`
- [x] Step 2 `npm run test -- format` 确认 FAIL（模块不存在）
- [x] Step 3 实现 `formatFileSize`（含 `Math.min(i, sizes.length-1)` 越界钳制）
- [x] Step 4 测试 PASS 后逐文件替换 13 处（每处：删函数体、加 import、模板引用不变）
- [x] Step 5 `npm run typecheck && npm run test` 绿 → `git add -A && git commit -m "refactor(utils): formatFileSize 收敛至 utils/format.ts，消灭 13 处重复定义"`

### Task 2: formatDate 两族收敛（10 处核对）

**Files:**
- Modify: `utils/format.ts`（追加两个导出）；10 个含本地 `formatDate` 的 vue（admin/{Dashboard:308,Moderation:113,Activities:82,TransferLogs:133,Files:317,Users:297}、user/{History:132,Dashboard:272,Notifications:129,Shares:426}）

**Interfaces（Produces）:**
```ts
// 族 A：字符串归一（不解析 Date，locale 无关）——user/Shares、user/History 已证同款
export function formatDateTime(s: string | null | undefined, fallback?: string): string
// 默认 fallback '—'；"…T…" → replace('T',' ').slice(0,19)；否则原样返回
// 族 B：解析为本地时间串——admin/Files（Safari T 修复 + zh-CN）、admin/Dashboard（locale 响应式）等
export function toLocaleDateTime(s: string | null | undefined, opts?: { locale?: string; fallback?: string }): string
// 默认 locale 'zh-CN'、fallback '-'；空 → fallback；Invalid Date → fallback（微修复②）
```

- [x] Step 1 逐个读 10 处函数体，分拣：族 A / 族 B / 异类（异类留 local 并在 commit message 列名）
- [x] Step 2 format.spec.ts 补两族用例（T 归一、null fallback、Invalid Date fallback）
- [x] Step 3 实现并逐文件替换（admin/Dashboard 调用点传 `{ locale: locale.value === 'zh-CN' ? 'zh-CN' : 'en-US' }`）
- [x] Step 4 typecheck+test 绿 → commit `refactor(utils): formatDate 按字符串归一/本地解析两族收敛`

### Task 3: `config/menu.ts` + AppLayout 双份菜单收敛

**Files:**
- Create: `src/config/menu.ts`
- Modify: `layouts/AppLayout.vue`（桌面侧栏 L50-79 与移动抽屉 L96-125 两段 el-menu-item 全部替换为 `v-for="item in userNavItems"`）

**Interfaces（Produces）:**
```ts
export interface MenuItem { path: string; icon: Component; labelKey: string }
export const userNavItems: MenuItem[]
// 六项：dashboard/moniter… 与现 AppLayout 硬编码逐项等价（path/icon/labelKey 三元组）
```

- [x] Step 1 建 menu.ts（六项硬编码数据平移，icon 直接引 @element-plus/icons-vue 组件）
- [x] Step 2 AppLayout 两段模板改 v-for（`:index="item.path"`、`<el-icon><component :is="item.icon"/></el-icon>`、`{{ t(item.labelKey) }}`）
- [x] Step 3 typecheck 绿 → commit `refactor(layout): 用户侧导航菜单收敛 config/menu.ts 单一数据源`

### Task 4: `components/layout/UserMenu.vue` 抽出

**Files:**
- Create: `src/components/layout/UserMenu.vue`
- Modify: `layouts/AppLayout.vue`、`views/home/index.vue`（各自删除内联头像+下拉，换 `<UserMenu @command="handleCommand" />` / `@command="handleUserCommand"`）

**Interfaces:**
- Produces: `UserMenu`，props 无；emits `command: [key: string]`（dashboard/home/logout 由父级路由处理——两处 handleCommand 现行为不同：home 登出不跳转、AppLayout 登出 push('/')，保持各自不动）
- 模板内容 = 现 AppLayout L19-43 的 el-dropdown 原样平移（头像取 `userStore.userInfo?.username?.charAt(0).toUpperCase()`）

- [x] Step 1 建 UserMenu.vue（dropdown 三项：dashboard/home/logout，home 项保留——home 页父级 switch 不处理 'home' 即无副作用，行为等价）
- [x] Step 2 AppLayout/home 替换并删各自 dropdown 模板与无用 icon import
- [x] Step 3 typecheck 绿 → commit `refactor(components): UserMenu 抽出，home/AppLayout 复用`

### Task 5: `components/layout/TopNav.vue` 抽出

**Files:**
- Create: `src/components/layout/TopNav.vue`
- Modify: `layouts/AppLayout.vue`（header 段换 TopNav，汉堡按钮走 `#leading` slot）、`views/home/index.vue`（header 段换 TopNav，API 文档/取件/登录按钮走 `#nav-extra` slot）

**Interfaces:**
- Produces: props `{ variant?: 'home' | 'app' }`（仅驱动背景类 `--color-bg`/`--color-surface` 差异，样式随之平移）；slots `leading`、`nav-extra`
- 内部固定：logo+站名（点击回首页）+ LocaleSwitcher + ThemeSwitcher + `NotifyBell v-if="userStore.isLoggedIn"`（AppLayout 原为无条件渲染，但其路由组 requiresAuth 恒已登录，等价）+ `nav-extra` slot + 登录态 UserMenu / 未登录登录按钮
- [x] Step 1 建 TopNav.vue（模板自两处 header 平移合并；两套 scoped 样式并入，按 variant 类名分流背景色）
- [x] Step 2 两处替换；home 删除本地 nav 样式与 LocaleSwitcher/ThemeSwitcher/NotifyBell import（TopNav 内部化）
- [x] Step 3 typecheck 绿 → commit `refactor(components): TopNav 抽出，消灭双套顶部导航`

### Task 6: `useShareSettings` + `ShareSettingsForm` + FileUpload/TextShare 接入

**Files:**
- Create: `src/composables/useShareSettings.ts`、`src/components/share/ShareSettingsForm.vue`
- Modify: `components/upload/FileUpload.vue`（设置区 L101-169 与 form 定义 L237-244 替换）、`components/upload/TextShare.vue`（设置区 L16-78 与 form L113-120 替换）

**Interfaces（Produces）:**
```ts
export type ShareExpireStyle = 'minute'|'hour'|'day'|'week'|'month'|'year'|'forever'
export interface ShareSettings { expire_value: number; expire_style: ShareExpireStyle; require_auth: boolean; password: string; e2e: boolean; custom_code: string }
export function defaultShareSettings(): ShareSettings   // {1,'day',false,'',false,''}（与两处现状默认一致）
export function useShareSettings(initial?: Partial<ShareSettings>): {
  settings: ShareSettings          // reactive
  validate(): boolean              // require_auth→password 非空；不弹 toast，调用方提示
  reset(): void
}
```
ShareSettingsForm props：`{ settings: ShareSettings; showPassword?: boolean=true; showCustomCode?: boolean|'auto'='auto'; showE2e?: boolean=true; units?: ShareExpireStyle[]=全量 }`——模板=两处 setting-group 平移，文案全 `t()`（`common.minutes`…`common.forever`、`upload.*` 现有 key）。
范围裁决（依 spec §5.2"不强求一次归一"）：admin/Files（改期弹窗，语义不同）、admin/LocalFiles、user/Requests（el-form-item 布局+单位子集）**本轮不动**；PresignUploadDialog 留 W2 随 Promise 化一并迁移。

- [x] Step 1 建 useShareSettings.ts + ShareSettingsForm.vue
- [x] Step 2 FileUpload 接入（删本地 form/设置模板，改用 `const { settings, validate } = useShareSettings()`；**引用 form.xxx 的脚本处全部改 settings.xxx**，含 uploadOne/multiDirect opts/E2E 校验；password 校验 toast 留在原位改用 validate() 返回值）
- [x] Step 3 TextShare 同法接入
- [x] Step 4 typecheck+test 绿 → commit `refactor(share): 分享设置表单收敛 ShareSettingsForm+useShareSettings`

### Task 7: `ShareResultDialog` 抽出 + TextShare 残余 i18n

**Files:**
- Create: `src/components/share/ShareResultDialog.vue`
- Modify: `views/home/index.vue`（弹窗模板 L172-251 与 shareUrl/shareCode/qrCodeDataUrl/shareE2EKey/shareMethod/handleShareSuccess/copy 函数全部移入组件）、`components/upload/TextShare.vue`（残余硬编码中文 key 化）、`i18n/locales/{zh-CN,en-US}.ts`（补 key）

**Interfaces:**
- Produces: `ShareResultDialog`，`defineExpose({ open(result: ShareResult): Promise<void> })`——open 内做现 handleShareSuccess 全部逻辑（hash URL 修正、E2E key 并入 query、二维码生成）后弹窗；`ShareResult` 类型从 home 上移至组件导出，FileUpload/TextShare 的 emit 类型改为 import 该类型（可选，保持字面量亦等价）
- 新 i18n key：`upload.textPlaceholder`/`textShareBtn`/`textSharing`/`textShared`/`textShareFailed`（zh+en 同步；其余复用现有 `upload.*`/`common.*`）

- [x] Step 1 建 ShareResultDialog.vue（模板/逻辑自 home 平移，QRCode import 随迁）
- [x] Step 2 home 替换：`<ShareResultDialog ref="shareResult" />`，成功回调改 `shareResult.value?.open(result)`
- [x] Step 3 TextShare 五处硬编码中文改 t() + 两 locales 补 key
- [x] Step 4 typecheck+test 绿 → commit `refactor(home): ShareResultDialog 抽出；fix(i18n): TextShare 硬编码中文 key 化`

### Task 8: 终验

​- [x] `npm run typecheck && npm run test` 绿
- [x] 手工冒烟（`npm run dev` + 本地 server 或 215 线上对照）：首页文件上传（单/多文件）→ 成功弹窗三 tab；文本分享全流程；设置表单（密码开关/自定义码登录显隐/E2E 开关）；user 侧栏 6 项与移动抽屉；home 顶部导航（登录/未登录两态）；`git log --oneline` 确认 7 个 commit 各自独立
- [x] 更新记忆 fcb-frontend-architecture-design（W1 完成状态）

## Self-Review 记录

- Spec 覆盖：spec §10-W1 四项全覆盖（format/menu+UserMenu/ShareSettingsForm/TextShare i18n）；§7 映射表中 TopNav、ShareResultDialog 两项 W1 未列但属纯抽取，归入本计划 Task 5/7（spec 缺口已在计划补齐）。
- 类型一致性：ShareSettings/ShareExpireStyle 命名在 Task 6 定义、Task 7 消费一致；formatDateTime/toLocaleDateTime 与 Task 1 的 formatFileSize 同驻 utils/format.ts。
- 占位符：无 TBD；异类 formatDate 处置规则已给出（留 local + commit message 列名）。
