# Svelte 多 LSP preset 调研与实现约束

日期：2026-07-20

> **文档状态（2026-07-20）：** 本文是 Svelte preset 的历史调研与验收设计，
> 不是当前支持契约；其中“建议”“应”以及未进入真实 E2E 的场景不代表已经实现。
> 当前 recipe、探测规则与验证范围以 [`docs/presets.md`](../presets.md) 为准，
> facade 行为以 [`docs/spec.md`](../spec.md) 为准。

## 结论

Svelte 的正确多服务器模型不是“给 `.svelte` 同时挂 TypeScript、HTML、CSS server”，而是：

1. `svelteserver --stdio` 是唯一必需的结构化主服务器；
2. ESLint、Tailwind CSS、Biome、GraphQL 只在项目明确声明对应工具时作为可选后端加入；
3. `typescript-language-server`、HTML Language Server、CSS Language Server **不得**加入 `svelte` 文档；
4. SvelteKit 不需要另一个 LSP，SvelteKit 的组件内类型支持已经在 Svelte Language Server 的 TypeScript plugin 中；
5. `.svelte.js` 和 `.svelte.ts` 是普通 JavaScript/TypeScript 文档，应继续走现有 TypeScript preset，而不是伪装成 `svelte`；
6. completion、diagnostic、formatting 必须按来源和方法精确路由，不能用“所有请求广播给所有服务器”的方式实现。

建议的默认栈如下：

| 后端 | 加入条件 | 在 `.svelte` 中的职责 | 默认格式化 |
| --- | --- | --- | --- |
| Svelte Language Server | `svelteserver` 可执行 | Svelte、HTML、CSS、JS/TS 的结构化语义 | 是 |
| ESLint | 有 ESLint 项目意图且 server 可执行 | lint diagnostics、code actions | 否 |
| Tailwind CSS | 有 Tailwind 项目意图且 server 可执行 | class completion/resolve、hover、Tailwind diagnostics/actions/colors | 否 |
| Biome 2.3+ | 有 Biome 项目意图且 server 可执行 | lint/actions；显式 full support 时也可格式化 | 仅显式 full support |
| GraphQL Language Service | 存在 GraphQL Config 且 server 可执行 | 内嵌 GraphQL completion/navigation/diagnostics | 否 |

当只有 Svelte Language Server 时，contact 应退化为普通 Eglot argv，保留单服务器快路径；至少有一个 add-on 时才创建 Eglotx facade。

## 调研快照

本次核对的关键上游版本如下：

| 项目 | 快照 |
| --- | --- |
| `svelte-language-server` | `0.18.3`，commit `fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b` |
| Svelte | `5.56.6` |
| SvelteKit | `2.70.1`；源码快照 `a91a937985cbcf987c897d59b4a13084b916964e` |
| Tailwind CSS IntelliSense | `0.16.0`，commit `5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a` |
| Biome | `2.5.4`，commit `4bf9b21319df240e2c5ef2e5a9cb2e9582a0e1d1` |
| ESLint for VS Code | commit `aa4667a2410ecda62744dfb9796daf612a5b730f` |
| `eslint-plugin-svelte` | `3.21.0`，commit `28c1234d318fe8980a80ca6bde77252e0ac82544` |
| GraphQL Language Service | commit `277cddad169962a580b0aa71e08f5ea3a29ffd01` |
| `typescript-language-server` | commit `c6a35fbbdd6fb8681ca7e19a09372d2376e108e5` |
| Zed Svelte extension | commit `ca6c2c6c891583a23820d9b23772e116426cc57d` |
| lsp-mode | commit `6bfc593d7b1bc0dd656f09ffce52cc085ebced05` |

## 1. Svelte Language Server 是结构化主服务器

### 命令和 language id

`svelte-language-server` npm 包只发布一个 bin：`svelteserver`，stdio 启动方式是：

```text
svelteserver --stdio
```

