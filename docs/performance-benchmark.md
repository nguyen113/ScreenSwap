# ScreenSwap performance benchmark

`ScreenSwapBenchmark` instruments the actual swap path with `mach_continuous_time`, not `Date`. Each operation records T0 (command received), T1 (all windows captured), T2 (one complete mapping plan), T3 (first AX move command), T4 (last AX move command returned), and T5 (every planned frame verified or the 500 ms verification timeout elapsed).

The production status-item path captures T0 synchronously in its click handler, then performs frame verification asynchronously. Verification compares positions and, for resizable windows, sizes with a 2 px tolerance. It polls only after a failed check, at 5 ms intervals and with a 500 ms timeout; no presentation delay or animation is introduced.

## Running a physical benchmark

This command moves real windows. Arrange exactly two displays and the requested scenario first, grant Accessibility to the benchmark executable, then run:

```sh
swift run ScreenSwapBenchmark --scenario P04 --windows 10 --stage-manager OFF --confirm-live-windows --output performance-results.json
```

It performs 10 unmeasured warmups and 100 measured forward swaps by default. Every forward swap is immediately followed by an unmeasured reverse swap, which restores the starting display arrangement before the next run. The command refuses to run without `--confirm-live-windows`.

Supported scenario labels are P01 (1 window), P02 (2), P03 (5), P04 (10), P05 (20), P06 (mixed apps), P07 (minimized/hidden present), P08 (fullscreen/non-movable present), P09 (spanning window present), and P10 (Stage Manager enabled). The label documents the operator-arranged workload; it does not create synthetic windows or disable Stage Manager. P09 spanning windows remain unmoved and are still included in discovery time. Filtered elements retain non-sensitive skip reasons in the capture data.

Use `--baseline prior-performance-results.json` to compare verified-complete p95. A regression greater than 15% is reported; add `--fail-on-regression` for CI. `--fail-on-target` optionally returns non-zero for a real-machine p95 over 200 ms, but is intentionally not the default CI behavior.

`performance-results.json` includes every measured timing record plus min, mean, p50, p90, p95, p99, max, and standard deviation for command-to-first-move, core complete (T4−T0), and verified complete (T5−T0). Any run that cannot verify all planned windows is retained and marked invalid; it is never reported as a completed fast swap.
