# Pyroscope codecache leak reproduction

We've observed code cache usage growing over time after deploying Pyroscope, eventually exhausting the code cache. We've been able to pinpoint this to the use of lock profiling in Pyroscope, which appears to keep old references to `Unsafe.park` alive in the code cache. In our production environments, we've seen the number of entries for `Unsafe.park` in the `Compiler.codelist` jcmd command grow to more than 300K. 

This project is a minimal, self-contained reproduction of the issue, demonstrating the code cache growth when using the Pyroscope java agent. Originally we believed the issue did **not** occur with async-profiler directly; however, it can be reproduced with async-profiler as well if you mimic Pyroscope's periodic start/stop cycle using its `--loop` option (e.g. `--loop 1s`). A single long-lived async-profiler session (started once and allowed to run) does **not** show the growth; the rapid restart pattern does.

## Observed vs Expected Behavior

Problematic (Pyroscope lock profiling enabled OR async-profiler with `--loop 1s`): the number of `Unsafe.park` occurrences reported by `Compiler.codelist` (counted by the monitor) steadily increases over time:

```
[monitor] Unsafe.park codelist occurrences: 0 | non-profiled nmethods:462K(0%) | profiled nmethods:3127K(2%) | non-nmethods:1923K(25%) | total:5512K(2%)
[monitor] Unsafe.park codelist occurrences: 1 | non-profiled nmethods:560K(0%) | profiled nmethods:3151K(2%) | non-nmethods:1359K(18%) | total:5070K(2%)
[monitor] Unsafe.park codelist occurrences: 1 | non-profiled nmethods:628K(0%) | profiled nmethods:3879K(3%) | non-nmethods:1932K(25%) | total:6439K(2%)
[monitor] Unsafe.park codelist occurrences: 2 | non-profiled nmethods:675K(0%) | profiled nmethods:3948K(3%) | non-nmethods:1386K(18%) | total:6009K(2%)
[monitor] Unsafe.park codelist occurrences: 3 | non-profiled nmethods:677K(0%) | profiled nmethods:3962K(3%) | non-nmethods:1386K(18%) | total:6025K(2%)
[monitor] Unsafe.park codelist occurrences: 4 | non-profiled nmethods:682K(0%) | profiled nmethods:3999K(3%) | non-nmethods:1386K(18%) | total:6067K(2%)
[monitor] Unsafe.park codelist occurrences: 5 | non-profiled nmethods:693K(0%) | profiled nmethods:3999K(3%) | non-nmethods:1386K(18%) | total:6078K(2%)
[monitor] Unsafe.park codelist occurrences: 6 | non-profiled nmethods:704K(0%) | profiled nmethods:4010K(3%) | non-nmethods:1386K(18%) | total:6100K(2%)
[monitor] Unsafe.park codelist occurrences: 7 | non-profiled nmethods:706K(0%) | profiled nmethods:4052K(3%) | non-nmethods:1386K(18%) | total:6144K(2%)
[monitor] Unsafe.park codelist occurrences: 8 | non-profiled nmethods:708K(0%) | profiled nmethods:4065K(3%) | non-nmethods:1386K(18%) | total:6159K(2%)
```

Expected / Baseline: when running either without any agent (`--agent none`) or with a single continuous async-profiler session (`--agent async-profiler`) under equivalent settings (no periodic restart), the count stabilizes quickly (typically at 1) and does **not** continue to grow.

How to compare quickly:
```bash
# Pyroscope (expect growing counts)
./scripts/run.sh --agent pyroscope --duration 120

# Async-profiler single run (expect stable count ~1)
./scripts/run.sh --agent async-profiler --duration 120

# No agent (expect stable count ~1)
./scripts/run.sh --agent none --duration 120

# Async-profiler with looped 1s sessions (expect growing counts similar to Pyroscope)
# (Demonstrates that the periodic restart cycle itself triggers accumulation)
./scripts/run.sh --agent async-profiler --loop=1s --duration 120
```

Interpretation: the repeated start/stop cycle (Pyroscope's continuous upload loop or async-profiler's `--loop`) triggers repeated re-registration of the native `Unsafe.park` method, accumulating obsolete compiled native wrappers that remain visible to `Compiler.codelist`. A single uninterrupted async-profiler run does not exhibit this growth.

## Project Structure

```
pyroscope-codecache-leak-reproduction
├── build.gradle.kts
├── README.md
├── scripts/
│   └── run.sh          # unified runner (build + choose agent)
└── src/main/java/com/example/pyroscope/
    ├── Main.java       # entry point + code cache monitor
    └── ReproductionWorkload.java  # tight LockSupport.parkNanos loop
```

## Requirements

* Java 21 (Gradle builds with `java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }` implicitly via sourceCompatibility)
* Gradle (wrapper provided `./gradlew`)

