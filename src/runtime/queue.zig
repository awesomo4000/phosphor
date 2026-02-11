const std = @import("std");
const Allocator = std.mem.Allocator;

/// Thread-safe MPSC (multi-producer, single-consumer) queue.
/// Mutex-based for simplicity - can optimize to lock-free later if needed.
///
/// Designed for testability:
/// - `push()` for producers (input thread, timers, etc.)
/// - `drain()` for consumer (main loop)
/// - `pushSlice()` for test injection
/// - `len()` for assertions
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        items: std.ArrayListUnmanaged(T) = .{},
        allocator: Allocator,
        mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        /// Push a single item (thread-safe)
        pub fn push(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.items.append(self.allocator, item) catch {};
        }

        /// Push multiple items (thread-safe) - useful for test injection
        pub fn pushSlice(self: *Self, items: []const T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.items.appendSlice(self.allocator, items) catch {};
        }

        /// Drain all items into provided buffer, returns slice of drained items.
        /// Clears the queue. (thread-safe)
        pub fn drain(self: *Self, out: []T) []T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const count = @min(self.items.items.len, out.len);
            @memcpy(out[0..count], self.items.items[0..count]);
            self.items.clearRetainingCapacity();
            return out[0..count];
        }

        /// Drain all items, allocating the result (thread-safe)
        pub fn drainAlloc(self: *Self, allocator: Allocator) ![]T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const result = try allocator.dupe(T, self.items.items);
            self.items.clearRetainingCapacity();
            return result;
        }

        /// Get current length (thread-safe) - useful for tests
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len;
        }

        /// Check if empty (thread-safe)
        pub fn isEmpty(self: *Self) bool {
            return self.len() == 0;
        }

        /// Clear all items (thread-safe)
        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.items.clearRetainingCapacity();
        }

        /// Pop a single item if available (thread-safe)
        /// Useful for non-batched processing
        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.pop();
        }

        /// Try to pop without blocking - same as pop() for mutex impl
        /// but named for API clarity when we switch to lock-free
        pub fn tryPop(self: *Self) ?T {
            return self.pop();
        }
    };
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "Queue: basic push and drain" {
    var q = Queue(u32).init(std.testing.allocator);
    defer q.deinit();

    q.push(1);
    q.push(2);
    q.push(3);

    try std.testing.expectEqual(@as(usize, 3), q.len());

    var buf: [10]u32 = undefined;
    const drained = q.drain(&buf);

    try std.testing.expectEqual(@as(usize, 3), drained.len);
    try std.testing.expectEqual(@as(u32, 1), drained[0]);
    try std.testing.expectEqual(@as(u32, 2), drained[1]);
    try std.testing.expectEqual(@as(u32, 3), drained[2]);
    try std.testing.expect(q.isEmpty());
}

test "Queue: pushSlice for test injection" {
    var q = Queue(u32).init(std.testing.allocator);
    defer q.deinit();

    const inject = [_]u32{ 10, 20, 30 };
    q.pushSlice(&inject);

    try std.testing.expectEqual(@as(usize, 3), q.len());

    var buf: [10]u32 = undefined;
    const drained = q.drain(&buf);
    try std.testing.expectEqual(@as(u32, 10), drained[0]);
}

test "Queue: pop single items" {
    var q = Queue(u32).init(std.testing.allocator);
    defer q.deinit();

    q.push(1);
    q.push(2);

    try std.testing.expectEqual(@as(u32, 2), q.pop().?);
    try std.testing.expectEqual(@as(u32, 1), q.pop().?);
    try std.testing.expectEqual(@as(?u32, null), q.pop());
}

test "Queue: drainAlloc" {
    var q = Queue(u32).init(std.testing.allocator);
    defer q.deinit();

    q.push(1);
    q.push(2);

    const drained = try q.drainAlloc(std.testing.allocator);
    defer std.testing.allocator.free(drained);

    try std.testing.expectEqual(@as(usize, 2), drained.len);
    try std.testing.expect(q.isEmpty());
}

test "Queue: thread safety" {
    var q = Queue(u32).init(std.testing.allocator);
    defer q.deinit();

    const num_threads = 4;
    const items_per_thread = 100;

    var threads: [num_threads]std.Thread = undefined;

    // Spawn producer threads
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(queue: *Queue(u32), thread_id: usize) void {
                for (0..items_per_thread) |j| {
                    queue.push(@intCast(thread_id * 1000 + j));
                }
            }
        }.run, .{ &q, i });
    }

    // Wait for all producers
    for (&threads) |*t| {
        t.join();
    }

    // Should have all items
    try std.testing.expectEqual(@as(usize, num_threads * items_per_thread), q.len());
}
