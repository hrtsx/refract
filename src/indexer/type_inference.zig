const std = @import("std");
const prism = @import("../prism.zig");

threadlocal var hash_type_buf: [128]u8 = undefined;

pub fn inferLiteralType(node: *const prism.Node) ?[]const u8 {
    return switch (node.*.type) {
        prism.NODE_INTEGER => "Integer",
        prism.NODE_FLOAT => "Float",
        prism.NODE_STRING, prism.NODE_INTERPOLATED_STR => "String",
        prism.NODE_SYMBOL => "Symbol",
        prism.NODE_TRUE => "TrueClass",
        prism.NODE_FALSE => "FalseClass",
        prism.NODE_NIL => "NilClass",
        prism.NODE_ARRAY => "Array",
        prism.NODE_HASH => blk: {
            const hn: *const prism.HashNode = @ptrCast(@alignCast(node));
            if (hn.elements.size > 0) {
                const first_elem = hn.elements.nodes[0];
                if (first_elem.*.type == prism.NODE_ASSOC) {
                    const assoc: *const prism.AssocNode = @ptrCast(@alignCast(first_elem));
                    if (assoc.key) |key| {
                        if (assoc.value) |value| {
                            if (inferLiteralType(key)) |key_type| {
                                if (inferLiteralType(value)) |val_type| {
                                    // Copy slices to avoid aliasing when key_type/val_type
                                    // point into hash_type_buf from a recursive call.
                                    var kt_buf: [64]u8 = undefined;
                                    var vt_buf: [64]u8 = undefined;
                                    const kt_len = @min(key_type.len, kt_buf.len);
                                    const vt_len = @min(val_type.len, vt_buf.len);
                                    @memcpy(kt_buf[0..kt_len], key_type[0..kt_len]);
                                    @memcpy(vt_buf[0..vt_len], val_type[0..vt_len]);
                                    const len = std.fmt.bufPrint(&hash_type_buf, "Hash[{s}, {s}]", .{ kt_buf[0..kt_len], vt_buf[0..vt_len] }) catch break :blk "Hash";
                                    break :blk len;
                                }
                            }
                        }
                    }
                }
            }
            break :blk "Hash";
        },
        prism.NODE_RANGE => "Range",
        else => null,
    };
}

pub fn normalizeRbsReturn(rt: []const u8) []const u8 {
    // RBS uses `bool` as a sugar for `TrueClass | FalseClass`. Keep that mapping
    // consistent with parseUnionTypes' handling of `boolean` and with the
    // hardcoded lookupStdlibReturn.
    if (std.mem.eql(u8, rt, "bool")) return "TrueClass | FalseClass";
    if (std.mem.eql(u8, rt, "boolish")) return "TrueClass | FalseClass";
    if (std.mem.eql(u8, rt, "nil")) return "NilClass";
    return rt;
}

fn parseUnionTypes(inner: []const u8, buf: *[512]u8) ?[]const u8 {
    var result_len: usize = 0;
    var it = std.mem.splitSequence(u8, inner, ", ");
    var first = true;
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " ");
        if (t.len == 0) continue;
        const normalized: []const u8 = if (std.mem.eql(u8, t, "nil")) "NilClass" else if (std.mem.eql(u8, t, "boolean")) "TrueClass | FalseClass" else t;
        if (!first) {
            if (result_len + 3 > buf.len) break;
            buf[result_len..][0..3].* = " | ".*;
            result_len += 3;
        }
        if (result_len + normalized.len > buf.len) break;
        @memcpy(buf[result_len..][0..normalized.len], normalized);
        result_len += normalized.len;
        first = false;
    }
    if (result_len == 0) return null;
    return buf[0..result_len];
}

