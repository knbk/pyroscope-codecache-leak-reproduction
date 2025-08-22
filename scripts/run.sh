#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
cd "$PROJECT_ROOT"

AGENT="none" # none|pyroscope|async-profiler (ap alias)
SMALL_CODECACHE=false
DURATION="" # seconds
LOOP_INTERVAL="" # for async-profiler --loop (CLI flag only)
POSITIONAL=()

show_help() {
  cat <<EOF
Minimal runner for code cache + lock profiling reproduction.

Usage: $0 [--agent <none|pyroscope|async-profiler>] [--small-codecache] [--duration <sec>] [--loop[=<interval>]] [--] [app args]

Flags:
  --agent (-a)        Select profiling agent (default: none)
  --small-codecache   Apply aggressive small code cache JVM flags
  --duration (-d)     Run duration in seconds (sets -Dwork.runSeconds)
  --loop[=<interval>] Enable async-profiler periodic restart (default interval 1s if omitted)
  --help (-h)         Show this help

Environment:
  JAVA_OPTS           Extra JVM options appended before execution

Agent-specific env (common defaults shown):
  Pyroscope: PYROSCOPE_APPLICATION_NAME, PYROSCOPE_SERVER_ADDRESS, PYROSCOPE_PROFILER_LOCK (10ms)
  Async-profiler: AP_FORMAT (jfr|flamegraph|collapsed), SAMPLE_INTERVAL (10ms), LOCK_THRESHOLD (10ms)

Examples:
  $0 --duration 60 --small-codecache
  AP_FORMAT=flamegraph $0 --agent async-profiler --duration=30
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent|-a)
      AGENT="${2:-}"; shift 2 ;;
    --agent=*)
      AGENT="${1#*=}"; shift ;;
    --small-codecache)
      SMALL_CODECACHE=true; shift ;;
    --duration|-d)
      DURATION="${2:-}"; shift 2 ;;
    --duration=*)
      DURATION="${1#*=}"; shift ;;
    --loop)
      # If next arg exists and is not another flag, treat as interval; else default 1s
      if [[ ${2:-} != "" && ${2:-} != -* ]]; then
        LOOP_INTERVAL="$2"; shift 2
      else
        LOOP_INTERVAL="1s"; shift
      fi ;;
    --loop=*)
      LOOP_INTERVAL="${1#*=}"; shift ;;
    --help|-h)
      show_help; exit 0 ;;
    --)
      shift; POSITIONAL+=("$@"); break ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

echo "Building project (Gradle)..." >&2
./gradlew -q clean build || { echo "Gradle build failed" >&2; exit 1; }

# Pick the main application jar from Gradle build output (libs/pyroscope-codecache-leak-reproduction-<ver>.jar)
JAR=$(ls -t build/libs/pyroscope-codecache-leak-reproduction-*.jar 2>/dev/null | grep -v '\-sources\|\-javadoc' | head -n1 || true)
if [[ -z "$JAR" ]]; then
  echo "Application jar not found (expected build/libs/pyroscope-codecache-leak-reproduction-*.jar)" >&2; exit 1
fi

if [[ -n "$DURATION" ]]; then
  if [[ ! $DURATION =~ ^[0-9]+$ ]]; then
    echo "--duration must be an integer number of seconds" >&2; exit 1
  fi
  JAVA_OPTS="${JAVA_OPTS:-} -Dwork.runSeconds=${DURATION}"
fi

if $SMALL_CODECACHE; then
  # Shrink nmethod code heap segments. Use aggressive (smaller) sizes by default;
  # keep the larger (previous) sizes only when using the Pyroscope agent.
  if [[ "$AGENT" == "pyroscope" ]]; then
    JAVA_OPTS="${JAVA_OPTS:-} -XX:NonProfiledCodeHeapSize=768K -XX:ProfiledCodeHeapSize=4M"
  else
    JAVA_OPTS="${JAVA_OPTS:-} -XX:NonProfiledCodeHeapSize=500K -XX:ProfiledCodeHeapSize=2500K"
  fi
fi

