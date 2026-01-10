const std = @import("std");

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_not_initialized = -32002,
    request_cancelled = -32800,
};

pub const ResponseError = struct {
    code: i32,
    message: []const u8,
};

pub const RequestMessage = struct {
    id: ?std.json.Value,
    method: []const u8,
    params: ?std.json.Value,
};

pub const ResponseMessage = struct {
    id: ?std.json.Value,
    result: ?std.json.Value,
    @"error": ?ResponseError,
    raw_result: ?[]const u8 = null, // pre-serialized JSON; caller must free
};
