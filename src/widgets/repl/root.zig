pub const Repl = @import("repl.zig").Repl;
pub const History = @import("repl.zig").History;
pub const LineBuffer = @import("line_buffer.zig").LineBuffer;

test {
    _ = @import("repl.zig");
    _ = @import("line_buffer.zig");
}
