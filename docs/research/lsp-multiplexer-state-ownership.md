# LSP multiplexer state ownership audit and minimal interface design

调研日期：2026-07-18

> **历史调研说明（2026-07-19）：** 本文保留对完整 LSP 状态面的研究，后文的
> 扩展方案不再代表当前实现。生产实现已收敛到 Eglot 实际协商的协议面：只接受
> `workspace/didChangeWatchedFiles` 动态注册，只向上游转发被选中 provider 的
> `workspace/semanticTokens/refresh`，不实现 `workspace/diagnostic` facade，且剥离而非
> 虚拟化 initialize-time static registration IDs。当前行为以
> [`docs/spec.md`](../spec.md) 和 [`docs/architecture.md`](../architecture.md) 为准。

## 范围与结论

本文只使用以下一手来源：LSP 3.17 规范、仍在开发中的 LSP 3.18
规范、GNU Emacs 的 Eglot 源码，以及本仓库的 `eglotx.el`。调研用的 LSP
规范仓库固定在
[`b7f5132c`](https://github.com/microsoft/language-server-protocol/tree/b7f5132c95261c0898ae5124e7a91707abc48fcd)；Eglot 审计对象是
GNU Emacs 31.0.90，2026-07-18 的 GNU master 与本机安装源码在本文引用的函数上
一致。

结论有三层：

1. `textDocument/publishDiagnostics` 不是孤例。它属于一组“原本以一条
   connection 作为隐式 server namespace”的机制；multiplexer 折叠 connection
   后，必须显式恢复 backend ownership。
2. 标准 LSP 中真正会产生持久 child identity collision 的机制共有五类：完整快照、
   opaque follow-up data/command、注册 ID、progress token、增量 result cursor。
   Refresh/invalidation 本身没有 token collision，但必须做 provider admission 和
   去重，否则未被 facade 选中的 child 也能使客户端刷新错误的 provider。
3. 不应再把 diagnostics、registration、progress 当作互不相关的转发特例。实现需要
   在 decoded LSP message seam 先判定 state kind，再进入统一的 ingest、client
   projection 和 backend retirement 生命周期。

## 实现决议（历史方案）

本轮实现采用“一个概念上的 state ownership module、多个私有深入口”，没有增加
对用户暴露的新 core 配置：

- replaceable diagnostics 只存一份 backend-owned source slot；open streaming、unopened
  aggregate、mixed pull/push、native child stream 与 backend retirement 都调用同一个
  projection policy；
- 所有 unopened diagnostic URI 由跨 modality 的 O(1) LRU 约束；淘汰原子释放 source、
  owner、cursor、version/watermark，并只撤销实际投影过的 client view。open document
  继续由 generation/lifecycle 管理；
- canonical document identity 在 queue、snapshot、owner 与 cursor 之前建立；
- opaque `data`、command、dynamic registration 和 progress 继续使用各自的 typed owner
  record，因为它们不是 replaceable snapshot；
- pull diagnostic provider identifier 与 result cursor 加入有界 per-backend ledger；
- refresh 作为无 value 的 invalidation 进入 admission/coalescing queue；
- initialize-time child static registration `id` 记录为 source contribution，wire 上只
  暴露稳定的 opaque aggregate ID；owner 的 raw `(method, id)` unregistration 只撤销
  自己的 contribution；
- child 发起的 server-to-client request 在 raw envelope seam 保存 `(connection, id)`，
  使 `$/cancelRequest` 能精确终止 handler，且嵌套请求不会被跨层 unwind。
- native stream 在 didChange 后保留 preceding-generation dormant snapshot；只有同一
  source 的新版本 full/unchanged 确认后才恢复 ownership。advancing unchanged 对 Eglot
  materialize 为 full，避免其新 token map 在版本切换时被初始化为空。

这种分层刻意不做一个接收任意 JSON 的“万能 state map”。类型化 record 能保留
absent/null、document generation、modality 和 selector 等不同不变量，同时所有 record
都遵守同一个 backend ownership/retirement 原则。

## lsp-mode 带来的启发与边界

调研固定在 lsp-mode `6bfc593d`（2026-07-16）。它最值得借鉴的不是具体 API，而是
状态归属：一个 `lsp--workspace` 对应一个 server connection，每个 workspace 拥有独立
diagnostics hash；Flymake 在读取时才跨 workspace 聚合。这直接验证了 Eglotx 的
backend-owned source slots，而不是把后到 publication 当作全局真相。
[lsp-mode diagnostics storage](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-mode.el#L2403-L2505)
[workspace state](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-mode.el#L3171-L3262)
[Flymake aggregation](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-diagnostics.el#L319-L340)

它的 `:_workspace` CodeLens owner 也印证了 opaque follow-up 必须回源，而 dynamic
registration/progress 依赖 workspace/connection 隔离，折叠 connection 后必须显式
namespace。
[CodeLens owner routing](https://github.com/emacs-lsp/lsp-mode/blob/6bfc593d7b1bc0dd656f09ffce52cc085ebced05/lsp-lens.el#L263-L309)

不能照搬的部分同样明确：lsp-mode 的 pull diagnostics 没有完整处理 provider
`identifier`、`resultId`、`previousResultId(s)`、related documents 与 workspace
diagnostics；它的 URI 规范化也没有覆盖所有 lexical dot segments。Eglotx 因而保留
自己的 cursor virtualization 和 canonical identity，而不是复用这两段浅实现。

## 为什么单 server LSP 不需要显式 backend identity

LSP 的 request ID、registration ID、progress token、result ID 和 diagnostic snapshot
都没有 server 字段。普通部署中，transport connection 本身就是 server identity。
JSON-RPC request 只带 `id`、`method`、`params`；notification 甚至没有 `id`。
[`RequestMessage`、`NotificationMessage`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#requestMessage)
当 N 个 child connection 被折叠为一条 facade connection，原来的隐式 namespace
消失；任何需要在后续 message 中引用先前状态的字段都必须由 multiplexer
虚拟化或钉死到一个 provider。

规范只给出“roughly the same order”的 response 建议，并允许不影响正确性的并行
response 重排。它没有定义不同 server 之间的全序。
[`Request, Notification and Response Ordering`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#messageOrdering)
因此正确的 multiplexer 不应试图给 child publications 建立虚假的全局先后关系；
它应保持每条 child connection 的 FIFO，并让不同 backend 更新互相独立的 slot。

## 完整机制清单与碰撞矩阵

下表“基线状态”指 `f553430` 的 `eglotx.el`；实现后的决议见上节。

| 机制 | 协议中的 owner / key | 合并后的风险 | 基线 core | 推荐规则 |
| --- | --- | --- | --- | --- |
| JSON-RPC request、response、`$/cancelRequest` | connection + request `id` | 两个 child 可使用相同 id；cancel 可能误投 | facade→child cancellation 已按 child leg 处理；child→client raw request id 尚未保留 | id 永不跨 connection 复用；双向 cancel 都以 exact connection-local request record 为边界 |
| Push diagnostics | server + document URI；新数组完整替换旧数组 | 同 URI 的后到 child 覆盖或清空 sibling | 已按 `(backend, raw-uri, modality)` 保存；raw URI alias 与 unopened streaming 尚有缺口 | canonical document + backend source slot；空数组只清自己的 slot |
| Eglot `$/streamDiagnostics` | buffer-local token + version；非标准 LSP | token 冲突；unopened URI 不进入 token map | open buffer token 已 namespace；unopened URI 仍可能覆盖 | 只有 visiting buffer 可用 streaming；unopened 始终发送 ordinary aggregate |
| Pull diagnostics | diagnostic provider `identifier`；document/workspace `resultId` | facade 只有一个 identifier/cursor，不能原样送给 N 个 child | child resultId 不外泄并有 snapshots；identifier 未按 child 注入，resultId 被全部丢弃 | facade cursor 映射为 `{backend -> child cursor}`；每个 leg 注入 child identifier |
| Semantic tokens | provider legend + `resultId` | 数字 token 必须由同一 legend 解码；delta cursor 不能跨 provider | 静态 provider 被 pin，动态注册拒绝，已安全 | 保持 singleton；resultId 仍宜包成 generation-bound facade cursor |
| Opaque result `data` | 产生 item 的 server | resolve/follow-up 被 fan-out 或送错 child | owner token、exact restore、document generation 已处理 | 所有 opaque data 使用 session-scoped handle；保留 absent/null 区别 |
| `Command.command` | 声明/产生 command 的 server | 同名 command collision，executeCommand 误投 | completion/code action/code lens/inlay-hint 等路径已处理，inline completion 与 capability documentation 尚待补齐 | 所有六类直接携带 Command 的标准结构都 namespace，facade 永不暴露 raw child string |
| Dynamic registration | server + `Registration.id` | 同 id collision；unregister 撤销 sibling | dynamic id、selector、watcher 已 namespace，已处理 | registration 是 source contribution；register/unregister 事务化 |
| Static registration ID | initialize capability 中的 `StaticRegistrationOptions.id` | 两个 child id collision；后续 unregistration 无 dynamic record | 没有统一虚拟化 | facade static handle 代表 aggregate contribution，绝不透传 raw id |
| Work-done progress | `ProgressToken` + begin/report/end lifecycle | token collision；fan-out 多个 lifecycle 共用一 UI token | server-created 和单 target 已映射；fan-out 删除 token | 每个 child 独立 token；若不实现 aggregate UI，fan-out 明确禁用 |
| Partial result progress | request 的 `partialResultToken` | raw chunk 绕过 method merge、owner tagging 与 final-result 规则 | 所有 child leg 删除 token，安全但没有 streaming | 在能够消费、merge、decorate chunk 前继续禁用；禁止透明转发 |
| Refresh/invalidation | active provider + feature，通常 global | 无 id collision；inactive child 可触发错误 provider，N 次 refresh 放大 | generic forward；Eglot 31 只广告 semantic refresh | admission by active contribution；按 `(feature, scope)` coalesce；每个 child request 仍得到 response |
| Workspace folder change registration | static `changeNotifications` boolean/string 或 dynamic id | string id collision | static 合并为 boolean；dynamic 走通用 namespace，安全 | boolean facade capability；source registrations 留在 ledger |
| File watchers | registration id + glob selector | sibling selector/ID 混淆 | union watch + per-backend match，已处理 | registration contribution 驱动一个 facade watch set |
| Workspace file operations | provider filters；后续 notification 不带 registration id | overlapping dynamic providers无法判断 owner | static per method pin；dynamic 拒绝，已安全 | singleton 或显式 selector router；不能假装 registration id 会随 event 返回 |
| Notebook sync | notebook selector + shared open/change/close lifecycle | 后续 notification 不带 provider id | static pin；dynamic stateful registration 拒绝，已安全 | 一个 lifecycle owner；切换 owner 需要完整 replay，首版不 fail over |
| Position encoding | initialize session capability | 所有 position/range 都共享编码 | 强制 UTF-16，已处理 | session singleton |
| 3.18 text document content | URI scheme provider + URI-scoped refresh | overlapping scheme provider 与 refresh 误路由 | 未建立显式 3.18 policy；unknown capability 只随 primary | 每个 scheme pin 一个 provider；refresh 只接受该 URI 的 owner |

`WorkspaceEdit.changeAnnotations` 等 ID 只在一个独立 result object 内被引用；
`window/showMessageRequest` 的 action、`workspace/applyEdit` 的 response 也由原 child
request continuation 自然返回。只要不跨 child merge 这些 object，它们不需要持久
ledger。普通 location、hover、log、telemetry 是值或事件，也没有后续 affinity。

## 一手来源逐类核对

### 1. Replaceable snapshot：push 与 workspace diagnostics

LSP 明确说 diagnostics 由 server 拥有；新 publication 总是完整替换旧
publication，空数组清除旧值，客户端不做 merge。
[`PublishDiagnostics`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_publishDiagnostics)
这正是 child identity 丢失后会互相覆盖的原因。

Workspace pull diagnostics 还有第二层 replacement：一次 streaming workspace pull
可以为同一 URI 多次报告，最后一份获胜；document pull 应优先于 workspace pull，
较高 document version 应优先于较低 version。
[`Workspace Diagnostics`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_diagnostic)
所以 diagnostic key 不能只有 `(backend, uri)`，至少还要区分 `push`、`pull`、
`workspace` modality，并在最终 reducer 中表达 version 与 modality precedence。

Eglot 31 的普通 push 状态是单个 buffer-local `(DIAGNOSTICS VERSION)`；
`textDocument/publishDiagnostics` 每次直接替换它。实验性的 streaming 状态才是
`TOKEN -> DIAGS` map。
[`eglot--pushed-diagnostics` / `eglot--streamed-diagnostics`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/eglot.el#n2386)
[`publishDiagnostics` 与 `$/streamDiagnostics` handlers](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/eglot.el#n3362)

关键的 Eglot adapter 限制是：`eglot--flymake-handle-push` 只在找到 visiting buffer
时调用 streaming handler 的 token-map continuation；unopened URI 直接写
`flymake-list-only-diagnostics`，没有 token namespace。
[`eglot--flymake-handle-push`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/eglot.el#n3497)
因此 open buffer 可用每-backend streaming token，unopened URI 必须由 facade 先聚合
为 ordinary `publishDiagnostics`。这不是一个全局 session boolean 能表达的选择，而是
per-document delivery policy。

### 2. Canonical document identity

LSP 的 `DocumentUri` 在 wire 上只是 string。规范特别指出，drive colon 的 percent
encoding 与 drive-letter casing 都可能不同，双方不能假设对方会返回相同拼法。
[`URI`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#uri)
因此以 raw URI string 作为 document/snapshot/owner key 不足以满足规范容许的输入。

Eglot 自己在发送 `didOpen` 时以 `file-truename` 建立 cached
`TextDocumentIdentifier`，并提供 URI/path converter；收到 diagnostics 时又把 URI
转回 path 来寻找 buffer。
[`eglot-uri-to-path` / `eglot-path-to-uri`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/eglot.el#n1255)
[`eglot--TextDocumentIdentifier`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/eglot.el#n2980)
Eglotx 应复用这层语义，但不能在 diagnostics hot path 对每条 workspace URI 做
remote `file-truename`。

推荐内部 `document-ref`：

- `raw-uri -> document-ref` alias table 是首个 O(1) fast path。
- Client `didOpen` 建立 authoritative facade URI；所有 child 等价 file URI 绑定到同一
  ref。对 file URI 只做 decode、drive/host/path 的 lexical normalization，并缓存；
  不在 notification hot path 访问磁盘或 TRAMP。
- 每个 ref 保留 `facade-uri` 与 `backend -> last-wire-uri`。给 Eglot 发送 facade URI，
  给 child 回送该 child 自己的 URI。
- 非-file、server-defined URI 默认保持 exact identity；只有 provider registration
  或一次 client ownership transfer 明确建立 alias 时才合并，避免错误规范化 opaque
  virtual URI。
- Document generation 属于 ref，而不是某一个 URI spelling。`didChange`、`didClose`
  和 owner cleanup 因而对所有 aliases 一致生效。

### 3. Opaque follow-up ownership

以下标准 object 都包含“由一次 request 产生、在之后 resolve/follow-up request 原样
保留”的 `data`：CompletionItem（包括 `CompletionList.itemDefaults.data`）、
CodeAction、CodeLens、DocumentLink、InlayHint、Diagnostic、CallHierarchyItem、
TypeHierarchyItem、WorkspaceSymbol。
[`CompletionItem`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionItem)
[`CodeAction`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeAction)
[`Diagnostic`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic)
[`CallHierarchyItem`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#callHierarchyItem)
[`WorkspaceSymbol`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceSymbol)

这里的问题不只是两个 child 恰好返回相同 JSON `data`；facade 若 fan-out resolve，
会把 server-private data 泄露给 sibling。正确策略是把 raw data 留在 ledger，向 Eglot
暴露 session-scoped opaque handle，并在 follow-up 只恢复给 owner。字段 absent、JSON
null 和任意 JSON value 必须分别保存。Diagnostic data 还要求 code-action context 按
backend 过滤，不能把另一 backend 的 diagnostic 交给当前 child。

`Command.command` 是另一种 affinity handle。它同时出现在 server capability 和多个
result object 中；不同 server 完全可能注册相同 string。
[`Command`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#command)
所以即使 raw command 当前全局唯一，facade 也应稳定 namespace，避免新 child 加入后
改变 routing。

当前 core 已有 owner 与 command token，见
[`eglotx--tag-owned-object`](../../eglotx.el#L4116)、
[`eglotx--restore-owned-object`](../../eglotx.el#L4172) 和
[`eglotx--transform-client-params`](../../eglotx.el#L4275)。新 module 应吸收这些
implementation，而不是在外部接口暴露更多 data-specific operations。

### 4. Registration lifecycle

动态 `Registration.id` 由 server 生成并用于之后 unregister；规范要求同一 server
不能对相同 selector 同时 static 与 dynamic 注册。
[`Register Capability`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#client_registerCapability)
`StaticRegistrationOptions.id` 同样是 server-controlled ID，并且明确允许之后注销
initialize result 中的 feature。这一点容易被只处理 `client/registerCapability`
的实现漏掉。
[`StaticRegistrationOptions`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#staticRegistrationOptions)

推荐把 static 与 dynamic 都建模为 source contribution：

- raw `(backend, id)` 永远不直接成为 facade id；facade token 不拼接 raw string。
- Register 请求只在 Eglot 接受后 commit；error、quit 或 dispatcher failure rollback
  registration、selector、command 与 watcher state。
- 一个可组合 facade capability 的 static id 代表 aggregate contribution。一个 child
  注销时先移除自己的 contribution；仍有 provider 就保留 facade capability，最后一个
  provider 消失才向客户端注销。若 options 只能缩小，保留安全 superset 并在 router
  过滤；客户端支持动态变更时才 transactionally unregister/register 新 options。
- Stateful provider 的后续 message 不携带 registration id（semantic legend、notebook
  lifecycle、workspace file operation）。这类 capability 必须 singleton，或实现完整
  selector router；不能只 namespace registration id 后继续 fan-out。

Dynamic registrations 已 transactionally namespace；semantic/notebook dynamic
registration 被拒绝，workspace file operations 被 pin 或拒绝。
[`eglotx--handle-registration-request`](../../eglotx.el#L5130)
实现已经落地完整的 aggregate static contribution ledger：initialize-time raw
`id` 只保存在 `(backend, method, id)` owner 表，Eglot 看到的是稳定 opaque aggregate
ID。owner 的合法 raw unregistration 会撤销自己的 capability/selector contribution
并重新计算 facade；同 raw ID 的 sibling 不受影响，最后一个 owner 退出才移除 facade
能力。unknown、unowned 或 method-mismatched ID 明确失败。workspace folder
`changeNotifications` string ID 使用同一机制。

### 5. Progress 与 partial result

`ProgressToken` 可以是 integer 或 string，并与 request id 不同。Work-done progress
可由 client request 的 `workDoneToken` 发起，也可由 server 先请求
`window/workDoneProgress/create`；server-created token 只能用于一个 begin/many report/
one end lifecycle。
[`Progress Support`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#progress)
[`Work Done Progress`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workDoneProgress)
Eglot 的 progress reporter 正是一个以 token 为 key 的 facade-wide hash table，所以
child token 必须 namespace。
[`eglot-handle-notification $/progress`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/eglot.el#n2867)

Partial result 也走 `$/progress`，但语义不同：一旦 server 发送 partial chunks，完整
result 必须全部通过 chunks 发送，最终 response 在 result values 上为空；非取消错误
还要求丢弃已收到 chunks。
[`Partial Result Progress`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#partialResults)
所以透明转发 child partial progress 是错误的：它绕过 method-specific merge、owner
tagging、dedupe 与 error discard。当前删除所有 `partialResultToken` 是明确、安全且
性能可预测的降级。
[`eglotx--transform-client-progress-tokens`](../../eglotx.el#L4297)
未来若支持 partial streaming，应由 state module 消费每个 child chunk，将它当作同一
method 的中间 result 执行相同 normalization/ownership，再产生一个 facade stream；
在此之前不要暴露配置开关让 raw chunks 穿透。

### 6. Incremental result cursor

Pull diagnostics 有三种互相关联的 server-owned value：provider `identifier`、
document `resultId/previousResultId`、workspace 每 URI 的 `previousResultIds`。Full
report 可产生新 resultId；只有在先前提供 resultId 时 server 才能合法返回 unchanged。
[`DiagnosticOptions` 与 `DocumentDiagnosticParams`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_diagnostic)
[`WorkspaceDiagnosticParams`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_diagnostic)

基线实现曾丢弃 child resultId 和 provider `identifier`。当前实现采用 facade cursor：

```text
facade resultId "eglotx:<session>:cursor:42"
  -> document-ref D, modality pull, generation 7
  -> { vue: "vls-result-9", eslint: "eslint-result-a" }
```

- Client 回送 facade cursor 时，`state-prepare-client` 为每个 target 注入自己的 child
  cursor 与 diagnostic provider identifier；未知、过期或 generation 不匹配就删掉
  previous cursor，强制 full，而不是把 foreign string 送给 child。
- Full/unchanged response 都更新 source cursor；unchanged 从同 source snapshot 恢复。
- Related documents 与 workspace `previousResultIds` 复用 canonical document refs，
  每个 URI 的 facade cursor 展开为 per-backend value。
- 任一 leg error 后可以保留上一份可见 snapshot，但本轮不签发可复用 aggregate cursor，
  使下一轮重新同步。
- Cursor map 有界；安全 eviction 的行为是“忘记 cursor，下一次请求 full”，不会产生
  stale UI。

上述规则已经覆盖 document、related document 与 workspace diagnostics；cursor 还绑定
exact open-document object，close/reopen 后即使 URI 相同也会强制 full。

Semantic tokens 也有 `resultId/previousResultId`，并且 token integer 必须按 provider
legend 解码。
[`Semantic Tokens legend`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#semanticTokensLegend)
[`Full / delta semantic tokens`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#semanticTokens_deltaRequest)
当前 singleton pin 已阻止跨 legend merge。
[`eglotx--merge-semantic-capability`](../../eglotx.el#L7929)
仍建议将 resultId 包成 facade cursor并记录 backend generation；这样 optional backend
重启或未来 provider policy 改变时，旧 cursor 会安全失效而非误送。

### 7. Refresh 与 invalidation

LSP 3.17 定义五个 server-to-client refresh request：

- `workspace/semanticTokens/refresh`
- `workspace/codeLens/refresh`
- `workspace/inlineValue/refresh`
- `workspace/inlayHint/refresh`
- `workspace/diagnostic/refresh`

它们都是 void request；前四个要求客户端重新请求当前显示内容，diagnostic refresh
要求刷新所需 document/workspace pulls。规范强调这些 global refresh 会刷新所有当前
显示结果，应谨慎使用。
[`Semantic Tokens Refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#semanticTokens_refreshRequest)
[`Code Lens Refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeLens_refresh)
[`Inline Value Refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_inlineValue_refresh)
[`Inlay Hint Refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_inlayHint_refresh)
[`Diagnostic Refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic_refresh)

这里没有可碰撞 ID，但有 ownership：只有对 facade 当前 capability 有 contribution 的
backend 才能使其失效。Global merged feature 的任一 active contributor refresh，应使
下一次 facade query 重新询问全部 contributors；singleton secondary 的 refresh 应
响应 void 但不刷新被 pin 的 primary。相邻相同 refresh 可在一个固定且不延长的短窗口
内按 `(feature, scope)` 合并，避免 N servers 造成 N×buffers 的 request storm；固定
deadline 也避免持续 refresh 造成饥饿，每个 child request continuation 仍必须完成。

Eglot 31 只广告并处理 semantic-token refresh，而且当前 handler 有意不触发实际
font-lock refresh，因为现实 server 存在滥用。
[`Eglot client capabilities`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/eglot.el#n1088)
[`workspace/semanticTokens/refresh`](https://git.savannah.gnu.org/cgit/emacs.git/tree/lisp/progmodes/eglot.el#n5433)
Eglotx 必须以 facade 原始 client capabilities 作为 admission 上限；未广告的 refresh
不应因为某个 child 自己实现了 feature 就被“升级”为受支持。

实现会在 child request seam 立即返回 void，然后只将 active contributor 的
invalidation 放入 bounded work queue；相邻相同 global refresh 合并成一次 client
request。singleton secondary 与未广告 feature 均 ack 后丢弃。

LSP 3.18 仍标为 under development；它增加 global
`workspace/foldingRange/refresh`，以及按 URI 的
`workspace/textDocumentContent/refresh`。后者的 provider 以 URI schemes 注册，
因此多个 child overlap 时必须每 scheme pin owner，并只接受该 owner 对 URI 的
refresh。
[`LSP 3.18 status`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/)
[`Folding Range Refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_foldingRange_refresh)
[`Text Document Content / Refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_textDocumentContentRefresh)
Emacs 31 没有广告这些 3.18 capabilities，所以当前首要工作是 policy/admission，
而不是向 Eglot 暴露它尚未实现的功能。

## Conceptual deep module：最小 interface，最大 leverage

### Seam

Seam 放在 decoded child message 已携带 backend object、但尚未进入 Eglot dispatcher
的位置，以及相反方向 client message 已选出 targets、但尚未复制给 child 的位置。
Transport、JSON encode/decode、进程 supervision 留在现有 router；普通 stateless
result merge 也不需要经过 ledger。只有会创建、引用、替换或撤销持久状态的 message
进入该 module。

以下三个操作是审计时用来验证模块深度的 conceptual interface。实现使用 core 内部的
typed helpers，没有把这组伪 API 暴露给 package 或 preset 层：

```emacs-lisp
(eglotx--state-ingest-child state backend event)
;; Child -> facade。验证、事务化更新 source state，并通过内部 facade
;; adapter 发出必要 request/notification。Server request 的返回值直接返回 child。

(eglotx--state-prepare-client state event targets)
;; Facade -> children。返回稳定 backend 顺序的 (BACKEND . TRANSFORMED-EVENT)，
;; 展开 owner、cursor、identifier、registration/progress token。

(eglotx--state-retire state scope reason)
;; scope 是 request、document generation、backend 或 session。
;; 原子撤销该 scope 的 contributions，并通过内部 adapter 产生必要 retraction/end。
```

`event` 是 router 已有 method/request context 的一个私有 immutable envelope；interface
不暴露 diagnostics-specific keyword soup。Module implementation 可按 method family
拆成多个私有 handler 和 policy table；Depth 是 interface 的 leverage，不要求一个
巨型函数。

### 用例

Push diagnostics：

```emacs-lisp
(eglotx--state-ingest-child state eslint
  (server-notification
   'textDocument/publishDiagnostics
   '(:uri "file:///p/a.ts" :version 3 :diagnostics [...])))
```

Module 解析 URI alias、更新 `(eslint, diagnostic, document-ref, push)` slot。若文档
已打开且 Eglot 支持 streaming，只发稳定 ESLint stream token；若 unopened，则按
backend priority 构建 ordinary aggregate。之后 ESLint 发布 `[]` 只清该 slot。

Pull diagnostics：

```emacs-lisp
(eglotx--state-prepare-client
 state
 (client-request 'textDocument/diagnostic
                 '(:textDocument (:uri "file:///p/a.ts")
                   :previousResultId "eglotx:...:cursor:42"))
 '(vue eslint))
```

Module 返回两个 leg：各自含 child provider identifier 与自己的 previousResultId；
如果 facade cursor 已过期，两者都省略 previousResultId，强制 full。

Backend crash：

```emacs-lisp
(eglotx--state-retire state '(:backend eslint) 'process-exit)
```

一次调用撤销 ESLint diagnostics、static/dynamic registrations、progress、opaque
owners、commands 和 cursors；重新向 Eglot 发布剩余 aggregate。Caller 不需要知道
这些表分别存在哪里。

### Interface invariants

- **Provenance**：owner 必须是当前 session 中的 backend object/id；绝不使用 executable
  name 或 child 提供的 wire field 作为 provenance。
- **Slot identity**：持久 source state 的逻辑 key 是
  `(session, backend, domain, canonical-subject, modality)`。
- **Replacement**：一次 publication 只替换同 source slot。Aggregate 是派生 view，
  不是另一个 source of truth。
- **Opaque handles**：facade token 全部由 session monotonic allocator 产生，不拼接或
  stringify child token；integer `1` 与 string `"1"` 始终不同。
- **Document identity**：raw URI 只做 alias；所有 document state、generation、cursor
  与 diagnostics 使用 `document-ref`。
- **Ordering**：同 child FIFO；跨 child 没有全序。Facade effects 进入同一 FIFO；
  deterministic aggregate 只按 backend priority/declaration order。
- **Generation**：open document 的 versionless state 绑定当前 generation；显式 version
  包括 `0`；stale update 被忽略且不修改旧 slot。
- **Transactional error**：malformed payload、registration rejection、quit、dispatcher
  error 不得留下半个 state transition。Unknown/foreign handle 不 fan-out；需要 full
  state 的 cursor miss 退化为省略 previous id。
- **Retirement**：request completion、didClose/new generation、backend exit、session
  shutdown 都只调用 `state-retire`；重复调用幂等。
- **Capability admission**：refresh/registration/provider state 不得超过原 facade client
  capabilities；inactive singleton child 的 invalidation 没有 facade effect。

### 隐藏在 implementation 后面的复杂性

- Raw URI aliases、canonical `document-ref`、preferred facade/child wire URI。
- Diagnostics source snapshots、modality/version reducer、Eglot open/unopened delivery。
- Opaque data/command owners、per-backend intrusive index，以及 document/orphan
  exact bounded retention container。
- Dynamic 与 static registrations、selectors、watchers、aggregate capability handles。
- Progress forward/reverse maps 与 active lifecycle。
- Diagnostic/semantic facade cursor，provider identifier transform。
- Refresh admission、scope、coalescing。
- Eglot 29--31 compatibility：visiting-buffer 查询、普通/streaming dispatcher、pull-state
  invalidation。
- Backend/session cleanup 和 outward retraction。

删除这个 module 时，上述复杂性会重新散回 diagnostics、request merge、registration、
notification、progress、crash cleanup 等多个 caller；它通过 deletion test，不是一个
pass-through。

### Ordering、错误与性能合同

1. Child notification 在 process filter 外进入 facade FIFO；同 child 先收到的完整
   snapshot 必须先 commit。Batch 可以 coalesce 同 `(backend, document-ref, modality)`，
   只保留 barrier 之前最后一份完整 snapshot。
2. Server-to-client registration request 是同步 transaction：验证与 staged state 在
   outward request 前完成，只有 client success 才 commit；失败回滚并把原错误返回
   source child。
3. Snapshot malformed/stale publication 被 source-locally drop；不能清除旧 snapshot，
   也不能影响 sibling。
4. Backend retire 先令 owner 不再可路由，再产生 outward retractions；late response/
   progress/end 找不到 live generation 时无副作用。
5. Raw URI、opaque token、registration id、cursor 与 provider lookup 为期望 O(1)。
   Target selection只扫描配置的 bounded backend cohort。
6. Open-buffer streaming update 为 O(child diagnostics)；unopened ordinary aggregate 在
   coalescing 后为 O(B + visible diagnostics)。Canonicalization cache miss 不做 package
   manager、recursive filesystem scan 或 remote stat。
7. Cursor eviction 为 O(1) bounded ring/hash 操作，退化为下一轮 full response；active
   push snapshot 若受 workspace memory cap 驱逐，必须同步发 retraction，不能静默
   遗忘仍显示在 Eglot 中的 state。
8. Refresh coalescing 在固定且不延长的短窗口内每 `(feature, scope)` 最多一次 facade
   invalidation；每个 child request 仍独立结束，持续 storm 不会无限推迟 flush。
9. Optional backend retirement 不扫描 facade-wide table。Owner、command 与 diagnostic
   key 由 backend-owned intrusive ledger 精确枚举，按
   `owners -> commands -> remove -> retract -> reset -> finalize` 分阶段；每个
   continuation 最多处理 `eglotx-diagnostic-chunk-size` 项并强制让出到下一 event turn。
   Outward dispatcher 的 error/quit/non-local exit 不能跳过 retirement；retraction/reset
   只在正常返回后 unlink，因此幂等重试不会丢任务。失败重试从 50ms 指数退避至 1s，
   timer 到期后进入普通 FIFO 队尾；成功推进即重置，从而同时保证 stale-state 最终撤回、
   告警限速与普通工作的公平性。
10. Owner token 只属于一个 authoritative container。Orphan→document、同 document
    refresh 与 document→orphan 都先 O(1) unlink 原位置再插入新位置；bounded eviction
    同时撤销 global owner 与 backend index，不存在 tombstone compaction 或重复 membership。

## Dependency 分类与 adapter strategy

按 deep-module dependency 分类：

| Dependency | 分类 | Strategy |
| --- | --- | --- |
| Ownership tables、URI alias、reducers、policy | in-process | 直接放在 module implementation，通过三个入口测试 |
| Child/facade decoded message 与 transport dispatch | local-substitutable | 生产使用现有 jsonrpc/Eglot dispatcher；测试使用 recording adapter；adapter 是内部 seam，不扩张外部 interface |
| Eglot 29--31 buffer/diagnostic behavior | local-substitutable、version-varying | 至少有 ordinary、streaming、fake 三个 adapter，是真实 internal seam |
| Clock/event queue | local-substitutable | 注入 fake clock/queue 测 timeout、coalesce、late events |
| Local/remote filesystem | 避免成为 hot-path dependency | canonical identity 用 cached URI/path lexical transform；不在 child event 上调用 remote filesystem |

没有 remote owned service 或 third-party network port；无需把 ports & adapters 暴露成
用户或 preset 配置。Production/fake 两个 adapter 足以证明内部 seam 真实存在。

## Trade-offs 与拒绝的设计

优势：

- 三个入口覆盖所有 LSP state lifecycle，caller 不再学习每种 token/snapshot 的 cleanup。
- Method-specific protocol knowledge集中，修复一次可同时覆盖 normal、failure、shutdown。
- 直接以真实 LSP event 为 test surface，测试不会绑死内部 hash table。
- Stateless hot path不进入 ledger；性能成本只由真正 stateful mechanisms 支付。

代价：

- Module implementation 会很深，必须用私有 policy handlers 拆分；仅把现有函数包进
  三个转发入口不会产生 locality。
- Cursor virtualization 增加少量 hash allocation；换来 pull diagnostics/semantic delta
  的增量性能与 backend-generation safety。
- Canonical URI 对非-file scheme 必须保守，不能声称所有语义等价 URI 都能自动识别。
  LSP 本身要求双方保持一致；module 只统一规范明确提示的 file encoding/case 和已知
  ownership aliases。
- Refresh coalescing改变可观察 timing，但规范允许客户端延迟 recalculation；每个 request
  的 void/error contract 仍保留。

拒绝两种更浅的方案：

1. **只修 diagnostics key**：无法覆盖 provider identifier/resultId、static registration
   id、refresh ownership，下一种机制还会再建一套 cleanup。
2. **暴露通用 `put/get/delete(namespace,key,value)` registry**：interface 虽只有三个
   名字，caller 仍必须知道 replacement、generation、rollback、retraction、cursor
   expansion；复杂性没有消失，只是换了 hash table 包装。

也不建议让所有 stateless LSP message 经过一个“万能 protocol actor”。它会把 location/
hover 等普通 merge 与持久 ownership 绑在一起，扩大 failure surface。推荐的 seam 只接管
会创建、引用或撤销 state 的消息。

## 实施顺序与验收

建议按风险分三步迁移，不在旧 helpers 外再叠一层：

1. 建立 `document-ref` + source slot，将 push/pull/workspace diagnostics 和 open/unopened
   Eglot delivery移入新 module；旧 diagnostics tests 改为通过 interface event 驱动。
2. 搬迁现有 owner/command/registration/progress maps，并让 backend/document/request/
   session cleanup 只走 `state-retire`。补 static registration id、refresh admission。
3. 加 facade cursor，先做 pull diagnostic identifier/resultId，再包 semantic resultId；
   3.18 virtual-content policy只在 Eglot 宣告 capability 后启用。

必须新增的 interface-level cases：

- 两个 backend 用不同 URI encoding 发布同一 file，合并到同一 document-ref；任一
  `[]` 只清自己的 snapshot。
- Push-only streaming session 的 unopened URI 连续收到 alpha/beta/alpha-clear，Eglot
  list-only state 最终只含 beta；打开 buffer 后切为独立 stream tokens。
- `didClose` 使用 client URI spelling，撤销 child alternate spelling 下的 owners。
- 两个 diagnostic providers 使用相同 raw resultId 与不同 identifier；每个 request leg
  收到自己的 identifier/cursor，unchanged 恢复自己的 snapshot。
- Expired facade cursor不送给任何 child，而是触发 full。
- 两个 child 使用相同 dynamic/static registration id；注销一方不撤销另一方。
- Integer progress token `1` 与 string token `"1"`、两个 child 的相同 token 全部独立。
- Inactive semantic provider refresh 得到 void 但不刷新 primary；两个 active merged
  providers 在同一固定批次窗口内只产生一次 facade invalidation。
- Backend crash通过一次 retire 同时撤销 diagnostics、registration、progress、cursor、
  owner；重复 retire 无额外 effect。
- Malformed/stale update、dispatcher error、quit 都保留 transaction 前 state。

达到这些验收条件后，`publishDiagnostics` fork 暴露的问题才算从架构上解决：不是给
某个 notification 加 backend tag，而是恢复 facade 折叠 connection 时丢失的完整
state ownership namespace。
