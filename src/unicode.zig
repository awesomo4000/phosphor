/// Unicode text utilities for terminal display width calculation.
///
/// This module wraps the zg library to provide grapheme-aware display width
/// calculation, essential for correct cursor positioning and text layout
/// in terminals with Unicode content (emoji, CJK, combining marks, etc.).
///
/// Usage:
///   // Initialize once at app startup
///   try phosphor.unicode.init(allocator);
///   defer phosphor.unicode.deinit(allocator);
///
///   // Use anywhere without passing state around
///   const width = phosphor.unicode.strWidth("Hello 👨‍👩‍👧");  // returns 8
///
const std = @import("std");
const Allocator = std.mem.Allocator;

// Re-export zg DisplayWidth type for advanced usage
pub const DisplayWidth = @import("zg");

/// Global DisplayWidth instance, initialized once.
/// Thread-safe for reads after initialization.
var global_dw: ?DisplayWidth = null;

/// Initialize the Unicode display width calculator.
/// Called automatically by the phosphor runtime - no need to call directly.
pub fn init(allocator: Allocator) !void {
    if (global_dw != null) return; // Already initialized
    global_dw = try DisplayWidth.init(allocator);
}

/// Deinitialize and free resources.
/// Called automatically by the phosphor runtime - no need to call directly.
pub fn deinit(allocator: Allocator) void {
    if (global_dw) |*dw| {
        dw.deinit(allocator);
    }
    global_dw = null;
}

/// Returns the display width of a string in terminal columns.
/// Handles grapheme clusters correctly (emoji ZWJ sequences, combining marks, etc.).
///
/// Examples:
///   strWidth("Hello")        // 5
///   strWidth("Hello 😊")     // 8  (emoji is width 2)
///   strWidth("👨‍👩‍👧")           // 2  (family emoji, single grapheme)
///   strWidth("café")         // 4
///   strWidth("cafe\u{0301}") // 4  (combining accent)
///   strWidth("你好")          // 4  (CJK, each char width 2)
///
/// Returns 0 if not initialized (fails gracefully).
pub fn strWidth(str: []const u8) usize {
    if (global_dw) |dw| {
        return dw.strWidth(str);
    }
    // Fallback: assume 1 byte = 1 column (wrong for Unicode, but better than crashing)
    return str.len;
}

/// Returns the display width of a single Unicode codepoint.
/// Returns: -1 for control chars, 0 for combining/zero-width, 1 or 2 for normal chars.
pub fn codePointWidth(cp: u21) i4 {
    if (global_dw) |dw| {
        return dw.codePointWidth(cp);
    }
    // Fallback
    if (cp < 32 or (cp >= 0x7F and cp < 0xA0)) return -1;
    return 1;
}

/// Check if the module has been initialized.
pub fn isInitialized() bool {
    return global_dw != null;
}

/// Get direct access to the DisplayWidth instance for advanced usage.
/// Returns null if not initialized.
pub fn getDisplayWidth() ?*const DisplayWidth {
    if (global_dw) |*dw| {
        return dw;
    }
    return null;
}

// ─────────────────────────────────────────────────────────────
// Unicode String Wrapper
// ─────────────────────────────────────────────────────────────

/// A grapheme handle - lightweight reference into a source string.
/// Use `.slice()` to get the actual bytes.
pub const Grapheme = struct {
    offset: usize,
    len: usize,

    /// Get the bytes of this grapheme from the source string.
    pub fn slice(self: Grapheme, src: []const u8) []const u8 {
        return src[self.offset..][0..self.len];
    }
};

