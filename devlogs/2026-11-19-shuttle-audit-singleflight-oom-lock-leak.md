# singleflight：do 分配失败后持锁返回

**日期**: 2026-11-19
**位置**: `src/sync/singleflight.zig` `Group.do`（执行路径，约 86 行）
**严重性**: 高（Group 永久锁死，且 deinit 无法自愈）
**调度依赖**: 无；单线程即可确定性复现

## 结论

`do` 持锁期间用 `try` 创建 `Call` 结构，分配失败时提前返回，互斥锁未释放。
此后该 Group 的所有 `do` / `deinit` 永久阻塞。

## 触发路径

单任务即可：

1. `g = Group(u32).init(零容量分配器)`。
2. `g.do("same", compute, ...)`：持锁查 map 无记录 → `try create(Call)` 失败 →
   `try` 语义直接带着锁返回 `error.OutOfMemory`。
3. 场景随后 `g.mu.tryLock()` 应成功（锁应已释放），实际失败，
   报 `LockHeldAfterAllocationFailure`。回放轨迹 `9101032a00`。

## 原理解析

`do` 执行路径（`src/sync/singleflight.zig`）：

```zig
self.mu.lock();
if (self.calls.get(key)) |existing_c| { ... self.mu.unlock(); ... }

const c = try self.allocator.create(Call);   // ← 锁内 try，失败路径不经过任何 unlock
...
const owned_key = self.allocator.dupe(u8, key) catch |err| {
    ...
    self.mu.unlock();                        // 后两个失败分支都手工解锁了
    return err;
};
```

手工锁管理中，`try` 是"任意错误即提前返回"的语法糖，绕过了后面所有显式
`unlock`。同函数内 `dupe(key)` 与 `calls.put` 两个失败分支都记得解锁，唯独
`create(Call)` 漏掉——典型的遗漏模式而非设计取舍。

**影响**：OOM 一次即永久锁死整个 Group；若其他线程正在 `do` 中等待，表现为
集体挂起；`deinit` 同样需要该锁，无法清理。

**修复建议**：`self.mu.lock()` 之后紧跟 `errdefer self.mu.unlock();`，删除各
失败分支的手工解锁；或把 `Call` 的创建移到锁外。

## test suite

场景代码位于 shuttle 仓库 `wrappers/zig/stdgo_sync.zig`（`flightOom`）：

```zig
fn flightOom() !void {
    var storage: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var ctx = Flight{ .group = .init(fba.allocator()) };
    if (ctx.group.do("same", Flight.compute, .{&ctx})) |_| return error.ExpectedOom else |err| {
        if (err != error.OutOfMemory) return err;   // do 应返回 OOM
    }
    // 没有调用在途：锁必须是空闲的（deinit 会因锁死而挂起，故先直接探测锁）
    if (!ctx.group.mu.tryLock()) return error.LockHeldAfterAllocationFailure;
    ctx.group.mu.unlock();
    ctx.group.deinit();
}
```

复现：

```sh
git clone -b zig-adapter https://github.com/fanyang89/shuttle
cd shuttle/wrappers/zig
zig build stdgo-run -Dstdgo=<stdgo> -- flight-oom            # 首次失败
zig build stdgo-run -Dstdgo=<stdgo> -- flight-oom 9101032a00 # 确定性回放
```

预期标准错误含 `LockHeldAfterAllocationFailure`。该场景不依赖调度，可直接改写为
stdgo 原生单元测试（OOM 后断言 `tryLock()` 成功）。
