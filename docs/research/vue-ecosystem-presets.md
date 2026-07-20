# Eglotx Vue 生态零配置 preset 调研

调研日期：2026-07-18

本文只采用 Vue、Vue Language Tools、TypeScript Language Server、ESLint Vue、Tailwind CSS、Biome、GraphQL Language Service 的官方文档或源码。lsp-mode 仅用于证明现有 Emacs 客户端如何接线，不把它当协议规范。

> **文档状态（2026-07-19）：** 本文保留方案形成过程和未落地的扩展建议。当前实现
> 为每次 contact resolution 建立一个有界缓存；Vue 与普通 JS/TS 是独立 Eglot cohort
> 和 facade，不跨 session 共享缓存，也不共享 TLS process，因此同一项目可能启动两套
> TLS。当前支持面和测试矩阵以 [`docs/presets.md`](../presets.md) 为准。

## 结论

Vue 3 的生产级默认方案不是“再启动一个 Volar 就结束”，而是一个有依赖关系的双服务组合：

1. TypeScript Language Server（TLS）必须加载 `@vue/typescript-plugin`，并接受 `vue` language id。
2. Vue Language Server（VLS）负责 Vue SFC 能力。
3. Eglotx 必须在两者之间实现私有 `tsserver/request` / `tsserver/response` 异步桥。
4. ESLint、Tailwind、Biome、GraphQL 只在各自具有强项目意图时，作为 Vue cohort 的可选 add-on。

