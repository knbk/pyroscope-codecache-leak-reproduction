# Code Cache Growth Analysis (Pyroscope Lock Profiling)

## Summary
When Pyroscope's Java agent runs with lock profiling enabled, the number of `Unsafe.park` occurrences reported by `Compiler.codelist` grows steadily. The same growth can be reproduced with plain async-profiler if you use its looping mode (e.g. `--loop 1s`) so that profiling is stopped and restarted frequently. This growth does **not** occur when:
- Running the workload without any agent
- Running a single long-lived async-profiler session (no periodic restart)

Root cause: any periodic start/stop cycle that re-registers the native `Unsafe.park` method (Pyroscope's continuous upload loop or async-profiler's `--loop`) triggers repeated invalidation of its compiled native wrapper, accumulating obsolete (not_entrant) nmethods. High-frequency cycles (e.g. 1s) inflate code cache occupancy and the count of `Unsafe.park` entries.

## Reproduction Context
Project: `pyroscope-codecache-leak-reproduction`
Workload: tight loop invoking `LockSupport.parkNanos(1ms)` with a periodic monitor querying:
- `compilerCodelist` (count `Unsafe.park` occurrences)
- `compilerCodecache` (segment usage summary)

Problem signature (Pyroscope agent OR async-profiler with loop): monotonically increasing `Unsafe.park` count. Baseline (no agent or single async-profiler run): count stabilizes (≈1).

## Key Behavioral Difference
Pyroscope (default continuous mode) performs a full profiling cycle every upload interval, and async-profiler with `--loop <interval>` behaves equivalently by design:
```
stop async-profiler
read profile data
dump & export
start async-profiler
```
Contrast: a typical async-profiler invocation without `--loop` is started once and left running for the whole duration and does not show growth.

## Relevant Code (Pyroscope)
- `ContinuousProfilingScheduler.schedulerTick()`:
  ```java
  profiler.stop();
  snapshot = profiler.dumpProfile(startTime, now);
  profiler.start();
  ```
- `AsyncProfilerDelegate.start()` (JFR path): constructs `start,...,lock=...,interval=...,file=...` command.
- `AsyncProfilerDelegate.stop()`: calls native `instance.stop()`.

## Relevant Code (async-profiler native)
`lockTracer.cpp`:
- `LockTracer::start` hooks `Unsafe.park` by re-registering its native entry with `RegisterNatives` (via `setUnsafeParkEntry`).
- `LockTracer::stop` restores the original `_orig_unsafe_park`.

Each start/stop cycle therefore performs two native method re-registrations (`Unsafe.park` -> hook, then hook -> original). Repeated frequently, this alters the method's native entry pointer repeatedly.

## Hypothesized Mechanism
1. Start cycle re-registers `Unsafe.park` to a hook function.
2. JVM invalidates / deoptimizes compiled methods that inline or call `Unsafe.park` (parking-heavy workload ensures hot paths).
3. New compilations are produced referencing the new entry.
4. On stop, native pointer restored → another wave of invalidations & recompilations.
5. Obsolete nmethods linger → cumulative growth in `Compiler.codelist` entries referencing `Unsafe.park`.

Amplifiers:
- Short upload interval (1s) → high churn frequency.
- Optional small code cache JVM flags accelerate saturation / visibility.
- Parking-heavy workload ensures `Unsafe.park` is hot, encouraging rapid recompilation each cycle.

## Refined Root Cause (HotSpot Internals)
Subsequent inspection of HotSpot sources and runtime evidence shows why the obsolete `Unsafe.park` nmethods linger instead of being promptly reclaimed:

1. Native re-registration path:
  Each restart toggles the native entry pointer of `Unsafe.park` (hook install / restore). In HotSpot this ultimately invokes `Method::set_native_function` which, if a compiled wrapper exists, calls `nm->make_not_entrant()` on the current compiled native wrapper.
2. State transition only (no immediate free):
  `nmethod::make_not_entrant()` patches the verified entry, unlinks the nmethod from the `Method`, and marks it `not_entrant`, but leaves its memory in the code cache for later sweeping.
3. Native wrapper exclusion from cold heuristic:
  In `nmethod::is_cold()` the first guard returns `false` for `is_native_method()`. Thus native wrappers never participate in the heuristic early reclamation path that removes other non-entrant Java nmethods when they become cold.
4. Conservative on-stack assumption:
  Because invalidation is initiated outside a safepoint, the code may conservatively mark the nmethod as maybe-on-stack, further delaying eligibility for reclamation until later safepoint/sweeper passes prove quiescence.
5. Restart frequency outpaces sweeper cadence:
  Sweeper / unloading cycles are triggered by allocation thresholds and GC epochs. Per-second invalidations generate new native wrappers faster than sweeping cycles reclaim prior generations (which are excluded from cold heuristic anyway), yielding a linear accumulation of `not_entrant` native `Unsafe.park` wrappers.
6. Diagnostic visibility:
  `jcmd ... Compiler.codelist` enumerates all nmethods (active + not_entrant + zombies until freed). Therefore each new retired wrapper permanently increases the count until an eventual, much later reclamation (often never within the reproduction window), producing the observed monotonic rise.

Net effect: growth rate ≈ restart rate; aggressive sweeping and forced GC reclaim other code but scarcely affect the pile of retired native `Unsafe.park` wrappers, so their count does not decline even under code cache pressure (eventually leading to compilation disabling when the cache fills).

### Why Aggressive Sweeper Settings Didn't Help
Even with small code cache and flags to trigger frequent sweeping, native wrappers are shielded from cold eviction by the `is_native_method()` early return and by conservative on-stack marking. Other nmethods are reclaimed, but the retired `Unsafe.park` wrappers accumulate until hard capacity limits are reached.

### Direct Evidence (LogCompilation)
Observed with `-XX:+LogCompilation` (example):
```
95470 2643     n 0       jdk.internal.misc.Unsafe::park (native)   made not entrant
95624 2644     n 0       jdk.internal.misc.Unsafe::park (native)
```
Each restart produces a pair of lines: first the prior native wrapper is marked "made not entrant"; shortly after, a freshly compiled native wrapper (`n 0 ...`) is installed. Repeating this cycle increments the total number of historical entries without reclaiming earlier ones.

## Conclusion
The accumulating `Unsafe.park` entries are caused by frequent native method re-registration that repeatedly invokes `Method::set_native_function`, forcing the existing compiled native wrapper to `make_not_entrant()`. Because native wrappers are excluded from the cold nmethod heuristic and are conservatively considered maybe-on-stack, they linger in the code cache and remain listed by `Compiler.codelist`. Pyroscope's periodic restart loop and async-profiler's `--loop` option both create the necessary churn; eliminating the rapid restart (single continuous session) prevents the growth.