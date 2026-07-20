# Astro 多 LSP preset 调研与实现约束

日期：2026-07-20

状态：面向 Eglotx Astro preset 的实现依据；上游源码链接固定到调研快照，在线文档只用于项目公开承诺。

## 结论

Astro 的默认栈应以 `astro-ls --stdio` 为唯一结构化主服务器，并按项目意图加入 ESLint、Tailwind CSS、Biome 和 GraphQL。

| 后端 | 加入条件 | `.astro` 中的职责 | 格式化 |
| --- | --- | --- | --- |
| Astro Language Server | server 与项目 TypeScript SDK 都可解析 | Astro、TS/JS frontmatter、HTML、CSS、导航、diagnostics | 默认 owner；需项目 Prettier 插件才能实际工作 |
| ESLint | ESLint 配置/依赖与 server 同时存在 | lint diagnostics、code actions | 否 |
| Tailwind CSS | Tailwind 项目意图与 server 同时存在 | class completion/resolve、hover、Tailwind diagnostics/actions/colors | 否 |
| Biome 2.3+ | Biome 配置/依赖与 server 同时存在 | lint/actions；显式 full support 时可格式化 | 仅显式 full support |
| GraphQL | GraphQL Config 与 server 同时存在 | frontmatter 内嵌 GraphQL completion/navigation/diagnostics | 否 |

不得把 TypeScript、HTML、CSS、Vue 或 Svelte Language Server 再绑定到同一个 `.astro` URI；这些结构能力已经位于 Astro LS 内部，额外 fan-out 只会重复解析并争抢结果。

## 调研快照

| 项目 | 快照 |
| --- | --- |
| Astro monorepo / `@astrojs/language-server` | `2.16.12`，commit `311e42c77d689e7f7bacb7ea2e000beac6835a37` |
| lsp-mode | commit `6bfc593d7b1bc0dd656f09ffce52cc085ebced05` |
| Tailwind CSS IntelliSense | commit `5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a` |
| GraphQL Language Service | commit `277cddad169962a580b0aa71e08f5ea3a29ffd01` |
| astro-ts-mode | commit `49ca84baa671f7e7d135b32813629ec533edf637` |

## 1. Astro Language Server contact

`@astrojs/language-server` 发布的 bin 名为 `astro-ls`，stdio contact 是：

```text
astro-ls --stdio
```

包定义见 [`language-server/package.json`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/package.json)。lsp-mode 的 Astro client 也使用该 argv，并以 `astro` 为 activation language id：[`clients/lsp-astro.el`](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-astro.el)。

官方 VS Code client 的 document selector 同样是 `astro`，并传入 TypeScript SDK：[`vscode/src/client.ts`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/vscode/src/client.ts)。

Eglotx 应按具体 mode 优先排序：

```elisp
((astro-ts-mode :language-id "astro")
 (astro-mode :language-id "astro"))
```

