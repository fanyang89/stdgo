# errgroup：未 wait 即 deinit 导致互等

**日期**: 2026-11-19
**位置**: `src/sync/errgroup.zig` `Group.deinit`（约 44–56 行）
**严重性**: 高（互等挂起；errdefer 清理路径天然命中）
**调度依赖**: 需要调度暴露互等结构；原生多线程同样死锁，表现为挂起

## 结论

`deinit` 持有组锁调用 `join`。若 worker 失败，其 `setError` 需要同一把锁：
主任务持锁等 worker 退出，worker 等锁释放——互等。`deinit` 是资源清理接口，
用户在 `wait` 之前调用（典型如 `errdefer g.deinit()`）即触发。

## 触发路径

固定种子 42 首次失败轨迹
`9101409bdbd29794bbb9eb920100aa2aa2aaaaaaaaaaaaaaaaaaaaaaaa`。任务 A 为主任务，
任务 B 为 worker：

1. A `g.spawn(groupWork)`：任务创建成功、`wg.add(1)`，B 可运行但尚未被调度。
2. A 直接 `g.deinit()`：持锁进入 `for (self.threads) |*t| t.join()`。
3. 调度 B：`groupWork` 让出后返回 `error.WorkerError` → `setError` →
   `self.mutex.lock()` 自旋让出（锁被 A 持有）。
4. 互等：A 的 `join` 等 B 退出，B 的 `setError` 等锁释放。自旋等待在 Shuttle
   下耗尽步数上限（64 步），报 `exceeded max_steps`。

场景未设限额（`limit = 0`）以排除限额循环的干扰——`setError` 的锁需求本身就足够
构成互等。

## 原理解析

```zig
pub fn deinit(self: *Group) void {
    self.mutex.lock();
    for (self.threads.items) |*t| {
        t.join();                    // ← 持锁等待其他任务退出
    }
    self.threads.deinit(self.allocator);
    self.mutex.unlock();
    ...
}
```

持锁 `join` 是反模式：被 join 的任务在退出路径上（`setError`、限额回退的
`defer` 块）可能需要同一把锁。`wait()` 也有同样的持锁 `join`，但它先执行
`wg.wait()` 保证所有 worker 已结束（`setError` 在 `wg.done` 之前完成），因此
`join` 立即返回——只有 `deinit` 缺少这层保护。

Go 的 errgroup 依赖 GC，没有 deinit；stdgo 提供显式清理契约后，`deinit` 必须
允许在任意时刻调用（包括 `errdefer` 路径），否则清理接口本身变成挂起点。

**修复建议**：持锁只做"取走线程列表快照"，解锁后再逐个 `join`；`wait()` 中的
持锁 `join` 建议同型处理以保持一致。

## test suite

场景代码位于 shuttle 仓库 `wrappers/zig/stdgo_sync.zig`（`groupWork` / `groupDeinit`）：

```zig
fn groupWork(n: *usize) !void {
    const prev = n.*;
    s.yield();                // 调度点：制造 deinit 与 worker 的交错窗口
    n.* = prev + 1;
    return error.WorkerError; // 失败路径需要 setError → 组锁
}
fn groupDeinit() !void {
    var g = sync.ErrGroup.init(alloc);
    var n: usize = 0;
    try g.spawn(groupWork, .{&n});
    g.deinit();               // 未先 wait：持锁 join 与 setError 互等
}
```

复现：

```sh
git clone -b zig-adapter https://github.com/fanyang89/shuttle
cd shuttle/wrappers/zig
zig build stdgo-run -Dstdgo=<stdgo> -- group-deinit   # 首次失败
zig build stdgo-run -Dstdgo=<stdgo> -- group-deinit 9101409bdbd29794bbb9eb920100aa2aa2aaaaaaaaaaaaaaaaaaaaaaaa  # 回放
```

预期标准错误含 `exceeded max_steps bound 64`。修复后的回归断言：`spawn` +
`deinit`（不经 `wait`）能正常返回，且 `n` 已被 worker 更新（join 语义保持）。
