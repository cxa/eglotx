# 社区多 Language Server 场景与 Eglotx presets 路线图

研究日期：2026-07-18。本文主要核对 Emacs lsp-mode `6bfc593`、
nvim-lspconfig `e7ca2c9`、各 language server 的官方文档和源码。目标不是把“能启动的
server”全部启动，而是找出社区已经反复验证的组合，并为零配置自动发现设定生产级
边界。

> **文档状态（2026-07-19）：** 本文是形成 preset 策略的调研记录，不是当前支持
> 矩阵。已经落地的 recipe、探测限制与验证范围以
> [`docs/presets.md`](../presets.md) 为准；下文标为 B/C 或“建议”的内容仍可能只是候选。

## 结论

社区里的“一个项目启动多个 server”其实分成三类：

1. **同一文档的互补 server**：一个全功能主 server，加一个 lint、框架语义或
   utility server。这才需要 Eglotx facade。
2. **同一仓库的不同语言**：例如 Java + Kotlin、Rust + Cargo TOML、Go + YAML。
   每个 buffer 仍只有一个 server，普通 Eglot contact 已足够，不应为了“项目里有多个
   进程”强制经过 facade。
3. **同一语言的替代实现**：clangd/ccls、nil/nixd、ElixirLS/NextLS/Lexical、
   Intelephense/PHPactor。这些必须择一，全部启动只会重复索引、重复诊断并争夺编辑。

按收益、社区证据和误启动风险，建议这样排期：

| 级别 | 默认组合 | 自动启动前提 |
| --- | --- | --- |
| A：应做成正式 preset | TypeScript 主 server + ESLint/Tailwind/Biome；Python 主 server + Ruff；Go gopls + golangci-lint-langserver；Ruby LSP + Sorbet；TS/JS + GraphQL LS；TS + Angular LS | 当前语言匹配；主 server 可执行；add-on 同时具备明确项目意图和可执行文件 |
| A：扩展到原生 Web buffer | HTML LS + Tailwind；CSS LS + Tailwind/Biome；JSON LS + Biome；GraphQL LS + Biome | 只在对应 server 官方支持的语言中启用；Biome HTML 必须显式开启 |
| B：强 selector 或性能保护后再做 | Terraform LS + TFLint；YAML LS + Ansible LS；PHP 主 server + Psalm；Java JDT LS + Spring Boot LS | 能准确识别当前文档；对每次编辑触发全项目分析或启动很重的工具提供节流、延迟或 opt-in |
| C：只选一个主 server | Rust、C/C++、Java/Kotlin 各自的主 server、Elixir、Lua、Nix；PHP 的多个全功能 server | 不经过 multiplexer；按项目信号和可执行性选一个 |
| C：默认不启用 | Copilot、Semgrep、Trunk、无项目 marker 的 Emmet/拼写服务、归档的 Credo LS | 需要用户授权、明确配置或专门集成 |

这张表意味着 presets 应是一个**策略层**，而不是 server 名称清单：它负责判定项目
意图、解析 executable、选出恰好一个 primary、追加零到多个真正互补的 add-on，并为
重叠方法指定唯一 owner。

## 社区客户端已经形成的模型