不能臆造 `svelte-language-server` 可执行文件作为 fallback。包定义和 server 对 `--stdio` 的处理分别见：

- [`packages/language-server/package.json`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/package.json)
- [`packages/language-server/src/server.ts`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/src/server.ts)

官方 VS Code extension 将 `.svelte` 注册为 language id `svelte`。Eglot contact 因此应至少覆盖：

```elisp
((svelte-ts-mode :language-id "svelte")
 (svelte-mode :language-id "svelte"))
```

依据：[`packages/svelte-vscode/package.json`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/svelte-vscode/package.json)。

### 一个 server 已覆盖四类嵌入语言

上游 server 在同一进程内依次注册：

- `SveltePlugin`
- `HTMLPlugin`
- `CSSPlugin`
- `TypeScriptPlugin`

源码见 [`server.ts`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/src/server.ts)。其 README 也明确列出组件内 Svelte、HTML、CSS/SCSS/LESS、JavaScript/TypeScript 的 diagnostics、completion、hover、navigation、formatting 等功能：[`packages/language-server/README.md`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/README.md)。

由此得到一个硬约束：

> `.svelte` 不应再附加 TypeScript、HTML 或 CSS Language Server。它们不会补足能力，只会重复解析、重复 diagnostics、争抢 formatting，并增加 completion fan-out 和内存占用。

这与 Vue 的架构不同。Svelte Language Server 没有要求客户端桥接一个类似 Vue `tsserver/request` 的私有通道。其 server-to-client 请求是标准 LSP 请求，例如 `workspace/applyEdit`、diagnostic/semantic-token/inlay refresh；可选的 `html/tag` 和 `$/get...` 是客户端主动使用的扩展功能，不是维持基础 diagnostics 或 TypeScript 能力所需的桥。

### Svelte 5 和 SvelteKit

Svelte Language Server 从项目解析 `svelte/compiler`，而不是把某个内置 Svelte 版本永远写死。当前 server 认识 Svelte 5 的 runes、legacy/runes code lens 和迁移命令；因此 fixture 应包含 `$state` 等 Svelte 5 语法，防止错误回退到旧语法假设。相关实现见：

- [`packages/language-server/src/importPackage.ts`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/src/importPackage.ts)
- [`packages/language-server/src/plugins/svelte/SveltePlugin.ts`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/src/plugins/svelte/SveltePlugin.ts)

SvelteKit 没有单独的官方 language server。Svelte Language Server 的 TypeScript 层已经包含 SvelteKit 路由类型、import completion 和虚拟文档转换逻辑；实现可见 [`packages/language-server/src/plugins/typescript/features/CompletionProvider.ts`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/src/plugins/typescript/features/CompletionProvider.ts) 和 [`packages/language-server/src/plugins/typescript/DocumentSnapshot.ts`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/src/plugins/typescript/DocumentSnapshot.ts)。

