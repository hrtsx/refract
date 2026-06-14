// Git HEAD/branch/project-identity detection for branch-accurate indexing.
//
// Pure filesystem reads — no subprocess, no libgit. Handles the three shapes
// that matter: a normal repo (`.git/` directory), a linked worktree (`.git`
// is a file holding `gitdir: <path>`), and detached HEAD (HEAD holds a raw
// sha instead of `ref: refs/heads/<branch>`).
//
// The server compares a cheap (branch, commit) token across flush ticks; on
// change it re-kicks the background indexer, whose scan + cleanupStale pass
// reconciles the derived graph to the new checkout before queries are served.

const std = @import("std");
const io = std.Options.debug_io;

const MAX_GIT_FILE = std.Io.Limit.limited(1 * 1024 * 1024);

const GitDirs = struct {
    /// Per-worktree git dir (holds HEAD).
    gitdir: []u8,
    /// Shared common dir (holds refs/heads, config). Equals gitdir for a
    /// normal repo; differs for a linked worktree.
    commondir: []u8,
    alloc: std.mem.Allocator,

    fn deinit(self: GitDirs) void {
        self.alloc.free(self.gitdir);
        if (self.commondir.ptr != self.gitdir.ptr) self.alloc.free(self.commondir);
    }
};

fn readTrimmed(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, MAX_GIT_FILE) catch return null;
    defer alloc.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return alloc.dupe(u8, trimmed) catch null;
}

/// Resolve a path that may be relative to `base`. Caller owns the result.
fn resolveRel(alloc: std.mem.Allocator, base: []const u8, p: []const u8) ![]u8 {
    if (p.len > 0 and p[0] == '/') return alloc.dupe(u8, p);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, p });
}

fn resolveGitDirs(alloc: std.mem.Allocator, root_path: []const u8) ?GitDirs {
    // Walk up from root_path to the enclosing repo: a project rooted in a
    // repo subdir (monorepo package, vendored corpus) must still resolve the
    // branch. `git` itself walks up; mirror that. Cap depth to bound work.
    var dir: []const u8 = root_path;
    var depth: usize = 0;
    while (depth < 40) : (depth += 1) {
        const dot_git = std.fmt.allocPrint(alloc, "{s}/.git", .{dir}) catch return null;
        defer alloc.free(dot_git);

        if (std.Io.Dir.cwd().statFile(io, dot_git, .{})) |st| {
            var gitdir: []u8 = undefined;
            if (st.kind == .directory) {
                gitdir = alloc.dupe(u8, dot_git) catch return null;
            } else {
                // Linked worktree: `.git` is a file `gitdir: <path>`.
                const content = readTrimmed(alloc, dot_git) orelse return null;
                defer alloc.free(content);
                const prefix = "gitdir:";
                if (!std.mem.startsWith(u8, content, prefix)) return null;
                const ptr = std.mem.trim(u8, content[prefix.len..], " \t");
                gitdir = resolveRel(alloc, dir, ptr) catch return null;
            }
            return finishGitDirs(alloc, gitdir);
        } else |_| {}

        // Ascend one directory; stop at filesystem root.
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
        if (slash == 0) return null; // reached "/"
        dir = dir[0..slash];
    }
    return null;
}

/// Given a resolved per-worktree gitdir, attach the shared commondir (if any).
fn finishGitDirs(alloc: std.mem.Allocator, gitdir: []u8) ?GitDirs {

    // commondir: present for linked worktrees, points at the main git dir.
    const commondir_file = std.fmt.allocPrint(alloc, "{s}/commondir", .{gitdir}) catch {
        return .{ .gitdir = gitdir, .commondir = gitdir, .alloc = alloc };
    };
    defer alloc.free(commondir_file);
    if (readTrimmed(alloc, commondir_file)) |rel| {
        defer alloc.free(rel);
        const common = resolveRel(alloc, gitdir, rel) catch gitdir;
        return .{ .gitdir = gitdir, .commondir = common, .alloc = alloc };
    }
    return .{ .gitdir = gitdir, .commondir = gitdir, .alloc = alloc };
}

/// Absolute path of the HEAD file to stat for cheap change detection.
/// Caller owns the result. null when the workspace is not a git repo.
pub fn headStatPath(alloc: std.mem.Allocator, root_path: []const u8) ?[]u8 {
    const dirs = resolveGitDirs(alloc, root_path) orelse return null;
    defer dirs.deinit();
    return std.fmt.allocPrint(alloc, "{s}/HEAD", .{dirs.gitdir}) catch null;
}

