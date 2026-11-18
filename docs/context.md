# `stdgo.context` 与 Go `context` 对比

本文对照 Go 1.27 的 `context` 包和当前 Zig 0.17 `stdgo.context` 实现（结合 `std.Io`）。

## 一句话结论

**核心并发原语已经对齐：** 通过 `std.Io.Event` + 侵入式订阅链 + `std.Io.Select`，`stdgo.context` 已支持：
- **推送式父子取消传播**（`parent.cancel()` 主动唤醒子 context 和 `afterFunc`）；
- **阻塞等待与多路复用**（`ctx.wait(io)`、`ctx.waitTimeout(io, timeout)`，可与 `std.Io.Select` 组合实现 Go `select { case <-ctx.Done(): ... }`）；
- **自动定时器到期**（`withTimeout`、`withDeadlineIo` 到点自动取消并唤醒等待者，无需手动 `check`）；
- **完整衍生 API**：`withCancelIo`、`withCancelCause`、`withTimeout`、`withTimeoutCause`、`withoutCancel`、`afterFunc`、`cause`、`valueAs`、`withTypedValue`、`typedValue`。

**无法消除的本质差异来自语言与运行时：**
1. **无 GC，节点生命周期仍需手动管理**（`defer node.deinit(gpa)`，且需保证所有持有派生 `Context` 的任务在 `deinit` 前结束）。
2. **Value 为类型化 Key 或字符串键 + 裸指针**（通过 `TypedKey` 提供类似 Go 的防碰撞类型化键，通过 `valueAs` 提供字符串键强转，但 key/value 生命周期仍由调用方保证覆盖 context 存活期）。
3. **底层同步阻塞 syscall 的中断能力受限于 `std.Io` 后端**：在 `std.Io.Threaded` 下，已经阻塞在 OS `connect`/`read` 上的 syscall 无法像 Go netpoller 那样由外部 `cancel()` 强行唤醒（除非底层操作本身支持 `std.Io.Timeout` 或处于 `Io` cancelation point）。

---

## 核心对比表

| 维度 | Go `context` | `stdgo.context` | 说明 |
|---|---|---|---|
| 取消通知 | `Done() <-chan struct{}`（可 `select`） | `ctx.wait(io)` / `waitTimeout(io, timeout)` + `std.Io.Select` | 使用 `withCancelIo` / `withTimeout` 时由 `std.Io.Event`（futex）零轮询唤醒；无 `io` 的 `withCancel` 回退为 1ms 轮询 |
| 取消传播 | 父取消时主动通知所有已注册子 context | 侵入式 `Subscriber` 链表，父取消时主动推送子 context | 零额外堆分配，无后台轮询 |
| Deadline / Timeout | runtime timer 自动触发 | `withTimeout` / `withDeadlineIo` 自动触发；`withDeadline` 为惰性（配合 `errWithIo`/`check`） | `withTimeout` / `withDeadlineIo` 会启动 1 个 OS 定时器线程；`deinit` 时通过 `done_event` 立即唤醒回收 |
| 取消原因 | `WithCancelCause` / `WithTimeoutCause` / `Cause` | `withCancelCause` / `withTimeoutCause` / `cause` | `err()` 返回 `?Error`，`cause()` 返回 `?anyerror` |
| 剥离取消 | `WithoutCancel(parent)` | `withoutCancel(gpa, parent)` | 保留 `value` 与 `parentIo`，屏蔽 `deadline` / `done` / `err` / `subscribe` |
| 回调钩子 | `AfterFunc(ctx, f)` | `afterFunc(gpa, ctx, func, arg)` | 返回 `*AfterFuncHandle`，支持 `stop() bool` 与 `deinit` |
| 键与值 | `key any` + `Value() any` | `TypedKey(T)`（`typedValue`）或 `[]const u8`（`valueAs`） | 无 GC，key 和 value 指针生命周期必须覆盖 context 使用期 |
| 内存管理 | GC 自动回收，仅需 `defer cancel()` | 每个节点 `allocator.create`，需 `defer node.deinit(gpa)` | `deinit` 负责取消、停止定时器、从父节点退订并释放内存 |

> **OS 线程开销提示**：`withTimeout`、`withDeadlineIo` 和 `afterFunc` 在底层都会通过 `std.Thread.spawn` 启动真实的 OS 线程（不同于 Go 的轻量化 goroutine 与全局 runtime timer）。在极高并发或短生命周期请求中，建议优先直接向底层 I/O 传递 `std.Io.Timeout`（或使用无后台线程的 `withDeadline` + `errWithIo`），避免为每个请求创建定时器线程。