/// Unicode string wrapper providing grapheme-aware operations.
/// This is a lightweight view - no allocation, just wraps the source bytes.
pub const Unicode = struct {
    bytes: []const u8,

    /// Returns the display width in terminal columns.
    pub fn width(self: Unicode) usize {
        return strWidth(self.bytes);
    }

    /// Returns the number of graphemes (user-perceived characters).
    /// Note: O(n) - must iterate the entire string.
    pub fn len(self: Unicode) usize {
        const dw = global_dw orelse return self.bytes.len;
        var count: usize = 0;
        var iter = dw.graphemes.iterator(self.bytes);
        while (iter.next()) |_| count += 1;
        return count;
    }

    /// Returns a forward iterator over graphemes.
    pub fn iterator(self: Unicode) Iterator {
        return Iterator.init(self.bytes);
    }

    /// Returns a reverse iterator over graphemes (for backspace).
    pub fn reverseIterator(self: Unicode) ReverseIterator {
        return ReverseIterator.init(self.bytes);
    }

    /// Find a substring, returning its grapheme index if found at a grapheme boundary.
    /// Returns null if not found or if the match doesn't align with grapheme boundaries.
    ///
    /// Example: find("👩") in "👨‍👩‍👧" returns null (not a standalone grapheme).
    pub fn find(self: Unicode, needle: []const u8) ?usize {
        if (needle.len == 0) return 0;
        if (needle.len > self.bytes.len) return null;

        // Fast byte-level search first
        const byte_pos = std.mem.indexOf(u8, self.bytes, needle) orelse return null;

        // Verify it's at a grapheme boundary and count grapheme index
        const dw = global_dw orelse return null;
        var grapheme_idx: usize = 0;
        var iter = dw.graphemes.iterator(self.bytes);

        while (iter.next()) |g| {
            if (g.offset == byte_pos) {
                // Check if the needle matches complete graphemes
                var check_iter = dw.graphemes.iterator(self.bytes[byte_pos..]);
                var needle_byte_count: usize = 0;
                while (check_iter.next()) |ng| {
                    needle_byte_count += ng.len;
                    if (needle_byte_count == needle.len) {
                        // Needle ends exactly at a grapheme boundary
                        return grapheme_idx;
                    }
                    if (needle_byte_count > needle.len) {
                        // Needle ends in the middle of a grapheme
                        return null;
                    }
                }
                // Reached end of string
                if (needle_byte_count == needle.len) return grapheme_idx;
                return null;
            }
            if (g.offset > byte_pos) {
                // byte_pos is in the middle of a grapheme
                return null;
            }
            grapheme_idx += 1;
        }
        return null;
    }

    /// Find a substring, returning its byte offset if found at a grapheme boundary.
    /// Faster than find() when you need byte position, not grapheme index.
    pub fn findByte(self: Unicode, needle: []const u8) ?usize {
        if (needle.len == 0) return 0;
        if (needle.len > self.bytes.len) return null;

        const byte_pos = std.mem.indexOf(u8, self.bytes, needle) orelse return null;

        // Verify it's at a grapheme boundary
        const dw = global_dw orelse return byte_pos; // fallback: return byte pos anyway
        var iter = dw.graphemes.iterator(self.bytes);

        while (iter.next()) |g| {
            if (g.offset == byte_pos) {
                // Also verify needle ends at grapheme boundary
                const needle_end = byte_pos + needle.len;
                var end_iter = dw.graphemes.iterator(self.bytes);
                while (end_iter.next()) |eg| {
                    if (eg.offset == needle_end or eg.offset + eg.len == needle_end) {
                        return byte_pos;
                    }
                    if (eg.offset > needle_end) return null;
                }
                // needle_end is at string end
                if (needle_end == self.bytes.len) return byte_pos;
                return null;
            }
            if (g.offset > byte_pos) return null;
        }
        return null;
    }

    /// Check if the string contains a substring at a grapheme boundary.
    pub fn contains(self: Unicode, needle: []const u8) bool {
        return self.findByte(needle) != null;
    }

    /// Get the grapheme at a specific grapheme index.
    /// Note: O(n) - must iterate from the start.
    pub fn at(self: Unicode, index: usize) ?Grapheme {
        var iter = self.iterator();
        var i: usize = 0;
        while (iter.next()) |g| {
            if (i == index) return g;
            i += 1;
        }
        return null;
    }

    /// Collect all graphemes into an array.
    /// Caller owns the returned slice and must free it.
    pub fn collect(self: Unicode, allocator: Allocator) ![]Grapheme {
        var list: std.ArrayListUnmanaged(Grapheme) = .empty;
        errdefer list.deinit(allocator);

        var iter = self.iterator();
        while (iter.next()) |g| {
            try list.append(allocator, g);
        }
        return list.toOwnedSlice(allocator);
    }

    /// Forward grapheme iterator.
    pub const Iterator = struct {
        bytes: []const u8,
        pos: usize,

        pub fn init(bytes: []const u8) Iterator {
            return .{ .bytes = bytes, .pos = 0 };
        }

        pub fn next(self: *Iterator) ?Grapheme {
            if (self.pos >= self.bytes.len) return null;

            const dw = global_dw orelse {
                // Fallback: one byte = one grapheme (wrong but won't crash)
                const g = Grapheme{ .offset = self.pos, .len = 1 };
                self.pos += 1;
                return g;
            };

            var iter = dw.graphemes.iterator(self.bytes[self.pos..]);
            if (iter.next()) |zg_grapheme| {
                const g = Grapheme{
                    .offset = self.pos,
                    .len = zg_grapheme.len,
                };
                self.pos += zg_grapheme.len;
                return g;
            }
            return null;
        }
    };

    /// Reverse grapheme iterator (for backspace/delete backward).
    pub const ReverseIterator = struct {
        bytes: []const u8,
        pos: usize,

        pub fn init(bytes: []const u8) ReverseIterator {
            return .{ .bytes = bytes, .pos = bytes.len };
        }

        pub fn next(self: *ReverseIterator) ?Grapheme {
            if (self.pos == 0) return null;

            const dw = global_dw orelse {
                // Fallback: one byte = one grapheme
                self.pos -= 1;
                return Grapheme{ .offset = self.pos, .len = 1 };
            };

            var iter = dw.graphemes.reverseIterator(self.bytes[0..self.pos]);
            if (iter.prev()) |zg_grapheme| {
                self.pos = zg_grapheme.offset;
                return Grapheme{
                    .offset = zg_grapheme.offset,
                    .len = zg_grapheme.len,
                };
            }
            return null;
        }
    };
};

