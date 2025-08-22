package com.example.pyroscope;

import java.time.Instant;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;

/**
 * Minimal reproduction workload: simply parks in a tight loop for the given
 * duration.
 */
public class ReproductionWorkload {
    private static final long PARK_NANOS = TimeUnit.MILLISECONDS.toNanos(1); // 1 ms

    public ReproductionWorkload() {
    }

    public void run(long runSeconds) {
        Instant end = Instant.now().plusSeconds(runSeconds);
        while (Instant.now().isBefore(end)) {
            LockSupport.parkNanos(PARK_NANOS);
        }
    }
}