pub fn parseYardReturn(doc: []const u8, buf: *[512]u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        const tag = "@return [";
        const idx = std.mem.indexOf(u8, t, tag) orelse continue;
        const rest = t[idx + tag.len ..];
        const end = std.mem.indexOfScalar(u8, rest, ']') orelse continue;
        const inner = rest[0..end];
        if (std.mem.startsWith(u8, inner, "Array<") and inner[inner.len - 1] == '>') {
            return inner[6 .. inner.len - 1];
        }
        if (std.mem.startsWith(u8, inner, "Hash{") and inner.len > 5 and inner[inner.len - 1] == '}') {
            return inner;
        }
        if (std.mem.startsWith(u8, inner, "Set[") or std.mem.startsWith(u8, inner, "Set<")) {
            return inner;
        }
        if (std.mem.indexOf(u8, inner, ",") != null) {
            return parseUnionTypes(inner, buf);
        }
        return inner;
    }
    return null;
}

pub fn parseYardParam(doc: []const u8, name: []const u8, buf: *[512]u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, t, "@param ")) continue;
        const rest = t[7..];
        if (!std.mem.startsWith(u8, rest, name)) continue;
        const after = rest[name.len..];
        if (after.len == 0 or after[0] != ' ') continue;
        const bracket = std.mem.indexOf(u8, after, "[") orelse continue;
        const inner_start = after[bracket + 1 ..];
        const end = std.mem.indexOfScalar(u8, inner_start, ']') orelse continue;
        const inner = inner_start[0..end];
        if (std.mem.indexOf(u8, inner, ",") != null) {
            return parseUnionTypes(inner, buf);
        }
        return inner;
    }
    return null;
}

/// Returns the description text that follows `[Type]` on a YARD @param line.
/// e.g. `@param name [String] the user's name` → `"the user's name"`
pub fn parseYardParamDesc(doc: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, t, "@param ")) continue;
        const rest = t[7..];
        if (!std.mem.startsWith(u8, rest, name)) continue;
        const after = rest[name.len..];
        if (after.len == 0 or after[0] != ' ') continue;
        const bracket = std.mem.indexOf(u8, after, "[") orelse continue;
        const inner_start = after[bracket + 1 ..];
        const close = std.mem.indexOfScalar(u8, inner_start, ']') orelse continue;
        const desc = std.mem.trim(u8, inner_start[close + 1 ..], " \t");
        if (desc.len == 0) return null;
        return desc;
    }
    return null;
}

pub fn extractDocComment(source: []const u8, node_start: u32, alloc: std.mem.Allocator) ?[]u8 {
    if (node_start == 0) return null;
    const end: usize = @min(@as(usize, node_start), source.len);

    // Find start of the def/class/module line
    var def_line_start: usize = end;
    while (def_line_start > 0 and source[def_line_start - 1] != '\n') {
        def_line_start -= 1;
    }

    // Collect comment lines going backward (up to 64)
    var lines: [64][]const u8 = undefined;
    var line_count: usize = 0;
    var pos: usize = def_line_start;

    while (pos > 0 and line_count < 64) {
        const prev_line_end = pos - 1; // '\n' at pos-1
        var prev_line_start = prev_line_end;
        while (prev_line_start > 0 and source[prev_line_start - 1] != '\n') {
            prev_line_start -= 1;
        }
        const line_slice = source[prev_line_start..prev_line_end];
        const trimmed = std.mem.trimStart(u8, line_slice, " \t");
        if (!std.mem.startsWith(u8, trimmed, "#")) break;
        const stripped: []const u8 = if (std.mem.startsWith(u8, trimmed, "# ")) trimmed[2..] else trimmed[1..];
        lines[line_count] = stripped;
        line_count += 1;
        pos = prev_line_start;
    }

    if (line_count == 0) return null;

    // Reverse (collected bottom-to-top)
    var i: usize = 0;
    var j: usize = line_count - 1;
    while (i < j) {
        const tmp = lines[i];
        lines[i] = lines[j];
        lines[j] = tmp;
        i += 1;
        j -= 1;
    }

    // Join with '\n'
    var result = std.ArrayList(u8).empty;
    for (lines[0..line_count], 0..) |line, idx| {
        if (idx > 0) result.append(alloc, '\n') catch {
            result.deinit(alloc);
            return null;
        };
        result.appendSlice(alloc, line) catch {
            result.deinit(alloc);
            return null;
        };
    }
    const raw = result.toOwnedSlice(alloc) catch return null;
    return appendYardTags(raw, alloc);
}