/// Create a Unicode wrapper for grapheme-aware string operations.
///
/// Example:
///   const u = phosphor.unicode("Hello 👨‍👩‍👧");
///   const w = u.width();       // 8
///   const n = u.len();         // 7 graphemes
///   var iter = u.iterator();   // iterate graphemes
///
pub fn unicode(str: []const u8) Unicode {
    return Unicode{ .bytes = str };
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

test "basic ASCII" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), strWidth("Hello"));
    try std.testing.expectEqual(@as(usize, 0), strWidth(""));
}

test "emoji" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    // Simple emoji
    try std.testing.expectEqual(@as(usize, 8), strWidth("Hello 😊"));

    // ZWJ family emoji (multiple codepoints, single grapheme)
    try std.testing.expectEqual(@as(usize, 2), strWidth("👨‍👩‍👧"));

    // Skin tone modifier
    try std.testing.expectEqual(@as(usize, 2), strWidth("👋🏽"));
}

test "CJK" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    // Each CJK character is width 2
    try std.testing.expectEqual(@as(usize, 4), strWidth("你好"));
    try std.testing.expectEqual(@as(usize, 17), strWidth("슬라바 우크라이나"));
}

test "combining marks" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    // café with combining acute accent
    try std.testing.expectEqual(@as(usize, 4), strWidth("cafe\u{0301}"));

    // Zalgo text
    try std.testing.expectEqual(@as(usize, 9), strWidth("Ẓ̌á̲l͔̝̞̄̑͌g̖̘̘̔̔͢͞͝o̪̔T̢̙̫̈̍͞e̬͈͕͌̏͑x̺̍ṭ̓̓ͅ"));
}

test "fallback when not initialized" {
    // Don't init - should fall back to byte length
    const width = strWidth("test");
    try std.testing.expectEqual(@as(usize, 4), width);
}

test "variation selectors" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    // Heart with text presentation (VS15) = width 1
    try std.testing.expectEqual(@as(usize, 1), strWidth("\u{2764}\u{FE0E}"));
    // Heart with emoji presentation (VS16) = width 2
    try std.testing.expectEqual(@as(usize, 2), strWidth("\u{2764}\u{FE0F}"));
}

