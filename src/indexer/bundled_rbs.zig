const std = @import("std");

pub const BundledRbs = struct {
    path: []const u8,
    content: []const u8,
};

pub const files = [_]BundledRbs{
    .{ .path = "<bundled>/core/object.rbs", .content = @embedFile("bundled_rbs/object.rbs") },
    .{ .path = "<bundled>/core/numeric.rbs", .content = @embedFile("bundled_rbs/numeric.rbs") },
    .{ .path = "<bundled>/core/string.rbs", .content = @embedFile("bundled_rbs/string.rbs") },
    .{ .path = "<bundled>/core/symbol.rbs", .content = @embedFile("bundled_rbs/symbol.rbs") },
    .{ .path = "<bundled>/core/array.rbs", .content = @embedFile("bundled_rbs/array.rbs") },
    .{ .path = "<bundled>/core/hash.rbs", .content = @embedFile("bundled_rbs/hash.rbs") },
    .{ .path = "<bundled>/core/enumerable.rbs", .content = @embedFile("bundled_rbs/enumerable.rbs") },
    .{ .path = "<bundled>/core/time.rbs", .content = @embedFile("bundled_rbs/time.rbs") },
    .{ .path = "<bundled>/core/date.rbs", .content = @embedFile("bundled_rbs/date.rbs") },
    .{ .path = "<bundled>/core/io.rbs", .content = @embedFile("bundled_rbs/io.rbs") },
    .{ .path = "<bundled>/core/exceptions.rbs", .content = @embedFile("bundled_rbs/exceptions.rbs") },
    .{ .path = "<bundled>/core/env.rbs", .content = @embedFile("bundled_rbs/env.rbs") },
    .{ .path = "<bundled>/rails/active_support.rbs", .content = @embedFile("bundled_rbs/active_support.rbs") },
};