SvelteKit 的 `svelte-kit sync` 会生成 `.svelte-kit/tsconfig.json` 和路由 `$types`。Eglotx 不应在启动 LSP 时擅自执行该命令；项目正常安装/prepare 流程负责生成，preset 只选择正确 root 和项目本地 server。CLI 行为见 [`documentation/docs/98-reference/52-cli.md`](https://github.com/sveltejs/kit/blob/a91a937985cbcf987c897d59b4a13084b916964e/documentation/docs/98-reference/52-cli.md)。

### `.svelte.ts` / `.svelte.js`

Svelte 5 允许在 `.svelte.js`、`.svelte.ts` 中使用 runes。这些仍是 JavaScript/TypeScript source modules，不是 SFC 的 `svelte` language id。官方说明见 [Svelte runes 文档](https://svelte.dev/docs/svelte/what-are-runes)。

因此：

- `.svelte` → Svelte contact；
- `.svelte.ts` / `.svelte.js` → 现有 TypeScript contact；
- 不要让 `svelteserver` 和 TypeScript LS 同时接管同一 `.svelte` URI。

## 2. TypeScript server 与 `typescript-svelte-plugin`

`typescript-svelte-plugin` 的用途是让用户从普通 TS/JS 文件跨边界 rename、find usages、go to definition 和获得 diagnostics。上游 README 明确说明：Svelte 文件内部的 IntelliSense 由 `svelte-language-server` 提供，而且插件看到 Svelte 文件变更要等保存：[`packages/typescript-plugin/README.md`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/typescript-plugin/README.md)。

这意味着 Svelte preset 本身不需要把 `typescript-language-server` 作为第二个必需 backend。正确分工是：

```text
App.svelte                 -> svelteserver
src/lib/model.ts           -> existing TypeScript preset
TS -> Svelte cross refs    -> optional typescript-svelte-plugin in TS server
```

Zed 的官方社区 extension 采取的也是这个模型：它启动 Svelte Language Server，并把 `typescript-svelte-plugin` 注入 vtsls 的 `globalPlugins`，而不是让 vtsls 打开 `.svelte` 文档。见 [`zed-extensions/svelte/src/svelte.rs`](https://github.com/zed-extensions/svelte/blob/ca6c2c6c891583a23820d9b23772e116426cc57d/src/svelte.rs)。

`typescript-language-server` 的 `initializationOptions.plugins[].languages` 仅用于允许额外 language id 进入 server，并不决定 tsserver plugin 本身的语义。Svelte 场景不应填写 `languages: ["svelte"]`；它会把本应由 Svelte LS 处理的完整 SFC 交给 TypeScript LS。上游配置文档：[`docs/configuration.md`](https://github.com/typescript-language-server/typescript-language-server/blob/c6a35fbbdd6fb8681ca7e19a09372d2376e108e5/docs/configuration.md)。

可将“自动向现有 TS preset 注入项目本地 `typescript-svelte-plugin`”作为后续增强，但它与本次 `.svelte` 多 server contact 解耦，且必须满足：

- 插件可从所选项目/TS server 位置解析；
- 只增强普通 JS/TS 文档；
- 不把 `.svelte` 添加到 TypeScript backend 的 `:languages`；
- 缺失插件不能阻止 Svelte 主服务器启动。

## 3. 初始化参数和 completion 性能

直接使用 server 时，配置放入 `initializationOptions.configuration`；后续 `workspace/didChangeConfiguration` 则直接发送相同配置对象。支持的顶层配置包含 `svelte`、`typescript`、`javascript`、`prettier`、`emmet`、`css`、`less`、`scss`、`html`。依据：[`language-server/README.md`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/README.md)。

生产默认值应尽量小：没有需要覆盖的用户 setting 时，直接省略 `:initialization-options`；有 setting 时才构造 `:configuration` 对象。不要为了“看起来完整”发送空数组或 `null` 冒充 JSON object。

```elisp
;; 没有覆盖项：省略 :initialization-options。
;; 有覆盖项：只发送真实配置，例如：
:initialization-options '(:configuration (:svelte (:plugin (:html (:enable t)))))
```

不建议默认复制 VS Code extension 的：

- `isTrusted`：Eglot 没有等价的 workspace trust 状态；server 缺省本来就是 trusted；
- `dontFilterIncompleteCompletions: true`：server 的实现会因此关闭服务端 incomplete completion 过滤；
- 旧兼容字段 `config`、`typescriptConfig`、`prettierConfig`：新客户端应使用 `configuration`；
- `provideFormatter`：当前 server 不用它作为能力开关。

尤其针对 Corfu，建议**省略** `dontFilterIncompleteCompletions`。当前实现是：

```text
filterIncompleteCompletions = !dontFilterIncompleteCompletions
```

省略后 server 在 incomplete completion 的后续筛选中保留服务端过滤，可减少无须再次传给 Emacs 的候选。实现位置：[`server.ts`](https://github.com/sveltejs/language-tools/blob/fbb12913ceab9dd3d33de531e0fbdbe432bc8e6b/packages/language-server/src/server.ts)。这与 Tailwind 近万候选的吞吐优化方向一致：尽量让能在 server 侧完成的筛选留在 server 侧，不要为了模仿另一个客户端而扩大载荷。

## 4. 可选后端

### 4.1 Tailwind CSS

官方 Tailwind Language Service 对 `svelte` 有一等支持：

- `specialLanguages` 包含 `vue` 和 `svelte`；
- `isSvelteDoc` 精确检查 `languageId === "svelte"`；
- language boundaries 将 Svelte 外层 markup 作为 HTML，并识别 script/style 区域。

依据：

- [`util/languages.ts`](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-service/src/util/languages.ts)
- [`util/html.ts`](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-service/src/util/html.ts)
- [`util/getLanguageBoundaries.ts`](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-service/src/util/getLanguageBoundaries.ts)

命令：

```text
tailwindcss-language-server --stdio
```

Svelte backend 应仅允许 Tailwind 实际拥有的方法：同步、configuration、completion、`completionItem/resolve`、hover、code action、color、document link、diagnostics。不得授予 formatting、rename、references 等结构化方法。

Tailwind v4 不再依赖 `tailwind.config.*` marker。探测顺序应与现有 Tailwind 研究保持一致：

1. `package.json` 中精确依赖 `tailwindcss`；
2. 项目内 CSS 入口由 server 自己通过 `@import "tailwindcss"` 图发现；
3. v3 才用边界感知的 `tailwind` + `config` 文件名关键字作为兼容信号。

不要为 Svelte 默认注入脆弱的 `classRegex`。上游已经识别 `svelte` language id；如 Svelte 特有 `class:` directive 仍存在个别 completion 缺口，应以 server 版本升级或单独的、可测配置解决，而不是正则解析整份 SFC。

### 4.2 ESLint

Microsoft ESLint extension 的默认 `eslint.probe` 包含 `svelte`，server 也将 `svelte` 映射为对应的 ESLint plugin language。来源：

- [`vscode-eslint/package.json`](https://github.com/microsoft/vscode-eslint/blob/aa4667a2410ecda62744dfb9796daf612a5b730f/package.json)
- [`server/src/eslint.ts`](https://github.com/microsoft/vscode-eslint/blob/aa4667a2410ecda62744dfb9796daf612a5b730f/server/src/eslint.ts)

Svelte 官方 ESLint plugin 是 `eslint-plugin-svelte`，使用 `svelte-eslint-parser`。flat config 推荐入口是 `svelte.configs.recommended`；TypeScript 配置还需要 `typescript-eslint` parser 和 `extraFileExtensions: [".svelte"]`。依据：[`eslint-plugin-svelte/README.md`](https://github.com/sveltejs/eslint-plugin-svelte/blob/28c1234d318fe8980a80ca6bde77252e0ac82544/README.md)。

Eglotx 可继续使用项目已有的 standalone contact：

```text
vscode-eslint-language-server --stdio
```

但应注意：这个 bin 通常来自 `vscode-langservers-extracted`，不是 Microsoft extension package 承诺的 npm bin 名称；preset 只做可执行文件解析，不应声称由 Microsoft 自动安装。

加入条件必须同时包含“server 可执行”和强 ESLint 意图，例如：

- 精确 ESLint dependency；
- `eslintConfig`；
- 边界感知的 `eslint` config marker。

仅仅因为某个共享 `node_modules/.bin` 中偶然存在 ESLint server，不足以证明项目配置了 Svelte ESLint parser。Eglotx 也不应生成或改写用户的 ESLint config。

推荐 settings 和方法边界：

- `validate: "on"`；
- `format: false`；
- working directory 使用项目 root/auto；
- 仅同步、configuration、pull diagnostics、code action/resolve、execute command；
- 不接收 completion、hover、navigation、formatting。

### 4.3 Biome

Biome 自 2.3 起能直接打开 Vue、Svelte、Astro 文件，但官方仍将这些 HTML super languages 标为实验性。`html.experimentalFullSupportEnabled` 的语义非常关键：

- `false`/缺省：只提取 JS/TS 区域分析，忽略其余内容；官方提示可能产生需规避的 false positives；
- `true`：对 Svelte 的外层语法和嵌入语言进行一致的 parsing、formatting、linting。

官方依据：

- [Biome Language support](https://biomejs.dev/internals/language-support/)
- [Biome Configuration：`html.experimentalFullSupportEnabled`](https://biomejs.dev/reference/configuration/#htmlexperimentalfullsupportenabled)
- [`configuration_schema.json`](https://github.com/biomejs/biome/blob/4bf9b21319df240e2c5ef2e5a9cb2e9582a0e1d1/packages/%40biomejs/biome/configuration_schema.json)

命令：

```text
biome lsp-proxy
```

建议策略：

| 配置 | Biome 方法 | priority/格式化策略 |
| --- | --- | --- |
| 版本 `< 2.3` | 不加入 `.svelte` | 无 |
| `>= 2.3`，full support 未显式启用 | diagnostics、code actions、execute command | 低于 Svelte；移除 formatting/rangeFormatting |
| `>= 2.3`，full support 显式为 `true` | 上述方法 + formatting/rangeFormatting | 高于 Svelte，Biome 成为唯一 formatter |

不要由 preset 自动把实验开关设成 `true`。这是会改变格式和 lint 语义的项目选择，只能读取项目已有的 `biome.json`/`biome.jsonc`。读取时要支持 JSONC，但必须有大小上限、解析失败安全回退和 context cache。

Biome 没有必要参与 Svelte completion、hover 或 navigation。即使 server 广告了更宽能力，multiplexer 也应按 add-on 职责收窄。

若项目明确同时配置 ESLint 和 Biome，两者 diagnostics 可以并存。preset 不应猜测用户想停掉其中一个，也不能按 message 文本模糊去重。

### 4.4 GraphQL

GraphQL Language Service 官方实现明确支持 `.svelte`：

- 默认 source extensions 包含 `.svelte`；
- 默认 tag names 包含 `graphql`、`gql`、`graphqls`；
- 专用 Svelte parser 通过 `svelte2tsx` 转换并用 source map 把结果映射回原文件；
- 上游测试覆盖普通和 TypeScript `<script>`、空 script、无 script。

依据：

- [`constants.ts`](https://github.com/graphql/graphiql/blob/277cddad169962a580b0aa71e08f5ea3a29ffd01/packages/graphql-language-service-server/src/constants.ts)
- [`parsers/svelte.ts`](https://github.com/graphql/graphiql/blob/277cddad169962a580b0aa71e08f5ea3a29ffd01/packages/graphql-language-service-server/src/parsers/svelte.ts)
- [`findGraphQLTags.test.ts`](https://github.com/graphql/graphiql/blob/277cddad169962a580b0aa71e08f5ea3a29ffd01/packages/graphql-language-service-server/src/__tests__/findGraphQLTags.test.ts)

命令沿用现有 GraphQL preset：

```text
graphql-lsp server -m stream --configDir ROOT
```

GraphQL 不能因为项目有 `graphql` npm dependency 就自动加入；必须存在结构化 GraphQL Config。最终 documents/include 是否覆盖 `.svelte` 由 GraphQL server 依据 config 判定。方法继续使用现有 `eglotx-presets--graphql-only`，明确排除 formatting。

### 4.5 暂不默认加入的 server

- HTML/CSS/SCSS server：Svelte LS 已覆盖，属于重复后端；
- TypeScript LS：只服务普通 JS/TS，不能打开完整 SFC；
- Prettier server：Svelte LS 本身集成 Svelte formatting，Biome full support 又可能成为显式 formatter；再加入只会产生第三个 owner；
- Stylelint/UnoCSS 等：只有在上游 server 对 `svelte` URI、嵌入区域映射和能力边界有可验证支持，并且项目有强意图时，才适合后续单独加入。不能仅因工具流行就广播整份 `.svelte`。

## 5. 项目探测和本地 server 优先级

### Svelte 项目意图

打开 `.svelte` buffer 本身已经是最强的文档意图。用于 root/context 的项目信号按强度排序：

1. 当前文档扩展名 `.svelte` / language id `svelte`；
2. `package.json` 中精确依赖键 `svelte`、`@sveltejs/kit` 或 `@sveltejs/vite-plugin-svelte`；
3. 文件名分段后同时出现相邻/有序的 `svelte` 和 `config` 关键字；
4. 项目本地 `node_modules/.bin/svelteserver` 作为补强信号。

config marker 不应穷举 `.js`、`.cjs`、`.mjs`、`.ts` 等完整文件名。建议沿用统一的文件名 segment 逻辑：小写 basename，以 `[._-]+` 分段，匹配 `svelte` 与 `config`，再对可接受的配置扩展做结构约束。这样可以接受未来变体而不误把 `not-svelteish` 当成项目。

不应单独作为 Svelte 意图的信号：

- `vite` dependency；
- `vite.config.*`；
- `.svelte-kit` 生成目录；
- 文件名中任意位置出现 `svelte` 子串；
- 递归搜索整个仓库得到的某个远处 `.svelte` 文件。

Vite 是通用构建工具，`.svelte-kit` 是生成物。探测必须是有界的祖先目录扫描，复用 preset engine 的候选数量上限、manifest cache、directory cache 和 symlink/remote-file 安全策略，不能执行 package manager 或用户配置文件。

### 可执行文件选择

每个 backend 独立解析，顺序为：

1. 当前 package 最近祖先的 `node_modules/.bin/PROGRAM`；
2. workspace root 的 `node_modules/.bin/PROGRAM`；
3. `exec-path` / PATH。

不使用 `npx --yes`、`npm exec` 或网络自动下载。Svelte server 对项目 Svelte compiler、TypeScript、Prettier 和 config loader 的版本匹配较敏感，本地优先不仅是便利性，也是正确性要求。

monorepo 中必须“最近 package 优先”，避免一个 workspace sibling 的 Svelte/ESLint/Biome server 污染另一个 package。解析结果进入 context cache，contact 构建阶段不反复 `file-exists-p`/`executable-find`。

## 6. 方法所有权

推荐的静态 allowlist 如下；实际 dispatch 还要与 server initialize 后广告的 capabilities 取交集。

| LSP 方法族 | Svelte | Tailwind | ESLint | Biome partial | Biome full | GraphQL |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| didOpen/change/save/close、configuration | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| completion | ✓ | ✓ |  |  |  | ✓ |
| completion resolve | ✓ | ✓ |  |  |  | ✓ |
| hover | ✓ | ✓ |  |  |  | ✓ |
| signature help | ✓ |  |  |  |  |  |
| definition/type definition/implementation | ✓ |  |  |  |  | definition |
| references/rename | ✓ |  |  |  |  | references |
| symbols/semantic tokens/inlay/folding/hierarchy | ✓ |  |  |  |  | symbols |
| code action/resolve | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| execute command | ✓ |  | ✓ | ✓ | ✓ |  |
| colors/document links | ✓ | ✓ |  |  |  |  |
| diagnostics | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| formatting/range formatting | ✓ |  |  |  | ✓ |  |

三个关键规则：

1. `completionItem/resolve` 必须按 completion item 的来源精确回送。Svelte 和 Tailwind 都支持 resolve；丢失来源会重现 `No Eglotx backend handles :completionItem/resolve` 或把 item 送错 server。
2. `codeAction/resolve`、commands 和 workspace edits 同样保留来源；不能只给 completion 做 origin tagging。
3. formatting 在一次 contact 中只能有一个高优先级 owner。默认 Svelte；Biome full support 显式开启时改为 Biome。不要合并两份 `TextEdit[]`。

Svelte Language Server 当前同时支持 push diagnostics 和 LSP pull diagnostics 的实现路径。Eglotx core 应将它视为通用 LSP 机制处理，而不是在 Svelte preset 中写协议特例。

## 7. Diagnostics 合并

多 server diagnostics 的正确模型是“按 backend、URI 保存完整快照”：

```text
(backend, uri) -> latest diagnostics snapshot
facade(uri)     -> stable concatenation of live backend snapshots
```

要求：

- push `textDocument/publishDiagnostics` 到达时只替换该 backend 的 snapshot；
- pull `textDocument/diagnostic` 的 full/unchanged result 分别处理；
- backend clear (`diagnostics: []`) 只清自己的结果；
- backend restart/shutdown 要清除其所有 snapshot；
- 对外 `source` 应带 backend 身份，避免 `svelte`、`eslint`、`biome` 的同名 rule 无法区分；
- 不按 range/message 模糊去重，不覆盖不同工具有意报告的同一问题；
- stable backend order，避免 Flymake 列表每次刷新乱序。

避免重复 diagnostics 的主要手段不是事后猜测，而是前置的 language gate、project-intent gate 和能力 allowlist。

## 8. 最小 fixture 与 E2E

建议提供两个相互独立的最小项目；不要为了“像真实应用”引入路由、构建产物或大量依赖。

### `test/projects/svelte_ts_tailwind_eslint`

最低依赖：

```json
{
  "dependencies": {
    "svelte": "^5",
    "tailwindcss": "^4"
  },
  "devDependencies": {
    "svelte-language-server": "^0.18.3",
    "typescript": "^6.0.2",
    "@tailwindcss/language-server": "^0.16.0",
    "eslint": "^10",
    "eslint-plugin-svelte": "^3.21.0",
    "typescript-eslint": "^8",
    "vscode-langservers-extracted": "*"
  }
}
```

必要文件：

- `src/App.svelte`：`<script lang="ts">`、Svelte 5 `$state`、一个 TS type error、一个 ESLint 可报告问题、一个 Tailwind class completion 位置；
- `src/styles.css`：只有 `@import "tailwindcss";`；
- `eslint.config.js`：`eslint-plugin-svelte` recommended + TypeScript parser + `.svelte` extra extension；
- `tsconfig.json`：严格模式并包含 `src/**/*.svelte`；
- 可选最小 `svelte.config.js`，但 Tailwind v4 测试不得依赖 Tailwind config marker。

### `test/projects/svelte_ts_tailwind_biome`

将 ESLint 依赖/config 换成 `@biomejs/biome >= 2.3` 和：

```jsonc
{
  "html": {
    "experimentalFullSupportEnabled": true
  },
  "linter": {
    "enabled": true
  }
}
```

另加一个 unit test，把 flag 改为 false/缺省，验证 Biome 仍可作为 lint add-on，但 format 方法被移除且 priority 低于 Svelte。

### Contact 单元测试

至少覆盖：

- `svelte-mode`、`svelte-ts-mode` 注册为 language id `svelte`；
- 只有 `svelteserver` 时返回普通 argv；
- 多后端顺序稳定，所有 backend 的 `:languages` 都精确为 `("svelte")`；
- `.svelte` 栈绝不出现 `typescript`、`html`、`css` backend；
- 最近 package 本地 bin 优先于 workspace bin，workspace bin 优先于 PATH；
- primary 缺失时走既有 Eglot fallback，而不是启动一堆 add-on；
- 全局 add-on 必须有项目意图；共享 node bin 中偶然存在可执行文件不能单独触发；
- Svelte config 关键字变体能识别，`vite.config.*` 和随机子串不能识别；
- Tailwind v4 只有 dependency + CSS import、没有 config marker 仍加入；
- Biome 2.2 不加入，2.3 partial 不格式化，2.3 full 可格式化；
- GraphQL 仅有 dependency 不加入，有 GraphQL Config 时加入；
- disabled backend 逐一生效且不影响 primary。

### 真 server E2E

E2E 不只验证进程能启动，应验证 facade 的协议行为：

1. 打开 `App.svelte`，等待所有预期 backend ready，并断言命令都来自 fixture 本地 `node_modules/.bin`；
2. 断言 backend names 为 `svelte + eslint/biome + tailwindcss`，按 config 可再有 `graphql`，且不存在 `typescript`；
3. 请求 Svelte hover/completion，验证 Svelte 5 rune 不产生旧语法错误；
4. 在 class attribute 请求 Tailwind completion，找到已知候选后再发 resolve，验证 origin routing 且没有 `-32601`；
5. 等待 Flymake，分别看到 Svelte TypeScript diagnostic 和 ESLint/Biome diagnostic，source 带 backend 身份；
6. ESLint fixture 的 formatting owner 是 Svelte；Biome full fixture 的 owner 是 Biome；
7. 保存、修改、再次诊断，验证某个 backend 清空 diagnostics 不会清掉其他 backend；
8. 用有界 timeout，结束后显式 shutdown，检查无残留进程。

GraphQL E2E 可在同一 fixture 只增加最小 `.graphqlrc.*`、schema 和一个 `gql` tagged template，验证 completion/definition 和 source mapping；不应让所有 Svelte fixture 都承担 GraphQL 安装成本。

## 9. 与社区客户端实现的关系

lsp-mode 的 Svelte client 同样只把 `svelteserver` 当作 Svelte 主命令，并提供 Svelte server 的配置面；可作为 Emacs 命令、settings key 和 mode 注册的交叉验证：[`clients/lsp-svelte.el`](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-svelte.el)。

但 Eglotx 不能照抄 lsp-mode 的每个独立 client，然后把它们无条件同时启动。Eglotx preset 还必须负责：

- 项目意图检测；
- 项目本地 executable 优先；
- add-on 方法收窄；
- completion/code action origin routing；
- diagnostics snapshot 合并；
- 唯一 formatter；
- 单 server Eglot 快路径。

Zed 的 Svelte extension 对 Svelte server + TypeScript plugin 的拆分是重要佐证，但其 extension 会自行安装 npm package，并为自己的 completion pipeline 设置不同选项。Eglotx 的哲学是使用用户项目或 PATH 中已有的 server，不应复制自动下载行为，也不应复制会扩大 Corfu completion 载荷的客户端专属设置。

## 10. 实现验收标准

满足以下条件才算生产级支持，而不只是“能打开 `.svelte`”：

- 使用真实 bin 名 `svelteserver --stdio`，项目本地优先；
- Svelte 主服务器缺失时安全 fallback；
- 单服务器不引入 multiplexer 开销；
- `.svelte` 不启动 TypeScript/HTML/CSS 重复 server；
- Svelte 5 和 SvelteKit 项目无需用户手写 Eglot contact；
- ESLint、Tailwind、Biome、GraphQL 只在强意图下加入；
- Tailwind v4 不依赖 config marker；
- Biome full-support flag 决定其是否能取得 formatting；
- resolve、code action、command、workspace edit 都保留 backend origin；
- push/pull diagnostics 均按 backend snapshot 合并；
- Corfu completion 路径没有不必要的全量 fan-out 和客户端重复过滤；
- unit tests 覆盖 detector/resolver/policy，真 server E2E 覆盖 completion resolve、diagnostics 和 formatter ownership。

以上边界让 Svelte preset 与 Eglotx core 保持分离：preset 只表达“哪些 server、何时加入、允许哪些方法、优先级如何”，协议生命周期、来源路由、diagnostics 聚合和吞吐控制继续由通用 core 负责。
