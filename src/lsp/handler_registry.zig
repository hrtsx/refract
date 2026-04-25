const std = @import("std");
const types = @import("types.zig");

pub const RequestHandler = *const fn (server: *anyopaque, msg: types.RequestMessage) anyerror!?types.ResponseMessage;
pub const NotificationHandler = *const fn (server: *anyopaque, msg: types.RequestMessage) anyerror!void;

pub const DispatchResult = struct {
    response: ?types.ResponseMessage,
};

pub const Registry = struct {
    requests: std.StringHashMapUnmanaged(RequestHandler) = .{},
    notifications: std.StringHashMapUnmanaged(NotificationHandler) = .{},

    pub fn registerRequest(self: *Registry, alloc: std.mem.Allocator, method: []const u8, handler: RequestHandler) !void {
        const key = try alloc.dupe(u8, method);
        errdefer alloc.free(key);
        const gop = try self.requests.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(key);
            return error.DuplicateMethod;
        }
        gop.value_ptr.* = handler;
    }

    pub fn registerNotification(self: *Registry, alloc: std.mem.Allocator, method: []const u8, handler: NotificationHandler) !void {
        const key = try alloc.dupe(u8, method);
        errdefer alloc.free(key);
        const gop = try self.notifications.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(key);
            return error.DuplicateMethod;
        }
        gop.value_ptr.* = handler;
    }

    pub fn dispatchRequest(self: *Registry, server: *anyopaque, msg: types.RequestMessage) !?DispatchResult {
        const h = self.requests.get(msg.method) orelse return null;
        const resp = try h(server, msg);
        return DispatchResult{ .response = resp };
    }

    pub fn dispatchNotification(self: *Registry, server: *anyopaque, msg: types.RequestMessage) !bool {
        const h = self.notifications.get(msg.method) orelse return false;
        try h(server, msg);
        return true;
    }

    pub fn deinit(self: *Registry, alloc: std.mem.Allocator) void {
        var rit = self.requests.iterator();
        while (rit.next()) |e| alloc.free(e.key_ptr.*);
        self.requests.deinit(alloc);
        var nit = self.notifications.iterator();
        while (nit.next()) |e| alloc.free(e.key_ptr.*);
        self.notifications.deinit(alloc);
    }
};

test "registry registers and dispatches" {
    const alloc = std.testing.allocator;
    var reg = Registry{};
    defer reg.deinit(alloc);

    const Test = struct {
        fn ping(_: *anyopaque, _: types.RequestMessage) anyerror!?types.ResponseMessage {
            return null;
        }
        fn note(_: *anyopaque, _: types.RequestMessage) anyerror!void {}
    };

    try reg.registerRequest(alloc, "ping", Test.ping);
    try reg.registerNotification(alloc, "note", Test.note);

    var dummy: u8 = 0;
    const dummy_ptr: *anyopaque = @ptrCast(&dummy);

    const req = types.RequestMessage{ .id = .{ .integer = 1 }, .method = "ping", .params = null };
    const r = try reg.dispatchRequest(dummy_ptr, req);
    try std.testing.expect(r != null);

    const miss = types.RequestMessage{ .id = .{ .integer = 2 }, .method = "missing", .params = null };
    const r2 = try reg.dispatchRequest(dummy_ptr, miss);
    try std.testing.expect(r2 == null);

    const n = types.RequestMessage{ .id = null, .method = "note", .params = null };
    const handled = try reg.dispatchNotification(dummy_ptr, n);
    try std.testing.expect(handled);

    try std.testing.expectError(error.DuplicateMethod, reg.registerRequest(alloc, "ping", Test.ping));
}
