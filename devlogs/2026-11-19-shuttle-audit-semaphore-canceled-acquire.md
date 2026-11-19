# semaphore：Context 已取消仍授予许可

**日期**: 2026-11-19
**位置**: `src/sync/semaphore.zig` `Weighted.acquire`（快路径，约 74–80 行）
**严重性**: 中（取消语义被破坏，资源在取消后被占用）
**调度依赖**: 无；单线程即可确定性复现

## 结论

`Context` 已经取消后调用 `acquire`，即使信号量空闲，当前实现仍授予权重并返回成功；
Go 语义是此时必须返回 `Canceled`，不得占用资源。

## 触发路径

单任务即可：

1. `sem = Weighted.init(1, null)`；`ctx = withCancel(background())`。
2. `ctx.cancel()`。
3. `sem.acquire(ctx.context(), 1)` → 走快路径：`size - cur >= n` 且无等待者 → `cur += 1`，返回 `void`（成功）。

场景断言"取消后获取必须返回 `error.Canceled`"，实际成功，报 `AcquiredAfterCancellation`。
回放轨迹 `9101092a000000`。

## 原理解析

`acquire` 的检查顺序（`src/sync/semaphore.zig`）：

```zig
self.mu.lock();
// 1. Fast path: enough capacity and nobody ahead in FIFO queue
if (self.size - self.cur >= n and self.head == null) {
    self.cur += n;
    self.mu.unlock();
    return;                       // ← ctx 已取消也直接成功
}
// Check if context is already expired
if (ctx.done()) { ... return mapContextError(ctx); }
```

`ctx.done()` 只在快路径失败后才检查。Go 的 `x/sync/semaphore` 在 `Acquire` 中
持锁后**先**检查 `ctx.Done()`（源码注释明确称取消走"fast-path"），再判断容量——
已取消的 Context 即使资源充足也立刻返回 `ctx.Err()`。

**影响**：取消是协作式取消的标准退出通道（超时、上游失败、连接断开）。取消后仍
占用权重，会让依赖 `acquire` 返回值判断"是否持有资源"的调用方在清理路径上漏掉
`release`（否则泄漏），或本应立即中止的路径继续执行临界段。

**修复建议**：把 `ctx.done()` 检查移到快路径之前（锁内先查取消，再查容量）。

## test suite

场景代码位于 shuttle 仓库 `wrappers/zig/stdgo_sync.zig`（`canceled`）：

```zig
fn canceled() !void {
    var sem = sync.Semaphore.init(1, null);
    const ctx = try go.context.withCancel(alloc, go.context.background());
    defer ctx.deinit(alloc);
    ctx.cancel();
    sem.acquire(ctx.context(), 1) catch |err| {
        if (err == error.Canceled) return;   // 预期路径
        return err;
    };
    sem.release(1);
    return error.AcquiredAfterCancellation;  // 取消后仍成功 → 失败
}
```

复现：

```sh
git clone -b zig-adapter https://github.com/fanyang89/shuttle
cd shuttle/wrappers/zig
zig build stdgo-run -Dstdgo=<stdgo> -- canceled                 # 首次失败
zig build stdgo-run -Dstdgo=<stdgo> -- canceled 9101092a000000  # 确定性回放
```

预期标准错误含 `AcquiredAfterCancellation`。该场景不依赖调度，也可以直接写成
stdgo 原生单元测试（`ctx.cancel()` 后断言 `acquire` 返回 `Error.Canceled`）。
