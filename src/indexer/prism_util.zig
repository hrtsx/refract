const std = @import("std");
const prism = @import("../prism.zig");

/// Resolve a prism constant id to its source slice (no allocation).
pub fn resolveConstant(parser: *prism.Parser, id: prism.ConstantId) []const u8 {
    const ct = prism.constantPoolIdToConstant(&parser.constant_pool, id);
    return ct[0].start[0..ct[0].length];
}

/// Convert a byte offset into 1-based line + column via prism's line-offset list.
pub fn locationLineCol(parser: *prism.Parser, offset: u32) struct { line: i32, col: u32 } {
    const lc = prism.lineOffsetListLineColumn(&parser.line_offsets, offset, parser.start_line);
    return .{ .line = lc.line, .col = lc.column };
}
