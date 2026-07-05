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

/// Write a `Content-Length`-framed message to a child-process stdin stream
/// (`writeStreaming` API, distinct from the buffered `*std.Io.Writer` above).
/// Any locking (e.g. an io mutex) is the caller's responsibility.
pub fn writeStreamFrame(stdin: anytype, body: []const u8) !void {
    var sbuf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&sbuf, "Content-Length: {d}\r\n\r\n", .{body.len});
    try stdin.writeStreamingAll(std.Options.debug_io, header);
    try stdin.writeStreamingAll(std.Options.debug_io, body);
}

/// Build a JSON-RPC request body (`id`/`method`/`params`), without framing.
/// Caller owns the returned slice. Shared by the subprocess bridges so the
/// envelope format stays in one place.
pub fn buildRequestBody(alloc: std.mem.Allocator, id: i64, method: []const u8, params_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
        .{ id, method, params_json },
    );
}

/// True when `frame` is the JSON-RPC response to request `id`: it carries that
/// `id` and no `method` key (a server→client notification/request has `method`).
pub fn isResponseTo(alloc: std.mem.Allocator, frame: []const u8, id: i64) bool {
    var p = std.json.parseFromSlice(std.json.Value, alloc, frame, .{}) catch return false;
    defer p.deinit();
    if (p.value != .object) return false;
    const o = p.value.object;
    if (o.get("method") != null) return false;
    const idv = o.get("id") orelse return false;
    return idv == .integer and idv.integer == id;
}

/// Read frames from a child stdout stream, skipping interleaved notifications
/// (window/logMessage, $/progress, sorbet/showOperation, …) until the response
/// matching `id`. Caller frees the returned bytes.
pub fn readResponseById(stdout: anytype, alloc: std.mem.Allocator, id: i64) ![]u8 {
    var skipped: u32 = 0;
    while (skipped < 4096) : (skipped += 1) {
        const frame = try readStreamFrame(stdout, alloc);
        if (isResponseTo(alloc, frame, id)) return frame;
        alloc.free(frame);
    }
    return error.NoResponse;
}

/// Read one `Content-Length`-framed message from a child-process stdout stream.
/// Returns an allocator-owned body, freed on any read error.
pub fn readStreamFrame(stdout: anytype, alloc: std.mem.Allocator) ![]u8 {
    var hdr_buf: [256]u8 = undefined;
    var hdr_len: usize = 0;
    while (hdr_len < hdr_buf.len) {
        const n = try stdout.readStreaming(std.Options.debug_io, &.{hdr_buf[hdr_len .. hdr_len + 1]});
        if (n == 0) return error.EndOfStream;
        hdr_len += n;
        if (hdr_len >= 4 and std.mem.eql(u8, hdr_buf[hdr_len - 4 .. hdr_len], "\r\n\r\n")) break;
    }
    var content_len: usize = 0;
    var it = std.mem.splitSequence(u8, hdr_buf[0..hdr_len], "\r\n");
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "Content-Length: ")) {
            content_len = std.fmt.parseInt(usize, line["Content-Length: ".len..], 10) catch 0;
        }
    }
    if (content_len == 0 or content_len > max_message_size) return error.InvalidContentLength;
    const body = try alloc.alloc(u8, content_len);
    errdefer alloc.free(body);
    var got: usize = 0;
    while (got < content_len) {
        const n = try stdout.readStreaming(std.Options.debug_io, &.{body[got..]});
        if (n == 0) return error.EndOfStream;
        got += n;
    }
    return body;
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
