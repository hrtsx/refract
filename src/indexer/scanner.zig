const std = @import("std");

fn shouldSkipDir(root: []const u8, parent: []const u8, name: []const u8, extra_excludes: []const []const u8, negations: []const []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    const skip = [_][]const u8{
        "node_modules", "tmp",    "log",
        "coverage",     "public", ".bundle",
    };
    for (skip) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    // Skip vendor/bundle (bundler install path) but not vendor/ itself
    if (std.mem.eql(u8, name, "bundle")) {
        const parent_base = std.fs.path.basename(parent);
        if (std.mem.eql(u8, parent_base, "vendor")) return true;
    }
    var matched = false;
    for (extra_excludes) |e| {
        if (std.mem.startsWith(u8, e, "**/")) {
            // **/foo — match this directory name at any depth
            if (std.mem.eql(u8, name, e[3..])) {
                matched = true;
                break;
            }
        } else if (std.mem.endsWith(u8, e, "/**")) {
            // foo/** — skip all contents of directory foo
            if (std.mem.eql(u8, name, e[0 .. e.len - 3])) {
                matched = true;
                break;
            }
        } else if (std.mem.indexOfScalar(u8, e, '/') != null) {
            // Path-relative pattern: compare against root-relative path of this dir
            const rel_parent: []const u8 = if (parent.len > root.len and std.mem.startsWith(u8, parent, root))
                parent[root.len + 1 ..]
            else
                "";
            var path_buf: [1024]u8 = undefined;
            const rel_path: []const u8 = if (rel_parent.len > 0)
                (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ rel_parent, name }) catch name)
            else
                name;
            if (std.mem.eql(u8, rel_path, e)) {
                matched = true;
                break;
            }
        } else if (e.len > 1 and e[0] == '*') {
            // Leading-star pattern: suffix match (e.g. *.log matches foo.log)
            if (std.mem.endsWith(u8, name, e[1..])) {
                matched = true;
                break;
            }
        } else if (e.len > 0 and e[e.len - 1] == '*') {
            // Trailing-star pattern: prefix match (e.g. tmp* matches tmp_cache)
            if (std.mem.startsWith(u8, name, e[0 .. e.len - 1])) {
                matched = true;
                break;
            }
        } else {
            if (std.mem.eql(u8, name, e)) {
                matched = true;
                break;
            }
        }
    }
    if (matched) {
        for (negations) |n| {
            if (n.len > 0 and n[n.len - 1] == '*') {
                if (std.mem.startsWith(u8, name, n[0 .. n.len - 1])) return false;
            } else {
                if (std.mem.eql(u8, name, n)) return false;
            }
        }
        return true;
    }
    return false;
}

fn scanDir(root: []const u8, abs_path: []const u8, paths: *std.ArrayList([]u8), alloc: std.mem.Allocator, extra_excludes: []const []const u8, negations: []const []const u8, depth: u32) !void {
    if (depth > 64) return;
    var dir = std.fs.cwd().openDir(abs_path, .{ .iterate = true, .no_follow = true }) catch return;
    defer dir.close();

    // Parse a local .gitignore in this directory (only for depth > 0;
    // the root .gitignore is already parsed by the caller via parseGitignoreExcludes).
    var local_patterns = std.ArrayList([]const u8){};
    defer {
        for (local_patterns.items) |e| alloc.free(e);
        local_patterns.deinit(alloc);
    }
    if (depth > 0) {
        var gi_buf: [4096]u8 = undefined;
        const gi_path = std.fmt.bufPrint(&gi_buf, "{s}/.gitignore", .{abs_path}) catch "";
        if (gi_path.len > 0) {
            if (std.fs.cwd().readFileAlloc(alloc, gi_path, 64 * 1024)) |content| {
                defer alloc.free(content);
                var lines = std.mem.splitScalar(u8, content, '\n');
                while (lines.next()) |raw| {
                    const line = std.mem.trim(u8, raw, " \r\t");
                    if (line.len == 0 or line[0] == '#' or line[0] == '!') continue;
                    const pat = parsePattern(raw) orelse continue;
                    const duped = alloc.dupe(u8, pat) catch continue;
                    local_patterns.append(alloc, duped) catch {
                        alloc.free(duped);
                    };
                }
            } else |_| {}
        }
    }

    // Merge parent excludes + local patterns into effective_excludes for this level and below.
    const effective_excludes: []const []const u8 = blk: {
        if (local_patterns.items.len == 0) break :blk extra_excludes;
        const merged = alloc.alloc([]const u8, extra_excludes.len + local_patterns.items.len) catch break :blk extra_excludes;
        @memcpy(merged[0..extra_excludes.len], extra_excludes);
        @memcpy(merged[extra_excludes.len..], local_patterns.items);
        break :blk merged;
    };
    defer if (effective_excludes.ptr != extra_excludes.ptr) alloc.free(effective_excludes);

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDir(root, abs_path, entry.name, effective_excludes, negations)) continue;
            const sub = std.fs.path.join(alloc, &.{ abs_path, entry.name }) catch continue;
            defer alloc.free(sub);
            try scanDir(root, sub, paths, alloc, effective_excludes, negations, depth + 1);
        } else if (entry.kind == .file) {
            const is_ruby = std.mem.endsWith(u8, entry.name, ".rb") or
                std.mem.endsWith(u8, entry.name, ".erb") or
                std.mem.endsWith(u8, entry.name, ".haml") or
                std.mem.endsWith(u8, entry.name, ".slim") or
                std.mem.endsWith(u8, entry.name, ".rbs") or
                std.mem.endsWith(u8, entry.name, ".rbi") or
                std.mem.endsWith(u8, entry.name, ".rake") or
                std.mem.endsWith(u8, entry.name, ".gemspec") or
                std.mem.endsWith(u8, entry.name, ".ru") or
                std.mem.endsWith(u8, entry.name, ".jbuilder") or
                std.mem.endsWith(u8, entry.name, ".builder") or
                std.mem.endsWith(u8, entry.name, ".yml") or
                std.mem.endsWith(u8, entry.name, ".yaml") or
                std.mem.eql(u8, entry.name, "Rakefile") or
                std.mem.eql(u8, entry.name, "Gemfile");
            if (!is_ruby) continue;
            const full = std.fs.path.join(alloc, &.{ abs_path, entry.name }) catch continue;
            try paths.append(alloc, full);
        }
    }
}