fn appendYardTags(raw: []u8, alloc: std.mem.Allocator) ?[]u8 {
    // Collect @deprecated prefix and extra tag sections.
    // Two-pass: first pass handles single-line tags; @example blocks are multi-line.
    var deprecated_msg: ?[]const u8 = null;
    var extras = std.ArrayList(u8).empty;

    // State machine for multi-line @example blocks
    var in_example = false;
    var example_buf = std.ArrayList(u8).empty;

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");

        // Detect start of a new YARD tag (ends an open @example block)
        const is_yard_tag = t.len > 0 and t[0] == '@';

        if (in_example) {
            if (is_yard_tag) {
                // Close the current @example block before processing the new tag
                in_example = false;
                const ex = example_buf.toOwnedSlice(alloc) catch "";
                defer alloc.free(ex);
                if (ex.len > 0) {
                    extras.appendSlice(alloc, "\n\n**Example:**\n```ruby\n") catch {};
                    extras.appendSlice(alloc, ex) catch {};
                    extras.appendSlice(alloc, "\n```") catch {};
                }
                // Fall through to process the new tag below
            } else {
                // Accumulate example body line
                if (example_buf.items.len > 0) example_buf.append(alloc, '\n') catch {};
                example_buf.appendSlice(alloc, line) catch {};
                continue;
            }
        }

        if (std.mem.startsWith(u8, t, "@deprecated")) {
            deprecated_msg = std.mem.trim(u8, t["@deprecated".len..], " \t");
        } else if (std.mem.startsWith(u8, t, "@raise")) {
            const rest = std.mem.trim(u8, t["@raise".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Raises:** ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@see")) {
            const rest = std.mem.trim(u8, t["@see".len..], " \t");
            extras.appendSlice(alloc, "\n\n**See also:** ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@overload")) {
            const rest = std.mem.trim(u8, t["@overload".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Overload:** `") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, "`") catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@yieldparam")) {
            const rest = std.mem.trim(u8, t["@yieldparam".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Yield param:** ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@yieldreturn")) {
            const rest = std.mem.trim(u8, t["@yieldreturn".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Yield returns:** ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@note")) {
            const rest = std.mem.trim(u8, t["@note".len..], " \t");
            extras.appendSlice(alloc, "\n\n> ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@since")) {
            const rest = std.mem.trim(u8, t["@since".len..], " \t");
            extras.appendSlice(alloc, "\n\n_Since: ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, "_") catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@example")) {
            // Begin accumulating a multi-line example block
            in_example = true;
            example_buf.clearRetainingCapacity();
            // The text after @example on the same line is the optional title (skip it)
        }
    }

    // Close any open @example block at EOF
    if (in_example) {
        const ex = example_buf.toOwnedSlice(alloc) catch "";
        defer alloc.free(ex);
        if (ex.len > 0) {
            extras.appendSlice(alloc, "\n\n**Example:**\n```ruby\n") catch {};
            extras.appendSlice(alloc, ex) catch {};
            extras.appendSlice(alloc, "\n```") catch {};
        }
    } else {
        example_buf.deinit(alloc);
    }

    const extras_slice = extras.toOwnedSlice(alloc) catch "";
    defer if (extras_slice.len > 0) alloc.free(extras_slice);
    if (deprecated_msg == null and extras_slice.len == 0) return raw;
    var out = std.ArrayList(u8).empty;
    if (deprecated_msg) |msg| {
        out.appendSlice(alloc, "**Deprecated:**") catch {
            out.deinit(alloc);
            alloc.free(raw);
            return null;
        };
        if (msg.len > 0) {
            out.append(alloc, ' ') catch {};
            out.appendSlice(alloc, msg) catch {};
        } // OOM: doc formatting
        out.appendSlice(alloc, "\n\n") catch {}; // OOM: doc formatting
    }
    out.appendSlice(alloc, raw) catch {
        out.deinit(alloc);
        alloc.free(raw);
        return null;
    };
    out.appendSlice(alloc, extras_slice) catch {}; // OOM: doc formatting
    alloc.free(raw);
    return out.toOwnedSlice(alloc) catch null;
}
