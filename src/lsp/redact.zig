const std = @import("std");

pub const PLACEHOLDER: []const u8 = "«REDACTED»";

const SECRET_KEYS = [_][]const u8{
    "password",      "passwd",     "secret",
    "token",         "api_key",    "api-key",
    "apikey",        "access_key", "access-key",
    "authorization", "auth_token", "session",
    "cookie",        "bearer",     "private_key",
    "client_secret",
};

const MIN_VALUE_LEN: usize = 6;
const MAX_VALUE_LEN: usize = 8192;
const MIN_JWT_SEGMENT: usize = 8;

pub fn redactAlloc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    errdefer aw.deinit();
    try writeRedacted(&aw.writer, s);
    return try aw.toOwnedSlice();
}

pub fn writeRedacted(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (try tryRedactPem(w, s, &i)) continue;
        if (try tryRedactUrlUserinfo(w, s, &i)) continue;
        if (try tryRedactKeyword(w, s, &i)) continue;
        if (try tryRedactJwt(w, s, &i)) continue;
        try w.writeByte(s[i]);
        i += 1;
    }
}

fn tryRedactPem(w: *std.Io.Writer, s: []const u8, i: *usize) !bool {
    const start = i.*;
    const marker = "-----BEGIN ";
    if (!startsWithAt(s, start, marker)) return false;
    const end_marker = "-----END ";
    const end_search_from = start + marker.len;
    const end_start = std.mem.indexOfPos(u8, s, end_search_from, end_marker) orelse return false;
    const closing_dashes = std.mem.indexOfPos(u8, s, end_start + end_marker.len, "-----") orelse return false;
    const block_end = closing_dashes + 5;
    try w.writeAll(PLACEHOLDER);
    i.* = block_end;
    return true;
}

fn tryRedactUrlUserinfo(w: *std.Io.Writer, s: []const u8, i: *usize) !bool {
    const start = i.*;
    if (!startsWithAt(s, start, "://")) return false;
    const userinfo_start = start + 3;
    var has_colon = false;
    var j: usize = userinfo_start;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (c == '@') {
            if (!has_colon) return false;
            try w.writeAll(s[start..userinfo_start]);
            try w.writeAll(PLACEHOLDER);
            try w.writeByte('@');
            i.* = j + 1;
            return true;
        }
        if (c == ':') {
            has_colon = true;
            continue;
        }
        if (c == '/' or c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '"' or c == '?' or c == '#') return false;
    }
    return false;
}

const KeywordMatch = struct {
    sep_end: usize,
    value_end: usize,
};

fn tryRedactKeyword(w: *std.Io.Writer, s: []const u8, i: *usize) !bool {
    const start = i.*;
    if (start > 0) {
        const prev = s[start - 1];
        if (isIdentChar(prev)) return false;
    }
    for (SECRET_KEYS) |key| {
        if (start + key.len > s.len) continue;
        if (!eqlIgnoreCase(s[start .. start + key.len], key)) continue;
        const after_key = start + key.len;
        if (after_key < s.len and isIdentChar(s[after_key])) continue;
        const match = scanKeywordValue(s, after_key) orelse continue;
        var redact_end = match.value_end;
        const value_slice = s[match.sep_end..match.value_end];
        if (isAuthScheme(value_slice)) {
            if (extendThroughFollowingToken(s, redact_end)) |new_end| redact_end = new_end;
        }
        try w.writeAll(s[start..match.sep_end]);
        try w.writeAll(PLACEHOLDER);
        i.* = redact_end;
        return true;
    }
    return false;
}

fn isAuthScheme(v: []const u8) bool {
    const schemes = [_][]const u8{ "bearer", "basic", "token", "digest" };
    for (schemes) |sc| {
        if (eqlIgnoreCase(v, sc)) return true;
    }
    return false;
}

