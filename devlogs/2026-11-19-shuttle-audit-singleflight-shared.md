# singleflight：shared 标志违背 Go 语义

**日期**: 2026-11-19
**位置**: `src/sync/singleflight.zig` `Group.do`（执行路径，约 143 行）
**严重性**: 中（结果标志错误，非崩溃）
**调度依赖**: 需要；单线程原生代码难以稳定命中

## 结论

多个调用者并发 `do` 同一 key 时，函数只执行一次、所有调用者拿到同一个值——这部分正确；
但首个执行者固定返回 `shared = false`，即使确有重复调用者共享了该结果。Go 的
`golang.org/x/sync/singleflight` 语义是：只要 `dups > 0`，执行者与重复者都返回
`shared = true`。

## 触发路径

固定种子 42 首次失败轨迹 `91011c2a80aa80a0202a00`。任务 A 为主任务，任务 B 为 worker：

1. A 进入 `do("same")`：持锁查 map 无记录 → 注册 `Call`，`wg.add(1)`，解锁。
2. A 调用 `compute`：`calls += 1` 后在函数体内让出（场景在此插入了调度点）。
3. B 进入 `do("same")`：持锁发现已有记录 → `dups += 1`、`refs += 1`，解锁后 `wg.wait()`。
4. A 恢复：返回 17，持锁从 map 摘除本次调用，`wg.done()`，B 被释放并读到 `val = 17`、`shared = true`。
5. A 返回 `Result{ .val = 17, .shared = false }` ← 错误值：该结果被两个调用者共享。

场景断言：`calls == 1` 时 `shared` 计数应为 2（双方均为 true），实际为 1，报 `IncorrectShared`。

## 原理解析

执行路径的返回值（`src/sync/singleflight.zig`）：

```zig
c.wg.done();
...
return Result{
    .val = res_val,
    .shared = false,   // ← 从不读取 c.dups
};
```

而 `dups` 字段确实在重复路径被累加（`existing_c.dups += 1`），Go 源码中执行者返回
`Result{c.val, c.dups > 0, c.err}`——标志的含义是"该结果是否交给了多个调用者"，
与调用者身份（执行者/重复者）无关。

**影响**：调用方常用 `shared` 决定结果归属，例如缓冲是否可安全复用、返回值所有权是否
需要移交（Go 文档中的典型用法）。误报 `false` 会让首个调用者错误地认为自己独占结果。

**修复建议**：在持锁段读取 `dups` 后返回 `shared = dups > 0`（注意与 `release` 同一
临界区，避免与 `forget` 竞争）。

## test suite

场景代码位于 shuttle 仓库 `wrappers/zig/stdgo_sync.zig`（`Flight` 与 `flight`）：

```zig
const Flight = struct {
    group: sync.SingleFlight(u32),
    calls: usize = 0,
    shared: usize = 0,
    fn compute(ctx: *Flight) u32 {
        ctx.calls += 1;
        s.yield();          // 调度点：让重复者在此窗口到达
        return 17;
    }
    fn worker(ctx: *Flight) !void {
        const result = try ctx.group.do("same", compute, .{ctx});
        if (result.val != 17) return error.BadResult;
        if (result.shared) ctx.shared += 1;
    }
};
fn flight() !void {
    var ctx = Flight{ .group = .init(alloc) };
    defer ctx.group.deinit();
    try pair(&ctx, Flight.worker);            // 主任务 + worker 并发 do
    if (ctx.group.forget("same")) return error.RetainedCall;
    if (ctx.shared != (if (ctx.calls == 1) @as(usize, 2) else 0))
        return error.IncorrectShared;
}
```

复现（Zig 0.17.1、Cargo、x86_64 Linux；`<stdgo>` 为本仓库检出路径）：

```sh
git clone -b zig-adapter https://github.com/fanyang89/shuttle
cd shuttle/wrappers/zig
zig build stdgo-run -Dstdgo=<stdgo> -- singleflight                     # 首次失败
zig build stdgo-run -Dstdgo=<stdgo> -- singleflight 91011c2a80aa80a0202a00  # 确定性回放
```

预期标准错误含 `Zig scenario failed: IncorrectShared` 与失败轨迹；套件级入口
`zig build test -Dstdgo=<stdgo>` 会在子进程中断言"首次失败 + 回放失败"两次成立。