case "$AGENT" in
  none|"")
    echo "Running without agent" >&2
    exec java ${JAVA_OPTS:-} -jar "$JAR" "$@" ;;

  pyroscope)
    export PYROSCOPE_APPLICATION_NAME="${PYROSCOPE_APPLICATION_NAME:-code-cache-lock}"
    export PYROSCOPE_SERVER_ADDRESS="${PYROSCOPE_SERVER_ADDRESS:-http://localhost:4040}"
    export PYROSCOPE_FORMAT="${PYROSCOPE_FORMAT:-jfr}"
    export PYROSCOPE_PROFILER_LOCK="${PYROSCOPE_PROFILER_LOCK:-10ms}"
    export PYROSCOPE_UPLOAD_INTERVAL="${PYROSCOPE_UPLOAD_INTERVAL:-1s}"

    # Version from Gradle libs.versions.toml (already copied by copyAgents task into build/agents)
    # Derive version from copied jar filename (build/agents/pyroscope-agent-<ver>.jar)
    PYROSCOPE_VERSION=$(basename build/agents/pyroscope-agent-*.jar 2>/dev/null | sed -E 's/pyroscope-agent-(.*)\.jar/\1/')
    AGENT_JAR="build/agents/pyroscope-agent-${PYROSCOPE_VERSION}.jar"
    if [[ ! -f "$AGENT_JAR" ]]; then
      echo "Pyroscope agent jar not found at $AGENT_JAR (did copyAgents run?)." >&2; exit 1
    fi
    echo "Pyroscope agent: $AGENT_JAR (lock=${PYROSCOPE_PROFILER_LOCK}) smallCodeCache=$SMALL_CODECACHE" >&2
    exec java ${JAVA_OPTS:-} -javaagent:"$AGENT_JAR" -jar "$JAR" "$@" ;;

  async-profiler|ap)
    AP_FORMAT=${AP_FORMAT:-jfr}
    SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-10ms}
    LOCK_THRESHOLD=${LOCK_THRESHOLD:-10ms}

    AP_VERSION=$(basename build/agents/async-profiler-*.jar 2>/dev/null | sed -E 's/async-profiler-(.*)\.jar/\1/')
    AP_JAR="build/agents/async-profiler-${AP_VERSION}.jar"
    if [[ ! -f "$AP_JAR" ]]; then
      echo "Async-profiler jar not found at $AP_JAR (did copyAgents run?)." >&2; exit 1
    fi

    UNAME_S=$(uname -s | tr '[:upper:]' '[:lower:]')
    UNAME_M=$(uname -m)
    case "$UNAME_S" in
      linux) PLATFORM_DIR="linux" ;;
      darwin) PLATFORM_DIR="macos" ;;
      *) echo "Unsupported OS: $UNAME_S" >&2; exit 1 ;;
    esac
    case "$UNAME_M" in
      x86_64|amd64) ARCH="x64" ;;
      aarch64|arm64) ARCH="arm64" ;;
      *) ARCH="x64" ;;
    esac

    EXTRACT_DIR="build/async-profiler-extracted/${PLATFORM_DIR}-${ARCH}"
    LIB_PATH="$EXTRACT_DIR/libasyncProfiler.so"
    if [[ ! -f "$LIB_PATH" ]]; then
      echo "Expected pre-extracted async-profiler library missing at $LIB_PATH. Run './gradlew extractAsyncProfiler' (or build) first." >&2
      exit 1
    fi

    if [[ -n "${OUT_FILE:-}" ]]; then :; else
      case "$AP_FORMAT" in
        jfr) OUT_FILE="lock.jfr" ;;
        flamegraph) OUT_FILE="lock.html" ;;
        *) OUT_FILE="lock.${AP_FORMAT}" ;;
      esac
    fi
    # Apply loop only if provided via --loop flag.
    if [[ -n "$LOOP_INTERVAL" ]]; then
      LOOP_CLAUSE=",loop=${LOOP_INTERVAL}"
    else
      LOOP_CLAUSE=""
    fi
    AP_OPTS="start,event=itimer,interval=${SAMPLE_INTERVAL},lock=${LOCK_THRESHOLD},jstackdepth=2048,file=${OUT_FILE}${LOOP_CLAUSE}"
    echo "Async-profiler lib: $LIB_PATH version=$AP_VERSION smallCodeCache=$SMALL_CODECACHE" >&2
    if [[ -n "$LOOP_INTERVAL" ]]; then
      echo "Options: $AP_OPTS (format=$AP_FORMAT, loop every $LOOP_INTERVAL)" >&2
    else
      echo "Options: $AP_OPTS (format=$AP_FORMAT, single session)" >&2
    fi
    exec java ${JAVA_OPTS:-} -agentpath:"$LIB_PATH"="$AP_OPTS" -jar "$JAR" "$@" ;;

  *)
    echo "Unknown --agent value: $AGENT" >&2
    show_help; exit 1 ;;
esac