fn extendThroughFollowingToken(s: []const u8, from: usize) ?usize {
    var p = from;
    var saw_ws = false;
    while (p < s.len and (s[p] == ' ' or s[p] == '\t')) : (p += 1) {
        saw_ws = true;
    }
    if (!saw_ws) return null;
    const token_start = p;
    while (p < s.len) : (p += 1) {
        const c = s[p];
        const ok = (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '-' or c == '_' or c == '.' or c == '/' or c == '+' or c == '=';
        if (!ok) break;
    }
    if (p - token_start < 8) return null;
    return p;
}

fn scanKeywordValue(s: []const u8, after_key: usize) ?KeywordMatch {
    var p = after_key;
    if (p < s.len and (s[p] == '"' or s[p] == '\'')) p += 1;
    while (p < s.len and (s[p] == ' ' or s[p] == '\t')) : (p += 1) {}
    if (p >= s.len) return null;
    var sep_kind: u8 = 0;
    switch (s[p]) {
        '=', ':' => {
            sep_kind = s[p];
            p += 1;
        },
        ' ', '\t' => {},
        else => return null,
    }
    while (p < s.len and (s[p] == ' ' or s[p] == '\t')) : (p += 1) {}
    if (p >= s.len) return null;
    var quote: u8 = 0;
    if (s[p] == '"' or s[p] == '\'') {
        quote = s[p];
        p += 1;
    }
    const value_start = p;
    while (p < s.len) : (p += 1) {
        const c = s[p];
        if (quote != 0) {
            if (c == quote) break;
            if (c == '\\' and p + 1 < s.len) {
                p += 1;
                continue;
            }
        } else {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',' or c == ';' or c == '&' or c == ')' or c == '}' or c == ']') break;
        }
        if (p - value_start > MAX_VALUE_LEN) break;
    }
    const raw_len = p - value_start;
    if (raw_len < MIN_VALUE_LEN) return null;
    if (sep_kind == 0 and quote == 0) {
        var alnum = true;
        var k: usize = value_start;
        while (k < p) : (k += 1) {
            const c = s[k];
            const ok = (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '-' or c == '_' or c == '.' or c == '/' or c == '+' or c == '=';
            if (!ok) {
                alnum = false;
                break;
            }
        }
        if (!alnum) return null;
    }
    return KeywordMatch{ .sep_end = value_start, .value_end = p };
}

fn tryRedactJwt(w: *std.Io.Writer, s: []const u8, i: *usize) !bool {
    const start = i.*;
    if (start > 0 and isB64UrlChar(s[start - 1])) return false;
    var p = start;
    var seg1_len: usize = 0;
    while (p < s.len and isB64UrlChar(s[p])) : (p += 1) seg1_len += 1;
    if (seg1_len < MIN_JWT_SEGMENT or p >= s.len or s[p] != '.') return false;
    p += 1;
    var seg2_len: usize = 0;
    const seg2_begin = p;
    while (p < s.len and isB64UrlChar(s[p])) : (p += 1) seg2_len += 1;
    if (seg2_len < MIN_JWT_SEGMENT or p >= s.len or s[p] != '.') return false;
    _ = seg2_begin;
    p += 1;
    var seg3_len: usize = 0;
    while (p < s.len and isB64UrlChar(s[p])) : (p += 1) seg3_len += 1;
    if (seg3_len < MIN_JWT_SEGMENT) return false;
    try w.writeAll(PLACEHOLDER);
    i.* = p;
    return true;
}

fn startsWithAt(s: []const u8, at: usize, needle: []const u8) bool {
    if (at + needle.len > s.len) return false;
    return std.mem.eql(u8, s[at .. at + needle.len], needle);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (toLower(a[i]) != toLower(b[i])) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isIdentChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isB64UrlChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '-' or c == '_';
}

test "passthrough leaves clean text alone" {
    const alloc = std.testing.allocator;
    const out = try redactAlloc(alloc, "hello world, this is fine 12345");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello world, this is fine 12345", out);
}

test "redacts password=value" {
    const alloc = std.testing.allocator;
    const out = try redactAlloc(alloc, "DATABASE_URL: password=hunter2xyz keep");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hunter2xyz") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, PLACEHOLDER) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep") != null);
}

test "redacts token: bearer style" {
    const alloc = std.testing.allocator;
    const out = try redactAlloc(alloc, "Authorization: Bearer abcDEF123456ghiJKL trailing");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "abcDEF123456ghiJKL") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "trailing") != null);
}

test "redacts api_key, api-key, apikey variants" {
    const alloc = std.testing.allocator;
    const variants = [_][]const u8{
        "api_key=AKIA1234567890abcdef",
        "api-key: AKIA1234567890abcdef",
        "apikey=AKIA1234567890abcdef",
    };
    for (variants) |v| {
        const out = try redactAlloc(alloc, v);
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "AKIA1234567890abcdef") == null);
    }
}

test "redacts URL userinfo" {
    const alloc = std.testing.allocator;
    const out = try redactAlloc(alloc, "https://alice:topSecret@example.com/path");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "topSecret") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "example.com/path") != null);
}

test "does not redact URL without userinfo" {
    const alloc = std.testing.allocator;
    const out = try redactAlloc(alloc, "https://example.com/path?q=1");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("https://example.com/path?q=1", out);
}

test "redacts PEM block" {
    const alloc = std.testing.allocator;
    const input =
        \\before
        \\-----BEGIN RSA PRIVATE KEY-----
        \\MIIEowIBAAKCAQEA...
        \\AAAA...
        \\-----END RSA PRIVATE KEY-----
        \\after
    ;
    const out = try redactAlloc(alloc, input);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "MIIEowIBAAKCAQEA") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after") != null);
}

test "redacts JWT triple" {
    const alloc = std.testing.allocator;
    const out = try redactAlloc(alloc, "Cookie: session=eyJhbGciOi.eyJzdWIiOiI.SflKxwRJSMeKKF after");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "eyJhbGciOi.eyJzdWIiOiI.SflKxwRJSMeKKF") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after") != null);
}

test "does not match identifier substring (mypassword)" {
    const alloc = std.testing.allocator;
    const out = try redactAlloc(alloc, "my_password_field = setupComplete");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "setupComplete") != null);
}

test "redacts password in quoted value" {
    const alloc = std.testing.allocator;
    const out = try redactAlloc(alloc, "{\"password\":\"hunterXX12\",\"keep\":1}");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hunterXX12") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep") != null);
}

test "leaves short values that look like keys alone" {
    const alloc = std.testing.allocator;
    const out = try redactAlloc(alloc, "token=ok");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("token=ok", out);
}
