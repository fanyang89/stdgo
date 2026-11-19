# errgroup：spawn 分配失败后 wait 永久自旋

**日期**: 2026-11-19
**位置**: `src/sync/errgroup.zig` `Group.spawn`（约 92–139 行）
**严重性**: 高（OOM 后 Group 永久不可用）
**调度依赖**: 无；单线程可复现，原生表现为程序挂起，Shuttle 用步数上限把它变成可诊断失败

## 结论

`spawn` 在创建任务上下文前就执行 `wg.add(1)`；若随后分配失败返回 OOM，WaitGroup
计数不回退（设置了限额时 `active_count` 也不回退）。此后 `wait()` 永久自旋，
`deinit()` 也无法恢复。Go 的 `errgroup.Go()` 没有失败路径（goroutine 启动不失败），
该缺陷是 stdgo 引入手动内存管理后独有的协议破坏。

## 触发路径

单任务即可：

1. `g.setLimit(1)`；分配器为零容量（`FixedBufferAllocator` 0 字节）。
2. `g.spawn(work)`：限额循环占用 `active_count = 1` → `wg.add(1)` →
   `allocator.create(TaskContext)` 失败 → `return error.OutOfMemory`。
3. 残留状态：`wg` 计数 = 1（永远没有 worker 去 `done`），`active_count = 1`。
4. `g.wait()` 进入 `wg.wait()` 自旋，永不返回。

场景对 `wait()` 设了步数上限（64 步），报 `exceeded max_steps`；
回放轨迹 `9101402a00000000000000000000000000000000`。

## 原理解析

`spawn` 的顺序问题（`src/sync/errgroup.zig`）：

```zig
self.wg.add(1);                                  // ← 先计数

const ctx = try self.allocator.create(TaskContext);  // ← 后分配，失败直接返回
// （此路径上 wg 与 active_count 均未回退）
```

对照同函数内其余两个失败分支：`Thread.spawn` 失败与 `threads.append` 失败都
手工回退了 `wg`/`active_count`——唯独 `create(TaskContext)` 这一处漏掉。

**影响**：内存吃紧时任何一个 Group 的 `spawn` 失败，都会让后续 `wait` 挂死，
表现为整个进程失去响应，而不是向上层返回 OOM。

**修复建议**：把 `wg.add(1)` 移到 `create` 成功之后；限额计数在 `create` 失败
分支回退（与现有 `Thread.spawn` 失败分支同构）。

## test suite

场景代码位于 shuttle 仓库 `wrappers/zig/stdgo_sync.zig`（`groupOom`）：

```zig
fn groupOom() !void {
    var storage: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var g = sync.ErrGroup.init(fba.allocator());
    defer g.deinit();
    g.setLimit(1);
    var n: usize = 0;
    if (g.spawn(groupWork, .{&n})) |_| return error.ExpectedOom else |err| {
        if (err != error.OutOfMemory) return err;    // spawn 应返回 OOM
    }
    // 没有任务被创建：wait 必须立即返回 null，实际永久自旋
    if (g.wait() != null) return error.UnexpectedWorker;
}
```

复现：

```sh
git clone -b zig-adapter https://github.com/fanyang89/shuttle
cd shuttle/wrappers/zig
zig build stdgo-run -Dstdgo=<stdgo> -- group-oom                     # 首次失败
zig build stdgo-run -Dstdgo=<stdgo> -- group-oom 9101402a00000000000000000000000000000000  # 回放
```

预期标准错误含 `exceeded max_steps bound 64`。原生（无 Shuttle）复现：同样代码
会直接挂起在 `wait()`，可用 `timeout 5` 包裹观察。修复后的回归断言：
`spawn` 返回 OOM 且 `wait()` 立即返回 `null`、`active_count` 归零。