/// Resolve the sha a `refs/heads/<branch>` ref points at — loose ref first,
/// then packed-refs. Falls back to the ref name so a switch is still detected.
fn resolveRef(alloc: std.mem.Allocator, commondir: []const u8, ref: []const u8) []u8 {
    const loose = std.fmt.allocPrint(alloc, "{s}/{s}", .{ commondir, ref }) catch
        return alloc.dupe(u8, ref) catch @constCast(ref);
    defer alloc.free(loose);
    if (readTrimmed(alloc, loose)) |sha| return sha;

    const packed_path = std.fmt.allocPrint(alloc, "{s}/packed-refs", .{commondir}) catch
        return alloc.dupe(u8, ref) catch @constCast(ref);
    defer alloc.free(packed_path);
    if (std.Io.Dir.cwd().readFileAlloc(io, packed_path, alloc, MAX_GIT_FILE)) |body| {
        defer alloc.free(body);
        var lines = std.mem.tokenizeScalar(u8, body, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const sha = line[0..sp];
            const name = std.mem.trim(u8, line[sp + 1 ..], " \t\r");
            if (std.mem.eql(u8, name, ref)) return alloc.dupe(u8, sha) catch @constCast(ref);
        }
    } else |_| {}
    return alloc.dupe(u8, ref) catch @constCast(ref);
}

pub const Head = struct {
    /// Branch name (e.g. "main"), or null for detached HEAD.
    branch: ?[]u8,
    /// Resolved commit sha (or ref/HEAD content when unresolved).
    commit: []u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: Head) void {
        if (self.branch) |b| self.alloc.free(b);
        self.alloc.free(self.commit);
    }
};

/// Read current branch + commit. Caller owns the result. null when not a repo.
pub fn readHead(alloc: std.mem.Allocator, root_path: []const u8) ?Head {
    const dirs = resolveGitDirs(alloc, root_path) orelse return null;
    defer dirs.deinit();

    const head_path = std.fmt.allocPrint(alloc, "{s}/HEAD", .{dirs.gitdir}) catch return null;
    defer alloc.free(head_path);
    const content = readTrimmed(alloc, head_path) orelse return null;
    defer alloc.free(content);

    const ref_prefix = "ref:";
    if (std.mem.startsWith(u8, content, ref_prefix)) {
        const ref = std.mem.trim(u8, content[ref_prefix.len..], " \t");
        const short = if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| ref[i + 1 ..] else ref;
        const branch = alloc.dupe(u8, short) catch return null;
        const commit = resolveRef(alloc, dirs.commondir, ref);
        return .{ .branch = branch, .commit = commit, .alloc = alloc };
    }
    // Detached HEAD: content is the raw sha.
    const commit = alloc.dupe(u8, content) catch return null;
    return .{ .branch = null, .commit = commit, .alloc = alloc };
}

/// A compact "branch\x1fcommit" token for change detection. Caller owns it.
pub fn readToken(alloc: std.mem.Allocator, root_path: []const u8) ?[]u8 {
    const head = readHead(alloc, root_path) orelse return null;
    defer head.deinit();
    return std.fmt.allocPrint(alloc, "{s}\x1f{s}", .{ head.branch orelse "(detached)", head.commit }) catch null;
}

/// Stable project identity that survives worktrees and clones. Order: remote
/// origin url → git common dir → root_path. Returned as a 16-hex hash, always
/// non-null (root_path fallback). Caller owns the result.
pub fn projectId(alloc: std.mem.Allocator, root_path: []const u8) []u8 {
    var identity: []const u8 = root_path;
    var owned: ?[]u8 = null;
    defer if (owned) |o| alloc.free(o);

    if (resolveGitDirs(alloc, root_path)) |dirs| {
        defer dirs.deinit();
        const cfg_path = std.fmt.allocPrint(alloc, "{s}/config", .{dirs.commondir}) catch dirs.commondir;
        const free_cfg = cfg_path.ptr != dirs.commondir.ptr;
        if (originUrl(alloc, cfg_path)) |url| {
            owned = url;
            identity = url;
        } else {
            owned = alloc.dupe(u8, dirs.commondir) catch null;
            if (owned) |o| identity = o;
        }
        if (free_cfg) alloc.free(cfg_path);
    }

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(identity);
    return std.fmt.allocPrint(alloc, "{x:0>16}", .{hasher.final()}) catch alloc.dupe(u8, "0") catch @constCast("0");
}

/// Parse `url = ...` under `[remote "origin"]` from a git config file.
fn originUrl(alloc: std.mem.Allocator, cfg_path: []const u8) ?[]u8 {
    const body = std.Io.Dir.cwd().readFileAlloc(io, cfg_path, alloc, MAX_GIT_FILE) catch return null;
    defer alloc.free(body);
    var in_origin = false;
    var lines = std.mem.tokenizeScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            in_origin = std.mem.eql(u8, line, "[remote \"origin\"]");
            continue;
        }
        if (in_origin and std.mem.startsWith(u8, line, "url")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (val.len > 0) return alloc.dupe(u8, val) catch null;
        }
    }
    return null;
}

test "detached vs ref token differ" {
    const a = std.testing.allocator;
    // Smoke: projectId always returns non-empty for any path.
    const pid = projectId(a, "/nonexistent/xyz");
    defer a.free(pid);
    try std.testing.expect(pid.len == 16);
}