`astro-ts-mode` 是首选 Tree-sitter mode，并派生自 `html-mode`，所以 Astro
entry 必须排在 HTML entry 之前。该包的历史把原 `astro-mode` 重命名为
`astro-ts-mode`，preset 保留旧 symbol 作为兼容入口；不注册通用
`web-mode`，否则会劫持非 Astro 模板。依据：当前
[`astro-ts-mode.el`](https://github.com/Sorixelle/astro-ts-mode/blob/49ca84baa671f7e7d135b32813629ec533edf637/astro-ts-mode.el)
和[重命名提交](https://github.com/Sorixelle/astro-ts-mode/commit/688b7c9f661571fcd7d6d754a91e48a9938d8684)。

### TypeScript SDK 是硬条件

server 在 `initialize` 中读取 `initializationOptions.typescript.tsdk`；缺失时直接抛错。该目录必须含 `typescript.js` 或 `tsserverlibrary.js`：[`language-server/src/nodeServer.ts`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/src/nodeServer.ts)。

因此 contact 必须传：

```elisp
:initialization-options '(:typescript (:tsdk "/project/node_modules/typescript/lib"))
```

解析顺序应是当前 package 最近祖先的 SDK、workspace root SDK；不能把一个 sibling package 的 TypeScript 注入当前 Astro 项目。package 中 TypeScript 只是 dev dependency，不是运行时依赖，preset 不能假定 `astro-ls` 自带可用 SDK。

找不到 SDK 时不要启动一个必然 initialize 失败的 facade；保留 preset 安装前的 Eglot contact，并给出可操作原因。

`contentIntellisense` 缺省为 false，开启后还依赖 `.astro/collections/collections.json`。零配置 preset 不应擅自启用实验功能；源码见同一 [`nodeServer.ts`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/src/nodeServer.ts)。

server watch 列表包含 JS/TS/JSON/Astro/Vue/Svelte；这是项目图的文件监听范围，不表示客户端应把这些 language id 全部交给 Astro contact。

## 2. 不重复启动结构化 server

Astro LS 的 language plugins 包含 Astro、Vue、Svelte 和 frontmatter；service plugins 包含 HTML、CSS、Emmet、TypeScript、Astro、Prettier 和 YAML：[`languageServerPlugin.ts`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/src/languageServerPlugin.ts)。

Astro plugin 将 `.astro` 注册为 mixed-content TypeScript service file，并把源文件转换为 TSX：[`core/index.ts`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/src/core/index.ts)。

由此得到方法所有权：

- Astro LS 独占结构 completion、hover、signature help、navigation、rename、symbols、semantic tokens、inlay hints 和 folding；
- Astro LS 负责 Astro compiler 与 TypeScript diagnostics；
- HTML/CSS 能力由其内部 Volar services 提供；
- Vue/Svelte component files 打开时继续走各自 preset，不给 `.astro` 附加 Vue/Svelte backend。

上游测试直接覆盖 Astro language id 的 TypeScript diagnostics、completion 和 CSS completion：[`diagnostics.test.ts`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/test/typescript/diagnostics.test.ts)、[`completions.test.ts`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/test/typescript/completions.test.ts)、[`css/completions.test.ts`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/test/css/completions.test.ts)。

## 3. 格式化边界

Astro LS 的 Prettier service 只选择 `astro` 文档，并强制 `parser: "astro"`。它从 workspace 解析 Prettier 与 `prettier-plugin-astro`，缺失时通知 formatting 不工作：[`languageServerPlugin.ts`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/src/languageServerPlugin.ts)。

这两个包是 optional peer dependencies：[`language-server/package.json`](https://github.com/withastro/astro/blob/311e42c77d689e7f7bacb7ea2e000beac6835a37/packages/language-tools/language-server/package.json)。Astro 的编辑器指南也要求其他编辑器安装 Prettier 和 Astro plugin：[Editor setup](https://docs.astro.build/en/editor-setup/#prettier)。

默认 formatting owner 保持 Astro LS；Biome 只有在项目显式设置 `html.experimentalFullSupportEnabled: true` 时，才以更高优先级取得 formatting/rangeFormatting。不能合并两个 formatter 的 `TextEdit[]`。

## 4. 可选 add-on

### Tailwind CSS

Tailwind Language Service 把 `astro`、`astro-markdown` 列为 HTML language，并有专门的 Astro frontmatter lexer和 boundary mapping：[`util/languages.ts`](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-service/src/util/languages.ts)、[`util/getLanguageBoundaries.ts`](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-service/src/util/getLanguageBoundaries.ts)。

因此直接传 language id `astro`，无需脆弱的 class regex。allowlist 只保留同步/configuration、completion/resolve、hover、code action/resolve、colors、lens、links 和 diagnostics；排除 formatting、rename 与 navigation。

Tailwind v4 项目意图优先读取精确 `tailwindcss` dependency 或项目本地 server，不依赖 `tailwind.config.*`。v4 不会自动探测 JavaScript config：[Upgrade guide](https://tailwindcss.com/docs/upgrade-guide#using-a-javascript-config-file)。CSS 中的 `@import "tailwindcss"` 图由 server 自己发现，preset 不扫描全仓库 CSS。

### GraphQL

GraphQL Language Service 的默认扩展含 `.astro`，并有专用 parser：它调用 Astro compiler，只解析 frontmatter，再把 GraphQL ranges 映射回源文档：[`constants.ts`](https://github.com/graphql/graphiql/blob/277cddad169962a580b0aa71e08f5ea3a29ffd01/packages/graphql-language-service-server/src/constants.ts)、[`parsers/astro.ts`](https://github.com/graphql/graphiql/blob/277cddad169962a580b0aa71e08f5ea3a29ffd01/packages/graphql-language-service-server/src/parsers/astro.ts)。上游 fixture 测试见 [`findGraphQLTags.test.ts`](https://github.com/graphql/graphiql/blob/277cddad169962a580b0aa71e08f5ea3a29ffd01/packages/graphql-language-service-server/src/__tests__/findGraphQLTags.test.ts)。

只有结构化 GraphQL Config 才加入 backend；仅有 `graphql` dependency 不足以证明文档范围。复用现有 GraphQL allowlist，明确排除 formatting。

### ESLint

Astro 官方指南指向 `eslint-plugin-astro`：[Editor setup](https://docs.astro.build/en/editor-setup/#eslint)。preset 只在项目有 ESLint config/manifest 意图且 `vscode-eslint-language-server` 可执行时加入；偶然存在的全局 bin 或 `.eslintignore` 都不能单独触发。

ESLint 只拥有同步/configuration、diagnostics、code action/resolve 和 execute command；`format: false`，不参与 completion、hover、navigation 或 formatting。preset 不生成、执行或改写用户 ESLint 配置。

### Biome

Biome 2.3 起支持 Astro 等 HTML super languages，但仍标为实验性：[Language support](https://biomejs.dev/internals/language-support/)。项目配置决定 [`html.experimentalFullSupportEnabled`](https://biomejs.dev/reference/configuration/#htmlexperimentalfullsupportenabled)。

- `< 2.3`：不加入 `.astro`；
- `>= 2.3` 且 full support 缺省/false：只给 diagnostics、actions、commands，移除 formatting；
- `>= 2.3` 且 full support 显式 true：允许 formatting，并高于 Astro formatter；
- preset 永不自动打开实验 flag。

若 ESLint 与 Biome 都被项目明确配置，两份 diagnostics 可以并存；不能按 message/range 模糊去重。

## 5. Contact、路由与性能

每个 Node backend 独立按“最近 package 本地 bin、workspace 本地 bin、PATH”解析；不调用 `npx`，不联网安装。扫描使用有界祖先目录和 context cache。

只有 Astro LS 时返回普通 Eglot contact，但必须保留 `:initializationOptions (:typescript (:tsdk ...))`；有任一 add-on 时才创建 Eglotx facade，并把相同对象转换为 Astro backend 的 `:initialization-options`。

primary 缺失或 SDK 缺失时不能单独启动 add-on。所有 backend 的 `:languages` 必须精确为 `("astro")`。

`completionItem/resolve`、`codeAction/resolve`、commands 和 workspace edits 必须携带 origin 并回送原 backend；尤其 Astro 与 Tailwind 都会产生 completion item，不能按当前可处理 server 猜来源。

diagnostics 按 `(backend, uri)` 保存完整快照，再稳定合并；一个 backend 的空发布只清自己的快照。对外 source 保留 backend 身份。

## 6. 最小 fixture 与 E2E

建立两个隔离项目：`astro_ts_tailwind_eslint` 与 `astro_ts_tailwind_biome`。两者只需 `src/pages/index.astro`、`src/styles.css`、`package.json`、`tsconfig.json` 和对应 lint config。

共同依赖包含 Astro、`@astrojs/language-server`、TypeScript、Tailwind v4、Tailwind Language Server、Prettier 与 `prettier-plugin-astro`；CSS 只用 `@import "tailwindcss"`，不得添加 Tailwind config marker。

ESLint fixture 只配置 ESLint；Biome fixture 只配置 Biome，并显式开启 full support。这样 contact 测试不会因为共享依赖同时触发两个 lint backend。

单元测试应覆盖：mode/language id、项目本地 server 与 SDK 优先、单 server init options 快路径、缺 SDK fallback、结构 server 排除、Tailwind v4、GraphQL config gate、Biome 版本与 full-support formatter ownership。

真 server E2E 应验证：

1. 子进程全部来自 fixture 的 `node_modules/.bin` 且 ready；
2. Astro TypeScript diagnostic 与 ESLint/Biome diagnostic 都到达 Flymake；
3. Astro frontmatter completion 可 resolve；
4. Tailwind class completion 可 resolve，且不再出现 `-32601`；
5. ESLint fixture 的 formatter owner 是 Astro，Biome full fixture 的 owner 是 Biome；
6. contact 中从未出现 TypeScript/HTML/CSS/Vue/Svelte 独立 backend。

以上约束把 Astro preset 保持为“一个结构化主服务器 + 强意图 add-ons”，兼顾开箱即用、正确 URI 所有权与高吞吐下的确定性路由。
