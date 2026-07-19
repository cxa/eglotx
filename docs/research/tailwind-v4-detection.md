# Tailwind CSS v4 项目发现研究

研究日期：2026-07-18。本文以 Tailwind CSS IntelliSense `5067ff7`（0.16.0）和
Neovim nvim-lspconfig `e7ca2c9` 的源码为准。

> **文档状态（2026-07-19）：** 本文是 Tailwind v4 detector 的历史设计依据，
> 不是独立的支持契约。当前 preset 只把精确 core `tailwindcss` dependency、
> project-local language-server executable 或结构匹配的 v3 config 作为意图；它不在
> 同步 contact 路径扫描 CSS。当前行为以 [`docs/presets.md`](../presets.md) 为准。

## 结论

Tailwind v4 的“配置”是 CSS entrypoint，不再是必需的
`tailwind.config.*` 文件。标准安装同时具备两个独立信号：`package.json` 中的
`tailwindcss` 依赖，以及 CSS 中的 `@import "tailwindcss"`。官方的 Vite、PostCSS
和 CLI 安装步骤都要求安装 `tailwindcss`，随后在 CSS 中导入它；v4 也明确主打
zero configuration 和 CSS-first configuration
（[Vite 安装文档](https://tailwindcss.com/docs/installation/using-vite)、
[PostCSS 安装文档](https://tailwindcss.com/docs/installation/using-postcss)、
[CLI 安装文档](https://tailwindcss.com/docs/installation/tailwind-cli)、
[v4 发布说明](https://tailwindcss.com/blog/tailwindcss-v4#simplified-installation)）。

Eglotx 因此不应把 `tailwind.config.*` 当作 v4 的必要 marker。默认的低延迟策略
应以祖先 `package.json` 中**精确的** `tailwindcss` 依赖作为启动 language server
的廉价 coarse gate，然后把 CSS entrypoint、import graph、版本和 document selector
的精确判断交还给 Tailwind language server。`tailwind.config.*` 只保留为 v3
兼容信号。这样不会在 Eglot contact 路径上复制一遍 language server 已经实现的
全工作区 CSS 扫描。

## 第一方 VS Code 扩展实际怎样判断

第一方实现把“是否启动 server”和“server 内有哪些 Tailwind project”分成两层。

### 1. 扩展只做宽松的启动判断

若用户设置了 `tailwindCSS.experimental.configFile`，扩展直接启动 server；否则先
递归查找旧式 config 文件，再查找 CSS/预处理器文件。它逐个读取 CSS，并在遇到
`@config`、任意 `@import`、`@tailwind` 或 `@theme` 时启动。源码自己承认这个 CSS
判断可能误启动，因此把它放在最后并逐文件读取以降低磁盘 I/O
（[`analyze.ts` L11-L75](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/vscode-tailwindcss/src/analyze.ts#L11-L75)、
[`analyze.ts` L78-L92](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/vscode-tailwindcss/src/analyze.ts#L78-L92)）。

这里没有通过 `package.json` 依赖决定扩展是否启动。第一方文档中的常规安装会安装
本地 `tailwindcss` package，server 随后也会尝试做 package/version resolution；但
manifest 不是 VS Code activation scan 的条件，standalone 模式也不需要它。扩展还
监听新增的 config 以及创建/修改的 CSS，在 server 尚未运行时重新执行上述判断
（[`extension.ts` L214-L240](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/vscode-tailwindcss/src/extension.ts#L214-L240)）。

### 2. Language server 做严格的 v4 project discovery

server 在 workspace 内 glob 所有支持的 config 与 CSS 文件、应用
`tailwindCSS.files.exclude`、去重符号链接、读取 CSS，再做版本启发式判断
（[`project-locator.ts` L248-L343](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/project-locator.ts#L248-L343)）。

其信号强度并不相同：

- `@import "tailwindcss"` 或 `@import "tailwindcss/..."` 是明确的 v4 root；
- `@theme`、`@plugin`、`@utility`、`@variant`、`@custom-variant`、`@reference`
  只说明 CSS 与 v4 相关，单独出现时不是 root；
- `@config`、`@apply` 同时可能属于 v3/v4，也不是 root；
- 普通的非 URL `@import` 只是弱信号，可能成为待解析的 root。

这些等级直接编码在
[`version-guesser.ts` L20-L53](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/version-guesser.ts#L20-L53)
和
[`version-guesser.ts` L63-L145](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/version-guesser.ts#L63-L145)。
官方 directive 文档也把 `@import`/`@theme` 定义为 CSS-first 配置，而 `@config`
和 `@plugin` 是加载旧 JS 配置/插件的兼容入口
（[Functions and directives](https://tailwindcss.com/docs/functions-and-directives)）。

server 随后解析 CSS imports、`@source`，构造 import graph，并按“root 标志、是否
直接或间接 import Tailwind”的顺序挑选 graph roots；最终把 root CSS 文件本身作为
v4 config/entrypoint
（[`project-locator.ts` L366-L469](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/project-locator.ts#L366-L469)）。
所以仅在 Eglotx 里 grep 当前 CSS 文件无法等价替代第一方逻辑：真正的 entrypoint
可能间接 import Tailwind，也可能通过共享 CSS 跨 package 连接。

### 3. Package、版本与 standalone CLI

确定 entrypoint 后，server 从该 CSS 所在目录解析
`tailwindcss/package.json` 和 `tailwindcss` 模块，因此会优先加载项目本地版本；若
无法解析，本身还为 CSS config 提供 bundled v4 fallback，主要服务 standalone CLI
项目
（[`project-locator.ts` L472-L529](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/project-locator.ts#L472-L529)）。
这意味着“manifest 有 `tailwindcss`”是标准 npm/pnpm/yarn 项目的强启动信号，却不是
所有合法项目的必要条件；官方 CLI 也支持无需 Node.js 的 standalone executable
（[CLI 安装文档](https://tailwindcss.com/docs/installation/tailwind-cli)）。

不能把任意 `@tailwindcss/*` dependency 都当成等价信号。例如官方文档里的
`@tailwindcss/typography` 是由 CSS `@plugin` 加载的插件，而项目 entrypoint 仍由
`@import "tailwindcss"` 建立
（[Functions and directives — `@plugin`](https://tailwindcss.com/docs/functions-and-directives#plugin-directive)）。
因此仅安装插件包不应使 Eglotx 判定该 package 必然是 Tailwind project。

## Workspace、monorepo 与显式映射

自动发现时，server 从 CSS entrypoint 向上查找最近的 `package.json`，但不会越过
LSP workspace root；找不到时才退回 workspace root
（[`get-package-root.ts` L4-L20](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/util/get-package-root.ts#L4-L20)）。
它的 document selectors 综合 CSS 文件、entrypoint、自动/显式 source、CSS/config
目录与 package root；只有一个 project 时还给它 workspace-root fallback selector
（[`project-locator.ts` L59-L83](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/project-locator.ts#L59-L83)、
[`project-locator.ts` L854-L920](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/project-locator.ts#L854-L920)）。

多 entrypoint/多安装的 monorepo 是第一方明确建议显式配置的情况。
`tailwindCSS.experimental.configFile` 在 v4 中接受一个 CSS entrypoint 字符串，或
“entrypoint -> 适用文件 glob(s)”的对象；server 收到非空映射后直接加载它们，不走
自动 search
（[IntelliSense README L209-L267](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/vscode-tailwindcss/README.md#L209-L267)、
[`tw.ts` L270-L335](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/tw.ts#L270-L335)）。
Tailwind 自身的 `@source` 和 import 的 `source()` 也支持声明 sibling package 或调整
monorepo 的扫描 base
（[Detecting classes in source files](https://tailwindcss.com/docs/detecting-classes-in-source-files#explicitly-registering-sources)）。

社区客户端的折衷也支持“manifest 是廉价 coarse gate”这一方向。nvim-lspconfig
保留 legacy Tailwind config 与 PostCSS root markers，向上查找包含 `tailwindcss`
字段的 `package.json`，并用 `.git` 作为 v4 最后 fallback；同时优先运行 workspace 的
`node_modules/.bin/tailwindcss-language-server`
（[`tailwindcss.lua` L15-L23](https://github.com/neovim/nvim-lspconfig/blob/e7ca2c95ba316a8b846d3f3546d407908c5c4ccb/lsp/tailwindcss.lua#L15-L23)、
[`tailwindcss.lua` L124-L149](https://github.com/neovim/nvim-lspconfig/blob/e7ca2c95ba316a8b846d3f3546d407908c5c4ccb/lsp/tailwindcss.lua#L124-L149)）。
不过它的 helper 只是逐行搜索字段字符串，且源码明确标注该 breadth-first 方法在
multi-project workspace 中有缺陷，因此 Eglotx 不应照抄
（[`util.lua` L51-L101](https://github.com/neovim/nvim-lspconfig/blob/e7ca2c95ba316a8b846d3f3546d407908c5c4ccb/lua/lspconfig/util.lua#L51-L101)）。

当前 Emacs lsp-mode 采用同类但更保守的同步策略：默认从当前文件向上读取最近的
`package.json`，在 `tailwindcss` 版本为 v4+ 或工作区存在 v3 config 时激活
Tailwind client；用户也可通过显式 config 或 skip-check 覆盖判断。它不在 activation
function 中扫描 CSS 内容
（[`lsp-tailwindcss.el` L280-L312](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-tailwindcss.el#L280-L312)）。
这与 Eglot contact 同为同步 Emacs Lisp 路径，因而比 VS Code 的异步扫描（其中
文件枚举带 15 秒 cancellation）更适合作为 Eglotx 默认策略的直接参照
（[`api.ts` L9-L37](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/vscode-tailwindcss/src/api.ts#L9-L37)）。

## 对 Eglotx 的默认策略建议

### 必须调整

1. **不要要求 Tailwind config marker。** 将 v4 默认意图判断定义为：从当前 buffer
   目录到 project root 的 manifest 中，任一正式 dependency section 出现精确键
   `tailwindcss`；`tailwind.config.*` 只作为 v3 fallback。标准 v4 安装均满足这一
   条件（[官方安装路径](https://tailwindcss.com/docs/installation)）。
2. **收窄当前 `@tailwindcss/*` predicate。** 最稳妥的默认值仅认
   `tailwindcss`；若保留集成包 fallback，只 allowlist 第一方构建入口
   `@tailwindcss/vite`、`@tailwindcss/postcss`、`@tailwindcss/cli`，不要让
   `@tailwindcss/typography`、`@tailwindcss/oxide` 等插件/内部包单独触发。官方三种
   标准安装都同时要求 core `tailwindcss`，因此这个收窄不会损失标准 v4 项目
   （[Vite](https://tailwindcss.com/docs/installation/using-vite)、
   [PostCSS](https://tailwindcss.com/docs/installation/using-postcss)、
   [CLI](https://tailwindcss.com/docs/installation/tailwind-cli)）。
3. **启动后信任 language server。** Eglotx 只决定是否把 Tailwind backend 加入
   multiplexer，不自行猜 entrypoint；server 已完成递归 CSS discovery、import graph、
   本地 Tailwind resolution 与 selector 计算
   （[`ProjectLocator.search`](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/project-locator.ts#L59-L107)）。

### 性能边界

- 默认 contact 的同步操作数保持 `O(ancestor depth)`：只读祖先 manifest、在本地
  按需对每级祖先做至多一次非递归 v3 marker listing（每级最多保留 64 个关键字
  候选），并检查 `node_modules/.bin`；TRAMP 项目跳过 marker listing，避免完整目录
  传输。不要递归枚举/读取 workspace CSS。第一方 server 启动后本来就会 glob、
  读取并解析这些 CSS；在 Emacs 同步 contact 路径复制这项工作会造成双份 I/O
  （[`project-locator.ts` L248-L384](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/project-locator.ts#L248-L384)）。
- manifest gate 的预期误报是“monorepo 根安装 Tailwind、当前 package 未使用它”。
  代价是多启动一个 server，而当前 document 可能没有匹配 project，甚至整个
  workspace 得到零 project；相比在每次 Eglot contact 中扫描整个 monorepo，这是
  可控且不会阻塞 UI 的取舍。第一方 VS Code 的 coarse
  CSS gate 本身也明确接受误启动风险
  （[`analyze.ts` L61-L67](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/vscode-tailwindcss/src/analyze.ts#L61-L67)）。
- manifest gate 的预期漏报是 standalone CLI 或非标准依赖布局。不要为消除这个
  少数漏报而默认同步扫全项目；本次实现仍可用项目内 language-server executable
  作为 intent，特殊布局则继续使用手写 core contact。server 本身的 bundled v4
  fallback 已支持 standalone CLI
  （[`project-locator.ts` L503-L519](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/project-locator.ts#L503-L519)）。

### 后续可选扩展（本次不实现）

若有独立需求与 facade 级协议测试，可在 presets 层提供项目 entrypoint 设置。
Tailwind server 请求的
`workspace/configuration` section 已是 `tailwindCSS`，所以该 section 的响应 item
直接使用下面的形状；它既覆盖 standalone CLI，也让大型 monorepo 跳过 server 的
自动 search：

```elisp
(:experimental
 (:configFile "packages/web/src/app.css"))
```

多项目时 `configFile` 应支持“CSS entrypoint -> glob 或 glob 数组”的 JSON object，
与第一方协议一致；这是比新增更多 filename markers 更稳定的扩展点
（[IntelliSense README L220-L237](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/vscode-tailwindcss/README.md#L220-L237)）。

若未来确实要做到 standalone CLI 的全自动发现，应把 CSS indexer 做成 presets 层的
异步、按 project-root 缓存的可选能力：遵守 excludes，先停在精确信号
`@import "tailwindcss[/...]"`，再把结果作为 `experimental.configFile` 传给 server；
不要在每次 contact 中同步执行。精确 import 是最强、可单独判定且带
`explicitImport` 的 v4 root 信号
（[`version-guesser.ts` L63-L71](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/version-guesser.ts#L63-L71)）。