Vue 官方把 Vue - Official（原 Volar）列为推荐 IDE 支持，也明确指出其他 LSP 客户端可以复用 Volar；上游把编辑器接入拆为 `@vue/language-server`、`@vue/language-service` 与 `@vue/typescript-plugin` 三个包。[Vue Tooling](https://vuejs.org/guide/scaling-up/tooling.html#ide-support) [Vue Language Tools](https://github.com/vuejs/language-tools/tree/v3.3.7)

当前 VLS 3.x 已移除旧的 `vue.hybridMode` 开关和 `typescript.tsdk` initialization option，但**没有移除 TypeScript 协作架构**。当前 server 源码仍先请求 `_vue:projectInfo`，并把后续 tsserver 命令交给客户端转发；官方 README 也明确说明该私有通知通道。[3.3.7 changelog](https://github.com/vuejs/language-tools/blob/v3.3.7/CHANGELOG.md) [VLS server.ts](https://github.com/vuejs/language-tools/blob/v3.3.7/packages/language-server/lib/server.ts) [VLS README](https://github.com/vuejs/language-tools/blob/v3.3.7/packages/language-server/README.md)

因此 preset 不能再写旧 hybrid-mode setting，也不能把 VLS 当独立、可降级的普通 add-on。Vue 主链的 TLS、Vue TypeScript plugin、VLS 和私有桥中任一缺失，都应整体拒绝启动并保留原 Eglot contact，而不是暴露一个初始化成功、首次语义请求却永久挂起的 facade。

## 服务拓扑与职责

| 角色 | 是否必需 | language ids | 默认职责 |
| --- | --- | --- | --- |
| TypeScript Language Server | 必需 | Vue cohort 中仅 `vue`；普通 JS/TS 由独立 cohort 处理 | Vue 模板/脚本背后的 tsserver 语义、项目归属、类型推断 |
| Vue Language Server | 必需 | 基线仅 `vue` | SFC 映射、Vue 模板与样式、Vue 专用导航/补全 |
| ESLint Language Server | 条件 add-on | `vue` | 诊断与 code action；默认不抢格式化 |
| Tailwind CSS Language Server | 条件 add-on | `vue` | class 补全、hover、诊断 |
| Biome Language Server | 条件 add-on | `vue` | 按项目 Biome 配置提供诊断、code action、格式化 |
| GraphQL Language Server | 条件 add-on | `vue` | `gql` / `graphql` tagged template 中的 GraphQL 能力 |

普通 `.ts`、`.tsx`、`.js`、`.jsx` 文件继续走现有 TypeScript preset，不应为它们额外启动 VLS。Vue JSX/TSX 也仍是 `javascriptreact` / `typescriptreact`；只有外层 Vue SFC 文档使用 `vue`。

Pinia、Vue Router、Vuetify、VueUse 等库不需要独立 LSP。它们的类型能力来自 TypeScript/Vue plugin；不能仅因依赖这些库而新增后台进程。

## 可执行文件、argv 与初始化参数

### Vue Language Server

官方 npm 包是 `@vue/language-server`，bin 是 `vue-language-server`。[package.json](https://github.com/vuejs/language-tools/blob/v3.3.7/packages/language-server/package.json)

首选命令：

```text
/nearest/project/node_modules/.bin/vue-language-server --stdio --tsdk=/nearest/project/node_modules/typescript/lib
```

`--tsdk` 必须指向 TypeScript 的 `lib` 目录，不是 `.bin/tsserver`。这是当前官方 CLI 的参数形式；当前入口会从该目录加载 TypeScript。[VLS README](https://github.com/vuejs/language-tools/blob/v3.3.7/packages/language-server/README.md) [VLS index.ts](https://github.com/vuejs/language-tools/blob/v3.3.7/packages/language-server/index.ts)

版本兼容规则：

- VLS 3.1.1+ 支持 `--tsdk`。
- Vue 2 应固定项目本地 `@vue/language-server@~3.0.0`；3.1 起官方已删除 Vue 2 与 class-component 支持。[官方维护者说明](https://github.com/vuejs/language-tools/discussions/5455)
- 3.0 分支从 3.0.9 起也有 `--tsdk`；3.0.8 及更旧版本只传 `--stdio`。[changelog](https://github.com/vuejs/language-tools/blob/v3.3.7/CHANGELOG.md)
- 无法可靠读出版本时，兼容性优先，只传 `--stdio`；私有桥仍然必需。

VLS 当前不需要 preset 注入 initialization options。尤其禁止继续注入：

- `vue.hybridMode`
- `typescript.tsdk`
- 猜测出的 `vueCompilerOptions`

`vueCompilerOptions` 属于项目的 tsconfig/jsconfig；preset 应尊重项目文件，不代替项目决定 `target`、`strictTemplates`、扩展名或 casing。

### TypeScript Language Server

命令为：

```text
/nearest/project/node_modules/.bin/typescript-language-server --stdio
```

官方 TLS 支持通过 initialize 的 `plugins` 注册 TypeScript plugin，并用 `languages` 扩展它原本不接受的 language id。[TLS configuration](https://github.com/typescript-language-server/typescript-language-server/blob/c6a35fbbdd6fb8681ca7e19a09372d2376e108e5/docs/configuration.md#plugins-option)

推荐 initializationOptions：

```json
{
  "plugins": [
    {
      "name": "@vue/typescript-plugin",
      "location": "/nearest/project/node_modules/@vue/language-server",
      "languages": ["vue"]
    }
  ],
  "tsserver": {
    "path": "/nearest/project/node_modules/typescript/lib"
  }
}
```

`location` 是可 `require("@vue/typescript-plugin")` 的包目录，不是 VLS binary 路径。项目安装的 `@vue/language-server` 自带对 `@vue/typescript-plugin` 的依赖；当前 lsp-mode 也从 VLS 安装目录解析该位置并给 TLS 增加 `vue`。[VLS package.json](https://github.com/vuejs/language-tools/blob/v3.3.7/packages/language-server/package.json) [lsp-volar.el](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-volar.el)

不要给 TLS 插件对象塞入 VS Code extension manifest 专用字段作为正确性依赖；TLS 官方公开且必要的结构只有 `name`、`location`、可选 `languages`。

## 私有 tsserver 桥：精确 wire 形状

这是最需要协议测试覆盖的部分。vscode-jsonrpc 的字符串 method overload 使用 positional params，因此源码中的：

```typescript
connection.sendNotification('tsserver/request', [id, command, args])
```

在 JSON-RPC wire 上是**双层数组**，不是单层：

```json
{
  "jsonrpc": "2.0",
  "method": "tsserver/request",
  "params": [[17, "_vue:projectInfo", {"file": "/p/src/App.vue"}]]
}
```

Eglotx 收到后，向同一 project cohort 的 TLS 发标准 LSP 请求：

```json
{
  "jsonrpc": "2.0",
  "id": 91,
  "method": "workspace/executeCommand",
  "params": {
    "command": "typescript.tsserverRequest",
    "arguments": [
      "_vue:projectInfo",
      {"file": "/p/src/App.vue"}
    ]
  }
}
```

TLS 官方把 `typescript.tsserverRequest` 定义为 `[command, args, optional ExecuteInfo]`，响应是 tsserver response 对象。[TLS README](https://github.com/typescript-language-server/typescript-language-server#send-tsserver-command)

取 TLS 响应的 `body` 后回给 VLS：

```json
{
  "jsonrpc": "2.0",
  "method": "tsserver/response",
  "params": [[17, {"configFileName": "/p/tsconfig.json"}]]
}
```

官方 VS Code client 正是执行 TypeScript command、取 `res.body`、再发 response；当前 lsp-mode 的 handler 也明确解构 `[[id, command, payload]]` 并发送 `[[id, body]]`。[Vue VS Code extension.ts](https://github.com/vuejs/language-tools/blob/v3.3.7/extensions/vscode/src/extension.ts) [lsp-volar.el](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-volar.el)

生产实现必须满足：

- 桥接完全异步，绝不能阻塞 Emacs 主线程。
- 只允许 VLS role 定向到同 project cohort 的 TLS role，不能广播给所有 server。
- 为每个 VLS process 维护有界 pending 表；shutdown、进程退出和超时都要清理。
- TLS 不存在、command 失败、response 非预期或进程退出时，仍要回 `params: [[id, null]]`。VLS 当前 Promise 没有内部 timeout；不回包会永久 pending。[VLS server.ts](https://github.com/vuejs/language-tools/blob/v3.3.7/packages/language-server/lib/server.ts)
- 私有 request/response 不进入 Eglot facade 的普通通知合并逻辑，也不暴露给用户 client。
- `textDocument/didOpen` / `didChange` / `didClose` 必须同时送到 TLS 和 VLS；否则 TS plugin 看不到 Vue 文档。

## language id 与文件类型

基线 preset 只为 `.vue` 使用 `vue`。当前 Vue extension 注册的语言 id 是 `vue`，默认 server includeLanguages 也只有 `vue`。[VS Code package.json](https://github.com/vuejs/language-tools/blob/v3.3.7/extensions/vscode/package.json)

Vue Language Core 还支持项目显式扩展：

| 场景 | 外层 language id | 启用条件 |
| --- | --- | --- |
| Vue SFC | `vue` | 默认 `vueCompilerOptions.extensions = [".vue"]` |
| VitePress Markdown | `markdown` | tsconfig/jsconfig 同时把文件纳入 `include`，且 `vitePressExtensions` 包含对应扩展 |
| petite-vue HTML | `html` | `petiteVueExtensions` 显式包含对应扩展 |
| Pug template in SFC | 仍是 `vue` | 项目配置 `@vue/language-plugin-pug`；不新增外层 language id |

这些默认值和 plugin 入口由 Language Core 官方文档定义。[Language Core README](https://github.com/vuejs/language-tools/blob/v3.3.7/packages/language-core/README.md)

VitePress 官方要求两侧同时配置：tsconfig/jsconfig 的 `include` 和 `vueCompilerOptions.vitePressExtensions`，以及 client 侧把 `markdown` 加入 includeLanguages。[VitePress IntelliSense](https://vitepress.dev/guide/using-vue.html#vs-code-intellisense-support)

所以：

- 不得仅因为依赖里有 `vitepress` 就接管工作区所有 Markdown。
- 不得仅因为依赖里有 `petite-vue` 就接管所有 HTML。
- preset 可做有界、缓存的 tsconfig/jsconfig 解析；只有项目显式声明对应 extension 时才扩展 languages。
- `<template lang="pug">`、`<script lang="ts">`、`<style lang="scss">` 都仍是同一个 `vue` 文档，不应启动针对外层虚拟文件的重复 TypeScript server。

## Vue 项目意图侦测

### 强信号

按强到弱排序：

1. 当前 buffer 是 `.vue`，这是最直接且无歧义的信号。
2. 最近 package manifest 的 dependency/devDependency/peerDependency 中存在精确包名：`vue`、`nuxt`、`vitepress`、`@vitejs/plugin-vue`、`@vitejs/plugin-vue-jsx`、`@vue/compiler-sfc`。
3. 有以 token/stem 判断的 Vue/Nuxt 结构配置，如 basename stem 含 `vue.config` 或 `nuxt.config`；扩展名不应穷举。
4. 最近 project root 存在本地 `vue-language-server`，但该信号只能强化已打开的 Vue 文档，不能单独让非 Vue buffer 被接管。

### 明确排除

- 仅有 `vite` 或 `vite.config.*` 不足以判断 Vue；Vite 同样服务 React、Svelte 等生态。
- 不要用“包名中包含 vue”这种模糊规则；例如无关的 `vue-*` 包不能触发整个 Vue cohort。
- 不要递归扫描整个仓库寻找任意 `.vue`；在大型 monorepo 上既慢，又可能把其他 package 的技术栈错误施加到当前 package。

实现上应复用 presets 的最近祖先 manifest、token 化文件名匹配和 root 缓存。侦测只做有界祖先遍历与少量 manifest/tsconfig 解析，不启动 `npm`、`pnpm`、`yarn` 或 `npx` 探测。

## local-first 解析

对每个 root 分别解析并缓存，不把“可执行文件”和“package 目录”混为一个值：

1. 当前 package 最近的 `node_modules/.bin/vue-language-server`。
2. monorepo/workspace root 的本地 bin。
3. PATH 中的 `vue-language-server`。

TLS、ESLint、Tailwind、Biome、GraphQL 同样遵循最近 package、workspace root、PATH 的顺序。禁止默认使用 `npx --yes` 或动态安装；它增加冷启动延迟、网络与供应链不确定性。

另行解析：

- Vue TS plugin location：最近的 `node_modules/@vue/language-server` package 目录；必要时追踪 `.bin` symlink 回 package root。
- TypeScript SDK：最近的 `node_modules/typescript/lib`，其次 workspace root，再考虑 server 自身可解析的 fallback。
- 本地 package version：读取对应 package.json，决定 Vue 2 pin 与 `--tsdk` 兼容分支。

如果 current package 固定了 3.0.x，不能让 workspace 或 PATH 的 3.3.x 覆盖它。对 Vue 2 来说，local-first 是正确性的要求，不只是偏好。

## 可选 add-on

### ESLint

eslint-plugin-vue 官方可以检查 `.vue` 的 `<template>` 与 `<script>`，并要求 editor integration 把 `vue` 加入 validate。[eslint-plugin-vue](https://eslint.vuejs.org/) [Editor integrations](https://eslint.vuejs.org/user-guide/#editor-integrations)

启用条件应是“Vue 强意图 + 通用 ESLint 强意图 + 可执行文件可解析”。Vue 专属强化信号包括 package manifest 中精确的 `eslint-plugin-vue`、`vue-eslint-parser` 或 `@nuxt/eslint`。

推荐：

- 给 ESLint backend 增加 `vue` language id。
- 保持 `validate: on`、`format: false`，主要提供 diagnostics 与 code actions。
- 不替用户生成 ESLint 配置；是否启用 Vue parser 与规则由项目 flat config / legacy config 决定。
- 不因 Vue preset 同时存在而去重不同 source 的诊断；每个 backend 的完整 snapshot
  独立保留，再以带 backend 前缀的 source 投影给 Eglot。

### Tailwind CSS

官方 Tailwind language service 原生把 `vue` 列为 special language，所以无需把 Vue 人为映射为 HTML。[languages.ts](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-service/src/util/languages.ts)

官方包是 `@tailwindcss/language-server`，bin 为 `tailwindcss-language-server`，使用 `--stdio`。[package.json](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/package.json)

Vue preset 只需要在通用 Tailwind detector 已确认项目意图时，把该 backend 纳入 `vue` cohort。Tailwind v4 不应依赖 config marker：官方 IntelliSense 的激活条件是项目安装 Tailwind 且 CSS 文件导入 Tailwind stylesheet；v3 才依赖配置文件。[Tailwind IntelliSense README](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/vscode-tailwindcss/README.md)

因此 v4 策略是：

- manifest 中精确 `tailwindcss` 依赖作为廉价意图；
- 让 server 执行 CSS entrypoint discovery；当前 preset 不同步扫描 CSS 内容；
- 不维护 config 文件名穷举表。

### Biome

Biome 自 2.3.0 起可直接处理 Vue/Svelte/Astro 的 HTML、CSS、JS 部分，但官方到当前仍把 Vue 的 parsing、formatting、linting、plugin support 标为 experimental。[Biome language support](https://biomejs.dev/internals/language-support/)

`html.experimentalFullSupportEnabled` 为 false 时，Biome 只抽取 JS/TS 部分并忽略其余内容；官方还提示某些规则可能出现 false positive。为 true 时，嵌入语言的 parse/format/lint 才是一致的完整路径。[Biome configuration](https://biomejs.dev/reference/configuration/#htmlexperimentalfullsupportenabled) [Biome 2.4 changes](https://biomejs.dev/internals/changelog/version/2-4-0/)

生产默认建议：

- 仅在本地 Biome >= 2.3、存在通用 Biome 强意图且已确认 Vue 项目时，把 Biome 加入 `vue` cohort。
- 绝不替项目强开 experimental flag，也不静默写入规则 override。
- flag 明确为 true 时，可按通用 Biome preset 提供 diagnostics、code actions 与 formatting。
- flag 缺失/false 时仍可提供其官方支持的 JS/TS 分析，但不把 Biome 设为 Vue 文档的默认 formatter owner；保留一条可观测的“partial Vue support”状态，便于用户解释 false positive。
- 版本未知或 < 2.3 时，不把 Vue 文档发给 Biome。

### GraphQL

当前 GraphQL Language Service Server 的默认扩展列表包含 `.vue`，并有专用 Vue SFC parser 提取 script / script-setup 中的 tagged templates。[constants.ts](https://github.com/graphql/graphiql/blob/277cddad169962a580b0aa71e08f5ea3a29ffd01/packages/graphql-language-service-server/src/constants.ts) [vue.ts](https://github.com/graphql/graphiql/blob/277cddad169962a580b0aa71e08f5ea3a29ffd01/packages/graphql-language-service-server/src/parsers/vue.ts)

命令由官方 `graphql-language-service-cli` 提供：

```text
graphql-lsp server -m stream --configDir /project/root
```

[GraphQL CLI README](https://github.com/graphql/graphiql/blob/277cddad169962a580b0aa71e08f5ea3a29ffd01/packages/graphql-language-service-cli/README.md)

只有发现结构化 GraphQL config 且 executable 可解析时才加入 Vue cohort。最终包含哪些 Vue 文件应由 GraphQL config 的 documents/include/exclude 决定；不能仅因为 manifest 有 `graphql` runtime package 就启动 LSP。

## 性能与故障策略

1. **一次 contact 内复用**：当前有界 context 缓存该次 resolution 的 manifest、目录、
   文件读取与 executable probe，包括负结果；session 重启后重新侦测。
2. **cohort 隔离**：Vue 与普通 JS/TS 使用不同 facade，当前不共享 TLS process；共享
   process 需要跨 Eglot session 的生命周期与文档归属协议，保留为未来优化。
3. **按需 add-on**：只在首个适用 buffer 打开时启动，不在 project discovery 阶段预热所有 server。
4. **有界 I/O**：祖先查找有边界；不递归扫描仓库；CSS 内容探测限制候选文件数和读取字节数。
5. **稳定路由**：一次 request 的 owner set 在请求生命周期内固定；server 中途退出不能把 response 错配给新 process。
6. **失败隔离**：可选 ESLint/Tailwind/Biome/GraphQL 失败不应杀死 Vue 主链；TLS/VLS/bridge 任一失败则 Vue 主链整体不可用。
7. **未来可观测性**：可扩展状态输出以显示 resolved executable、version、tsdk、
   plugin location 与启用/跳过 add-on 的原因；当前公共状态只承诺 backend、运行状态、
   priority、languages、server info、last error 和 bridge 计数。
8. **禁止安装副作用**：preset discovery 不运行 package manager，不下载 server，不修改项目配置。

## 建议的 preset 判定结果

建议 detector 产出声明式结果，core 只消费它，不把 Vue 知识写进 multiplexer：

```text
vue preset
  root: /workspace/packages/app
  languages: (vue)
  required:
    - typescript-language-server
      plugin: @vue/typescript-plugin
      accepts: (vue)
    - vue-language-server
      argv: (--stdio --tsdk=/workspace/packages/app/node_modules/typescript/lib)
  private-links:
    - vue-tsserver-bridge(vls -> tls)
  optional:
    - eslint   when eslint-intent
    - tailwind when tailwind-intent
    - biome   when biome>=2.3
    - graphql when graphql-config
```

这样“如何发现与组合 Vue 生态”留在 preset 层；core 只需要通用的 required/optional backend、私有定向 notification bridge、method routing、生命周期和 facade 能力合并。

## 建议验收用例与当前覆盖

下面是完整方案的建议验收清单，不等同于当前自动化覆盖。当前 fixture ERT 覆盖
Vue/TLS/plugin 解析、版本与本地优先、bridge wire/error、add-on intent、Biome 版本/
full-support gate、fallback 和 cohort；`make test-vue-e2e` 覆盖真实本地
VLS/TLS/ESLint/Tailwind、bridge 以及 TypeScript/ESLint diagnostics。VitePress、
petite-vue、真实 Vue/Biome 和跨 cohort process 共享尚未实现。

1. Vue 3 + TypeScript：模板属性类型错误、`script setup` 未使用变量、跨 `.vue` component definition/completion。
2. wire test：明确断言 request `params == [[id, command, args]]`，response `params == [[id, body]]`。
3. TLS command error：VLS 在有限时间内收到 `[[id, null]]`，pending 表归零。
4. 本地优先：package-local VLS/TS 覆盖 workspace 与 PATH；plugin location 是 package dir，不是 bin。
5. Vue 2 fixture：本地 3.0.x 被选择，不能误用全局 3.1+。
6. monorepo：Vue package 启动 Vue cohort，相邻 React package 不启动；两个 package 的 tsdk/version 不串根。
7. VitePress：仅 tsconfig 明确声明 `vitePressExtensions` 的 Markdown 进入 cohort。
8. petite-vue：仅显式 `petiteVueExtensions` 的 HTML 进入 cohort。
9. ESLint：`.vue` template rule 诊断与 code action 可见，且不抢 formatter。
10. Tailwind v4：无 v3 config、manifest 有精确 `tailwindcss` dependency 且 CSS 入口
    导入 Tailwind 时，server 能在 Vue class 中补全。
11. Biome：2.2 不接收 Vue；2.3+ partial 状态可见；full flag 开启后格式化与跨块规则正常。
12. GraphQL：有 GraphQL config 的 `.vue` tagged template 有补全/诊断；只有 `graphql` runtime dependency 时不启动。
13. add-on crash：Vue/TLS 主链仍工作；主链任一 required process crash 时 facade 明确降级或断开，不悬挂。

## 历史实施顺序

以下是调研时的优先顺序；1–4 的当前支持范围以上述矩阵为准，5 仍未实现：

1. Vue + TLS required cohort 与双层 params 的私有桥。
2. local-first package/version/tsdk/plugin-location 解析。
3. `.vue` 基线检测与 monorepo root 隔离。
4. 复用现有 ESLint、Tailwind、Biome、GraphQL detector，把 backend 加入 `vue` cohort。
5. 最后增加显式 VitePress Markdown、petite-vue HTML 与 Vue 2 3.0.x 兼容分支。

不能把“移除了 hybrid mode 配置”误读为“无需 TypeScript bridge”。这是当前 Vue 3.3.x 接入最关键的正确性结论。
