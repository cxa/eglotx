# 巨量 LSP 结果的吞吐设计：Completion 与 Diagnostics

研究日期：2026-07-19。

> **文档状态（2026-07-19）：** 本文同时保留优化前审计和后续路线图。文中的本仓库
> 基线与实测来自 0.1.0 squash 前的工作快照；旧短 hash 没有进入发布历史，因此不再
> 作为可解析的源码引用。当前保证以 [`docs/spec.md`](../spec.md) 为准，当前 benchmark
> 实际覆盖以 [`README.md`](../../README.md) 和 benchmark 源码为准。

本文只使用一手来源：LSP 3.17 规范、Tailwind CSS IntelliSense、Zed、VS Code、
Neovim、lsp-mode、rust-analyzer 以及本仓库源码。调研固定版本如下：

| 项目 | 固定版本 |
| --- | --- |
| Tailwind CSS IntelliSense | [`5067ff7`](https://github.com/tailwindlabs/tailwindcss-intellisense/tree/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a)（0.16.0） |
| Zed | [`f032f4d`](https://github.com/zed-industries/zed/tree/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4) |
| VS Code | [`f4e18ff`](https://github.com/microsoft/vscode/tree/f4e18ff9f2d0f5dcea01d00ec73bed52be18f488) |
| Neovim | [`ad3720b`](https://github.com/neovim/neovim/tree/ad3720b882d69e361741597f2d17906dbf0a132c) |
| lsp-mode | [`6bfc593`](https://github.com/emacs-lsp/lsp-mode/tree/6bfc593d7b1bc0dd656f09ffce52cc085ebced05) |
| rust-analyzer | [`cac0779`](https://github.com/rust-lang/rust-analyzer/tree/cac0779549328e4bd4b808000c03307f1721f869) |
| GNU Emacs / Eglot | [`0f086c3`](https://github.com/emacs-mirror/emacs/tree/0f086c307c12b74aeedfba07cfe5b57ef2f99808) |
| 本仓库优化前审计基线 | 0.1.0 squash 前工作快照（未发布为 Git ref） |
| 本仓库实测版本 | 0.1.0 squash 前工作快照（未发布为 Git ref） |

## 结论

Tailwind 的万条 completion 不是假设。它的官方集成测试明确断言一个普通 class
completion 返回 **11,509** 项
（[`custom-languages.test.js` L34-L55](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/tests/env/custom-languages.test.js#L34-L55)）。
两个类似 backend 已经超过两万项；multiplexer 必须把 `O(N)` 当作正常输入，而不是
异常保护路径。

一手实现给出的共同答案不是“在代理层截前 1,000 项”，而是：

1. 保留 `CompletionList.itemDefaults` 的批次结构，避免把共享字段复制到每一项；
2. backend identity 与共享 defaults 按批次存储，只有真正不同的 item data 才建
   per-item override；
3. 新请求立即取消旧请求，在昂贵转换前丢弃 stale result；
4. 初始 item 保持轻量，只对选中或可见项做 `completionItem/resolve`；
5. 缓存、增量过滤、top-K 和虚拟列表属于 editor/UI 层，不属于通用 LSP facade；
6. diagnostics 按 backend snapshot 存储，合并 publication，并把存储与显示分离。

### 本轮交付边界与实测

本轮生产改动聚焦用户实际遇到的 completion 巨量响应；diagnostics 的 publication
batch/index 改造保留为独立后续，因为它有不同的 push/pull/streaming snapshot 生命周期，
不应为追求一份“大而全”的补丁再次膨胀 core。下文 P4 与三路 10k diagnostics 是后续
路线图，不是本轮 completion 优化的验收门槛。

当前实现已把 completion ownership 变为原子 response batch：每个 backend segment
共享 default data 与 common handle，显式 item data 才惰性创建 override vector/index
handle；合并直接写预分配 vector，每项最多浅复制一次。相同 Emacs 31 构建上的本轮实测：

- 默认 completion benchmark 从基线 **4.179 μs/item** 降到约
  **0.659 μs/item**；
- 11,509 项 Tailwind shared-default fixture 中位数约 **1.198 ms/response**，
  约 **9.61M items/s**，合并阶段 token 字符串分配约 **0.02/item**；
- ESLint 与 Biome 真实 fixture 均由 facade 返回 **23,632** 项，并通过 Tailwind
  首部、常用和尾部候选的 resolve；
- 真实 Tailwind → Eglot CAPF → Orderless → Corfu 热路径三次为
  **59.61 / 59.08 / 58.71 ms**，中位 **59.08 ms**，并通过 23,632 个 facade
  候选、选中项 resolve，以及四轮替换 CAPF 加 GC 后旧候选仍能 resolve 的检查。

这些是同机热路径数字，不是跨机器硬阈值。完整命令由默认 `make benchmark` 运行，
协议正确性由 fake-process facade ERT 与真实 preset E2E 覆盖；Corfu 路径可用
`make test-corfu-e2e` 复现，其 gate 可按同机基线覆盖或关闭。

对 Eglotx 最重要的第一步不是多线程，而是去掉当前 completion 热路径的分配放大：
`itemDefaults` materialize、两次 item copy、每项一个 owner struct/token/hash/ring node、
vector/list 往返以及无条件 command copy。完成批次 ownership 与单次遍历后，再用 profile
决定是否需要 cooperative chunking。

不能用“调大 limit”替代架构修正。当前
`eglotx-document-owner-limit` 是 8,192，而官方 Tailwind fixture 是 11,509 项；逐项
owner 会在同一响应仍在构造时淘汰最早的 3,317 个 owner，使这些 completion 的 resolve
路由在客户端看到结果前就已失效。下文“completion 热路径审计”保留该发布前实现的
函数级分析；这同时是性能问题和正确性问题。

## 规范边界：为什么 facade 不能随意截断

LSP 3.17 要求 client 对收到的 completion 做过滤与排序；完整列表在用户继续输入时应由
client 本地过滤，`isIncomplete` 才表示 server 希望 client 重新请求。昂贵的 detail、
documentation 等字段应通过 resolve 延迟填充
（[Completion request](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_completion)）。

这带来三个边界：

- generic facade 不知道用户后续 query，也不知道不同 server 的 `sortText`/relevance
  语义。截取“前 N 个”可能永久隐藏正确候选；伪造 `isIncomplete` 也会改变 server 的
  重查契约。
- 规范虽然让 CompletionParams 继承 `PartialResultParams`，却没有为 completion 声明
  可合并的 partial-result payload。因此不能依赖一个跨 client 可移植的“边到边流式
  completion”协议来掩盖单次巨量响应。
- `$/cancelRequest` 是正确的 stale-work 边界；被取消的 request 仍需结束其 JSON-RPC
  lifecycle，但 facade 可以在知道结果已失效后跳过 ownership/tag/merge
  （[Cancellation Support](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#cancelRequest)）。

所以 Eglotx core 的默认规则应是：不 dedup、不 hard cap、稳定按 backend priority
拼接，并传播任一 child 的 `isIncomplete`。若用户确实需要结果上限，它应是 server
自身的 relevance-aware 配置，或 Eglot/Corfu 过滤后的 UI top-K。

## Tailwind 自己为巨量列表做了什么

Tailwind language service 有一个明确的快路径：当 client 同时支持
`completionList.itemDefaults.data` 与 `editRange` 时，它不 map items，直接复用原
`completionList.items`，把共享 data/range 放到 `itemDefaults`；缺少任一 capability
才逐条展开
（[`withDefaults` L1642-L1677](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-service/src/completionProvider.ts#L1642-L1677)）。

共享 `data` 不能丢。Tailwind 的 resolve handler 用 `item.data._projectKey` 找回产生该
item 的 project，然后交给对应 project resolve
（[`tw.ts` L1084-L1092](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/tw.ts#L1084-L1092)），
且公开 `resolveProvider: true`
（[`tw.ts` L1151-L1155](https://github.com/tailwindlabs/tailwindcss-intellisense/blob/5067ff7ec0b4b8bb5c3325a69c1f3410eb5b350a/packages/tailwindcss-language-server/src/tw.ts#L1151-L1155)）。

这是 Eglotx 的最佳 common case：一万个 items 可以共享一个 backend owner、一个
generation、一个 raw Tailwind data object 和一个 facade token。只有显式覆盖
`:data` 的 items 才需要 override。

### Eglot 的现实限制

当前 Eglot 31 的 client capabilities 没有广告
`textDocument.completion.completionList.itemDefaults`，completion adapter 也只取
response 的 `:items`，不读取 `:itemDefaults`
（[Eglot capabilities L1107-L1123](https://github.com/emacs-mirror/emacs/blob/0f086c307c12b74aeedfba07cfe5b57ef2f99808/lisp/progmodes/eglot.el#L1107-L1123)、
[Eglot completion L3922-L3952](https://github.com/emacs-mirror/emacs/blob/0f086c307c12b74aeedfba07cfe5b57ef2f99808/lisp/progmodes/eglot.el#L3922-L3952)）。
因此 Eglotx **不能把 child defaults 原样透传给 Eglot**。

但 facade 可以在 child leg 上广告自己能够消费 `data`/`editRange` defaults，从而减少
Tailwind 子进程生成、stdout 字节数和 Emacs JSON decode 体积；随后只做必要的
compatibility projection：

- 共享 `data` 不恢复为 Tailwind object，而是让所有 common-case items 指向同一个
  facade batch token；resolve 时再恢复一次 raw default data。
- Eglot 的插入路径已经消费 resolve 结果中的 `textEdit`。独立 adapter 只需在公开的
  client capability generic 上声明这一点；facade 就能把 `editRange` 保留在 batch，
  仅为选中项 materialize，并让无 child resolve 的 item 走本地 identity resolve。
- 是否让 child 同时使用 `data` 与 `editRange` defaults，还是只让它共享 `data`、由
  Tailwind 侧展开 edit，必须以 benchmark 决定。前者 child wire 最小，后者把一部分
  CPU 从 Emacs Lisp 移回 Node，但会显著增加 JSON 与 pipe 成本。

若未来上游 Eglot 原生支持 itemDefaults，Eglotx 可以删除这层 capability adapter；
当前实现同样不 advice 或重写 Eglot completion UI。

## Zed：可借鉴的机制与不可照搬之处

### 传输与取消

Zed 的 reader 到 dispatcher 之间是容量 128 的有界队列；队列满时停止读 child
stdout，让 OS pipe 反压，而不是无界堆积 decoded messages
（[`input_handler.rs` L22-L27](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/lsp/src/input_handler.rs#L22-L27)）。
response envelope 先把 result 保留为 `RawValue`，typed deserialization 在 background
executor 中执行
（[`lsp.rs` L254-L263](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/lsp/src/lsp.rs#L254-L263)、
[`lsp.rs` L1457-L1481](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/lsp/src/lsp.rs#L1457-L1481)）。
request future 被 drop 或 timeout 时会发送 cancel，并从 handler table 删除 continuation
（[`lsp.rs` L1500-L1539](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/lsp/src/lsp.rs#L1500-L1539)）。

Emacs 的 jsonrpc 已经完成 JSON decode 后才把 result 交给 Eglotx，因而不能在不替换
上游 transport 的情况下照搬 RawValue/background parse。直接可用的原则是：request
一旦 stale/cancelled，就在进入 item loop 前 short-circuit；循环若要分块，每个边界
再次检查 request generation，ownership 必须先 staging、成功后原子 commit。

### 批次 defaults 与 backend identity

Zed 广告全部标准 itemDefaults，包括 `data`
（[`lsp.rs` L875-L918](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/lsp/src/lsp.rs#L875-L918)）。
每个 completion 保存 `server_id`、boxed raw LSP item 和 `Arc` 共享 defaults；只有调用者
要求应用 defaults 时才 clone，其他时候返回 borrowed item
（[`project.rs` L583-L595](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/project/src/project.rs#L583-L595)、
[`project.rs` L617-L682](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/project/src/project.rs#L617-L682)）。

这验证了 Eglotx 应把 backend/generation/default data 放在 batch record，而不是复制进
一万个 owner records。区别在于 Zed 内部对象可以直接带 `server_id`；Eglotx 必须在
送给 Eglot 的 LSP item `:data` 中留下 opaque facade handle，以便随后 resolve 回源。

Zed 也不是零成本模型。它收到 response 后仍逐项校验/解析 edit、调用 adapter、构造
CoreCompletion，只是 defaults 由 `Arc` 共享
（[`lsp_command.rs` L2578-L2766](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/project/src/lsp_command.rs#L2578-L2766)）。
因此“Zed 很快”不能推出 Eglotx 应照抄其全部 eager conversion；Rust 的 background
executor、typed vectors 与 Emacs 主线程 plist allocation 成本不同。

### 多 server、过滤与 resolve

Zed 并发请求所有 capable servers，给每个 server 独立 timeout，等待后返回各自的
CompletionResponse；这里没有跨 server hard cap 或 dedup
（[`lsp_store.rs` L6799-L6882](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/project/src/lsp_store.rs#L6799-L6882)）。

它的 1,000 上限位于 query-aware fuzzy matcher，不在 LSP ingestion：非空 query
才并行匹配并保留 top 1,000；空 query 直接返回全部 candidates，甚至绕过该上限
（[`code_context_menus.rs` L1297-L1337](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/editor/src/code_context_menus.rs#L1297-L1337)、
[`strings.rs` L117-L199](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/fuzzy/src/strings.rs#L117-L199)）。
resolve 也只覆盖约 12 个可见项及前后各 4 项，selected item 始终优先
（[`code_context_menus.rs` L626-L711](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/editor/src/code_context_menus.rs#L626-L711)）。

因此可借鉴的是“UI top-K、后台过滤、可见项 resolve”；不能把 Zed 的 1,000 当成
facade 截断依据。

## VS Code：大量 candidates 留在 model，减少重复工作

VS Code 的 provider contract 明确允许初始结果只有 label，在 item 获得 UI focus 时才
resolve，且 editor 只 resolve 一次
（[`languages.ts` L702-L735](https://github.com/microsoft/vscode/blob/f4e18ff9f2d0f5dcea01d00ec73bed52be18f488/src/vs/editor/common/languages.ts#L702-L735)）。
focus 改变会取消旧 resolve，只 resolve 新 focus item
（[`suggestWidget.ts` L385-L438](https://github.com/microsoft/vscode/blob/f4e18ff9f2d0f5dcea01d00ec73bed52be18f488/src/vs/editor/contrib/suggest/browser/suggestWidget.ts#L385-L438)）。

其吞吐策略包括：

- 同优先级 provider 并发请求；第一组产生结果后停止较低优先级 provider，并复用前一
  session 的 provider items
  （[`suggest.ts` L270-L321](https://github.com/microsoft/vscode/blob/f4e18ff9f2d0f5dcea01d00ec73bed52be18f488/src/vs/editor/contrib/suggest/browser/suggest.ts#L270-L321)）。
- 用户继续输入时，从上次已经过滤出的集合做 incremental refilter；候选超过 2,000
  时切换到较便宜的 scorer
  （[`completionModel.ts` L82-L140](https://github.com/microsoft/vscode/blob/f4e18ff9f2d0f5dcea01d00ec73bed52be18f488/src/vs/editor/contrib/suggest/browser/completionModel.ts#L82-L140)）。
- 新 trigger 先 cancel 前一 request
  （[`suggestModel.ts` L533-L558](https://github.com/microsoft/vscode/blob/f4e18ff9f2d0f5dcea01d00ec73bed52be18f488/src/vs/editor/contrib/suggest/browser/suggestModel.ts#L533-L558)）。
- list model 持有全部 items，但 DOM 只更新当前 render range，因此没有语义 hard cap
  （[`listView.ts` L666-L727](https://github.com/microsoft/vscode/blob/f4e18ff9f2d0f5dcea01d00ec73bed52be18f488/src/vs/base/browser/ui/list/listView.ts#L666-L727)）。

VS Code 仍然逐项构造 CompletionItem wrapper 并对全部结果做初始 sort
（[`suggest.ts` L235-L267](https://github.com/microsoft/vscode/blob/f4e18ff9f2d0f5dcea01d00ec73bed52be18f488/src/vs/editor/contrib/suggest/browser/suggest.ts#L235-L267)、
[`suggest.ts` L325-L335](https://github.com/microsoft/vscode/blob/f4e18ff9f2d0f5dcea01d00ec73bed52be18f488/src/vs/editor/contrib/suggest/browser/suggest.ts#L325-L335)）。
它说明 UI 的缓存/增量过滤能显著改善连续输入，但不能消除 facade 自己的 allocation
放大。Eglot 已有 complete-list session cache；Eglotx 不应在不了解 buffer version 与
completion context 的情况下再实现一套跨请求 cache。

## Neovim 与 lsp-mode：Emacs/单线程侧的直接参照

Neovim 广告全部 itemDefaults
（[`protocol.lua` L485-L519](https://github.com/neovim/neovim/blob/ad3720b882d69e361741597f2d17906dbf0a132c/runtime/lua/vim/lsp/protocol.lua#L485-L519)），
但当前实现仍会逐项原地应用 defaults
（[`completion.lua` L235-L294](https://github.com/neovim/neovim/blob/ad3720b882d69e361741597f2d17906dbf0a132c/runtime/lua/vim/lsp/completion.lua#L235-L294)）、
过滤、转换并排序所有 candidates
（[`completion.lua` L446-L615](https://github.com/neovim/neovim/blob/ad3720b882d69e361741597f2d17906dbf0a132c/runtime/lua/vim/lsp/completion.lua#L446-L615)）。
它没有通用 hard cap。值得借鉴的是 exact cancellation 与 freshness：一个 cancel closure
取消所有 client legs，新 trigger 取消 pending request，response 到达后重新验证当前
row/mode，incomplete list 按 RTT 自适应 debounce 重查
（[`completion.lua` L695-L734](https://github.com/neovim/neovim/blob/ad3720b882d69e361741597f2d17906dbf0a132c/runtime/lua/vim/lsp/completion.lua#L695-L734)、
[`completion.lua` L1027-L1159](https://github.com/neovim/neovim/blob/ad3720b882d69e361741597f2d17906dbf0a132c/runtime/lua/vim/lsp/completion.lua#L1027-L1159)）。

lsp-mode 同样没有 facade cap。它缓存 complete list，在相同 completion session 中本地
过滤；请求和逐项过滤/sort 包在“有用户输入就终止”的边界中
（[`lsp-completion.el` L295-L311](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-completion.el#L295-L311)、
[`lsp-completion.el` L356-L399](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-completion.el#L356-L399)、
[`lsp-completion.el` L580-L646](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-completion.el#L580-L646)）。
resolve 是按 item 异步执行
（[`lsp-completion.el` L194-L248](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-completion.el#L194-L248)）。

lsp-mode 不能作为 defaults 的参考：其 CompletionList protocol shape 只有 `items` 与
`isIncomplete`，没有 `itemDefaults`
（[`lsp-protocol.el` L745-L759](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-protocol.el#L745-L759)）。
可以借鉴的是 `while-no-input` 的中断边界，而不是它同样 eager 的逐项 map/sort。

## Server 侧上限：rust-analyzer 说明了什么

rust-analyzer 提供 `completion.limit`，默认 `null`/无限
（[`configuration_generated.md` L510-L515](https://github.com/rust-lang/rust-analyzer/blob/cac0779549328e4bd4b808000c03307f1721f869/docs/book/src/configuration_generated.md#L510-L515)）。
它先把所有 internal items 转成 LSP CompletionItem，再按 `sort_text` 排序并 truncate
（[`to_proto.rs` L250-L284](https://github.com/rust-lang/rust-analyzer/blob/cac0779549328e4bd4b808000c03307f1721f869/crates/rust-analyzer/src/lsp/to_proto.rs#L250-L284)），
并返回 `is_incomplete: true`
（[`request.rs` L1187-L1203](https://github.com/rust-lang/rust-analyzer/blob/cac0779549328e4bd4b808000c03307f1721f869/crates/rust-analyzer/src/handlers/request.rs#L1187-L1203)）。

这类上限由 server 的 relevance 排序驱动，能减少 wire/client 成本，但甚至没有减少
server 自己的 per-item conversion。它验证了：若某个具体 server 提供 limit，preset
可以选择性暴露；generic multiplexer 不能拿各 backend 尚未统一的顺序做 first-N。

## Diagnostics：同样避免逐条 ownership 与重复显示

Completion 是本次首要热点，但大规模 diagnostics 应遵守相同的 source/batch 原则。
Zed 的 Buffer 按 `LanguageServerId` 保存独立 DiagnosticSet
（[`buffer.rs` L115-L127](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/language/src/buffer.rs#L115-L127)），
DiagnosticSet 排序后放入 SumTree，后续可按 buffer range 迭代
（[`diagnostic_set.rs` L152-L240](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/language/src/diagnostic_set.rs#L152-L240)）。
它在 notification burst 中每处理一条 message 主动 yield，避免主线程饥饿；但单个巨大
notification 的 handler 仍是一次同步工作
（[`lsp.rs` L631-L687](https://github.com/zed-industries/zed/blob/f032f4d433da3747f9d7bcc9e9cd52d6ca3fb3e4/crates/lsp/src/lsp.rs#L631-L687)）。

Neovim 为每个 client、push/pull identifier 建独立 namespace，再将整批 diagnostics
写入 store
（[`diagnostic.lua` L200-L265](https://github.com/neovim/neovim/blob/ad3720b882d69e361741597f2d17906dbf0a132c/runtime/lua/vim/lsp/diagnostic.lua#L200-L265)）。
当 `update_in_insert` 关闭时，它只保留每个 `(buffer, namespace)` 最新 display args，
到 InsertLeave/CursorHoldI 才展示，因而把 storage correctness 与 UI repaint 解耦
（[`_display.lua` L25-L74](https://github.com/neovim/neovim/blob/ad3720b882d69e361741597f2d17906dbf0a132c/runtime/lua/vim/diagnostic/_display.lua#L25-L74)、
[`_display.lua` L146-L179](https://github.com/neovim/neovim/blob/ad3720b882d69e361741597f2d17906dbf0a132c/runtime/lua/vim/diagnostic/_display.lua#L146-L179)）。

对 Eglotx 的推论是：

- 每个 `(backend, canonical-uri, modality)` 继续是 replaceable snapshot；空 publication
  只能清自己。
- 同一 event-loop turn 内，同 source 的多次 publication 只处理最新 full snapshot；
  aggregate 给 Eglot 的 publication 按 URI coalesce，避免每个 child 更新都触发一次
  Flymake rebuild。
- snapshot 本身保存 backend ownership，不为每条 diagnostic 创建通用 owner，除非
  codeAction follow-up 确实需要恢复该 diagnostic 的 raw `data/source`。这种 follow-up
  data 可按 publication batch + item index 编码，而不是 N 个独立 owner struct。
- validation、source attribution 与 aggregate append 合并成一次遍历；不要先
  `copy-sequence` 全批，再 tag 全批，再 vconcat。

## Eglotx 当前 completion 热路径审计

当前代码对一个带 defaults 的 item 最多经历以下阶段：

1. `eglotx--completion-parts` 把 vector/list 变成 list，并 map 所有 items；
2. `eglotx--completion-default` 复制 item，逐字段 materialize defaults，可能构造 textEdit；
3. `eglotx--tag-sequence` 再做 list/vector 往返；
4. `eglotx--tag-owned-object` 再复制 item，格式化唯一 token，分配 owner struct，写 owner
   hash、backend ledger、document ring hash 和 linked node；
5. 因 completion policy 有 commands，再无条件进入 `eglotx--tag-command-object`，即便
   item 没 command 也再复制一次；
6. 每个 backend append 回 list，最后整体 `vconcat`。

对应的发布前函数是 `eglotx--completion-default`、
`eglotx--completion-parts`、`eglotx--merge-completions`、
`eglotx--tag-sequence` 和 `eglotx--tag-owned-object`。其中部分 helper 已被后续批次实现
替换，不应再用当前源码行号解释这份基线。

这不是算法阶数错误，仍是 `O(N)`；问题是 `O(N)` 前面的 cons/hash/string/copy 常数被
重复放大，并在 10k--30k 下触发 GC。优化目标应是“一个 item 一次循环、common case
一次浅 copy、一个 batch owner”，而不是加入更多中间 abstraction。

## 生产实现状态与后续顺序

P0–P3 已在 0.1.0 发布前实现阶段落地；P4 是独立的未来路线图，不属于当前实现承诺。

### P0：批次 ownership，修复 8,192/11,509 正确性缺口

为 completion response 建一个 session-scoped batch record，至少包含：

```text
batch-token -> backend, uri, document-generation,
               shared-default-data-present?, shared-default-data,
               item-data-overrides
```

- 没有 item-specific `data` 的所有 items 共用同一个 `batch-token`；resolve 根据 batch
  backend 路由，并按 absent/default 语义恢复 raw data。
- item 有独立 `data` 时，用紧凑 `(batch-token, index)` handle，从 batch override vector
  取回；不要为每项分配完整 owner struct、唯一长字符串、ring node 和多个 hash entry。
- batch 作为一个 document-owner cache entry 参与 generation/retirement；一次淘汰释放
  整批。现有 8,192 limit 因而限制“批次/其他 object”，不再限制一张 completion menu
  能正确 resolve 多少项。
- construction 先写局部 staging record；只有整个 merge 成功且 request 仍 current 才
  commit。异常、输入中断或 cancel 都是 O(1) 丢弃，不留下半批 owner。

### P1：专用 completion 单遍 fast path

不要再组合通用 `completion-parts -> tag-sequence -> tag-owned-object -> tag-command-object`。
专用 loop 在一次 pass 中完成：

1. 读取 child list shape/defaults 与 `isIncomplete`；
2. 确定 common batch data；
3. 对每项只做一次浅 copy；
4. client 未协商 resolve-time `textEdit` 时才 eager materialize editRange；
5. 写 shared/override facade data handle；
6. 仅当 `plist-member :command` 时 namespace command；
7. 直接写预分配/增长的 output vector，并在批次边界检查 cancellation。

不要 deep-copy immutable defaults；不要在 vector→list→vector 间往返；不要对 completion
做 generic equality dedup；不要在 loop 内反复 `format` token。跨 backend 顺序保持现有
稳定 priority append。

### P2：child capability 与 Tailwind fast path

Eglotx 作为 child 的 client，应独立维护“facade 能消费”的 completion capabilities，
而不是机械等同于 Eglot 默认广告的能力。独立 Eglot adapter 声明它已经能在 resolve
结果中消费 `textEdit`；core 据此把 `itemDefaults.editRange` 紧凑保存在 segment，并在
选中项 resolve 时只展开一次。未协商该能力的 client 继续走 eager compatibility。
必须增加以下协议测试：

- shared default `data` 中的 Tailwind `_projectKey` 在 resolve 时完全恢复；
- item-specific data 覆盖 default，JSON absent 与 null 不混淆；
- `textEditText + editRange` 正确转成 TextEdit/InsertReplaceEdit；
- command namespace 只改 command ID，不破坏 raw item；
- child 未协商某个 default 时不接受/伪造该字段。

### P3：取消优先于转换

- facade cancel 立即把 aggregate request 标为 terminal，并取消所有 child legs；
- child response callback 首先验证 request identity/generation，再触碰 item vector；
- 合并多个 child 时，每个 leg 完成后再次验证；旧 completion 绝不分配 owner；
- 若用 `while-no-input` 中断 CPU loop，必须让 staging batch 的 unwind cleanup 无需扫描
  已处理 items。不要用 `sit-for 0` 引入不可控 reentrancy。

### P4：diagnostic coalescing

按 source slot 接收并覆盖，队列中只保留 `(source, uri)` 的最新 publication；一个 URI
在一个 drain turn 最多向 Eglot publish 一次 aggregate。继续保留现有 generation、
streaming/push/pull 与 backend retirement 语义，但把逐诊断 owner 改成 publication
batch/index handle。显示侧节流应尽量交给 Eglot/Flymake，而不是 core 再实现 UI。

## 明确不做

- 不在 core 截断 Tailwind 到固定 N；
- 不跨 backend 按 label/filterText 去重；两个 server 的同名 item 可能有不同 edit、
  command、resolve data 与语义；
- 不在 facade 实现 fuzzy matching、top-K 或 completion menu virtualization；
- 不为模仿 Zed 重写 Emacs jsonrpc transport，除非 profile 证明 JSON decode 而非当前
  post-decode allocation 是主导成本；
- 不复制一套 VS Code/Eglot session cache；缓存必须拥有 buffer version、prefix、trigger
  context 与 incomplete semantics，应用层比 multiplexer 更适合；
- 不通过无限增大 owner limit 掩盖 per-item ownership。

## 扩展 Benchmark 路线图

后续扩展 diagnostics batching 或调度模型时，应继续用真实数量而不是 100/1,000 项
micro fixture。表中 completion shared-default 的本轮现实基线已经纳入默认 benchmark；
其余场景用于后续容量规划：

| 场景 | 数量 | 目的 |
| --- | ---: | --- |
| Tailwind 单 backend | 11,509 | 官方现实基线 |
| Tailwind + TS | 20,000 左右 | 常见 frontend multiplexer |
| 三个大列表 | 30,000 | 合并、GC 与 cancellation 压力 |
| shared defaults | 11,509 | 批次 fast path |
| per-item data overrides | 11,509 | worst-case ownership |
| diagnostics 三 backend | 每个 10,000 | snapshot/coalescing |

每个场景记录：

- child response 收到到 facade response 完成的 wall time；
- cons cells、GC 次数与 GC wall time；
- child stdout 字节数、decode 后对象大小；
- cancel/input 到主循环重新可用的 latency；
- batch owner、per-item override、command owner 数；
- Eglot/Corfu 首次出现候选与选中项 resolve 的 E2E latency。

正确性验收至少包括：

1. 11,509 项全部可见，首项、中间项、末项都能 resolve 到正确 Tailwind backend；
2. 30k 合并保持 backend priority 与 child 内部顺序，不 dedup、不截断；
3. complete/incomplete 合并契约不变；
4. cancel 后没有 batch/override/command owner 泄漏，也不发布 stale result；
5. shared data、override data、absent、JSON null 四种情况 round-trip；
6. backend failure/document generation 变化可 O(批次数) retirement，不扫描 30k owner；
7. diagnostics 的空 snapshot 只清本 backend，burst 最终只 publish 最新 aggregate。

首轮目标应以相同输入相对当前基线衡量：owner entry 从 `O(items)` 降为
`O(batches + overrides)`，common Tailwind case 不超过一个 completion batch owner；
cons/GC 至少显著下降，且 11,509 项首项 resolve 的正确性问题必须消失。绝对毫秒门槛
应在同一 Emacs build、`gc-cons-threshold`、机器与冷/热进程条件下由 benchmark 基线
确定，避免用跨机器数字制造虚假的生产保证。
