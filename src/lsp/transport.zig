const std = @import("std");

const max_message_size: usize = 16 * 1024 * 1024;

pub fn readMessage(reader: *std.Io.Reader, alloc: std.mem.Allocator) ![]u8 {
    var content_length: usize = 0;

    var header_count: usize = 0;
    while (header_count < 100) : (header_count += 1) {
        // takeDelimiterInclusive advances past the '\n'; strip \r\n from result
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return error.InvalidHeader,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;

        if (std.mem.startsWith(u8, trimmed, "Content-Length: ")) {
            const val = trimmed["Content-Length: ".len..];
            content_length = std.fmt.parseInt(usize, val, 10) catch return error.InvalidContentLength;
        }
    }
    if (header_count >= 100) return error.MalformedHeader;

    if (content_length == 0 or content_length > max_message_size) {
        return error.InvalidContentLength;
    }

    return reader.readAlloc(alloc, content_length);
}

pub fn writeMessage(writer: *std.Io.Writer, json_bytes: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{json_bytes.len});
    try writer.writeAll(json_bytes);
    try writer.flush();
}

test "negative Content-Length returns InvalidContentLength" {
    const bad_frame = "Content-Length: -1\r\n\r\n";
    var r = std.Io.Reader.fixed(bad_frame);
    try std.testing.expectError(error.InvalidContentLength, readMessage(&r, std.testing.allocator));
}

test "round-trip header parsing" {
    var write_buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&write_buf);
    const body = "{\"jsonrpc\":\"2.0\"}";
    try writeMessage(&w, body);

    const written = w.buffered();
    var r = std.Io.Reader.fixed(written);
    const msg = try readMessage(&r, std.testing.allocator);
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings(body, msg);
}

test "truncated message returns EndOfStream" {
    const frame = "Content-Length: 100\r\n\r\n{\"jsonrpc\":\"2.0\"}";
    var r = std.Io.Reader.fixed(frame);
    try std.testing.expectError(error.EndOfStream, readMessage(&r, std.testing.allocator));
}
