# `eglot-lspx` published diagnostics fork 调研

调研日期：2026-07-18

> **实现范围更新（2026-07-19）：** 下文保留 fork 根因分析；当前实现只接受标准
> `textDocument/publishDiagnostics` 和 document pull diagnostics。Eglot streaming 是
> facade-to-client 投影，未协商的 child `$/streamDiagnostics` 会被忽略；
> `workspace/diagnostic` facade 也不在支持面内。

本文只使用 `cxa/eglot-lspx`、`thefrontside/lspx`、`cxa/lspx` 的 README、源码和提交历史，以及 LSP 3.17 规范。所有仓库链接都固定到 commit，避免后续主分支变化影响结论。

## 结论

README 中 “To make published diagnostics work, you must use the lspx fork” 的准确含义不是“上游 `lspx` 不会转发 diagnostics”，而是：**上游会转发每个 child server 的 `textDocument/publishDiagnostics`，但转发给单一 Eglot 连接时丢失了 child server 身份；Eglot 因而无法为同一 URI 分别保存各 server 的最新快照。后到的快照会覆盖先到的快照。** `cxa/lspx` fork 添加的唯一 diagnostics 功能就是在通知参数上附加私有字段 `_lspx_agent`；`eglot-lspx.el` 再以该字段为 key 缓存、替换并拼接各 agent 的最新 diagnostics。

因此问题分类是：

| 层 | 是否根因 | 说明 |
| --- | --- | --- |
| URI | 否 | 原始 `uri` 从 child 到 Eglot 一直保留；它只标识文档，不能标识 child server。 |
| JSON-RPC id | 否 | `publishDiagnostics` 是 notification，协议上没有 request id。 |
| notification forwarding | 否 | 上游 multiplexer 已逐条转发所有 child notifications。 |
| backend provenance | 是 | 上游内部知道 `agent`，但在写回 facade client 前只发送原始 params，agent 身份没有进入 wire。 |
| diagnostic aggregation | 是 | 缺少 provenance 就无法按 backend 保存独立快照；fork 与 Emacs advice 合作完成聚合。 |

这也是 Eglotx 必须解决的真实不变量：snapshot key 至少要包含 `(backend, uri, modality)`，一个 backend 发布空数组时只能清除它自己的贡献。

## 为什么普通转发会互相覆盖

LSP 明确规定 diagnostics 由 server “拥有”；同一 server 对一个 URI 新发布的完整数组会替换旧数组，空数组用于清除旧 diagnostics，而且客户端不负责合并。规范原文所在段落同时说明 “newly pushed diagnostics always replace previously pushed diagnostics” 和 “There is no merging that happens on the client side”。[`PublishDiagnostics` 语义](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_publishDiagnostics)

