const std = @import("std");
const fuzz = @import("fuzz.zig");

pub export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) c_int {
    if (size == 0) return 0;

    const target_byte = data[0];
    const input = data[1..size];

    switch (target_byte) {
        0x01 => fuzz.fuzzPrismParse(input),
        0x02 => fuzz.fuzzIndexer(input),
        0x03 => fuzz.fuzzTransport(input),
        0x04 => fuzz.fuzzTypeWalker(input),
        else => {},
    }

    return 0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var stdin_buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().readerStreaming(io, &stdin_buf);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(alloc);

    const cap: usize = 4 * 1024 * 1024;
    var chunk: [4096]u8 = undefined;
    while (bytes.items.len < cap) {
        const n = fr.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        const room = cap - bytes.items.len;
        const take = if (n > room) room else n;
        try bytes.appendSlice(alloc, chunk[0..take]);
    }

    const data = bytes.items;
    if (data.len > 0) {
        _ = LLVMFuzzerTestOneInput(data.ptr, data.len);
    }
}
