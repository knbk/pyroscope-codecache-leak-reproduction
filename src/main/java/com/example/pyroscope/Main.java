package com.example.pyroscope;

import java.util.concurrent.atomic.AtomicBoolean;
import java.lang.management.ManagementFactory;
import javax.management.MBeanServer;
import javax.management.ObjectName;
import java.util.regex.Pattern;
import java.util.regex.Matcher;

/**
 * Entry point: parses params, sets up monitor, launches reproduction workload.
 */
public class Main {
    private static final long RUN_SECONDS = Long.getLong("work.runSeconds", 300L);

    private static final AtomicBoolean running = new AtomicBoolean(true);
    private static final long MONITOR_INTERVAL_MS = Long.getLong("monitor.intervalMillis", 1_000L);

    public static void main(String[] args) throws InterruptedException {
        for (String a : args) {
            if ("--help".equals(a) || "-h".equals(a)) {
                printUsage();
                return;
            }
        }
        System.out.printf("Starting workload: runSeconds=%d%n", RUN_SECONDS);
        startMonitor();
        ReproductionWorkload workload = new ReproductionWorkload();
        workload.run(RUN_SECONDS);
        running.set(false); // signal monitor to exit
        System.out.println("Workload finished.");
    }

    private static void printUsage() {
        System.out.println("Usage: java [JVM opts] com.example.pyroscope.Main [--help|-h]\n" +
                "Purpose: Minimal code cache reproduction: single thread repeatedly parks.\n" +
                "System properties (set with -Dname=value):\n" +
                "  work.runSeconds         (long, default 300)  Total run time in seconds.\n" +
                "  monitor.intervalMillis  (long, default 1000) Interval for code cache Unsafe.park count logging.\n" +
                "JIT / diagnostic helpful flags: -XX:+UnlockDiagnosticVMOptions\n" +
                "Example: java -XX:+UnlockDiagnosticVMOptions -Dwork.runSeconds=60 -Dmonitor.intervalMillis=1000 com.example.pyroscope.Main\n");
    }

    private static void startMonitor() {
        Thread monitor = new Thread(() -> {
            while (running.get()) {
                int count = countUnsafeParkInCodeCache();
                String ccStatus = codeCacheStatus();
                if (count >= 0) {
                    System.out.printf("[monitor] Unsafe.park codelist occurrences: %d | %s%n", count, ccStatus);
                } else {
                    System.out.printf("[monitor] Failed compilerCodelist (-XX:+UnlockDiagnosticVMOptions?) | %s%n",
                            ccStatus);
                }
                try {
                    Thread.sleep(MONITOR_INTERVAL_MS);
                } catch (InterruptedException ignored) {
                }
            }
        }, "codecache-monitor");
        monitor.setDaemon(true);
        monitor.start();
    }

    /**
     * Invoke the DiagnosticCommand MBean's compilerCodelist (jcmd
     * Compiler.codelist) and count
     * how many compiled methods reference Unsafe.park. Returns -1 on failure.
     */
    private static int countUnsafeParkInCodeCache() {
        try {
            MBeanServer server = ManagementFactory.getPlatformMBeanServer();
            ObjectName on = new ObjectName("com.sun.management:type=DiagnosticCommand");
            String op = "compilerCodelist"; // maps from jcmd "Compiler.codelist"
            String[] args = new String[0];
            String[] sig = new String[] { "[Ljava.lang.String;" };
            String output = (String) server.invoke(on, op, new Object[] { args }, sig);
            Matcher m = Pattern.compile("\\bUnsafe\\.park\\b").matcher(output);
            int count = 0;
            while (m.find())
                count++;
            return count;
        } catch (Throwable t) {
            return -1;
        }
    }

    private static String codeCacheStatus() {
        try {
            MBeanServer server = ManagementFactory.getPlatformMBeanServer();
            ObjectName on = new ObjectName("com.sun.management:type=DiagnosticCommand");
            String[] sig = new String[] { "[Ljava.lang.String;" };
            // Official DiagnosticCommand name for jcmd Compiler.codecache
            String output = (String) server.invoke(on, "compilerCodecache", new Object[] { new String[0] }, sig);
            return summarizeCodeCache(output);
        } catch (Throwable t) {
            return "codecache: error " + t.getClass().getSimpleName();
        }
    }

    private static String summarizeCodeCache(String output) {
        try {
            java.io.BufferedReader br = new java.io.BufferedReader(new java.io.StringReader(output));
            String line;
            boolean first = true;
            int matched = 0;
            long totalUsed = 0, totalSize = 0;
            StringBuilder sb = new StringBuilder();
            while ((line = br.readLine()) != null) {
                String trimmed = line.trim();
                if (trimmed.startsWith("CodeHeap '") && trimmed.contains("size=") && trimmed.contains(" used=")) {
                    // Example: CodeHeap 'non-profiled nmethods': size=119168Kb used=788Kb
                    // max_used=788Kb free=118379Kb
                    int nameStart = trimmed.indexOf('\'') + 1;
                    int nameEnd = trimmed.indexOf('\'', nameStart);
                    if (nameStart <= 0 || nameEnd <= nameStart)
                        continue;
                    String name = trimmed.substring(nameStart, nameEnd);
                    long size = extractNumber(trimmed, "size=");
                    long used = extractNumber(trimmed, "used=");
                    if (size > 0 && used >= 0) {
                        totalUsed += used;
                        totalSize += size;
                        int pct = (int) (used * 100 / size);
                        if (!first)
                            sb.append(" | ");
                        else
                            first = false;
                        sb.append(name).append(':').append(used).append('K').append('(').append(pct).append("%)");
                        matched++;
                    }
                }
            }
            if (matched > 0 && totalSize > 0) {
                int tpct = (int) (totalUsed * 100 / totalSize);
                sb.append(" | total:").append(totalUsed).append('K').append('(').append(tpct).append("%)");
                return sb.toString();
            }
            return "codecache: no-heap-lines";
        } catch (Throwable t) {
            return "codecache: parse-error";
        }
    }

    private static long extractNumber(String line, String key) {
        int idx = line.indexOf(key);
        if (idx < 0)
            return -1;
        idx += key.length();
        int end = idx;
        while (end < line.length() && Character.isDigit(line.charAt(end)))
            end++;
        try {
            return Long.parseLong(line.substring(idx, end));
        } catch (Exception e) {
            return -1;
        }
    }
}