test "flags (regional indicators)" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    // Flag emoji (two regional indicator letters = one flag, width 2)
    try std.testing.expectEqual(@as(usize, 2), strWidth("🇺🇸"));
    try std.testing.expectEqual(@as(usize, 2), strWidth("🇪🇸"));
}

test "mixed content" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    // ASCII + emoji + CJK: "Hi " (3) + "😊" (2) + " " (1) + "你好" (4) = 10
    try std.testing.expectEqual(@as(usize, 10), strWidth("Hi 😊 你好"));
    // Multiple emoji
    try std.testing.expectEqual(@as(usize, 6), strWidth("😀😃😄"));
}

test "whitespace and control" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    // Spaces
    try std.testing.expectEqual(@as(usize, 3), strWidth("   "));
    // Tab (control char, width 0)
    try std.testing.expectEqual(@as(usize, 0), strWidth("\t"));
    // Newline (control char, width 0)
    try std.testing.expectEqual(@as(usize, 0), strWidth("\n"));
    // Mixed with text
    try std.testing.expectEqual(@as(usize, 5), strWidth("Hello\n"));
}

test "codePointWidth" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    // ASCII
    try std.testing.expectEqual(@as(i4, 1), codePointWidth('A'));
    // CJK
    try std.testing.expectEqual(@as(i4, 2), codePointWidth('你'));
    // Emoji
    try std.testing.expectEqual(@as(i4, 2), codePointWidth('😊'));
    // Control char
    try std.testing.expectEqual(@as(i4, -1), codePointWidth(0x7F)); // DEL
    try std.testing.expectEqual(@as(i4, 0), codePointWidth('\n'));
}

// ─────────────────────────────────────────────────────────────
// Unicode wrapper tests
// ─────────────────────────────────────────────────────────────

test "Unicode.len and width" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const u = unicode("Hello 👨‍👩‍👧");
    try std.testing.expectEqual(@as(usize, 7), u.len()); // 6 ASCII + 1 family emoji
    try std.testing.expectEqual(@as(usize, 8), u.width()); // 6 + 2

    const empty = unicode("");
    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expectEqual(@as(usize, 0), empty.width());
}

test "Unicode.find basic" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const u = unicode("Hello world");

    // Find at start
    try std.testing.expectEqual(@as(?usize, 0), u.find("Hello"));
    // Find in middle
    try std.testing.expectEqual(@as(?usize, 6), u.find("world"));
    // Find single char
    try std.testing.expectEqual(@as(?usize, 4), u.find("o"));
    // Not found
    try std.testing.expectEqual(@as(?usize, null), u.find("xyz"));
    // Empty needle
    try std.testing.expectEqual(@as(?usize, 0), u.find(""));
}

test "Unicode.find with emoji" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const u = unicode("Hi 😊 there");

    // Find emoji
    try std.testing.expectEqual(@as(?usize, 3), u.find("😊"));
    // Find after emoji
    try std.testing.expectEqual(@as(?usize, 5), u.find("there"));
}

test "Unicode.find ZWJ sequence - should not match partial" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const family = "👨‍👩‍👧"; // family emoji (ZWJ sequence)
    const u = unicode(family);

    // The whole family emoji should be found
    try std.testing.expectEqual(@as(?usize, 0), u.find(family));

    // Individual components should NOT be found (they're not standalone graphemes)
    try std.testing.expectEqual(@as(?usize, null), u.find("👨")); // man alone
    try std.testing.expectEqual(@as(?usize, null), u.find("👩")); // woman alone
    try std.testing.expectEqual(@as(?usize, null), u.find("👧")); // girl alone
}