fn parsePattern(raw: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw, " \r\t");
    if (line.len == 0 or line[0] == '#') return null;
    // Strip trailing slashes (dir-only marker) and leading slash (rooted marker)
    const stripped = std.mem.trimRight(u8, line, "/");
    const name = std.mem.trimLeft(u8, stripped, "/");
    if (name.len == 0 or name.len > 512) return null;
    if (std.mem.indexOfAny(u8, name, "?[") != null) return null;
    // Allow: trailing * (prefix match), leading * (suffix match), interior / (path-relative)
    // Allow: **/X and X/** patterns (double-star depth anchors)
    // Reject: * in middle of a non-slash pattern, or multiple * (except ** anchors)
    const star_count = std.mem.count(u8, name, "*");
    if (star_count == 2) {
        if (std.mem.startsWith(u8, name, "**/") or std.mem.endsWith(u8, name, "/**")) return name;
        return null;
    }
    if (star_count > 2) return null;
    if (star_count == 1) {
        if (std.mem.indexOfScalar(u8, name, '*')) |star_idx| {
            // Allow leading * (e.g. *.log) or trailing * (e.g. tmp*)
            // Reject * in the middle of a segment
            if (star_idx != 0 and star_idx != name.len - 1) return null;
        }
    }
    return name;
}

pub fn parseGitignoreExcludes(root: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    var results = std.ArrayList([]const u8){};
    const gi_path = try std.fs.path.join(alloc, &.{ root, ".gitignore" });
    defer alloc.free(gi_path);
    const content = std.fs.cwd().readFileAlloc(alloc, gi_path, 64 * 1024) catch return results.toOwnedSlice(alloc);
    defer alloc.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#' or line[0] == '!') continue;
        const name = parsePattern(raw) orelse continue;
        const duped = alloc.dupe(u8, name) catch continue;
        results.append(alloc, duped) catch {
            alloc.free(duped);
            continue;
        };
    }
    return results.toOwnedSlice(alloc);
}

pub fn parseGitignoreNegations(root: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    var results = std.ArrayList([]const u8){};
    const gi_path = try std.fs.path.join(alloc, &.{ root, ".gitignore" });
    defer alloc.free(gi_path);
    const content = std.fs.cwd().readFileAlloc(alloc, gi_path, 64 * 1024) catch return results.toOwnedSlice(alloc);
    defer alloc.free(content);
    var saw_exclude = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '!') {
            if (!saw_exclude) continue;
            const name = parsePattern(line[1..]) orelse continue;
            const duped = alloc.dupe(u8, name) catch continue;
            results.append(alloc, duped) catch {
                alloc.free(duped);
                continue;
            };
        } else {
            if (parsePattern(raw) != null) saw_exclude = true;
        }
    }
    return results.toOwnedSlice(alloc);
}

pub fn scan(root: []const u8, alloc: std.mem.Allocator, extra_excludes: []const []const u8) ![][]u8 {
    var paths = std.ArrayList([]u8){};
    errdefer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }
    try scanDir(root, root, &paths, alloc, extra_excludes, &.{}, 0);
    return paths.toOwnedSlice(alloc);
}

pub fn scanWithNegations(root: []const u8, alloc: std.mem.Allocator, extra_excludes: []const []const u8, negations: []const []const u8) ![][]u8 {
    var paths = std.ArrayList([]u8){};
    errdefer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }
    try scanDir(root, root, &paths, alloc, extra_excludes, negations, 0);
    return paths.toOwnedSlice(alloc);
}