## Deadline 和 `std.Io`

`withDeadline` / `withDeadlineIo` / `withTimeout` 都会保留父 context 和子 context 中更早的 deadline，这一点与 Go 一致。

- **自动定时器（推荐）**：使用 `withTimeout(gpa, io, parent, dur)` 或 `withDeadlineIo(gpa, io, parent, deadline)`，会基于注入的 `io` 启动定时器线程，到期自动取消并唤醒 `ctx.wait(io)`；`defer node.deinit(gpa)` 会立即唤醒并回收定时器线程。
- **惰性检查（无后台线程）**：使用 `withDeadline(gpa, parent, deadline)` 时不启动定时器线程，需通过 `ctx.errWithIo(io)` / `ctx.doneWithIo(io)` 或 `node.check(io)` 刷新时钟状态：

```zig
const derived = try context.withDeadline(gpa, parent, deadline);
defer derived.deinit(gpa);

const ctx = derived.context();
if (ctx.errWithIo(io)) |err| return err;
```

当底层操作支持 `std.Io.Timeout`（如 `std.Io.Event.waitTimeout`、`std.Io.Condition.waitTimeout`）时，可直接传入 `ctx.ioTimeout()`：

```zig
const timeout = ctx.ioTimeout();
try event.waitTimeout(io, timeout);
```

注意：`std.Io.Timeout` 只表达时间截止，不表达另一个 context 的取消事件；需要同时响应「工作完成 / 超时 / 取消」时，应使用 `ctx.wait(io)` / `ctx.waitTimeout(io, timeout)` 配合 `std.Io.Select`。

## Value 的使用方式与限制

`context` 支持两种 Value 模式：**类型化防碰撞键（推荐）** 与 **字符串键**。由于没有 GC，不论使用哪种方式，value 指针必须在整个 context 使用期间保持有效。

### 1. 类型化防碰撞键（推荐）

借鉴 Go 官方使用私有未导出 struct 作为 key 的实践，`stdgo.context` 提供了 `TypedKey(comptime T, comptime name)`：
- 每个泛型实例具有全局唯一的静态变量地址，实现跨包/跨模块零碰撞；
- 键匹配仅需指针地址比较，开销极小且具有编译期类型安全：

```zig
// 定义唯一键类型（值类型为 usize）
const TraceKey = context.TypedKey(usize, "mypackage.trace_id");

const trace_id: usize = 12345;
var value_node = try context.withTypedValue(gpa, parent, TraceKey, &trace_id);
defer value_node.deinit(gpa);

const actual = value_node.context().typedValue(TraceKey) orelse return error.MissingValue;
```

### 2. 字符串键与 `valueAs`

`withValue` 不复制 key，也不拥有 value 指针。跨包使用时应使用带包名前缀的 key（如 `"mypackage/trace_id"`）：

```zig
const trace_id: usize = 12345;
const value_node = try context.withValue(gpa, parent, "trace_id", &trace_id);
defer value_node.deinit(gpa);

const actual = value_node.context().valueAs(usize, "trace_id") orelse return error.MissingValue;
```

`valueAs(T, key)` 封装了指针转换，但仍依赖调用方保证传入的 `T` 与写入时一致；错误的类型转换在 Zig 中属于未定义行为。

## 生命周期

每个派生节点都是独立的 allocator 分配，**务必通过 `defer node.deinit(gpa)` 释放**（不要直接 `gpa.destroy(node)`）：
- `deinit` 会自动取消节点、唤醒并 `join` 定时器线程（如有）、从父节点订阅链表退订，最后释放内存；
- 销毁节点前，所有保存该节点 `Context` 的任务必须已结束；父节点也必须保持有效。

典型模式：

```zig
var cancel_node = try context.withCancelIo(gpa, io, parent);
defer cancel_node.deinit(gpa);
const ctx = cancel_node.context();
```

Go 的惯用模式是 `defer cancel()`；Zig 版本通过 `defer cancel_node.deinit(gpa)` 同时完成取消与资源回收。

## 后续可继续深化的方向

1. **网络/HTTP/DB 阻塞点集成**：目前 `rate.Limiter.waitN` 已接入 `ctx.waitTimeout(io, ...)`，可立即被取消唤醒；`net.Dialer.dialContext`、`http.Transport.roundTrip`、`os.exec` 在 `std.Io.Threaded` 下仍受限于底层同步 socket/进程 syscall，后续可结合 `std.Io.Select` 与 `Evented` 后端进一步深化。