`PublishDiagnosticsParams` 的标准字段只有 `uri`、可选 `version` 和 `diagnostics`，没有 server/backend identity。[`PublishDiagnosticsParams`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_publishDiagnostics) 它又是 notification；JSON-RPC notification 只有 `method` 与可选 `params`，没有 request `id`。[`NotificationMessage`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#notificationMessage)

单 server 连接下这没有歧义，因为连接本身就是 server identity。multiplexer 把多个 child 伪装成一个逻辑 server 后，连接身份只剩 facade；如果不额外保留 child provenance，两次通知会变成：

```text
TypeScript -> publishDiagnostics(U, [TS1]) -> Eglot 显示 [TS1]
ESLint     -> publishDiagnostics(U, [ES1]) -> Eglot 替换为 [ES1]
ESLint     -> publishDiagnostics(U, [])    -> Eglot 清空 U
                                                ^ TS1 也一并消失
```

所以“published diagnostics 不工作”更精确地说是“多个 server 的 push diagnostic snapshots 不能共存和独立清除”；单个 child 的通知本身仍然能到达 Eglot。

## 上游 `thefrontside/lspx` 的数据流

fork 的父提交是双方共享的 `08e276f3e2667cb07dc615d8c80ad6706800a509`。在这份上游源码中：

1. 每个 child 的 JSON-RPC connection 用 `onNotification` 收到 `(method, params)`，将原始参数 tuple 放入该 agent 的 notification signal。[`json-rpc-connection.ts`](https://github.com/thefrontside/lspx/blob/08e276f3e2667cb07dc615d8c80ad6706800a509/lib/json-rpc-connection.ts#L54-L82)
2. multiplexer 为每个 agent 启动独立循环；进入 middleware 时数据是 `{ agent, params }`，所以此时来源仍然已知。[`multiplexer.ts`](https://github.com/thefrontside/lspx/blob/08e276f3e2667cb07dc615d8c80ad6706800a509/lib/multiplexer.ts#L32-L49)
3. 上游 lifecycle middleware 对 server-to-client notification 只调用 `next`，没有把 `agent` 写入 params。[`lifecycle.ts`](https://github.com/thefrontside/lspx/blob/08e276f3e2667cb07dc615d8c80ad6706800a509/lib/lifecycle.ts#L26-L36)
4. middleware 的 continuation 最终只执行 `execute(params)`，随后 facade connection 用 `client.notify` 把这份原始 notification tuple 发给 Eglot；`agent` wrapper 在这里结束生命周期。[`multiplexer.ts`](https://github.com/thefrontside/lspx/blob/08e276f3e2667cb07dc615d8c80ad6706800a509/lib/multiplexer.ts#L40-L46) [`server.ts`](https://github.com/thefrontside/lspx/blob/08e276f3e2667cb07dc615d8c80ad6706800a509/lib/server.ts#L64-L69)

也就是说，上游不是“没收到”或“没发送” notification；它缺的是跨 facade wire 的 child identity。当前上游主分支的 lifecycle 仍维持原样，没有 `_lspx_agent` 注入。[当前上游 `1b9649f`](https://github.com/thefrontside/lspx/blob/1b9649fa5567ef482dc54519943737922ef291dd/lib/lifecycle.ts#L26-L36)

## `cxa/lspx` fork 实际增加了什么

fork 的 diagnostics 变更全部在提交 [`d1f56f8ce272a0463a9bc2bad3929bade826d9a8`](https://github.com/cxa/lspx/commit/d1f56f8ce272a0463a9bc2bad3929bade826d9a8)，父提交正是共享上游 `08e276f`。该 commit 只改动 `lib/lifecycle.ts`，增加 8 行：

```ts
const [method, ...reqParams] = params.params;
reqParams.forEach((p) => {
  if (typeof p === "object" && p !== null &&
      method === "textDocument/publishDiagnostics") {
    (p as Record<string, unknown>)._lspx_agent = params.agent.name;
  }
});
```

完整固定源码见 [`cxa/lspx` lifecycle](https://github.com/cxa/lspx/blob/d1f56f8ce272a0463a9bc2bad3929bade826d9a8/lib/lifecycle.ts#L26-L44)。它没有改 URI、没有生成或重写 JSON-RPC id，也没有在 TypeScript 进程内聚合 diagnostics；它只是把 multiplexer 已经拥有的 agent provenance 写进非标准参数字段。

`params.agent.name` 来自 server 启动 child 时记录的 `exe`。[`server.ts`](https://github.com/cxa/lspx/blob/d1f56f8ce272a0463a9bc2bad3929bade826d9a8/lib/server.ts#L19-L42) 因此 wire 大致变为：

```json
{
  "jsonrpc": "2.0",
  "method": "textDocument/publishDiagnostics",
  "params": {
    "uri": "file:///p/a.ts",
    "diagnostics": [],
    "_lspx_agent": "vscode-eslint-language-server"
  }
}
```

`_lspx_agent` 是 lspx/eglot-lspx 之间的私有扩展，不属于标准 `PublishDiagnosticsParams`。

## `eglot-lspx.el` 如何消费 provenance

`eglot-lspx` 在提交 [`e727dfcf3a83f5a9fb5e84d181a5b310675bf176`](https://github.com/cxa/eglot-lspx/commit/e727dfcf3a83f5a9fb5e84d181a5b310675bf176) 中同时加入 README 要求和 Emacs 聚合逻辑；它比 fork commit 晚约 40 分钟提交，二者显然是配套变更。

当前固定源码的数据流是：

1. `_lspx_agent` 被 Eglot JSON 解码为 `:_lspx_agent`。
2. around method 从 notification 中取 agent、URI、完整 diagnostics 数组，并找到对应 managed buffer。
3. buffer-local `eglot-lspx--diagnostics` 保存 `agent -> latest diagnostics`；同一 agent 的新数组替换自己的旧数组。
4. 所有 agent 的数组通过 `vconcat` 拼接后，只调用一次 Eglot 原始 `textDocument/publishDiagnostics` handler。[缓存定义](https://github.com/cxa/eglot-lspx/blob/8636d0d1a26b1e0405a90d8510c882fc5bb7ea10/eglot-lspx.el#L213-L225) [聚合 advice](https://github.com/cxa/eglot-lspx/blob/8636d0d1a26b1e0405a90d8510c882fc5bb7ea10/eglot-lspx.el#L244-L262)

空数组仍会被保存在对应 agent 项下，但拼接结果不再包含该 agent 的 diagnostics；其他 agent 的快照继续存在。README 的 fork 要求就是为了让第 3 步有可靠的 key。[README note](https://github.com/cxa/eglot-lspx/blob/8636d0d1a26b1e0405a90d8510c882fc5bb7ea10/README.md#L26-L29)

## 原方案的边界

这个 fork 修复了最核心的互相覆盖问题，但它不是完整的生产级 diagnostics ownership 模型：

- `agent.name` 只取 executable；同一个 executable 以不同参数启动两次会 key 冲突。[agent 构造](https://github.com/cxa/lspx/blob/d1f56f8ce272a0463a9bc2bad3929bade826d9a8/lib/server.ts#L23-L42)
- 聚合只在 `eglot-lspx--find-it` 找到 managed buffer 时发生；unopened workspace URI 会走原始 handler，仍没有独立快照。[buffer 查找与 advice](https://github.com/cxa/eglot-lspx/blob/8636d0d1a26b1e0405a90d8510c882fc5bb7ea10/eglot-lspx.el#L213-L262)
- 调用原始 handler 时只重建 `:uri` 与 `:diagnostics`，没有传回可选 `:version`，因此不能用 child 发布版本淘汰 stale diagnostics。[聚合调用](https://github.com/cxa/eglot-lspx/blob/8636d0d1a26b1e0405a90d8510c882fc5bb7ea10/eglot-lspx.el#L253-L261)
- child 退出时没有显式撤销它的缓存快照；只有它之后发布新数组或 buffer 生命周期结束时才会改变。
- fork commit 没有增加测试；该 commit 的变更统计只有 `lib/lifecycle.ts` 的 8 行 additions。[fork commit](https://github.com/cxa/lspx/commit/d1f56f8ce272a0463a9bc2bad3929bade826d9a8)

这些限制不否定 fork 的根因判断，但说明 Eglotx 不应复制 `_lspx_agent` wire hack，而应在进程内保留明确的 backend 对象和快照生命周期。

## 对 Eglotx 的验收标准

Eglotx 自己启动并持有每个 child connection，所以收到 notification 时天然已经有 backend identity，不需要在发给 Eglot 的标准 LSP params 中添加 `_lspx_agent`。要判定 README 所述问题是否真正解决，至少应验证：

1. child notification 进入 facade 时始终携带其 backend 对象。
2. push snapshot 按 `(backend, uri)` 独立替换，而不是按 URI 全局替换。
3. backend A 发布 `[]` 后，backend B 对同一 URI 的 diagnostics 仍存在。
4. opened 与 unopened URI 都使用同一 provenance 模型。
5. 可选 `version` 被保留或用于拒绝 stale publication，包括 version `0`。
6. backend 退出时只撤销该 backend 的 snapshots。
7. 最终给不支持多流 diagnostics 的 Eglot 发送确定性 aggregate；支持独立 streaming token 时，也必须给每个 backend 使用稳定 token。
8. diagnostic `data` 的 owner 仍可追溯，相关 code action 只路由回源 backend。

满足这些条件即表示 Eglotx 在自身 facade 内解决了 fork 所补的 provenance/aggregation 问题，而且覆盖范围强于原 `cxa/lspx` + `eglot-lspx.el` 组合。

## 修复前对照（基线 `f553430`）：两个广义场景仍有缺口

该基线实现不依赖 `cxa/lspx` 的私有字段，并且已经解决 README 原场景中最核心的 open-buffer provenance/aggregation 问题：

以下位置以 `f553430` 的源码行号为准，可用
`git show f553430:eglotx.el` 与 `git show f553430:test/eglotx-test.el` 核对：

- 每条 child connection 的 notification dispatcher 闭包直接捕获 `backend`，来源身份不会在进入 facade 前丢失（L1064-L1073）。
- diagnostics queue 用 `(backend-id . uri)` 区分同 URI 的并发发布；正式 snapshot key 是 `(backend-id, uri, modality)`（L4517-L4538、L4218-L4221）。
- 完整 publication 验证后只替换对应 backend snapshot；空数组删除该 key，ordinary aggregate 再按 backend priority 拼出 facade 快照（L4345-L4392、L4290-L4304）。
- version 是否存在与其 truthiness 分开判断，因此 version `0` 也能正确拒绝 stale publication（L4345-L4378）。
- backend 失败时只枚举并移除以该 backend id 开头的 diagnostic keys，再重发剩余 aggregate（L1168-L1220）。
- 非 streaming fallback 与含 pull provider 的 mixed cohort 都给 Eglot 发送 ordinary aggregate，所以一个 backend 的空数组不会清掉 sibling；open buffer 的全 push streaming cohort 则以稳定的 `backend:<id>` token 隔离快照（L4380-L4392）。
- 回归测试覆盖双 backend 聚合/清除、version-zero stale publication，以及 **non-streaming** unopened URI 的聚合、独立清除和 `data` owner round-trip（测试 L1197-L1250、L1290-L1334、L1443-L1512）。

但是该基线还不能宣称所有 published diagnostics 场景完整解决：

1. **push-only streaming cohort + unopened URI 仍可能覆盖。** Eglotx 在 streaming 分支会按 backend 逐条发送带不同 token 的 `$/streamDiagnostics`。Emacs 31 的 `eglot--flymake-handle-push` 只有找到 visiting buffer 时才执行 `$/streamDiagnostics` handler 提供的 token-map continuation；对 unopened URI，它直接把当前 notification 转成 diagnostics 并覆盖 `flymake-list-only-diagnostics`，不会进入 token map。因此后到 backend 仍可能覆盖先到 backend。现有 unopened regression test 没有强制 streaming，不能覆盖这个组合。修复应在 facade 侧对 unopened URI 即使处于 streaming session 也发送 ordinary aggregate，或者要求 Eglot 的 list-only 路径原生支持 streaming token。
2. **等价 URI 拼法可能分裂 snapshot。** queue 与 snapshot 目前使用 child 提供的原始 URI 字符串作 key；两个 backend 若为同一文件发送语义等价但字符串不同的 URI，它们会落入不同 snapshot。LSP server 通常会回显 client URI，所以这是低概率、非阻断缺口，但生产实现宜在不破坏 remote URI 的前提下建立统一 document identity。

因此准确 verdict 是：**README 所指的 open-buffer child provenance 与 diagnostic aggregation 问题已经解决；ordinary fallback 和 mixed pull 路径也已解决。但广义 published diagnostics 尚有 streaming + unopened URI 缺口，现阶段不能称为完全解决。**

## 实现后对照：从 facade 架构内完整解决

当前实现不依赖 `cxa/lspx` 的私有字段，也不要求 diagnostics-specific Eglot advice。它在 child
message 仍带有 connection identity 的位置保存来源，然后只把投影视图交给 Eglot：

- 每条 child connection 的 dispatcher 闭包直接捕获 backend 对象；来源身份不会进入
  标准 LSP wire，也不会在 facade 内丢失。
- 唯一诊断事实表以 `(backend, canonical-document, modality)` 为 key。完整 publication
  只替换该来源 slot；空数组只删除该 slot。open-document record 不再保存第二份容易
  漂移的 diagnostics map。
- `file:` URI 在 hot path 做纯 lexical canonicalization：scheme/host case、unreserved
  percent encoding、dot segment 与 Windows drive spelling 归一并有界缓存；不会触发
  filesystem、TRAMP 或 `file-truename` I/O。非-file URI 保持 opaque exact identity。
- storage 与 client projection 分离。全 push cohort 中，open managed URI 使用稳定的
  per-backend `$/streamDiagnostics` token；unopened URI 即使处于同一 streaming session
  也只发送一次 ordinary aggregate，因此 Eglot 的 list-only path 不会互相覆盖。
- 私有 streaming capability 不发送给 child；未协商的 child
  `$/streamDiagnostics` 会被忽略，避免为客户端未声明的扩展维护第二套状态机。
- 所有 unopened URI 的 push/pull/cursor/version 状态进入同一个 O(1)
  LRU。淘汰会一次释放该 canonical URI 的所有来源状态；只对曾经可见的 aggregate 发
  clear。首次空报告不写入 Eglot，clear 与 didOpen 后还会移除 Eglot 留下的精确
  `flymake-list-only-diagnostics` cell，因此 facade 与 client 端都不会因遍历大量文件
  无界增长。
- mixed push/pull cohort 继续使用 ordinary push aggregate。pull provider `identifier`、
  document `resultId` 和 `previousResultId` 都通过有界 facade cursor 展开成 per-backend
  值；related documents 复用同一 canonical identity。
- version 是否存在与 truthiness 分开验证，因此 version `0` 也能淘汰 stale publication。
  backend 退出则通过同一个 storage-to-projection seam 只撤销自己的 slot，再发布兄弟
  backend 的剩余 aggregate。
- Diagnostic `data` 仍由 backend owner token 隔离；code action 等 follow-up 只恢复给
  原来源。
- Diagnostic owner 不再挂在需要整表过滤的 list/ring 上。每个 token 有唯一 intrusive
  retention container 与 backend index，document/orphan 迁移和 source teardown 都是
  O(1) unlink；同一 token 不可能同时被两个容器淘汰。
- Optional backend retirement 直接遍历 per-backend owner、command、diagnostic-key
  intrusive ledgers，按 `owners -> commands -> remove -> retract -> reset -> finalize`
  跨 event turn 推进。Source slot 全部移除后才向 Eglot retract；dispatcher 非局部退出
  会保留 queue head 并幂等重试，不会留下 stale published diagnostics。持续失败采用
  50ms 到 1s 的有界指数退避并回到普通 FIFO 队尾，不会制造告警风暴或饿死正常请求。

测试不是只观察内部 hash。真实 fake-child JSON-RPC 会穿过 facade，再由实际 Eglot
handler 写入 Flymake/list-only 状态，覆盖以下回归：

1. streaming session 的 unopened URI 同时保留两个 child 的 diagnostics；
2. 两个 child 使用等价但不同拼法的 file URI 时只形成一个 Eglot 文档视图；
3. optional backend 退出只清自己的 unopened diagnostics；
4. open-buffer 独立清除、stale version（含 zero）、owner round-trip，以及未协商 child
   stream 的拒绝；
5. pull document cursor、provider identifier、close/reopen ABA invalidation，
   以及 LRU 淘汰后不签发失去 snapshot 的 stale cursor；
6. unopened LRU 的跨 modality 清理、真实 Eglot list-only clear/didOpen 清理与 backend
   retraction 分块；
7. cleanup/retraction dispatcher 非局部退出、empty pull cursor-only state、owner/command
   分块，以及 orphan↔document owner migration 后的精确 eviction。

最终 verdict：**`eglot-lspx` README 所要求的 fork 已不再需要。Eglotx 在进程内保留
backend provenance，并同时覆盖 fork 没有处理的 unopened streaming、URI alias、版本、
backend retirement 与 pull incremental state。**