test "Unicode.find combining marks - should not match partial" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const cafe = "cafe\u{0301}"; // café with combining acute (c-a-f-é as 4 graphemes)
    const u = unicode(cafe);

    // Full grapheme should be found
    try std.testing.expectEqual(@as(?usize, 3), u.find("e\u{0301}"));
    // Base 'e' alone should NOT match (it's part of a larger grapheme)
    // The only "e" in "café" is combined with the accent, so standalone "e" shouldn't match
    try std.testing.expectEqual(@as(?usize, null), u.find("e"));

    // But if we have both standalone and combined 'e', it should find the standalone one
    const mixed = "recaf\u{0301}"; // r-e-c-a-f-é (6 graphemes, standalone 'e' at index 1)
    const u_mixed = unicode(mixed);
    try std.testing.expectEqual(@as(?usize, 1), u_mixed.find("e")); // matches standalone 'e'
}

test "Unicode.find at end" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const u = unicode("Hello");
    try std.testing.expectEqual(@as(?usize, 4), u.find("o"));
    try std.testing.expectEqual(@as(?usize, 3), u.find("lo"));
}

test "Unicode.contains" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const u = unicode("Hello 👨‍👩‍👧 world");

    try std.testing.expect(u.contains("Hello"));
    try std.testing.expect(u.contains("👨‍👩‍👧"));
    try std.testing.expect(u.contains("world"));
    try std.testing.expect(!u.contains("xyz"));
    try std.testing.expect(!u.contains("👩")); // partial ZWJ
}

test "Unicode.iterator" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const text = "Hi👋";
    const u = unicode(text);
    var iter = u.iterator();

    // First grapheme: "H"
    const g1 = iter.next().?;
    try std.testing.expectEqualStrings("H", g1.slice(text));

    // Second grapheme: "i"
    const g2 = iter.next().?;
    try std.testing.expectEqualStrings("i", g2.slice(text));

    // Third grapheme: "👋"
    const g3 = iter.next().?;
    try std.testing.expectEqualStrings("👋", g3.slice(text));

    // No more
    try std.testing.expectEqual(@as(?Grapheme, null), iter.next());
}

test "Unicode.reverseIterator" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const text = "Hi👋";
    const u = unicode(text);
    var iter = u.reverseIterator();

    // Last grapheme first: "👋"
    const g1 = iter.next().?;
    try std.testing.expectEqualStrings("👋", g1.slice(text));

    // Then "i"
    const g2 = iter.next().?;
    try std.testing.expectEqualStrings("i", g2.slice(text));

    // Then "H"
    const g3 = iter.next().?;
    try std.testing.expectEqualStrings("H", g3.slice(text));

    // No more
    try std.testing.expectEqual(@as(?Grapheme, null), iter.next());
}

test "Unicode.at" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const text = "A😊B";
    const u = unicode(text);

    const g0 = u.at(0).?;
    try std.testing.expectEqualStrings("A", g0.slice(text));

    const g1 = u.at(1).?;
    try std.testing.expectEqualStrings("😊", g1.slice(text));

    const g2 = u.at(2).?;
    try std.testing.expectEqualStrings("B", g2.slice(text));

    // Out of bounds
    try std.testing.expectEqual(@as(?Grapheme, null), u.at(3));
    try std.testing.expectEqual(@as(?Grapheme, null), u.at(100));
}

test "Unicode.collect" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const text = "A👨‍👩‍👧B";
    const u = unicode(text);
    const gs = try u.collect(std.testing.allocator);
    defer std.testing.allocator.free(gs);

    try std.testing.expectEqual(@as(usize, 3), gs.len);
    try std.testing.expectEqualStrings("A", gs[0].slice(text));
    try std.testing.expectEqualStrings("👨‍👩‍👧", gs[1].slice(text));
    try std.testing.expectEqualStrings("B", gs[2].slice(text));
}

test "Unicode with flags" {
    try init(std.testing.allocator);
    defer deinit(std.testing.allocator);

    const flags = "🇺🇸🇪🇸";
    const u = unicode(flags);

    // Two flag emoji
    try std.testing.expectEqual(@as(usize, 2), u.len());

    // Find first flag
    try std.testing.expectEqual(@as(?usize, 0), u.find("🇺🇸"));
    // Find second flag
    try std.testing.expectEqual(@as(?usize, 1), u.find("🇪🇸"));
    // Partial regional indicator should not match
    try std.testing.expectEqual(@as(?usize, null), u.find("🇺"));
}