## Running the Workload

Single script: `scripts/run.sh`

Basic (no agent):
```bash
./scripts/run.sh --duration 60
```

Attach Pyroscope agent:
```bash
./scripts/run.sh --agent pyroscope --duration 60
```

Attach async-profiler (JFR output by default):
```bash
./scripts/run.sh --agent async-profiler --duration 60
```

Show help / options:
```bash
./scripts/run.sh --help
```

### Key Flags

| Flag                                        | Purpose                                                                                                                             |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `--agent <none\|pyroscope\|async-profiler>` | Choose profiling mode (alias `ap` accepted).                                                                                        |
| `--duration <sec>`                          | Sets `-Dwork.runSeconds` (default 300).                                                                                             |
| `--small-codecache`                         | Applies aggressive small code heap sizes to accelerate exhaustion (`-XX:NonProfiledCodeHeapSize=768K -XX:ProfiledCodeHeapSize=4M`). |

`JAVA_OPTS` env var is appended to the JVM invocation (e.g. to add `-XX:+UnlockDiagnosticVMOptions`).

### Agent Environment Variables

Pyroscope:
* `PYROSCOPE_APPLICATION_NAME` (default `code-cache-lock`)
* `PYROSCOPE_SERVER_ADDRESS` (default `http://localhost:4040`)
* `PYROSCOPE_FORMAT` (default `jfr`)
* `PYROSCOPE_PROFILER_LOCK` (default `10ms`)
* `PYROSCOPE_UPLOAD_INTERVAL` (default `1s`)

Async-profiler:
* `AP_FORMAT` (`jfr|flamegraph|collapsed`, default `jfr`)
* `SAMPLE_INTERVAL` (default `10ms`, passed as `interval=` to `event=itimer`)
* `LOCK_THRESHOLD` (default `10ms`, passed as `lock=`)
* `OUT_FILE` (optional override; defaults to `lock.jfr` / `lock.html` / `lock.<format>`)

Examples:
```bash
# Flamegraph with async-profiler lock + CPU sampling
AP_FORMAT=flamegraph ./scripts/run.sh --agent async-profiler --duration 45

# Increase sampling interval (lower CPU) & custom output
SAMPLE_INTERVAL=50ms OUT_FILE=locks.jfr ./scripts/run.sh --agent async-profiler --duration 120

# Pyroscope with custom lock threshold
PYROSCOPE_PROFILER_LOCK=20ms ./scripts/run.sh --agent pyroscope --duration 90

# Constrain code cache to amplify behavior
JAVA_OPTS="-XX:+UnlockDiagnosticVMOptions" ./scripts/run.sh --small-codecache --agent ap --duration 120
```

### What the Workload Does

`ReproductionWorkload` simply performs a tight loop of `LockSupport.parkNanos(1ms)` for the configured duration. This encourages repeated interaction with the parking path while remaining lightweight.

`Main` launches a background monitor thread that every second:
1. Calls the DiagnosticCommand MBeans (`compilerCodelist`) and counts occurrences of `Unsafe.park` among compiled methods.
2. Summarizes code cache segment usage via `compilerCodecache`.

Sample monitor line:
```
[monitor] Unsafe.park codelist occurrences: 42 | non-profiled nmethods:512K(40%) | profiled nmethods:1024K(50%) | total:1536K(46%)
```

If the diagnostic commands aren’t available (e.g. missing `-XX:+UnlockDiagnosticVMOptions` on some JVMs), the monitor reports a fallback error label but continues running.

Goal: Observe relative code cache pressure and whether agents correlate with higher counts of compiled artifacts referencing `Unsafe.park`.

### Async-profiler vs Pyroscope Parity

The chosen defaults mirror a “lock + CPU sampling” configuration in both tools (10ms sampling & 10ms lock threshold). Adjust environment variables (above) to align settings for apples-to-apples comparisons.

#### Async-profiler loop reproduction

To explicitly reproduce the growth using async-profiler alone (without Pyroscope), run it in short looping mode so it restarts profiling every second, mimicking Pyroscope's snapshot/upload cadence:

```bash
./scripts/run.sh --agent async-profiler --loop=1s --duration 90
```

Omit `--loop` for a single continuous session (baseline, stable `Unsafe.park` count). You can choose another interval, e.g. `--loop=2s`.

## Build Manually (Optional)

The script performs `./gradlew -q clean build` automatically. Manual build:
```bash
./gradlew clean build
```
Outputs:
* Thin app jar: `build/libs/pyroscope-codecache-leak-reproduction-1.0-SNAPSHOT.jar`
* Agent jars copied to: `build/agents/`
    * `pyroscope-agent-<ver>.jar`
    * `async-profiler-<ver>.jar` (native library pre-extracted by build into `build/async-profiler-extracted/<platform>-<arch>/`)