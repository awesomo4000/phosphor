const std = @import("std");

/// Simple startup timer for debugging initialization delays.
/// Stores timestamps that can be displayed after startup completes.
/// Set `enabled = true` to activate; when disabled, mark() is a no-op.
pub const StartupTimer = struct {
    const MAX_EVENTS = 64;

    events: [MAX_EVENTS]Event = undefined,
    count: usize = 0,
    start_time: i128 = 0,
    initialized: bool = false,
    enabled: bool = false,

    pub const Event = struct {
        label: []const u8,
        time_ns: i128,
    };

    pub fn markEvent(self: *StartupTimer, label: []const u8) void {
        if (!self.enabled) return;

        // Lazy init on first mark
        if (!self.initialized) {
            self.start_time = std.time.nanoTimestamp();
            self.initialized = true;
        }
        if (self.count >= MAX_EVENTS) return;
        self.events[self.count] = .{
            .label = label,
            .time_ns = std.time.nanoTimestamp(),
        };
        self.count += 1;
    }

    /// Get elapsed time in microseconds from start to a specific event
    pub fn elapsedUs(self: *const StartupTimer, index: usize) i64 {
        if (index >= self.count) return 0;
        return @intCast(@divTrunc(self.events[index].time_ns - self.start_time, 1000));
    }

    /// Get delta time in microseconds between two consecutive events
    pub fn deltaUs(self: *const StartupTimer, index: usize) i64 {
        if (index >= self.count) return 0;
        if (index == 0) {
            return @intCast(@divTrunc(self.events[0].time_ns - self.start_time, 1000));
        }
        return @intCast(@divTrunc(self.events[index].time_ns - self.events[index - 1].time_ns, 1000));
    }

    /// Print all events to log
    pub fn dumpToLog(self: *const StartupTimer, log: anytype) !void {
        try log.append("=== Startup Timing ===");
        for (0..self.count) |i| {
            const elapsed = self.elapsedUs(i);
            const delta = self.deltaUs(i);
            try log.print("{d:>8}us (+{d:>6}us) {s}", .{ elapsed, delta, self.events[i].label });
        }
        try log.append("======================");
    }

    pub fn resetTimer(self: *StartupTimer) void {
        self.count = 0;
        self.initialized = false;
    }
};

// Global timer instance - zero-initialized, lazy start on first mark
pub var global_timer: StartupTimer = .{};

pub fn mark(label: []const u8) void {
    global_timer.markEvent(label);
}

pub fn reset() void {
    global_timer.resetTimer();
}

pub fn enable() void {
    global_timer.enabled = true;
}

pub fn isEnabled() bool {
    return global_timer.enabled;
}
