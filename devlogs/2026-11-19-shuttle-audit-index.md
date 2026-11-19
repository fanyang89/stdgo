# Shuttle 并发审计：sync 包五个缺陷索引

**日期**: 2026-11-19
**方法**: 用 [Shuttle](https://github.com/awslabs/shuttle) 的 Zig 适配器（[fanyang89/shuttle `zig-adapter` 分支](https://github.com/fanyang89/shuttle/tree/zig-adapter)）对 `src/sync` 做随机化并发调度测试，固定种子 42、每场景 200 轮、步数上限见各报告。所有失败均可用编码轨迹确定性回放。

| # | 报告 | 严重性 | 单线程可复现 |
|---|------|--------|--------------|
| 1 | [singleflight：shared 标志违背 Go 语义](2026-11-19-shuttle-audit-singleflight-shared.md) | 中 | 否（依赖调度） |
| 2 | [semaphore：Context 已取消仍授予许可](2026-11-19-shuttle-audit-semaphore-canceled-acquire.md) | 中 | 是 |
| 3 | [errgroup：spawn 分配失败后 wait 永久自旋](2026-11-19-shuttle-audit-errgroup-spawn-oom-hang.md) | 高 | 是（表现为挂起） |
| 4 | [singleflight：do 分配失败后持锁返回](2026-11-19-shuttle-audit-singleflight-oom-lock-leak.md) | 高 | 是 |
| 5 | [errgroup：未 wait 即 deinit 导致互等](2026-11-19-shuttle-audit-errgroup-deinit-deadlock.md) | 高 | 是（表现为挂起） |

插桩方式见 `src/sync/backend.zig`：生产构建回退到 `std.atomic.Value` / `std.Thread`，行为零变化；测试可执行文件通过根模块声明替换为带调度点的实现。stdgo 自身测试无回归（323 通过 / 1 跳过，跳过项为网络代理不可达）。