lsp-mode 明确把 client 分成 primary 与 `add-on?`：同一 mode 的 primary 按
`priority` 只取一个最高优先级 client，而所有适用 add-on 都会一起启动
（[`lsp--client` 定义](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-mode.el#L1686-L1689)、
[`lsp--find-clients`](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-mode.el#L9115-L9129)）。
Ruff、ESLint、Tailwind、Angular、GraphQL、GolangCI、Ansible、Volar 等都被登记为
add-on；这比按“同一 major-mode 下发现几个 executable”盲目并跑更接近社区实践
（[Ruff client](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-ruff.el#L112-L120)、
[Angular client](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-angular.el#L86-L96)、
[GraphQL client](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-graphql.el#L64-L75)、
[GolangCI client](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-golangci-lint.el#L168-L178)）。

nvim-lspconfig 则把 `cmd`、`filetypes` 和 root markers 都声明在 server 配置中；启用
配置并不等于无条件启动，必须命中文档类型、项目根且命令可执行。其 Node server
配置普遍先找 workspace 内的 `node_modules/.bin`，再退回 PATH，例如
[Tailwind](https://github.com/neovim/nvim-lspconfig/blob/e7ca2c95ba316a8b846d3f3546d407908c5c4ccb/lsp/tailwindcss.lua#L15-L23)、
[CSS LS](https://github.com/neovim/nvim-lspconfig/blob/e7ca2c95ba316a8b846d3f3546d407908c5c4ccb/lsp/cssls.lua#L25-L36)、
[JSON LS](https://github.com/neovim/nvim-lspconfig/blob/e7ca2c95ba316a8b846d3f3546d407908c5c4ccb/lsp/jsonls.lua#L26-L40) 和
[YAML LS](https://github.com/neovim/nvim-lspconfig/blob/e7ca2c95ba316a8b846d3f3546d407908c5c4ccb/lsp/yamlls.lua#L64-L75)。
Eglotx 应吸收这两个原则：**primary/add-on 分型**和**项目本地优先**。

## 推荐纳入的同文档组合

### Web 与框架

- **TypeScript/JavaScript + ESLint + Tailwind + Biome** 是现有 preset 的基线。
  ESLint、Tailwind 和 Biome 都必须以精确 dependency/config 或项目本地 executable
  表达意图；若项目同时明确配置 ESLint 与 Biome，可以都保留 diagnostics/code
  actions，但 formatter 只能选一个。Tailwind v4 的判断沿用单独的
  [CSS-first discovery 研究](./tailwind-v4-detection.md)，不能退回 config filename
  穷举。
- **HTML LS + Tailwind、CSS LS + Tailwind/Biome、JSON LS + Biome** 应成为独立
  contacts，而不是被绑在 TypeScript preset 内。Biome 官方当前稳定支持 JSON/JSONC、
  CSS 和 GraphQL；HTML 仍要求项目显式 opt-in，SCSS 与 YAML 尚未 ready，因此不能仅凭
  `biome.json*` 就向所有 Web 文档附加 Biome
  （[Biome language support](https://biomejs.dev/internals/language-support/)）。
  HTML、CSS、JSON 的通用 server 继续负责结构、schema、hover 和 navigation；Biome
  在项目明确采用时负责 lint/format。
- **TypeScript/JavaScript + GraphQL LS** 是成熟 add-on 场景。lsp-mode 源码特别说明
  JSX/TSX buffer 会同时需要多个 server
  （[client 注释](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-graphql.el#L20-L25)）。
  自动启用必须找到结构化的 GraphQL Config；由 GraphQL Language Service 继续按其中的
  `documents`/include globs 判断实际文档。GraphQL Config 官方支持
  `graphql.config.*`、`.graphqlrc.*` 及
  `package.json` 的 `graphql` 字段，文件名用关键字/结构匹配，不应列完所有扩展名
  （[GraphQL Config usage](https://the-guild.dev/graphql/config/docs/user/usage)）。
- **TypeScript + Angular LS** 也是 lsp-mode 的正式 add-on。强意图是 `angular.json`
  以及本地 `@angular/language-server`/`ngserver`；TS server 负责普通 TypeScript，
  Angular LS 提供 template diagnostics、completion、navigation 和 quick info
  （[Angular Language Service](https://angular.dev/tools/language-service)）。
- **Vue/Volar + TypeScript** 已在后续专项调研后实现为有依赖关系的 facade
  preset，而不是普通 fan-out。当前 Vue Language Tools 仍要求客户端转发私有
  `tsserver/request`；Eglotx 用通用、有界、异步的定向 backend request seam 承载
  bridge，具体 Vue wire policy 保留在 presets 层
  （[Volar client](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-volar.el#L106-L145)、
  [Vue 专项调研](./vue-ecosystem-presets.md)）。Svelte/Astro 仍按各自 mode 选主
  server；Biome 对这些 embedded languages 目前仍是 experimental。

### Python：一个类型/导航主 server + Ruff

Ruff 官方明确把自己的 server 定位为可与 Pyright 等主 server 并用，并给出“主 server
保留 hover、Ruff 负责 lint/format/import organization”的配置
（[Ruff editor setup](https://docs.astral.sh/ruff/editors/setup/)、
[Ruff editors](https://docs.astral.sh/ruff/editors/)）。因此默认模型应为：

- 从 Pyright、basedpyright、pylsp、Jedi、ty 中选择**恰好一个** primary；
- 仅在 `[tool.ruff]`、`ruff.toml`/`.ruff.toml`、精确 dependency 或项目环境里的
  `ruff` executable 命中时追加 `ruff server`；
- primary 拥有 hover/navigation/rename/completion；Ruff 拥有 lint diagnostics、
  source fixes、organize imports，并在项目采用 Ruff formatter 时拥有 formatting。

`pyproject.toml` 本身不是 Ruff 意图，因为它是 Python 的通用 manifest；要解析
`[tool.ruff]` 或 dependency，而不是看到文件就启动。Pyright 的强信号同理是
`pyrightconfig.json`/`[tool.pyright]`
（[Pyright configuration](https://github.com/microsoft/pyright/blob/main/docs/configuration.md)）。
ty 现在是全功能主 server；其官方扩展默认禁用其他 Python server，和别的 server
并用时要求显式关闭 ty 的 language services，因此不能因为 lsp-mode 把它标记为
add-on 就默认再叠一个 primary
（[ty editor integration](https://docs.astral.sh/ty/editors/)、
[ty language server](https://docs.astral.sh/ty/features/language-server/)）。

### Go：gopls + golangci-lint-langserver

这是社区中确实存在且 lsp-mode 默认登记为 add-on 的组合。第三方 server 的官方
README 同时给出 gopls 并跑的 Emacs/Helix 配置，底层调用 `golangci-lint run`
（[golangci-lint-langserver](https://github.com/nametake/golangci-lint-langserver)）。
不过 gopls 已内置 go vet 和可选 Staticcheck analyzers
（[gopls analyzers](https://go.dev/gopls/analyzers)），所以“PATH 里恰好装过”不是足够
意图。建议只在祖先目录发现结构匹配的 GolangCI 配置，且
`golangci-lint-langserver` 与 `golangci-lint` 都可执行时附加；它只贡献 diagnostics，
gopls 独占其他请求。配置显式声明 v2 时使用 v2 参数，否则使用 v1 兼容参数；项目内
无配置的当前工具链可采用 v2 默认值。contact 阶段不能为了猜版本同步启动子进程。

### Terraform：terraform-ls + TFLint

协议能力上这是干净的多 server 组合之一。TFLint 官方支持 `--langserver`，项目配置为
`.tflint.hcl`，并带推荐的 Terraform ruleset
（[TFLint README](https://github.com/terraform-linters/tflint)）。其初始化源码只声明
text synchronization，不声明 completion、hover、definition 或 formatting；结果通过
publish diagnostics 返回
（[`initialize.go`](https://github.com/terraform-linters/tflint/blob/15c65a33b322750f6131e286cd9597896299ba32/langserver/initialize.go#L9-L23)）。
因此 facade 无需解决请求竞争：terraform-ls 是 primary，TFLint 只合并 diagnostics。
但当前实现会在每个 `textDocument/didChange` 上立即重建 runner 并执行完整
`inspect()`，没有 `didSave` 路径或内建 debounce
（[`text_document_did_change.go`](https://github.com/terraform-linters/tflint/blob/15c65a33b322750f6131e286cd9597896299ba32/langserver/text_document_did_change.go#L16-L68)、
[`handler.go`](https://github.com/terraform-linters/tflint/blob/15c65a33b322750f6131e286cd9597896299ba32/langserver/handler.go#L166-L190)）。
这与 Eglotx 的性能优先目标冲突，所以本轮不做默认 preset；将来需要 save-only/debounce
保护或显式 opt-in。即使加入，仍应要求 `.tflint.hcl` 或项目本地 `tflint`，全局安装
不能代表每个 Terraform 项目都采用它。

### Ruby：Ruby LSP + Sorbet

Ruby LSP 官方会在检测到 Sorbet codebase 时自动关闭一部分冲突功能，并明确期望 Sorbet
LSP 提供更准确的类型能力
（[Ruby LSP troubleshooting](https://shopify.github.io/ruby-lsp/troubleshooting.html)）。
Sorbet 的强项目信号是 `sorbet/config`，server 命令是 `srb tc --lsp`
（[Sorbet LSP](https://sorbet.org/docs/lsp)）；lsp-mode 也提供可选 Sorbet add-on
（[Sorbet client](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-sorbet.el#L34-L61)）。
所以在 `sorbet/config` 且 `bin/srb`/`srb` 可用时可自动并跑，由 Sorbet 主导类型
diagnostics、hover/navigation，Ruby LSP 保留其未禁用的 workspace、format 和 Ruby
生态功能。

Ruby executable resolution 不能简单套 Node：优先已经激活的项目 Ruby、`bin/ruby-lsp`
和 `bin/srb`，再看 PATH；Ruby LSP 官方明确提醒 editor 必须获得正确 Ruby/Bundler
环境，并明确不应通过 `bundle exec ruby-lsp` 启动
（[editor setup](https://shopify.github.io/ruby-lsp/editors.html)、
[troubleshooting](https://shopify.github.io/ruby-lsp/troubleshooting.html)）。
Ruby LSP 已自动选择项目声明的 RuboCop/Syntax Tree formatter，不能再把 RuboCop LSP
无条件叠上去造成重复格式化
（[VS Code extension behavior](https://shopify.github.io/ruby-lsp/vscode-extension)）。

## 需要精确 selector 或重型保护的组合

### YAML、Ansible 与 Helm

通用 YAML LS 已提供 schema validation、completion、hover 和 formatting
（[YAML Language Server](https://github.com/redhat-developer/yaml-language-server)）。
Ansible LS 可作为补充，但仓库里有 `ansible.cfg` 并不说明每个 YAML 文件都是 playbook；
lsp-mode 也要求 YAML mode **同时**开启 Ansible minor mode，避免污染普通 YAML
（[Ansible client](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/clients/lsp-ansible.el#L228-L250)）。
Eglotx 只有在准确的 Ansible major/minor mode、language-id 或可靠 document classifier
可用时才应组合 YAML LS + Ansible LS；意图 marker 可用 `ansible.cfg`、`.ansible-lint`
的结构匹配和本地 executable，但 marker 不能替代 document selector。

Helm 不需要外置第二个 YAML LS：helm-ls 本身会启动并组合 yaml-language-server，且以
`Chart.yaml` 为 root。它还特别警告把普通 `yaml-mode` 当 Helm selector 会让所有
非 Helm YAML 误启动
（[helm-ls README](https://github.com/mrjosh/helm-ls)）。因此 Helm 文档使用 helm-ls
单 server，Kubernetes/Docker Compose 等继续由 YAML schemas 解决。

### PHP：全功能 primary + Psalm

Intelephense 与 PHPactor 是替代 primary，绝不能一起启动。Psalm LS 同时提供
diagnostics、definition、hover 和有限 completion，官方 Eglot 示例优先项目的
`vendor/bin/psalm-language-server`；文档还提醒大项目初始化可能需要 240 秒
（[Psalm language server](https://psalm.dev/docs/running_psalm/language_server/)）。
若要把 Psalm 作为静态分析 add-on，必须命中 `psalm.xml`/结构变体或 Composer 的精确
`vimeo/psalm` dependency，优先 `vendor/bin`，并在 facade 中把它限制为 diagnostics
和 Psalm code actions；否则它和 primary 的 hover/completion 会冲突。因为启动成本
高，第一版宜标为 opt-in/延迟启动，而不是只凭全局 Psalm 自动启动。

### Java 与 Spring

JDT LS 已覆盖 Java completion、navigation、refactor、diagnostics，并识别 Maven/Gradle
项目（[VS Code Java](https://github.com/redhat-developer/vscode-java)）。Spring Boot LS
是常见补充，但当前 Spring Tools 已专门优化与 JDT 的通信来避免重复索引/内存，说明
它不是可以假设完全独立的普通 fan-out
（[Spring Tools changelog](https://github.com/spring-projects/spring-tools/wiki/Changelog)）。
在确认 Emacs 客户端所需初始化配置、JDT 通信和能力边界前，先保留成实验 preset；
`pom.xml`/`build.gradle*` 只能说明 JVM 项目，必须进一步解析 Spring Boot dependency。

Kotlin 官方 language server 是独立的 Kotlin primary，并非 JDT add-on，且目前仍标注
Alpha/快速迭代
（[Kotlin LSP](https://github.com/Kotlin/kotlin-lsp)）。Java/Kotlin 混合仓库会启动两个
进程，但分别服务 `.java` 与 `.kt` buffer，不需要同文档 multiplexer。

## 不应制造 multiplexer 的语言

| 生态 | 默认策略 | 原因 |
| --- | --- | --- |
| Rust | rust-analyzer 单 primary；Cargo TOML 另交 Taplo | rust-analyzer 已整合 rustc/clippy diagnostics、rustfmt、completion 和 navigation；Clippy 通过 `check.command` 配置，不是第二个 LSP（[manual](https://rust-analyzer.github.io/manual.html)、[diagnostics](https://rust-analyzer.github.io/book/diagnostics.html)） |
| C/C++ | clangd 或 ccls 二选一 | clangd 自带 compiler/clang-tidy diagnostics、format、completion 和 navigation；两者会重复建立昂贵的 compilation database index（[clangd features](https://clangd.llvm.org/features)） |
| Elixir | ElixirLS、NextLS、Lexical 选一 | 它们是同一文件类型的完整 primary；ElixirLS 已带 build error、Dialyzer、completion 和 formatting，第一次 Dialyzer 可耗时很久（[ElixirLS](https://github.com/elixir-lsp/elixir-ls)） |
| Lua | LuaLS 单 primary | LuaLS 已覆盖 diagnostics、类型检查、completion、navigation、formatting；其他 Lua LS 是替代项（[LuaLS](https://github.com/LuaLS/lua-language-server)、[settings](https://luals.github.io/wiki/settings/)） |
| Nix | nil 或 nixd 二选一 | 两者都是全功能 Nix primary，拥有相同 selector；并跑只会重复 evaluation/diagnostics（[nil](https://github.com/oxalica/nil)、[nixd](https://github.com/nix-community/nixd)） |

Elixir 的旧 Credo language server 曾是 lsp-mode add-on，但项目已归档并说明 NextLS 已
内置 Credo 支持，不能据旧客户端配置新增默认进程
（[credo-language-server](https://github.com/elixir-tools/credo-language-server)）。若使用
ElixirLS，则继续依赖它的 Dialyzer/编译诊断；若选择 NextLS，就让 NextLS 自己集成
Credo。

## 通用 add-on 的社区证据不等于默认授权

lsp-mode 还把 Copilot、Semgrep、Trunk、Emmet、typos-lsp、Fortitude、Apache Camel LS
和 tree-sitter query LS 登记成 add-on。这些可作为后续 catalog，但不应全部成为
零配置默认值：

- Copilot 涉及登录、网络和代码传输；Semgrep/Trunk 可能访问远端规则或执行全仓库扫描，
  必须用户显式授权。
- Emmet 没有可靠的项目采用信号；全局安装 executable 不能代表每个 HTML/JS 项目都想
  要第二套 completion。
- typos-lsp 是跨语言 utility，若未来支持，只在项目的 `typos` TOML 配置或本地
  executable 明确存在时启用，并默认只合并 diagnostics/code actions。
- Fortitude（Fortran lint）、Camel（XML/Java DSL）和 tree-sitter query LS 都应等有
  对应语言 preset、官方项目 marker 与 fixture 后再加入，不能以“lsp-mode 标成
  add-on”为唯一依据。

同理，不自动启用旧 `ruff-lsp` 与 native `ruff server` 两个实现，不自动启动已归档
server，也不把全局可执行的 AI/security server 当作项目意图。

## 能力归属与冲突处理

presets 不能只返回 argv 列表，还应为每个组合声明角色。建议的默认 ownership 为：

| LSP 方法/数据 | 默认策略 |
| --- | --- |
| definition、declaration、references、rename、type hierarchy、semantic tokens、inlay hints | 只发给 primary；除非框架 add-on 有明确的嵌入语言 selector |
| completion、hover、signature help | primary 为基线；Tailwind/Angular/GraphQL 等语义互补 add-on 可合并；保持 backend 优先级与 child 内部顺序，不做跨 backend 语义去重 |
| formatting、range formatting | 永远只选一个 owner；项目采用 Biome/Ruff 时优先相应 formatter，否则 primary |
| code actions | 可 fan-out；只对完全相同的 JSON 值去重并保留 server provenance；`source.fixAll`/organize imports 设唯一 owner |
| diagnostics | 按 backend 保存并合并完整 snapshot，保留每个 backend 的贡献与 source；不做跨 backend 语义去重；server 退出或重启时清除其旧 diagnostics |
| workspace symbols | 默认 primary；重型 analyzer 不参与 |

当 add-on 广告了超出预期的 capabilities 时，facade 仍应按 preset policy 路由，而不是
把 server 的 capability declaration 当作所有权。Python/Ruff 与 PHP/Psalm 都证明
“两个 server 都支持某方法”并不意味着用户希望收到两份结果。

## 零配置发现与 executable resolution

### 判定规则

1. 先由 mode/language-id 确定候选 preset，再做有界祖先查找；不递归扫描 workspace。
2. primary 只要求语言适用和 executable，可按稳定优先级择一；永远不同时选择两个
   全功能 primary。
3. add-on 必须同时满足**项目意图**和**可执行性**。强意图按优先级是：精确 manifest
   dependency/config section、官方结构化 config marker、项目本地 executable。单独的
   `.git`、通用 manifest 或 PATH executable 都不够。
4. marker 名称用关键字/结构 predicate，而不是把所有扩展名穷举进常量。例如识别
   ESLint config 应验证 basename 的 `eslint` + `config`/`.eslintrc` 结构；GraphQL、
   GolangCI、Psalm、Tailwind v3 同理。能解析 manifest 时优先解析字段，而非字符串
   grep。
5. 若只解析出一个 backend，返回普通 Eglot argv，保持 single-server fast path；
   两个以上才构造 Eglotx facade。

### 本地优先顺序

- Node：最近 package root 的 `node_modules/.bin`，向上到 Eglot project root 为止，
  再在已确认 intent 后查 PATH。
- Python：当前已选 venv、项目 `.venv`/环境中的 executable，再查 PATH；contact 阶段
  不运行 Poetry/uv/pip。
- PHP：`vendor/bin` 优先。
- Ruby：项目 binstub 与已激活 Ruby 环境优先，不在 contact 阶段运行 Bundler。
- Go/Terraform：项目本地 wrapper/bin 优先，再查 PATH；lint add-on 仍需 config gate。
- rust-analyzer、clangd、gopls、JDT LS、LuaLS、nil/nixd 等系统分发的 primary 可以使用
  PATH，但只选择一个。

所有 manifest、目录和 executable 结果只在一次 contact resolution 的有界 context
内缓存，包括负结果；不维护需要失效协议的跨进程或跨 session 缓存。TRAMP 默认避免
目录枚举和执行本地 package manager。发现过程不得下载 server、运行构建、解析任意
代码配置或启动全仓库 lint。项目本地 executable 本身是信任边界，应继续服从
Eglot/Emacs 对 local variables 和 project 的信任机制。

## 实现状态与后续顺序

下列 1–3 已由当前 catalog、fixture 和负向 ERT 覆盖；4–5 仍是后续候选，不属于
当前开箱即用支持面。

1. 把 preset 数据模型从“前端 server 列表”提升为 `primary candidates + add-ons +
   intent predicates + capability policy + executable resolvers`。
2. 保持现有 TS/ESLint/Tailwind/Biome 回归测试，新增 Python/Ruff、Go/GolangCI、
   Ruby/Sorbet 的最小 fixtures；每个 fixture同时测试“有强信号启动”和“只有全局
   executable 不启动”。Terraform/TFLint 等有明确性能风险的组合先保留研究结论，
   不用半成品 fixture 暗示默认支持。
3. 增加 HTML、CSS、JSON、GraphQL contacts，让 Tailwind/Biome 不再依赖 TypeScript
   buffer；再加入 Angular 与 embedded GraphQL。
4. 在有准确 document selector 后加入 Ansible；在有 method ownership 和慢启动测试后
   再开放 Psalm/Spring 实验 preset。
5. 为每个生态增加 negative fixtures，证明 alternatives 不会并跑：clangd/ccls、
   nil/nixd、多个 Elixir/PHP/Python primary，以及普通 YAML 不会因同仓库的 Ansible/
   Helm 文件而误启动。

这样可以覆盖社区最常见的多 server 用法，同时保住 Eglotx 的核心哲学：零配置并不
等于猜测用户意图；它意味着在强、廉价、可解释的项目证据下做出确定选择。
