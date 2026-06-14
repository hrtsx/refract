const std = @import("std");
const db_mod = @import("../db.zig");
const refactor_mod = @import("../lsp/refactor.zig");
const overlay = @import("../lsp/overlay.zig");
const git_branch = @import("../lsp/git_branch.zig");
const build_meta = @import("build_meta");

const PROTOCOL_VERSION = "2025-06-18";

const schema_resolve_type =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"line":{"type":"integer","description":"1-based line number"},"col":{"type":"integer","description":"0-based column offset (optional)"}},"required":["file","line"]}
;
const schema_class_summary =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Fully qualified class or module name"}},"required":["class_name"]}
;
const schema_method_signature =
    \\{"type":"object","properties":{"symbol":{"type":"string","description":"Qualified form 'Class#method' (preferred)"},"class_name":{"type":"string","description":"Class or module name (legacy, use 'symbol' instead)"},"method_name":{"type":"string","description":"Method name (legacy, use 'symbol' instead)"}},"required":[]}
;
const schema_find_callers =
    \\{"type":"object","properties":{"symbol":{"type":"string","description":"Qualified form 'Class#method' or bare method name (preferred)"},"class_name":{"type":"string","description":"Receiver class name (optional filter, legacy)"},"method_name":{"type":"string","description":"Method name to find callers of (legacy, use 'symbol' instead)"},"ref_kind":{"type":"string","description":"Optional kind filter: call, assign, decl, super, yield, alias"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":[]}
;
const schema_find_implementations =
    \\{"type":"object","properties":{"method_name":{"type":"string","description":"Method name to find implementations of"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["method_name"]}
;
const schema_workspace_symbols =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Name prefix or substring to search for"},"kind":{"type":"string","description":"Optional kind filter: class, def, module, constant"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["query"]}
;
const schema_type_hierarchy =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Class or module name"},"ancestors_offset":{"type":"integer","description":"Pagination offset for ancestors list, default 0"},"descendants_offset":{"type":"integer","description":"Pagination offset for descendants list, default 0"}},"required":["class_name"]}
;
const schema_association_graph =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"ActiveRecord class name"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["class_name"]}
;
const schema_route_map =
    \\{"type":"object","properties":{"prefix":{"type":"string","description":"Optional prefix filter for route helper names"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":[]}
;
const schema_diagnostics =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the file (omit for all files)"},"offset":{"type":"integer","description":"Pagination offset for workspace mode, default 0"}},"required":[]}
;
const schema_get_symbol_source =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Fully qualified class or module name"},"method_name":{"type":"string","description":"Method name"}},"required":["class_name","method_name"]}
;
const schema_grep_source =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Text to search for (literal or regex)"},"file_pattern":{"type":"string","description":"Optional glob-style path filter, e.g. 'models/*.rb'"},"context_lines":{"type":"integer","description":"Lines of context around each match (default 1, max 5)"},"use_regex":{"type":"boolean","description":"If true, treat query as regex supporting ^ $ . * +"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["query"]}
;
const schema_i18n_lookup =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Key prefix or substring (case-insensitive), e.g. 'models.user'"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["query"]}
;
const schema_list_by_kind =
    \\{"type":"object","properties":{"kind":{"type":"string","enum":["class","module","def","constant","association","route_helper"],"description":"Symbol kind to list"},"name_filter":{"type":"string","description":"Optional name prefix"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["kind"]}
;
const schema_find_unused =
    \\{"type":"object","properties":{"kind":{"type":"string","description":"Symbol kind to check, default 'def'"},"parent_name":{"type":"string","description":"Optional class filter"}},"required":[]}
;
const schema_get_file_overview =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Path to the source file (absolute or relative to workspace root)"}},"required":["file"]}
;
const schema_list_validations =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Class or module name to list validations for"}},"required":["class_name"]}
;
const schema_list_callbacks =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Class or module name"},"callback_type":{"type":"string","description":"Optional callback name filter, e.g. 'before_save'"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["class_name"]}
;
const schema_concern_usage =
    \\{"type":"object","properties":{"module_name":{"type":"string","description":"Module or concern name to find usages of"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["module_name"]}
;
const schema_find_references =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Method or symbol name to find references to"},"ref_kind":{"type":"string","description":"Optional kind filter: call, assign, decl, super, yield, alias"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["name"]}
;
const schema_explain_symbol =
    \\{"type":"object","properties":{"symbol":{"type":"string","description":"Qualified form 'Class#method' (preferred)"},"class_name":{"type":"string","description":"Fully qualified class or module name (legacy, use 'symbol' instead)"},"method_name":{"type":"string","description":"Method name (legacy, use 'symbol' instead)"}},"required":[]}
;
const schema_batch_resolve =
    \\{"type":"object","properties":{"positions":{"type":"array","description":"Array of source positions to resolve (max 20)","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"col":{"type":"integer"}},"required":["file","line"]}}},"required":["positions"]}
;
const schema_workspace_health =
    \\{"type":"object","properties":{},"required":[]}
;
const schema_test_summary =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the test file"}},"required":["file"]}
;
const schema_list_routes =
    \\{"type":"object","properties":{"prefix":{"type":"string","description":"Optional helper name prefix filter"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":[]}
;
const schema_refactor =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"start_line":{"type":"integer","description":"0-based start line"},"end_line":{"type":"integer","description":"0-based end line"},"kind":{"type":"string","enum":["extract_method","extract_variable"],"description":"Type of refactoring to perform"}},"required":["file","start_line","end_line","kind"]}
;
const schema_available_code_actions =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"line":{"type":"integer","description":"0-based line number"},"character":{"type":"integer","description":"0-based column (default 0)"}},"required":["file","line"]}
;
const schema_diagnostic_summary =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Optional file path filter"},"severity_filter":{"type":"string","enum":["error","warning","info"],"description":"Filter by severity"},"code_filter":{"type":"string","description":"Filter by diagnostic code"}},"required":[]}
;
const schema_type_coverage =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Optional file path — omit for workspace-wide"},"min_coverage":{"type":"number","description":"Only show files below this percentage (0-100, default 100)"}},"required":[]}
;
const schema_find_similar =
    \\{"type":"object","properties":{"method_name":{"type":"string","description":"Method name to find similar methods for"},"max_distance":{"type":"integer","description":"Maximum edit distance (default 2)"}},"required":["method_name"]}
;
const schema_explain_type_chain =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"line":{"type":"integer","description":"1-based line number"},"col":{"type":"integer","description":"0-based column offset"}},"required":["file","line"]}
;
const schema_suggest_types =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"limit":{"type":"integer","description":"Max suggestions (default 20)"}},"required":["file"]}
;
const schema_coverage_gap_analyzer =
    \\{"type":"object","properties":{"file":{"type":"string"},"threshold":{"type":"integer"}},"required":[]}
;
const schema_security_audit_summary =
    \\{"type":"object","properties":{"file":{"type":"string"}},"required":[]}
;
const schema_migration_chain_analyzer =
    \\{"type":"object","properties":{},"required":[]}
;
const schema_dependency_tree_resolver =
    \\{"type":"object","properties":{},"required":[]}
;
const schema_unused_association_chain =
    \\{"type":"object","properties":{"class_name":{"type":"string"}},"required":[]}
;

const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
};

const schema_overlay_annotate =
    \\{"type":"object","properties":{"op":{"type":"string","enum":["note","tag","concept","edge","override","suppress"],"description":"Overlay write kind"},"reason":{"type":"string","description":"Required justification (audited)"},"fqn":{"type":"string","description":"Target symbol 'Class#method' or 'Class' (note/tag/concept/override; or suppress target)"},"from":{"type":"string","description":"edge: source fqn"},"to":{"type":"string","description":"edge: target fqn"},"edge_kind":{"type":"string","description":"edge relation: depends_on|related_to|alias|overrides|custom (default related_to)"},"label":{"type":"string","description":"short label (concept/edge/tag)"},"content":{"type":"string","description":"note/comment body"},"method":{"type":"string","description":"override: method name (omit for class-level)"},"param_pos":{"type":"integer","description":"override: -1 return type, >=0 param index (default -1)"},"type":{"type":"string","description":"override: asserted type string"},"diag_code":{"type":"string","description":"suppress: diagnostic code"},"file":{"type":"string","description":"suppress: file path (alternative to fqn)"},"line":{"type":"integer","description":"suppress: optional line"},"source":{"type":"string","enum":["agent","user"],"description":"default agent (lower trust)"},"scope":{"type":"string","enum":["branch","global"],"description":"default branch (current git branch); global = all branches"},"branch":{"type":"string","description":"explicit branch to scope this tweak to (overrides scope/current branch)"}},"required":["op","reason"]}
;
const schema_overlay_list =
    \\{"type":"object","properties":{"kind":{"type":"string","enum":["node","edge","type","suppress"],"description":"Overlay table to list"},"all_branches":{"type":"boolean","description":"include every branch (default false = current branch + global)"}},"required":["kind"]}
;
const schema_overlay_revert =
    \\{"type":"object","properties":{"kind":{"type":"string","enum":["node","edge","type","suppress"],"description":"Overlay table"},"id":{"type":"integer","description":"overlay row id from overlay_list"},"reason":{"type":"string","description":"Required justification (audited)"}},"required":["kind","id","reason"]}
;
const schema_overlay_promote =
    \\{"type":"object","properties":{"from_branch":{"type":"string","description":"branch to promote from (default current branch)"},"reason":{"type":"string","description":"Required justification (audited)"}},"required":["reason"]}
;

const TOOLS = [_]ToolEntry{
    .{ .name = "resolve_type", .description = "Resolve the inferred type of a local variable at a source position", .schema = schema_resolve_type },
    .{ .name = "class_summary", .description = "Get methods, constants, and mixins for a class or module", .schema = schema_class_summary },
    .{ .name = "method_signature", .description = "Get the full signature and parameter types of a method", .schema = schema_method_signature },
    .{ .name = "find_callers", .description = "Find all call sites of a method in the workspace", .schema = schema_find_callers },
    .{ .name = "find_implementations", .description = "Find all classes that define a given method name", .schema = schema_find_implementations },
    .{ .name = "workspace_symbols", .description = "Search symbols across the entire workspace by name", .schema = schema_workspace_symbols },
    .{ .name = "type_hierarchy", .description = "Get ancestor chain and known descendants of a class", .schema = schema_type_hierarchy },
    .{ .name = "association_graph", .description = "Get ActiveRecord associations (has_many, belongs_to, etc) for a class", .schema = schema_association_graph },
    .{ .name = "route_map", .description = "List all Rails route helpers with optional prefix filter", .schema = schema_route_map },
    .{ .name = "diagnostics", .description = "Get parse and semantic diagnostics for a file", .schema = schema_diagnostics },
    .{ .name = "get_symbol_source", .description = "Get the source code of a class method", .schema = schema_get_symbol_source },
    .{ .name = "grep_source", .description = "Search for literal text across all workspace source files with surrounding context", .schema = schema_grep_source },
    .{ .name = "i18n_lookup", .description = "Find i18n translation keys and their values", .schema = schema_i18n_lookup },
    .{ .name = "list_by_kind", .description = "List all symbols of a given kind (class, module, def, etc)", .schema = schema_list_by_kind },
    .{ .name = "find_unused", .description = "Find symbols with no recorded call sites (static dead-code approximation)", .schema = schema_find_unused },
    .{ .name = "get_file_overview", .description = "List all symbols in a file ordered by line (flat, fast overview)", .schema = schema_get_file_overview },
    .{ .name = "list_validations", .description = "List ActiveRecord validation calls for a class", .schema = schema_list_validations },
    .{ .name = "list_callbacks", .description = "List ActiveRecord/ActionController callbacks for a class", .schema = schema_list_callbacks },
    .{ .name = "concern_usage", .description = "Find all classes that include/prepend/extend a given module or concern", .schema = schema_concern_usage },
    .{ .name = "find_references", .description = "Find all recorded call-site references to a method or symbol name", .schema = schema_find_references },
    .{ .name = "explain_symbol", .description = "Get a full picture of a method: signature, callers, and diagnostics in one call", .schema = schema_explain_symbol },
    .{ .name = "batch_resolve", .description = "Resolve types at multiple source positions in one call (max 20 positions)", .schema = schema_batch_resolve },
    .{ .name = "workspace_health", .description = "Get workspace quality metrics: file counts, type coverage, diagnostic summary, schema version", .schema = schema_workspace_health },
    .{ .name = "test_summary", .description = "List discovered tests in a file with their kind (rspec/minitest) and line numbers", .schema = schema_test_summary },
    .{ .name = "list_routes", .description = "List all Rails route helpers with controller and action details", .schema = schema_list_routes },
    .{ .name = "refactor", .description = "Apply refactoring operations (extract_method, extract_variable) to source code", .schema = schema_refactor },
    .{ .name = "available_code_actions", .description = "Get list of available code actions at a specific location", .schema = schema_available_code_actions },
    .{ .name = "diagnostic_summary", .description = "Get diagnostics with optional filtering by file, severity, or code", .schema = schema_diagnostic_summary },
    .{ .name = "explain_type_chain", .description = "Explain how a local variable's type was inferred — shows chain from source (RBS, YARD, literal, chain)", .schema = schema_explain_type_chain },
    .{ .name = "suggest_types", .description = "Suggest YARD/RBS type annotations for untyped methods in a file", .schema = schema_suggest_types },
    .{ .name = "type_coverage", .description = "Show type annotation coverage per file — percentage of methods with return types", .schema = schema_type_coverage },
    .{ .name = "find_similar", .description = "Find methods with similar names (typo detection, naming consistency)", .schema = schema_find_similar },
    .{ .name = "coverage_gap_analyzer", .description = "Identify untested definitions by reference count", .schema = schema_coverage_gap_analyzer },
    .{ .name = "security_audit_summary", .description = "Aggregate security findings with severity scoring", .schema = schema_security_audit_summary },
    .{ .name = "migration_chain_analyzer", .description = "Analyze Rails migrations for dependency hazards", .schema = schema_migration_chain_analyzer },
    .{ .name = "dependency_tree_resolver", .description = "Build transitive dependency DAG from Gemfile.lock", .schema = schema_dependency_tree_resolver },
    .{ .name = "unused_association_chain", .description = "Find unused ActiveRecord associations", .schema = schema_unused_association_chain },
    .{ .name = "find_symbol", .description = "Alias for workspace_symbols — search symbols across the entire workspace by name", .schema = schema_workspace_symbols },
    .{ .name = "search_symbols", .description = "Alias for workspace_symbols — search symbols across the entire workspace by name", .schema = schema_workspace_symbols },
    .{ .name = "overlay_annotate", .description = "Add a gated overlay tweak (note/tag/concept/edge/type-override/diagnostic-suppress) — branch-scoped, reversible, audited. The only writable graph surface; derived facts stay immutable", .schema = schema_overlay_annotate },
    .{ .name = "overlay_list", .description = "List live overlay tweaks (node/edge/type/suppress) for the current project and branch (plus project-global)", .schema = schema_overlay_list },
    .{ .name = "overlay_revert", .description = "Soft-delete (revert) an overlay tweak by id", .schema = schema_overlay_revert },
    .{ .name = "overlay_promote", .description = "Promote branch-scoped overlay tweaks to project-global (visible on every branch and worktree)", .schema = schema_overlay_promote },
};

// Default per-second request cap. stdio MCP is a trusted single-user local
// process, so the default is generous; raise/disable via REFRACT_MAX_RPS
// (integer; 0 = unlimited). Guards only against runaway loops, not abuse.
const DEFAULT_MAX_REQUESTS_PER_SEC: u32 = 1000;
pub const MAX_RESPONSE_BYTES: usize = 1_048_576; // 1 MiB
pub const MAX_LINE_BODY_BYTES: usize = 512; // per-line cap for grep_source match/context

pub const Server = struct {
    db: db_mod.Db,
    alloc: std.mem.Allocator,
    request_count: u32 = 0,
    request_window_ms: i64 = 0,
    /// Per-second request cap (0 = unlimited). Set from REFRACT_MAX_RPS in init().
    max_rps: u32 = DEFAULT_MAX_REQUESTS_PER_SEC,
    audit_lock_err_logged: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Real (symlink-resolved) absolute path of the workspace root. Used to
    /// containment-check fpaths read by grep_source / get_symbol_source.
    workspace_root: ?[:0]u8 = null,

    pub fn init(db: db_mod.Db, alloc: std.mem.Allocator) Server {
        var s = Server{ .db = db, .alloc = alloc };
        if (std.c.getenv("REFRACT_MAX_RPS")) |v| {
            if (std.fmt.parseInt(u32, std.mem.span(v), 10) catch null) |n| s.max_rps = n;
        }
        // Resolve cwd's realpath once. Stored for containment checks; freed in deinit().
        if (std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, ".", alloc)) |root| {
            s.workspace_root = root;
        } else |_| {}
        return s;
    }

    pub fn deinit(self: *Server) void {
        if (self.workspace_root) |r| self.alloc.free(r);
        self.workspace_root = null;
    }

    /// Returns true if `fpath` (after symlink resolution) lies under the
    /// workspace root. Falls back to fail-open when workspace_root could not
    /// be resolved during init() — the indexer's own path scoping (only
    /// scans the workspace) is the primary defense; this is defense-in-depth.
    fn pathInWorkspace(self: *Server, fpath: []const u8) bool {
        const root = self.workspace_root orelse return true;
        const real = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, fpath, self.alloc) catch return false;
        defer self.alloc.free(real);
        if (!std.mem.startsWith(u8, real, root)) return false;
        // Tighten prefix match: avoid /workspace-evil matching /workspace.
        return real.len == root.len or real[root.len] == '/';
    }

    pub fn run(self: *Server, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        while (true) {
            // MCP stdio transport: bare JSON lines (one JSON object per line, no headers)
            const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            const raw = std.mem.trimEnd(u8, line, "\r\n \t");
            if (raw.len == 0) continue;

            const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, raw, .{}) catch continue;
            defer parsed.deinit();

            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            const method_val = obj.get("method") orelse continue;
            const method = switch (method_val) {
                .string => |s| s,
                else => continue,
            };
            const id = obj.get("id");
            const params = obj.get("params");

            const now_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
            if (now_ms - self.request_window_ms > 1000) {
                self.request_count = 0;
                self.request_window_ms = now_ms;
            }
            self.request_count += 1;
            if (self.max_rps != 0 and self.request_count > self.max_rps) {
                if (id != null) {
                    const rl_resp = self.buildError(id, -32600, "rate limit exceeded") catch null;
                    if (rl_resp) |resp| {
                        defer self.alloc.free(resp);
                        writer.writeAll(resp) catch break;
                        writer.writeByte('\n') catch break;
                        writer.flush() catch break;
                    }
                }
                continue;
            }

            const resp_opt = self.dispatch(method, id, params) catch |e| blk: {
                if (id == null) break :blk null;
                break :blk self.buildError(id, -32603, @errorName(e)) catch null;
            };
            if (resp_opt) |resp| {
                defer self.alloc.free(resp);
                if (resp.len > MAX_RESPONSE_BYTES) {
                    const too_big = self.buildError(id, -32000, "response too large — narrow the query or use pagination (offset)") catch null;
                    if (too_big) |tb| {
                        defer self.alloc.free(tb);
                        writer.writeAll(tb) catch break;
                        writer.writeByte('\n') catch break;
                        writer.flush() catch break;
                    }
                } else {
                    writer.writeAll(resp) catch break;
                    writer.writeByte('\n') catch break;
                    writer.flush() catch break;
                }
            }
        }
    }

    fn dispatch(self: *Server, method: []const u8, id: ?std.json.Value, params: ?std.json.Value) !?[]u8 {
        if (std.mem.eql(u8, method, "initialize")) {
            if (id == null) return null;
            return self.handleInitialize(id);
        }
        if (std.mem.eql(u8, method, "notifications/initialized") or
            std.mem.eql(u8, method, "initialized"))
        {
            return null;
        }
        if (std.mem.eql(u8, method, "ping")) {
            if (id == null) return null;
            return self.buildResult(id, "{}");
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            if (id == null) return null;
            return self.handleToolsList(id);
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            if (id == null) return null;
            return self.handleToolsCall(id, params);
        }
        if (std.mem.eql(u8, method, "resources/list")) {
            if (id == null) return null;
            return self.handleResourcesList(id);
        }
        if (std.mem.eql(u8, method, "resources/read")) {
            if (id == null) return null;
            return self.handleResourcesRead(id, params);
        }
        if (std.mem.eql(u8, method, "prompts/list")) {
            if (id == null) return null;
            return self.handlePromptsList(id);
        }
        if (std.mem.eql(u8, method, "prompts/get")) {
            if (id == null) return null;
            return self.handlePromptsGet(id, params);
        }
        if (id == null) return null;
        return self.buildError(id, -32601, "Method not found");
    }

    fn handleInitialize(self: *Server, id: ?std.json.Value) !?[]u8 {
        const result =
            "{\"protocolVersion\":\"" ++ PROTOCOL_VERSION ++ "\"," ++
            "\"capabilities\":{\"tools\":{},\"resources\":{\"listChanged\":false},\"prompts\":{\"listChanged\":false}}," ++
            "\"serverInfo\":{\"name\":\"refract\",\"version\":\"" ++ build_meta.version ++ "\"}}";
        return self.buildResult(id, result);
    }

    fn handleToolsList(self: *Server, id: ?std.json.Value) !?[]u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"tools\":[");
        for (TOOLS, 0..) |t, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, t.name);
            try w.writeAll(",\"description\":");
            try writeJsonStr(w, t.description);
            try w.writeAll(",\"inputSchema\":");
            try w.writeAll(t.schema);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        const result = try aw.toOwnedSlice();
        defer self.alloc.free(result);
        return self.buildResult(id, result);
    }

    fn handleToolsCall(self: *Server, id: ?std.json.Value, params: ?std.json.Value) !?[]u8 {
        const params_obj = switch (params orelse return self.buildToolError(id, "missing params")) {
            .object => |o| o,
            else => return self.buildToolError(id, "params must be object"),
        };
        const name_val = params_obj.get("name") orelse return self.buildToolError(id, "missing tool name");
        const name = switch (name_val) {
            .string => |s| s,
            else => return self.buildToolError(id, "tool name must be string"),
        };
        const args = if (params_obj.get("arguments")) |a| switch (a) {
            .object => |o| o,
            else => null,
        } else null;

        if (std.mem.eql(u8, name, "resolve_type")) return self.toolResolveType(id, args);
        if (std.mem.eql(u8, name, "class_summary")) return self.toolClassSummary(id, args);
        if (std.mem.eql(u8, name, "method_signature")) return self.toolMethodSignature(id, args);
        if (std.mem.eql(u8, name, "find_callers")) return self.toolFindCallers(id, args);
        if (std.mem.eql(u8, name, "find_implementations")) return self.toolFindImplementations(id, args);
        if (std.mem.eql(u8, name, "workspace_symbols")) return self.toolWorkspaceSymbols(id, args);
        if (std.mem.eql(u8, name, "type_hierarchy")) return self.toolTypeHierarchy(id, args);
        if (std.mem.eql(u8, name, "association_graph")) return self.toolAssociationGraph(id, args);
        if (std.mem.eql(u8, name, "route_map")) return self.toolRouteMap(id, args);
        if (std.mem.eql(u8, name, "diagnostics")) return self.toolDiagnostics(id, args);
        if (std.mem.eql(u8, name, "get_symbol_source")) return self.toolGetSymbolSource(id, args);
        if (std.mem.eql(u8, name, "grep_source")) return self.toolGrepSource(id, args);
        if (std.mem.eql(u8, name, "i18n_lookup")) return self.toolI18nLookup(id, args);
        if (std.mem.eql(u8, name, "list_by_kind")) return self.toolListByKind(id, args);
        if (std.mem.eql(u8, name, "find_unused")) return self.toolFindUnused(id, args);
        if (std.mem.eql(u8, name, "get_file_overview")) return self.toolGetFileOverview(id, args);
        if (std.mem.eql(u8, name, "list_validations")) return self.toolListValidations(id, args);
        if (std.mem.eql(u8, name, "list_callbacks")) return self.toolListCallbacks(id, args);
        if (std.mem.eql(u8, name, "concern_usage")) return self.toolConcernUsage(id, args);
        if (std.mem.eql(u8, name, "find_references")) return self.toolFindReferences(id, args);
        if (std.mem.eql(u8, name, "explain_symbol")) return self.toolExplainSymbol(id, args);
        if (std.mem.eql(u8, name, "batch_resolve")) return self.toolBatchResolve(id, params_obj.get("arguments"));
        if (std.mem.eql(u8, name, "workspace_health")) return self.toolWorkspaceHealth(id);
        if (std.mem.eql(u8, name, "test_summary")) return self.toolTestSummary(id, args);
        if (std.mem.eql(u8, name, "list_routes")) return self.toolListRoutes(id, args);
        if (std.mem.eql(u8, name, "refactor")) return self.toolRefactor(id, args);
        if (std.mem.eql(u8, name, "available_code_actions")) return self.toolAvailableCodeActions(id, args);
        if (std.mem.eql(u8, name, "diagnostic_summary")) return self.toolDiagnosticSummary(id, args);
        if (std.mem.eql(u8, name, "explain_type_chain")) return self.toolExplainTypeChain(id, args);
        if (std.mem.eql(u8, name, "suggest_types")) return self.toolSuggestTypes(id, args);
        if (std.mem.eql(u8, name, "type_coverage")) return self.toolTypeCoverage(id, args);
        if (std.mem.eql(u8, name, "find_similar")) return self.toolFindSimilar(id, args);
        if (std.mem.eql(u8, name, "coverage_gap_analyzer")) return self.toolCoverageGapAnalyzer(id, args);
        if (std.mem.eql(u8, name, "security_audit_summary")) return self.toolSecurityAuditSummary(id, args);
        if (std.mem.eql(u8, name, "migration_chain_analyzer")) return self.toolMigrationChainAnalyzer(id, args);
        if (std.mem.eql(u8, name, "dependency_tree_resolver")) return self.toolDependencyTreeResolver(id, args);
        if (std.mem.eql(u8, name, "unused_association_chain")) return self.toolUnusedAssociationChain(id, args);

        if (std.mem.eql(u8, name, "overlay_annotate")) return self.toolOverlayAnnotate(id, args);
        if (std.mem.eql(u8, name, "overlay_list")) return self.toolOverlayList(id, args);
        if (std.mem.eql(u8, name, "overlay_revert")) return self.toolOverlayRevert(id, args);
        if (std.mem.eql(u8, name, "overlay_promote")) return self.toolOverlayPromote(id, args);

        // Aliases for common guesses — forward to canonical handlers.
        if (std.mem.eql(u8, name, "find_symbol") or std.mem.eql(u8, name, "search_symbols")) return self.toolWorkspaceSymbols(id, args);

        return self.buildError(id, -32601, "Unknown tool");
    }

    // ---- overlay (agent/user-writable graph layer) ----

    const OverlayCtx = struct {
        pid: []u8,
        branch: ?[]u8,
        alloc: std.mem.Allocator,
        fn deinit(self: OverlayCtx) void {
            self.alloc.free(self.pid);
            if (self.branch) |b| self.alloc.free(b);
        }
    };

    /// Resolve project identity + current git branch for the workspace.
    fn overlayCtx(self: *Server) ?OverlayCtx {
        const root = self.workspace_root orelse return null;
        const pid = git_branch.projectId(self.alloc, root);
        var branch: ?[]u8 = null;
        if (git_branch.readHead(self.alloc, root)) |h| {
            if (h.branch) |b| branch = self.alloc.dupe(u8, b) catch null;
            h.deinit();
        }
        return .{ .pid = pid, .branch = branch, .alloc = self.alloc };
    }

    fn overlayTable(kind: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, kind, "node")) return "overlay_nodes";
        if (std.mem.eql(u8, kind, "edge")) return "overlay_edges";
        if (std.mem.eql(u8, kind, "type")) return "overlay_types";
        if (std.mem.eql(u8, kind, "suppress")) return "overlay_suppress";
        return null;
    }

    fn gateMsg(e: overlay.GateError) []const u8 {
        return switch (e) {
            overlay.GateError.ReasonRequired => "reason is required",
            overlay.GateError.ReasonTooLong => "reason exceeds size cap",
            overlay.GateError.PayloadTooLong => "payload exceeds size cap",
            overlay.GateError.BadOp => "unknown op",
            overlay.GateError.MissingTarget => "missing required target field",
        };
    }

    fn nowUs() i64 {
        return @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_us));
    }

    fn nowS() i64 {
        return @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_s));
    }

    fn auditOverlay(self: *Server, tool: []const u8, fqn: ?[]const u8, result_kind: []const u8) void {
        const stmt = self.db.prepare("INSERT INTO audit_log(ts_us,tool_name,result_kind,affected_fqn) VALUES(?,?,?,?)") catch {
            logAuditDbError(self);
            return;
        };
        defer stmt.finalize();
        stmt.bind_int(1, nowUs());
        stmt.bind_text(2, tool);
        stmt.bind_text(3, result_kind);
        if (fqn) |f| stmt.bind_text(4, f) else stmt.bind_null(4);
        _ = stmt.step() catch logAuditDbError(self);
    }

    fn overlayOk(self: *Server, id: ?std.json.Value, new_id: i64, eff_branch: ?[]const u8, is_user: bool) !?[]u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\"ok\":true,\"id\":{d},\"branch\":", .{new_id});
        if (eff_branch) |b| try writeJsonStr(w, b) else try w.writeAll("null");
        try w.print(",\"source\":\"{s}\",\"confidence\":{d}}}", .{ if (is_user) "USER" else "AGENT", @as(i64, if (is_user) overlay.CONF_USER else overlay.CONF_AGENT) });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolOverlayAnnotate(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const op_s = getStrArg(args, "op") orelse return self.buildToolError(id, "missing 'op'");
        const op = overlay.parseOp(op_s) orelse return self.buildToolError(id, "unknown 'op'");
        const reason = getStrArg(args, "reason") orelse return self.buildToolError(id, "missing 'reason'");
        const ctx = self.overlayCtx() orelse return self.buildToolError(id, "no workspace/project identity");
        defer ctx.deinit();
        const scope = getStrArg(args, "scope") orelse "branch";
        // Explicit 'branch' wins; else 'scope':global => project-global (null);
        // else the server-detected current branch.
        const eff_branch: ?[]const u8 = if (getStrArg(args, "branch")) |b|
            b
        else if (std.mem.eql(u8, scope, "global"))
            null
        else
            ctx.branch;
        const is_user = if (getStrArg(args, "source")) |s| std.mem.eql(u8, s, "user") else false;
        const now_s = nowS();

        var new_id: ?i64 = null;
        var affected: ?[]const u8 = null;
        switch (op) {
            .note, .tag, .concept => {
                const fqn = getStrArg(args, "fqn") orelse return self.buildToolError(id, "missing 'fqn'");
                affected = fqn;
                new_id = overlay.addNode(self.db, ctx.pid, eff_branch, fqn, op_s, getStrArg(args, "label"), getStrArg(args, "content"), is_user, reason, now_s) catch |e| {
                    self.auditOverlay("overlay_annotate", fqn, "error");
                    return self.buildToolError(id, gateMsg(e));
                };
            },
            .edge => {
                const from = getStrArg(args, "from") orelse return self.buildToolError(id, "edge requires 'from'");
                const to = getStrArg(args, "to") orelse return self.buildToolError(id, "edge requires 'to'");
                affected = from;
                new_id = overlay.addEdge(self.db, ctx.pid, eff_branch, from, to, getStrArg(args, "edge_kind") orelse "related_to", getStrArg(args, "label"), is_user, reason, now_s) catch |e| {
                    self.auditOverlay("overlay_annotate", from, "error");
                    return self.buildToolError(id, gateMsg(e));
                };
            },
            .override => {
                const fqn = getStrArg(args, "fqn") orelse return self.buildToolError(id, "override requires 'fqn'");
                const type_str = getStrArg(args, "type") orelse return self.buildToolError(id, "override requires 'type'");
                affected = fqn;
                new_id = overlay.addType(self.db, ctx.pid, eff_branch, fqn, getStrArg(args, "method"), getIntArg(args, "param_pos") orelse -1, type_str, is_user, reason, now_s) catch |e| {
                    self.auditOverlay("overlay_annotate", fqn, "error");
                    return self.buildToolError(id, gateMsg(e));
                };
            },
            .suppress => {
                const diag_code = getStrArg(args, "diag_code") orelse return self.buildToolError(id, "suppress requires 'diag_code'");
                const fqn = getStrArg(args, "fqn");
                const file = getStrArg(args, "file");
                affected = fqn orelse file;
                new_id = overlay.addSuppress(self.db, ctx.pid, eff_branch, fqn, file, diag_code, getIntArg(args, "line"), is_user, reason, now_s) catch |e| {
                    self.auditOverlay("overlay_annotate", affected, "error");
                    return self.buildToolError(id, gateMsg(e));
                };
            },
        }
        const nid = new_id orelse return self.buildToolError(id, "overlay write failed");
        self.auditOverlay("overlay_annotate", affected, "ok");
        return self.overlayOk(id, nid, eff_branch, is_user);
    }

    fn toolOverlayList(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const kind = getStrArg(args, "kind") orelse return self.buildToolError(id, "missing 'kind'");
        const table = overlayTable(kind) orelse return self.buildToolError(id, "unknown 'kind'");
        const ctx = self.overlayCtx() orelse return self.buildToolError(id, "no workspace/project identity");
        defer ctx.deinit();
        const all = if (args) |m| (if (m.get("all_branches")) |v| (v == .bool and v.bool) else false) else false;
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        overlay.listJson(self.db, self.alloc, &aw.writer, ctx.pid, table, ctx.branch, all);
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolOverlayRevert(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const kind = getStrArg(args, "kind") orelse return self.buildToolError(id, "missing 'kind'");
        const table = overlayTable(kind) orelse return self.buildToolError(id, "unknown 'kind'");
        const row_id = getIntArg(args, "id") orelse return self.buildToolError(id, "missing 'id'");
        const reason = getStrArg(args, "reason") orelse return self.buildToolError(id, "missing 'reason'");
        if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return self.buildToolError(id, "reason is required");
        const ok = overlay.revoke(self.db, self.alloc, table, row_id, nowS());
        self.auditOverlay("overlay_revert", null, if (ok) "ok" else "error");
        if (!ok) return self.buildToolError(id, "no live overlay row with that id");
        return self.buildToolResult(id, "{\"ok\":true,\"reverted\":true}");
    }

    fn toolOverlayPromote(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const reason = getStrArg(args, "reason") orelse return self.buildToolError(id, "missing 'reason'");
        if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return self.buildToolError(id, "reason is required");
        const ctx = self.overlayCtx() orelse return self.buildToolError(id, "no workspace/project identity");
        defer ctx.deinit();
        const from_branch = getStrArg(args, "from_branch") orelse (ctx.branch orelse return self.buildToolError(id, "detached HEAD — pass 'from_branch'"));
        const n = overlay.promote(self.db, self.alloc, ctx.pid, from_branch, nowS());
        self.auditOverlay("overlay_promote", null, "ok");
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        try aw.writer.print("{{\"ok\":true,\"promoted\":{d}}}", .{n});
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolResolveType(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file = getStrArg(args, "file") orelse return self.buildToolError(id, "missing 'file' argument");
        const line = getIntArg(args, "line") orelse return self.buildToolError(id, "missing 'line' argument");
        const col = getIntArg(args, "col") orelse 0;
        const resolved = normalizeFileArg(self.alloc, file) orelse return self.buildToolError(id, "cannot resolve file path");
        defer self.alloc.free(resolved);

        const stmt = self.db.prepare(
            \\SELECT lv.name, lv.type_hint, lv.confidence
            \\FROM local_vars lv JOIN files f ON f.id = lv.file_id
            \\WHERE f.path = ? AND lv.line = ? AND lv.type_hint IS NOT NULL
            \\ORDER BY ABS(lv.col - ?) LIMIT 1
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, resolved);
        stmt.bind_int(2, line);
        stmt.bind_int(3, col);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        if (stmt.step() catch |e| stepLog(e)) {
            const var_name = stmt.column_text(0);
            const type_hint = stmt.column_text(1);
            const confidence = stmt.column_int(2);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, var_name);
            try w.writeAll(",\"type_hint\":");
            try writeJsonStr(w, type_hint);
            try w.print(",\"confidence\":{d}", .{confidence});
            // Describe confidence source
            const source_label: []const u8 = if (confidence >= 90) "rbs_annotation" else if (confidence >= 85) "literal_or_guard" else if (confidence >= 75) "method_return" else if (confidence >= 55) "chain_1" else if (confidence >= 38) "chain_2" else "inferred";
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, source_label);
            // Split union components
            if (std.mem.indexOf(u8, type_hint, " | ")) |_| {
                try w.writeAll(",\"union_components\":[");
                var union_it = std.mem.splitSequence(u8, type_hint, " | ");
                var uf = true;
                while (union_it.next()) |part| {
                    if (!uf) try w.writeByte(',');
                    uf = false;
                    try writeJsonStr(w, std.mem.trim(u8, part, " \t"));
                }
                try w.writeByte(']');
            }
            try w.print(",\"line\":{d}}}", .{line});
        } else {
            // Fallback: check symbols table for method return types at this line
            const sym_stmt = self.db.prepare(
                \\SELECT s.name, s.return_type
                \\FROM symbols s JOIN files f ON f.id = s.file_id
                \\WHERE f.path = ? AND s.line = ? AND s.return_type IS NOT NULL
                \\LIMIT 1
            ) catch null;
            if (sym_stmt) |ss| {
                defer ss.finalize();
                ss.bind_text(1, file);
                ss.bind_int(2, line);
                if (ss.step() catch |e| stepLog(e)) {
                    try w.writeAll("{\"name\":");
                    try writeJsonStr(w, ss.column_text(0));
                    try w.writeAll(",\"type_hint\":");
                    try writeJsonStr(w, ss.column_text(1));
                    try w.print(",\"source\":\"method_return_type\",\"line\":{d}}}", .{line});
                } else {
                    try w.print("{{\"line\":{d},\"type_hint\":null}}", .{line});
                }
            } else {
                try w.print("{{\"line\":{d},\"type_hint\":null}}", .{line});
            }
        }
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolClassSummary(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const class_name = getStrArg(args, "class_name") orelse return self.buildToolError(id, "missing 'class_name'");

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"class\":");
        try writeJsonStr(w, class_name);
        try w.writeAll(",\"methods\":[");

        const sym_stmt = self.db.prepare(
            \\SELECT name, kind, return_type, doc, line, end_line, visibility
            \\FROM symbols WHERE parent_name = ? AND kind IN ('def','classdef')
            \\ORDER BY kind, name LIMIT 200
        ) catch return self.buildToolError(id, "database error");
        defer sym_stmt.finalize();
        sym_stmt.bind_text(1, class_name);

        var meth_count: usize = 0;
        while (sym_stmt.step() catch |e| stepLog(e)) {
            if (meth_count > 0) try w.writeByte(',');
            meth_count += 1;
            const sname = sym_stmt.column_text(0);
            const skind = sym_stmt.column_text(1);
            const sret = sym_stmt.column_text(2);
            const sdoc = sym_stmt.column_text(3);
            const sline = sym_stmt.column_int(4);
            const svis = sym_stmt.column_text(6);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, sname);
            try w.writeAll(",\"kind\":");
            try writeJsonStr(w, skind);
            try w.writeAll(",\"return_type\":");
            if (sret.len > 0) try writeJsonStr(w, sret) else try w.writeAll("null");
            try w.writeAll(",\"doc\":");
            if (sdoc.len > 0) try writeJsonStr(w, sdoc) else try w.writeAll("null");
            try w.print(",\"line\":{d},\"visibility\":", .{sline});
            try writeJsonStr(w, svis);
            try w.writeByte('}');
        }
        try w.print("],\"has_more\":{s},\"mixins\":[", .{if (meth_count >= 200) "true" else "false"});

        const mix_stmt = self.db.prepare(
            \\SELECT m.module_name, m.kind FROM mixins m
            \\JOIN symbols s ON s.id = m.class_id
            \\WHERE s.name = ? AND s.kind IN ('class','module')
            \\LIMIT 50
        ) catch {
            try w.writeAll("],\"instance_variables\":[]}");
            const text = try aw.toOwnedSlice();
            defer self.alloc.free(text);
            return self.buildToolResult(id, text);
        };
        defer mix_stmt.finalize();
        mix_stmt.bind_text(1, class_name);

        var mfirst = true;
        while (mix_stmt.step() catch |e| stepLog(e)) {
            if (!mfirst) try w.writeByte(',');
            mfirst = false;
            const mname = mix_stmt.column_text(0);
            const mkind = mix_stmt.column_text(1);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, mname);
            try w.writeAll(",\"kind\":");
            try writeJsonStr(w, mkind);
            try w.writeByte('}');
        }
        try w.writeAll("],\"instance_variables\":[");

        const ivar_stmt = self.db.prepare(
            \\SELECT DISTINCT lv.name, lv.type_hint
            \\FROM local_vars lv
            \\JOIN symbols s ON s.id = lv.class_id
            \\WHERE s.name = ? AND s.kind IN ('class','module') AND lv.name LIKE '@%'
            \\ORDER BY lv.name
            \\LIMIT 100
        ) catch {
            try w.writeAll("]}");
            const text = try aw.toOwnedSlice();
            defer self.alloc.free(text);
            return self.buildToolResult(id, text);
        };
        defer ivar_stmt.finalize();
        ivar_stmt.bind_text(1, class_name);

        var ivfirst = true;
        while (ivar_stmt.step() catch |e| stepLog(e)) {
            if (!ivfirst) try w.writeByte(',');
            ivfirst = false;
            const ivname = ivar_stmt.column_text(0);
            const ivhint = ivar_stmt.column_text(1);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, ivname);
            try w.writeAll(",\"type_hint\":");
            if (ivhint.len > 0) try writeJsonStr(w, ivhint) else try w.writeAll("null");
            try w.writeByte('}');
        }
        try w.writeAll("],\"callbacks\":[");

        const cb_stmt = self.db.prepare(
            \\SELECT name, doc, line FROM symbols
            \\WHERE parent_name = ? AND kind = 'callback'
            \\ORDER BY line LIMIT 50
        ) catch {
            try w.writeAll("],\"scopes\":[]}");
            const text2 = try aw.toOwnedSlice();
            defer self.alloc.free(text2);
            return self.buildToolResult(id, text2);
        };
        defer cb_stmt.finalize();
        cb_stmt.bind_text(1, class_name);

        var cbfirst = true;
        while (cb_stmt.step() catch |e| stepLog(e)) {
            if (!cbfirst) try w.writeByte(',');
            cbfirst = false;
            const cname = cb_stmt.column_text(0);
            const cdoc = cb_stmt.column_text(1);
            const cline = cb_stmt.column_int(2);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, cname);
            try w.writeAll(",\"callback_type\":");
            if (cdoc.len > 0) try writeJsonStr(w, cdoc) else try w.writeAll("null");
            try w.print(",\"line\":{d}}}", .{cline});
        }
        try w.writeAll("],\"scopes\":[");

        const sc_stmt = self.db.prepare(
            \\SELECT name, return_type, line FROM symbols
            \\WHERE parent_name = ? AND kind = 'classdef'
            \\ORDER BY name LIMIT 50
        ) catch {
            try w.writeAll("]}");
            const text3 = try aw.toOwnedSlice();
            defer self.alloc.free(text3);
            return self.buildToolResult(id, text3);
        };
        defer sc_stmt.finalize();
        sc_stmt.bind_text(1, class_name);

        var scfirst = true;
        while (sc_stmt.step() catch |e| stepLog(e)) {
            if (!scfirst) try w.writeByte(',');
            scfirst = false;
            const sname = sc_stmt.column_text(0);
            const sret = sc_stmt.column_text(1);
            const sline = sc_stmt.column_int(2);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, sname);
            try w.writeAll(",\"return_type\":");
            if (sret.len > 0) try writeJsonStr(w, sret) else try w.writeAll("null");
            try w.print(",\"line\":{d}}}", .{sline});
        }
        try w.writeAll("],\"constants\":[");

        // Constants are listed separately, not folded into `methods` — a constant
        // is not callable, and method_signature/explain resolve them via a distinct
        // path. Keeping them out of `methods` stops consumers probing a constant as
        // a method (which silently failed before).
        const const_stmt = self.db.prepare(
            \\SELECT name, line FROM symbols
            \\WHERE parent_name = ? AND kind = 'constant'
            \\ORDER BY name LIMIT 100
        ) catch {
            try w.writeAll("]}");
            const text4 = try aw.toOwnedSlice();
            defer self.alloc.free(text4);
            return self.buildToolResult(id, text4);
        };
        defer const_stmt.finalize();
        const_stmt.bind_text(1, class_name);

        var kfirst = true;
        while (const_stmt.step() catch |e| stepLog(e)) {
            if (!kfirst) try w.writeByte(',');
            kfirst = false;
            const kname = const_stmt.column_text(0);
            const kline = const_stmt.column_int(1);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, kname);
            try w.print(",\"line\":{d}}}", .{kline});
        }
        try w.writeAll("]}");
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    /// A method resolved either directly on a class or via its ancestors/mixins.
    /// `owner` is null for a direct hit; otherwise the (alloc'd) name of the
    /// ancestor/module that actually defines the method — caller frees it.
    const ResolvedMethod = struct { sym_id: i64, owner: ?[]u8 };

    /// Look up a method (`def`/`classdef`) directly owned by `class_name`.
    fn lookupMethodIn(self: *Server, class_name: []const u8, method_name: []const u8) ?i64 {
        const s = self.db.prepare(
            \\SELECT id FROM symbols
            \\WHERE parent_name = ? AND name = ? AND kind IN ('def','classdef') LIMIT 1
        ) catch return null;
        defer s.finalize();
        s.bind_text(1, class_name);
        s.bind_text(2, method_name);
        if (s.step() catch |e| stepLog(e)) return s.column_int(0);
        return null;
    }

    /// Resolve a method to its defining symbol: direct first, then walking the
    /// inheritance + mixin chain (same recursive CTE as type_hierarchy) so that
    /// inherited / included methods resolve — closes the plain-Ruby recall gap.
    fn resolveMethodSym(self: *Server, class_name: []const u8, method_name: []const u8) ?ResolvedMethod {
        if (self.lookupMethodIn(class_name, method_name)) |sid| return .{ .sym_id = sid, .owner = null };

        // Walk the ancestor closure — real superclass (FQN-resolved), lexical
        // parent_name (carries the superclass for top-level classes), and every
        // include/prepend/extend — breadth-first with a `seen` set. A SQL
        // recursive CTE over this graph blows up on cycles (no in-recursion
        // dedup); the deduped BFS is bounded. Same closure the diagnostics
        // ancestor-walker uses (indexer/index.zig resolveMethodInAncestors).
        var seen = std.StringHashMap(void).init(self.alloc);
        defer {
            var it = seen.keyIterator();
            while (it.next()) |k| self.alloc.free(k.*);
            seen.deinit();
        }
        var queue = std.ArrayList([]u8).empty;
        defer {
            for (queue.items) |item| self.alloc.free(item);
            queue.deinit(self.alloc);
        }
        const seed = self.alloc.dupe(u8, class_name) catch return null;
        queue.append(self.alloc, seed) catch {
            self.alloc.free(seed);
            return null;
        };

        var steps: u32 = 0;
        var first = true;
        while (queue.items.len > 0) {
            if (steps >= 64) break;
            steps += 1;
            const name = queue.orderedRemove(0);
            defer self.alloc.free(name);
            if (seen.contains(name)) {
                first = false;
                continue;
            }
            const key = self.alloc.dupe(u8, name) catch break;
            seen.put(key, {}) catch {
                self.alloc.free(key);
                break;
            };

            // Method defined directly on this ancestor? (skip the seed class —
            // its direct lookup already failed above.)
            if (!first) {
                if (self.lookupMethodIn(name, method_name)) |sid| {
                    return .{ .sym_id = sid, .owner = self.alloc.dupe(u8, name) catch null };
                }
            }
            first = false;

            const q = self.db.prepare(
                \\SELECT id, parent_name, superclass FROM symbols
                \\WHERE name = ? AND kind IN ('class','classdef','module','moduledef') LIMIT 1
            ) catch continue;
            defer q.finalize();
            q.bind_text(1, name);
            if (!(q.step() catch false)) continue;
            const cid = q.column_int(0);
            self.enqueueAncestor(&queue, q.column_text(2)); // superclass
            self.enqueueAncestor(&queue, q.column_text(1)); // parent_name

            const mix = self.db.prepare("SELECT module_name FROM mixins WHERE class_id = ?") catch continue;
            defer mix.finalize();
            mix.bind_int(1, cid);
            while (mix.step() catch false) self.enqueueAncestor(&queue, mix.column_text(0));
        }

        // Final fallback: the "method" is actually a constant defined on the class
        // (e.g. `Foo::VERSION`). Resolve it so a `Class#CONST` probe returns the
        // symbol instead of found:false. owner stays null (defined directly).
        const ks = self.db.prepare(
            \\SELECT id FROM symbols
            \\WHERE parent_name = ? AND name = ? AND kind = 'constant' LIMIT 1
        ) catch return null;
        defer ks.finalize();
        ks.bind_text(1, class_name);
        ks.bind_text(2, method_name);
        if (ks.step() catch |e| stepLog(e)) return .{ .sym_id = ks.column_int(0), .owner = null };
        return null;
    }

    fn enqueueAncestor(self: *Server, queue: *std.ArrayList([]u8), name: []const u8) void {
        if (name.len == 0) return;
        const dup = self.alloc.dupe(u8, name) catch return;
        queue.append(self.alloc, dup) catch self.alloc.free(dup);
    }

    /// Emit the comma-separated params array body for a method symbol_id into `w`.
    /// Shared by method_signature and explain_symbol (single source of truth for
    /// the param shape; querying by symbol_id, never the missing `default_val`).
    fn writeMethodParams(self: *Server, w: *std.Io.Writer, sym_id: i64) !void {
        const ps = self.db.prepare(
            \\SELECT name, kind, type_hint, position
            \\FROM params WHERE symbol_id = ? ORDER BY position
        ) catch return;
        defer ps.finalize();
        ps.bind_int(1, sym_id);
        var first = true;
        while (ps.step() catch |e| stepLog(e)) {
            if (!first) try w.writeByte(',');
            first = false;
            const pname = ps.column_text(0);
            const pkind = ps.column_text(1);
            const phint = ps.column_text(2);
            const ppos = ps.column_int(3);
            try w.print("{{\"position\":{d},\"name\":", .{ppos});
            try writeJsonStr(w, pname);
            try w.writeAll(",\"kind\":");
            try writeJsonStr(w, pkind);
            try w.writeAll(",\"type_hint\":");
            if (phint.len > 0) try writeJsonStr(w, phint) else try w.writeAll("null");
            try w.writeByte('}');
        }
    }

    fn toolMethodSignature(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        var class_name: []const u8 = "";
        var method_name: []const u8 = "";
        if (getStrArg(args, "symbol")) |sym| {
            if (splitQualified(sym)) |q| {
                class_name = q.class_name;
                method_name = q.method_name;
            } else return self.buildToolError(id, "'symbol' must be 'Class#method'");
        } else {
            class_name = getStrArg(args, "class_name") orelse return self.buildToolError(id, "missing 'class_name' (or pass 'symbol':'Class#method')");
            method_name = getStrArg(args, "method_name") orelse return self.buildToolError(id, "missing 'method_name' (or pass 'symbol':'Class#method')");
        }

        const resolved = self.resolveMethodSym(class_name, method_name) orelse
            return self.buildToolResult(id, "{\"found\":false}");
        defer if (resolved.owner) |o| self.alloc.free(o);

        const sym_stmt = self.db.prepare(
            \\SELECT return_type, doc, line, visibility FROM symbols WHERE id = ? LIMIT 1
        ) catch return self.buildToolError(id, "database error");
        defer sym_stmt.finalize();
        sym_stmt.bind_int(1, resolved.sym_id);
        if (!(sym_stmt.step() catch |e| stepLog(e))) {
            return self.buildToolResult(id, "{\"found\":false}");
        }
        const ret_type = sym_stmt.column_text(0);
        const doc = sym_stmt.column_text(1);
        const line = sym_stmt.column_int(2);
        const vis = sym_stmt.column_text(3);

        // Overlay correction: a user/agent type-override on this method's return
        // type supersedes the derived value. Keyed by the qualified "Class#method".
        const ctx = self.overlayCtx();
        defer if (ctx) |c| c.deinit();
        const qualified = try std.fmt.allocPrint(self.alloc, "{s}#{s}", .{ class_name, method_name });
        defer self.alloc.free(qualified);
        const ov_ret: ?[]u8 = if (ctx) |c| overlay.effectiveType(self.db, self.alloc, c.pid, c.branch, qualified, null, -1) else null;
        defer if (ov_ret) |o| self.alloc.free(o);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"found\":true,\"class\":");
        try writeJsonStr(w, class_name);
        try w.writeAll(",\"method\":");
        try writeJsonStr(w, method_name);
        try w.writeAll(",\"inherited_from\":");
        if (resolved.owner) |o| try writeJsonStr(w, o) else try w.writeAll("null");
        try w.print(",\"line\":{d},\"visibility\":", .{line});
        try writeJsonStr(w, vis);
        try w.writeAll(",\"return_type\":");
        if (ov_ret) |o| {
            try writeJsonStr(w, o);
            try w.writeAll(",\"return_type_source\":\"overlay\"");
        } else if (ret_type.len > 0) try writeJsonStr(w, ret_type) else try w.writeAll("null");
        try w.writeAll(",\"doc\":");
        if (doc.len > 0) try writeJsonStr(w, doc) else try w.writeAll("null");
        try w.writeAll(",\"params\":[");
        try self.writeMethodParams(w, resolved.sym_id);
        try w.writeAll("]}");
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn readFileLine(self: *Server, path: []const u8, line_1based: i64) ?[]u8 {
        const raw = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, self.alloc, std.Io.Limit.limited(8 * 1024 * 1024)) catch return null;
        defer self.alloc.free(raw);
        var lineno: i64 = 1;
        var i: usize = 0;
        while (i < raw.len) {
            const line_start = i;
            while (i < raw.len and raw[i] != '\n') i += 1;
            if (lineno == line_1based) {
                const line = std.mem.trimStart(u8, raw[line_start..i], " \t");
                return self.alloc.dupe(u8, line) catch null;
            }
            i += 1; // skip '\n'
            lineno += 1;
        }
        return null;
    }

    fn readFileLineFromCache(
        self: *Server,
        cache: *std.StringHashMap([]const u8),
        path: []const u8,
        line_1based: i64,
    ) ?[]u8 {
        const content = if (cache.get(path)) |c| c else blk: {
            if (cache.count() >= 50) return self.readFileLine(path, line_1based);
            const c = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, self.alloc, std.Io.Limit.limited(8 * 1024 * 1024)) catch return null;
            const owned_key = self.alloc.dupe(u8, path) catch {
                self.alloc.free(c);
                return self.readFileLine(path, line_1based);
            };
            cache.put(owned_key, c) catch {
                self.alloc.free(owned_key);
                self.alloc.free(c);
                return self.readFileLine(path, line_1based);
            };
            break :blk c;
        };
        var lineno: i64 = 1;
        var i: usize = 0;
        while (i < content.len) {
            const line_start = i;
            while (i < content.len and content[i] != '\n') i += 1;
            if (lineno == line_1based) {
                const line = std.mem.trimStart(u8, content[line_start..i], " \t");
                return self.alloc.dupe(u8, line) catch null;
            }
            i += 1;
            lineno += 1;
        }
        return null;
    }

    fn toolFindCallers(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        var method_name: []const u8 = "";
        var class_name: ?[]const u8 = null;
        if (getStrArg(args, "symbol")) |sym| {
            if (splitQualified(sym)) |q| {
                class_name = q.class_name;
                method_name = q.method_name;
            } else {
                method_name = sym;
            }
        } else {
            method_name = getStrArg(args, "method_name") orelse return self.buildToolError(id, "missing 'method_name' (or pass 'symbol':'Class#method')");
            class_name = getStrArg(args, "class_name");
        }
        const ref_kind = getStrArg(args, "ref_kind");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        const stmt = if (ref_kind != null)
            self.db.prepare(
                \\SELECT f.path, r.line, r.col
                \\FROM refs r JOIN files f ON f.id = r.file_id
                \\WHERE r.name = ? AND r.kind = ?
                \\ORDER BY f.path, r.line
                \\LIMIT 201 OFFSET ?
            ) catch return self.buildToolError(id, "database error")
        else
            self.db.prepare(
                \\SELECT f.path, r.line, r.col
                \\FROM refs r JOIN files f ON f.id = r.file_id
                \\WHERE r.name = ?
                \\ORDER BY f.path, r.line
                \\LIMIT 201 OFFSET ?
            ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        var param_idx: c_int = 1;
        stmt.bind_text(param_idx, method_name);
        param_idx += 1;
        if (ref_kind) |kind| {
            stmt.bind_text(param_idx, kind);
            param_idx += 1;
        }
        stmt.bind_int(param_idx, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"method\":");
        try writeJsonStr(w, method_name);
        if (class_name) |cn| {
            try w.writeAll(",\"class_filter\":");
            try writeJsonStr(w, cn);
        }
        try w.writeAll(",\"callers\":[");

        var file_cache = std.StringHashMap([]const u8).init(self.alloc);
        defer {
            var it = file_cache.iterator();
            while (it.next()) |entry| {
                self.alloc.free(entry.key_ptr.*);
                self.alloc.free(entry.value_ptr.*);
            }
            file_cache.deinit();
        }

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 200) break;
            const fpath = stmt.column_text(0);
            const fline = stmt.column_int(1);
            const fcol = stmt.column_int(2);
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            try w.writeAll("{\"file\":");
            try writeJsonStr(w, fpath);
            try w.print(",\"line\":{d},\"col\":{d}", .{ fline, fcol });
            const ctx_line = self.readFileLineFromCache(&file_cache, fpath, fline);
            defer if (ctx_line) |cl| self.alloc.free(cl);
            if (ctx_line) |cl| {
                try w.writeAll(",\"context\":");
                try writeJsonStr(w, cl);
            }
            try w.writeByte('}');
        }
        const has_more = stmt.step() catch false;
        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolFindImplementations(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const method_name = getStrArg(args, "method_name") orelse return self.buildToolError(id, "missing 'method_name'");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        const stmt = self.db.prepare(
            \\SELECT DISTINCT COALESCE(s.parent_name, '<top-level>'), f.path, s.line, s.return_type
            \\FROM symbols s JOIN files f ON f.id = s.file_id
            \\WHERE s.name = ? AND s.kind IN ('def','classdef')
            \\ORDER BY COALESCE(s.parent_name, '<top-level>'), f.path LIMIT 101 OFFSET ?
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, method_name);
        stmt.bind_int(2, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"method\":");
        try writeJsonStr(w, method_name);
        try w.writeAll(",\"implementations\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 100) break;
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const iclass = stmt.column_text(0);
            const ifile = stmt.column_text(1);
            const iline = stmt.column_int(2);
            const iret = stmt.column_text(3);
            try w.writeAll("{\"class\":");
            try writeJsonStr(w, iclass);
            try w.writeAll(",\"file\":");
            try writeJsonStr(w, ifile);
            try w.print(",\"line\":{d},\"return_type\":", .{iline});
            if (iret.len > 0) try writeJsonStr(w, iret) else try w.writeAll("null");
            try w.writeByte('}');
        }
        const has_more = stmt.step() catch false;
        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolWorkspaceSymbols(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const query = getStrArg(args, "query") orelse return self.buildToolError(id, "missing 'query'");
        const kind_filter = getStrArg(args, "kind");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        const q_trim = std.mem.trim(u8, query, " \t\r\n");
        const use_fts = q_trim.len >= 3;

        // Substring search ('%q%') can't use the name B-tree (leading wildcard) and
        // full-scans symbols. The trigram FTS makes it index-backed; LIKE remains
        // for queries shorter than the 3-char trigram floor.
        const match_or_like = if (use_fts)
            ftsQuote(self.alloc, q_trim) catch return self.buildToolError(id, "OOM")
        else
            std.fmt.allocPrint(self.alloc, "%{s}%", .{query}) catch return self.buildToolError(id, "OOM");
        defer self.alloc.free(match_or_like);

        const stmt = self.db.prepare(if (use_fts)
            \\SELECT s.name, s.kind, s.parent_name, s.return_type, f.path, s.line
            \\FROM symbols_fts
            \\JOIN symbols s ON s.id = symbols_fts.rowid
            \\JOIN files f ON f.id = s.file_id
            \\WHERE symbols_fts MATCH ? AND (? IS NULL OR s.kind = ?)
            \\ORDER BY s.name LIMIT 501 OFFSET ?
        else
            \\SELECT s.name, s.kind, s.parent_name, s.return_type, f.path, s.line
            \\FROM symbols s JOIN files f ON f.id = s.file_id
            \\WHERE s.name LIKE ? AND (? IS NULL OR s.kind = ?)
            \\ORDER BY s.name LIMIT 501 OFFSET ?
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, match_or_like);
        if (kind_filter) |kf| {
            stmt.bind_text(2, kf);
            stmt.bind_text(3, kf);
        } else {
            stmt.bind_null(2);
            stmt.bind_null(3);
        }
        stmt.bind_int(4, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"symbols\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 500) break;
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const sname = stmt.column_text(0);
            const skind = stmt.column_text(1);
            const sparent = stmt.column_text(2);
            const sret = stmt.column_text(3);
            const spath = stmt.column_text(4);
            const sline = stmt.column_int(5);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, sname);
            try w.writeAll(",\"kind\":");
            try writeJsonStr(w, skind);
            try w.writeAll(",\"parent_name\":");
            if (sparent.len > 0) try writeJsonStr(w, sparent) else try w.writeAll("null");
            try w.writeAll(",\"return_type\":");
            if (sret.len > 0) try writeJsonStr(w, sret) else try w.writeAll("null");
            try w.writeAll(",\"file\":");
            try writeJsonStr(w, spath);
            try w.print(",\"line\":{d}}}", .{sline});
        }
        const has_more = stmt.step() catch false;
        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolTypeHierarchy(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const class_name = getStrArg(args, "class_name") orelse return self.buildToolError(id, "missing 'class_name'");
        var ancestors_offset = getIntArg(args, "ancestors_offset") orelse 0;
        var descendants_offset = getIntArg(args, "descendants_offset") orelse 0;
        if (ancestors_offset < 0) ancestors_offset = 0;
        if (descendants_offset < 0) descendants_offset = 0;

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"class\":");
        try writeJsonStr(w, class_name);
        try w.writeAll(",\"ancestors\":[");

        // Recursive CTE walking class inheritance (parent_name), STI, and mixin inclusion
        const anc_stmt = self.db.prepare(
            \\WITH RECURSIVE anc(cn, depth) AS (
            \\  SELECT ?, 0
            \\  UNION ALL
            \\  SELECT s.parent_name, anc.depth + 1
            \\  FROM symbols s JOIN anc ON s.name = anc.cn
            \\  WHERE s.parent_name IS NOT NULL AND s.kind IN ('class','module') AND anc.depth < 20
            \\  UNION ALL
            \\  SELECT m.module_name, anc.depth + 1
            \\  FROM mixins m JOIN symbols s ON s.id = m.class_id
            \\  JOIN anc ON s.name = anc.cn
            \\  WHERE anc.depth < 20
            \\)
            \\SELECT cn, MIN(depth) as depth FROM anc WHERE depth > 0
            \\GROUP BY cn ORDER BY depth, cn LIMIT 51 OFFSET ?
        ) catch {
            try w.writeAll("],\"descendants\":[]}");
            const text = try aw.toOwnedSlice();
            defer self.alloc.free(text);
            return self.buildToolResult(id, text);
        };
        defer anc_stmt.finalize();
        anc_stmt.bind_text(1, class_name);
        anc_stmt.bind_int(2, ancestors_offset);

        var anc_count: usize = 0;
        while (anc_stmt.step() catch |e| stepLog(e)) {
            if (anc_count >= 50) break;
            if (anc_count > 0) try w.writeByte(',');
            anc_count += 1;
            const cn = anc_stmt.column_text(0);
            const depth = anc_stmt.column_int(1);
            try w.print("{{\"name\":", .{});
            try writeJsonStr(w, cn);
            try w.print(",\"depth\":{d}}}", .{depth});
        }
        const anc_has_more = anc_stmt.step() catch false;
        try w.print("],\"ancestors_has_more\":{s},\"ancestors_offset\":{d},\"descendants\":[", .{ if (anc_has_more) "true" else "false", ancestors_offset });

        // Find classes that include this class/module
        const desc_stmt = self.db.prepare(
            \\SELECT DISTINCT s.name FROM symbols s
            \\JOIN mixins m ON m.class_id = s.id
            \\WHERE m.module_name = ? AND s.kind IN ('class','module')
            \\ORDER BY s.name LIMIT 51 OFFSET ?
        ) catch {
            try w.writeAll("]}");
            const text = try aw.toOwnedSlice();
            defer self.alloc.free(text);
            return self.buildToolResult(id, text);
        };
        defer desc_stmt.finalize();
        desc_stmt.bind_text(1, class_name);
        desc_stmt.bind_int(2, descendants_offset);

        var desc_count: usize = 0;
        while (desc_stmt.step() catch |e| stepLog(e)) {
            if (desc_count >= 50) break;
            if (desc_count > 0) try w.writeByte(',');
            desc_count += 1;
            try writeJsonStr(w, desc_stmt.column_text(0));
        }
        const desc_has_more = desc_stmt.step() catch false;
        try w.print("],\"descendants_has_more\":{s},\"descendants_offset\":{d}}}", .{ if (desc_has_more) "true" else "false", descendants_offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolAssociationGraph(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const class_name = getStrArg(args, "class_name") orelse return self.buildToolError(id, "missing 'class_name'");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        const stmt = self.db.prepare(
            \\SELECT name, kind, return_type, doc, value_snippet FROM symbols
            \\WHERE parent_name = ? AND kind IN ('association','scope')
            \\ORDER BY name LIMIT 101 OFFSET ?
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, class_name);
        stmt.bind_int(2, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"class\":");
        try writeJsonStr(w, class_name);
        try w.writeAll(",\"associations\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 100) break;
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const aname = stmt.column_text(0);
            const akind = stmt.column_text(1);
            const aret = stmt.column_text(2);
            const adoc = stmt.column_text(3);
            const avs = stmt.column_text(4);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, aname);
            try w.writeAll(",\"association_type\":");
            if (adoc.len > 0) try writeJsonStr(w, adoc) else try writeJsonStr(w, akind);
            try w.writeAll(",\"return_type\":");
            if (aret.len > 0) try writeJsonStr(w, aret) else try w.writeAll("null");
            if (std.mem.startsWith(u8, avs, "through:")) {
                try w.writeAll(",\"through\":");
                try writeJsonStr(w, avs["through:".len..]);
            }
            try w.writeByte('}');
        }
        try w.writeAll("]");
        if (row_count == 0) {
            try w.writeAll(",\"note\":\"No associations detected. Supported: ActiveRecord (has_many, belongs_to, has_one), Sequel (one_to_many, many_to_one, many_to_many, one_to_one).\"");
        }
        const has_more = stmt.step() catch false;
        try w.print(",\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolRouteMap(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const prefix = getStrArg(args, "prefix");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        var like_buf: [256]u8 = undefined;
        const like_pat: []const u8 = if (prefix) |p|
            std.fmt.bufPrint(&like_buf, "{s}%", .{p}) catch "%"
        else
            "%";

        const stmt = self.db.prepare(
            \\SELECT name, doc, return_type FROM symbols
            \\WHERE kind = 'route_helper' AND name LIKE ?
            \\ORDER BY name LIMIT 201 OFFSET ?
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, like_pat);
        stmt.bind_int(2, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"routes\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 200) break;
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const rname = stmt.column_text(0);
            const rdoc = stmt.column_text(1);
            const rret = stmt.column_text(2);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, rname);
            try w.writeAll(",\"doc\":");
            if (rdoc.len > 0) try writeJsonStr(w, rdoc) else try w.writeAll("null");
            try w.writeAll(",\"return_type\":");
            if (rret.len > 0) try writeJsonStr(w, rret) else try w.writeAll("null");
            try w.writeByte('}');
        }
        const has_more = stmt.step() catch false;
        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolDiagnostics(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file = getStrArg(args, "file");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        // Overlay correction: drop diagnostics matched by a live suppression rule.
        const ctx = self.overlayCtx();
        defer if (ctx) |c| c.deinit();

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;

        if (file) |fpath| {
            try w.writeAll("{\"file\":");
            try writeJsonStr(w, fpath);
            try w.writeAll(",\"errors\":[");

            const dstmt = self.db.prepare(
                \\SELECT d.line, d.col, d.message, d.severity, d.code
                \\FROM diagnostics d JOIN files f ON f.id = d.file_id
                \\WHERE f.path = ?
                \\ORDER BY d.line
                \\LIMIT 1000
            ) catch {
                try w.writeAll("]}");
                const text = try aw.toOwnedSlice();
                defer self.alloc.free(text);
                return self.buildToolResult(id, text);
            };
            defer dstmt.finalize();
            dstmt.bind_text(1, fpath);

            var first_d = true;
            while (dstmt.step() catch |e| stepLog(e)) {
                const dline = dstmt.column_int(0);
                if (ctx) |c| {
                    if (overlay.isSuppressed(self.db, c.pid, c.branch, dstmt.column_text(4), fpath, dline, null)) continue;
                }
                if (!first_d) try w.writeByte(',');
                first_d = false;
                try w.print("{{\"line\":{d},\"col\":{d},\"message\":", .{ dline, dstmt.column_int(1) });
                try writeJsonStr(w, dstmt.column_text(2));
                try w.print(",\"severity\":{d}}}", .{dstmt.column_int(3)});
            }
            try w.writeAll("]}");
        } else {
            // Return workspace-level diagnostics from DB
            const wstmt = self.db.prepare(
                \\SELECT f.path, d.line, d.col, d.message, d.severity, d.code
                \\FROM diagnostics d JOIN files f ON f.id = d.file_id
                \\WHERE f.is_gem = 0
                \\ORDER BY f.path, d.line
                \\LIMIT 2001 OFFSET ?
            ) catch {
                try w.writeAll("{\"files\":[]}");
                const text = try aw.toOwnedSlice();
                defer self.alloc.free(text);
                return self.buildToolResult(id, text);
            };
            defer wstmt.finalize();
            wstmt.bind_int(1, offset);

            try w.writeAll("{\"files\":[");
            var cur_file: ?[]u8 = null;
            defer if (cur_file) |cf| self.alloc.free(cf);
            var in_file = false;
            var row_count: usize = 0;
            while (wstmt.step() catch |e| stepLog(e)) {
                if (row_count >= 2000) break;
                row_count += 1;
                const rpath = wstmt.column_text(0);
                const rline = wstmt.column_int(1);
                if (ctx) |c| {
                    if (overlay.isSuppressed(self.db, c.pid, c.branch, wstmt.column_text(5), rpath, rline, null)) continue;
                }
                const rcol = wstmt.column_int(2);
                const rmsg = wstmt.column_text(3);
                const rsev = wstmt.column_int(4);
                const new_file = cur_file == null or !std.mem.eql(u8, cur_file.?, rpath);
                if (new_file) {
                    if (in_file) try w.writeAll("]}");
                    if (cur_file != null) try w.writeByte(',');
                    if (cur_file) |cf| self.alloc.free(cf);
                    cur_file = self.alloc.dupe(u8, rpath) catch null;
                    in_file = true;
                    try w.writeAll("{\"file\":");
                    try writeJsonStr(w, rpath);
                    try w.writeAll(",\"errors\":[");
                }
                if (!new_file) try w.writeByte(',');
                try w.print("{{\"line\":{d},\"col\":{d},\"message\":", .{ rline, rcol });
                try writeJsonStr(w, rmsg);
                try w.print(",\"severity\":{d}}}", .{rsev});
            }
            if (in_file) try w.writeAll("]}");
            const has_more = wstmt.step() catch false;
            try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        }

        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn handlePromptsList(self: *Server, id: ?std.json.Value) !?[]u8 {
        const result =
            \\{"prompts":[
            \\{"name":"class-overview","description":"Summarize a class: purpose, public API, associations","arguments":[{"name":"class_name","description":"Fully qualified class name","required":true}]},
            \\{"name":"trace-callers","description":"Show all callers of a method and explain usage patterns","arguments":[{"name":"class_name","description":"Class name","required":true},{"name":"method_name","description":"Method name","required":true}]},
            \\{"name":"find-bugs","description":"List potential bugs or type mismatches in a file based on diagnostics and type inference","arguments":[{"name":"file","description":"Absolute path to the file","required":true}]}
            \\]}
        ;
        return self.buildResult(id, result);
    }

    fn handlePromptsGet(self: *Server, id: ?std.json.Value, params: ?std.json.Value) !?[]u8 {
        const params_obj = switch (params orelse return self.buildError(id, -32602, "missing params")) {
            .object => |o| o,
            else => return self.buildError(id, -32602, "params must be object"),
        };
        const name_val = params_obj.get("name") orelse return self.buildError(id, -32602, "missing name");
        const name = switch (name_val) {
            .string => |s| s,
            else => return self.buildError(id, -32602, "name must be string"),
        };
        const arguments = if (params_obj.get("arguments")) |a| switch (a) {
            .object => |o| o,
            else => null,
        } else null;

        const template: []const u8 = if (std.mem.eql(u8, name, "class-overview"))
            "Summarize {{class_name}}: purpose, public API, associations"
        else if (std.mem.eql(u8, name, "trace-callers"))
            "Show all callers of {{class_name}}#{{method_name}} and explain usage patterns"
        else if (std.mem.eql(u8, name, "find-bugs"))
            "List potential bugs or type mismatches in {{file}} based on diagnostics and type inference"
        else
            return self.buildError(id, -32002, "Prompt not found");

        var text_buf = std.Io.Writer.Allocating.init(self.alloc);
        errdefer text_buf.deinit();
        const tw = &text_buf.writer;
        var remaining = template;
        while (remaining.len > 0) {
            if (std.mem.indexOf(u8, remaining, "{{")) |open| {
                try tw.writeAll(remaining[0..open]);
                remaining = remaining[open + 2 ..];
                if (std.mem.indexOf(u8, remaining, "}}")) |close| {
                    const key = remaining[0..close];
                    remaining = remaining[close + 2 ..];
                    if (arguments) |amap| {
                        if (amap.get(key)) |av| {
                            switch (av) {
                                .string => |s| try tw.writeAll(s),
                                else => try tw.writeAll("{{"),
                            }
                            continue;
                        }
                    }
                    try tw.print("{{{{{s}}}}}", .{key});
                } else {
                    try tw.writeAll("{{");
                }
            } else {
                try tw.writeAll(remaining);
                break;
            }
        }
        const interpolated = try text_buf.toOwnedSlice();
        defer self.alloc.free(interpolated);

        var ctx_buf = std.Io.Writer.Allocating.init(self.alloc);
        errdefer ctx_buf.deinit();
        const cw = &ctx_buf.writer;
        try self.buildPromptContext(name, arguments, cw);
        const ctx_text = try ctx_buf.toOwnedSlice();
        defer self.alloc.free(ctx_text);

        var full_buf = std.Io.Writer.Allocating.init(self.alloc);
        errdefer full_buf.deinit();
        const fw = &full_buf.writer;
        if (ctx_text.len > 0) {
            try fw.writeAll(ctx_text);
            try fw.writeAll("\n\n");
        }
        try fw.writeAll(interpolated);
        const full_text = try full_buf.toOwnedSlice();
        defer self.alloc.free(full_text);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":");
        try writeJsonStr(w, full_text);
        try w.writeAll("}}]}");
        const result = try aw.toOwnedSlice();
        defer self.alloc.free(result);
        return self.buildResult(id, result);
    }

    fn buildPromptContext(self: *Server, name: []const u8, arguments: ?std.json.ObjectMap, w: *std.Io.Writer) !void {
        if (std.mem.eql(u8, name, "class-overview")) {
            const class_name = if (arguments) |a| if (a.get("class_name")) |v| switch (v) {
                .string => |s| s,
                else => return,
            } else return else return;

            try w.print("Class: {s}\n\n", .{class_name});

            const meth_stmt = self.db.prepare(
                \\SELECT name, kind, return_type, visibility FROM symbols
                \\WHERE parent_name=? AND kind IN ('def','classdef')
                \\ORDER BY kind, name LIMIT 30
            ) catch return;
            defer meth_stmt.finalize();
            meth_stmt.bind_text(1, class_name);

            var meth_count: usize = 0;
            var meth_buf = std.Io.Writer.Allocating.init(self.alloc);
            errdefer meth_buf.deinit();
            const mb = &meth_buf.writer;
            while (meth_stmt.step() catch |e| stepLog(e)) {
                meth_count += 1;
                const mn = meth_stmt.column_text(0);
                const mk = meth_stmt.column_text(1);
                const mr = meth_stmt.column_text(2);
                const mv = meth_stmt.column_text(3);
                const prefix: []const u8 = if (std.mem.eql(u8, mk, "classdef")) "self." else "";
                if (mr.len > 0) {
                    try mb.print("  def {s}{s}: {s}  [{s}]\n", .{ prefix, mn, mr, mv });
                } else {
                    try mb.print("  def {s}{s}  [{s}]\n", .{ prefix, mn, mv });
                }
            }
            const meth_text = try meth_buf.toOwnedSlice();
            defer self.alloc.free(meth_text);
            if (meth_count > 0) {
                try w.print("Methods ({d}):\n", .{meth_count});
                try w.writeAll(meth_text);
                try w.writeByte('\n');
            }

            const assoc_stmt = self.db.prepare(
                \\SELECT name, kind, return_type FROM symbols
                \\WHERE parent_name=? AND kind IN ('association','scope')
                \\ORDER BY name LIMIT 20
            ) catch {
                try w.writeAll("---\n");
                return;
            };
            defer assoc_stmt.finalize();
            assoc_stmt.bind_text(1, class_name);

            var assoc_count: usize = 0;
            var assoc_buf = std.Io.Writer.Allocating.init(self.alloc);
            errdefer assoc_buf.deinit();
            const ab = &assoc_buf.writer;
            while (assoc_stmt.step() catch |e| stepLog(e)) {
                assoc_count += 1;
                const an = assoc_stmt.column_text(0);
                const ak = assoc_stmt.column_text(1);
                const ar = assoc_stmt.column_text(2);
                if (ar.len > 0) {
                    try ab.print("  {s} :{s} → {s}\n", .{ ak, an, ar });
                } else {
                    try ab.print("  {s} :{s}\n", .{ ak, an });
                }
            }
            const assoc_text = try assoc_buf.toOwnedSlice();
            defer self.alloc.free(assoc_text);
            if (assoc_count > 0) {
                try w.writeAll("Associations:\n");
                try w.writeAll(assoc_text);
                try w.writeByte('\n');
            }

            const mix_stmt = self.db.prepare(
                \\SELECT m.module_name FROM mixins m JOIN symbols s ON s.id=m.class_id
                \\WHERE s.name=? LIMIT 10
            ) catch {
                try w.writeAll("---\n");
                return;
            };
            defer mix_stmt.finalize();
            mix_stmt.bind_text(1, class_name);

            var mix_first = true;
            var mix_any = false;
            while (mix_stmt.step() catch |e| stepLog(e)) {
                if (mix_first) {
                    try w.writeAll("Mixins: ");
                    mix_first = false;
                } else {
                    try w.writeAll(", ");
                }
                mix_any = true;
                try w.writeAll(mix_stmt.column_text(0));
            }
            if (mix_any) try w.writeByte('\n');

            try w.writeAll("\n---\n");
        } else if (std.mem.eql(u8, name, "trace-callers")) {
            _ = if (arguments) |a| a.get("class_name") else null; // class_name filtering planned (needs refs.scope_receiver)
            const method_name = if (arguments) |a| if (a.get("method_name")) |v| switch (v) {
                .string => |s| s,
                else => return,
            } else return else return;

            const cal_stmt = self.db.prepare(
                \\SELECT f.path, r.line, r.col
                \\FROM refs r JOIN files f ON f.id = r.file_id
                \\WHERE r.name = ?
                \\ORDER BY f.path, r.line LIMIT 20
            ) catch return;
            defer cal_stmt.finalize();
            cal_stmt.bind_text(1, method_name);

            var cal_count: usize = 0;
            while (cal_stmt.step() catch |e| stepLog(e)) {
                cal_count += 1;
                const cfpath = cal_stmt.column_text(0);
                const cline = cal_stmt.column_int(1);
                const ctx_line = self.readFileLine(cfpath, cline);
                defer if (ctx_line) |cl| self.alloc.free(cl);
                if (ctx_line) |cl| {
                    try w.print("{s}:{d}  {s}\n", .{ cfpath, cline, cl });
                } else {
                    try w.print("{s}:{d}\n", .{ cfpath, cline });
                }
            }
            if (cal_count > 0) try w.writeAll("\n---\n");
        } else if (std.mem.eql(u8, name, "find-bugs")) {
            const file = if (arguments) |a| if (a.get("file")) |v| switch (v) {
                .string => |s| s,
                else => return,
            } else return else return;

            const diag_stmt = self.db.prepare(
                \\SELECT d.line, d.col, d.message, d.severity
                \\FROM diagnostics d JOIN files f ON f.id = d.file_id
                \\WHERE f.path = ? ORDER BY d.line
            ) catch return;
            defer diag_stmt.finalize();
            diag_stmt.bind_text(1, file);

            var diag_count: usize = 0;
            while (diag_stmt.step() catch |e| stepLog(e)) {
                if (diag_count == 0) try w.writeAll("Diagnostics:\n");
                diag_count += 1;
                try w.print("  line {d}: {s}\n", .{ diag_stmt.column_int(0), diag_stmt.column_text(2) });
            }
            if (diag_count > 0) try w.writeByte('\n');

            const lv_stmt = self.db.prepare(
                \\SELECT lv.name, lv.line, lv.type_hint
                \\FROM local_vars lv JOIN files f ON f.id = lv.file_id
                \\WHERE f.path = ? AND lv.type_hint IS NOT NULL
                \\ORDER BY lv.line LIMIT 20
            ) catch {
                if (diag_count > 0) try w.writeAll("---\n");
                return;
            };
            defer lv_stmt.finalize();
            lv_stmt.bind_text(1, file);

            var lv_count: usize = 0;
            while (lv_stmt.step() catch |e| stepLog(e)) {
                if (lv_count == 0) try w.writeAll("Inferred types:\n");
                lv_count += 1;
                try w.print("  {s} (line {d}): {s}\n", .{ lv_stmt.column_text(0), lv_stmt.column_int(1), lv_stmt.column_text(2) });
            }
            if (diag_count > 0 or lv_count > 0) try w.writeAll("\n---\n");
        }
    }

    fn toolGetSymbolSource(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const class_name = getStrArg(args, "class_name") orelse return self.buildToolError(id, "missing 'class_name'");
        const method_name = getStrArg(args, "method_name") orelse return self.buildToolError(id, "missing 'method_name'");

        const sym_stmt = self.db.prepare(
            \\SELECT f.path, s.line, s.end_line
            \\FROM symbols s JOIN files f ON f.id = s.file_id
            \\WHERE s.parent_name = ? AND s.name = ?
            \\  AND s.kind IN ('def','classdef')
            \\LIMIT 1
        ) catch return self.buildToolError(id, "database error");
        defer sym_stmt.finalize();
        sym_stmt.bind_text(1, class_name);
        sym_stmt.bind_text(2, method_name);

        if (!(sym_stmt.step() catch |e| stepLog(e))) {
            return self.buildToolResult(id, "{\"found\":false}");
        }
        const fpath = sym_stmt.column_text(0);
        const sym_line = sym_stmt.column_int(1);
        var end_line = sym_stmt.column_int(2);
        if (end_line == 0) end_line = sym_line;

        const raw = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, fpath, self.alloc, std.Io.Limit.limited(8 * 1024 * 1024)) catch
            return self.buildToolError(id, "cannot read file");
        defer self.alloc.free(raw);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"found\":true,\"class\":");
        try writeJsonStr(w, class_name);
        try w.writeAll(",\"method\":");
        try writeJsonStr(w, method_name);
        try w.writeAll(",\"file\":");
        try writeJsonStr(w, fpath);
        try w.print(",\"line\":{d},\"end_line\":{d},\"source\":", .{ sym_line, end_line });

        // Extract lines sym_line..end_line (1-based), cap at 200 lines
        const cap_end = @min(end_line, sym_line + 199);
        var src_buf = std.Io.Writer.Allocating.init(self.alloc);
        errdefer src_buf.deinit();
        const sw = &src_buf.writer;
        var lineno: i64 = 1;
        var i: usize = 0;
        while (i <= raw.len) {
            const line_start = i;
            while (i < raw.len and raw[i] != '\n') i += 1;
            const line_end = i;
            if (lineno >= sym_line and lineno <= cap_end) {
                try sw.print("{d}: ", .{lineno});
                try sw.writeAll(raw[line_start..line_end]);
                try sw.writeByte('\n');
            }
            if (i >= raw.len) break;
            i += 1; // skip '\n'
            lineno += 1;
            if (lineno > cap_end) break;
        }
        const src_text = try src_buf.toOwnedSlice();
        defer self.alloc.free(src_text);
        try writeJsonStr(w, src_text);
        try w.writeByte('}');
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolGrepSource(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const query = getStrArg(args, "query") orelse return self.buildToolError(id, "missing 'query'");
        if (query.len == 0) return self.buildToolError(id, "'query' must be non-empty");
        const file_pattern = getStrArg(args, "file_pattern");
        if (file_pattern) |fp| {
            if (validateGlobPattern(fp)) |err_reason| {
                const err_msg = try std.fmt.allocPrint(self.alloc, "invalid file_pattern: {s}", .{err_reason});
                defer self.alloc.free(err_msg);
                return self.buildToolError(id, err_msg);
            }
        }
        const ctx_n: usize = @intCast(@min(getIntArg(args, "context_lines") orelse 1, 5));
        const use_regex = if (args) |a| if (a.get("use_regex")) |v| switch (v) {
            .bool => |b| b,
            else => false,
        } else false else false;
        var offset_raw = getIntArg(args, "offset") orelse 0;
        if (offset_raw < 0) offset_raw = 0;
        const offset: usize = @intCast(offset_raw);

        const query_lower = try self.alloc.alloc(u8, query.len);
        defer self.alloc.free(query_lower);
        for (query, 0..) |c, i| query_lower[i] = std.ascii.toLower(c);

        const files_stmt = self.db.prepare(
            \\SELECT path FROM files WHERE is_gem=0 ORDER BY path LIMIT 5000
        ) catch return self.buildToolError(id, "database error");
        defer files_stmt.finalize();

        var results_buf = std.Io.Writer.Allocating.init(self.alloc);
        errdefer results_buf.deinit();
        const rw = &results_buf.writer;

        var total: usize = 0;
        var skipped: usize = 0;
        var files_checked: usize = 0;
        var results_first = true;

        while (files_stmt.step() catch |e| stepLog(e)) {
            if (total >= 100) break;
            files_checked += 1;
            if (files_checked > 2000) break;
            const fpath = files_stmt.column_text(0);
            if (file_pattern) |fp| {
                const matched = blk: {
                    if (std.mem.indexOf(u8, fp, "*")) |star_idx| {
                        // Simple glob: split on * and require all parts present in path in order
                        const prefix = fp[0..star_idx];
                        const suffix = fp[star_idx + 1 ..];
                        if (prefix.len > 0 and !std.mem.containsAtLeast(u8, fpath, 1, prefix)) break :blk false;
                        if (suffix.len > 0 and !std.mem.endsWith(u8, fpath, suffix)) break :blk false;
                        break :blk true;
                    } else {
                        break :blk std.mem.endsWith(u8, fpath, fp);
                    }
                };
                if (!matched) continue;
            }
            if (!self.pathInWorkspace(fpath)) continue;
            const raw = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, fpath, self.alloc, std.Io.Limit.limited(8 * 1024 * 1024)) catch continue;
            defer self.alloc.free(raw);

            var lines = std.ArrayList([]const u8).empty;
            defer lines.deinit(self.alloc);
            var seg_start: usize = 0;
            for (raw, 0..) |ch, i| {
                if (ch == '\n') {
                    try lines.append(self.alloc, raw[seg_start..i]);
                    seg_start = i + 1;
                }
            }
            if (seg_start < raw.len) try lines.append(self.alloc, raw[seg_start..]);

            for (lines.items, 0..) |line, li| {
                if (total >= 100) break;
                const line_lower = try self.alloc.alloc(u8, line.len);
                defer self.alloc.free(line_lower);
                for (line, 0..) |c, ci| line_lower[ci] = std.ascii.toLower(c);
                const matched = if (use_regex)
                    regexMatchLine(line, query)
                else
                    std.mem.indexOf(u8, line_lower, query_lower) != null;
                if (!matched) continue;
                if (skipped < offset) {
                    skipped += 1;
                    continue;
                }

                total += 1;
                if (!results_first) try rw.writeByte(',');
                results_first = false;
                try rw.writeAll("{\"file\":");
                try writeJsonStr(rw, fpath);
                try rw.print(",\"line\":{d},\"match\":", .{li + 1});
                try writeJsonStrCapped(rw, line, MAX_LINE_BODY_BYTES);
                try rw.writeAll(",\"context_before\":[");
                const before_start: usize = if (li >= ctx_n) li - ctx_n else 0;
                var first_b = true;
                var bi: usize = before_start;
                while (bi < li) : (bi += 1) {
                    if (!first_b) try rw.writeByte(',');
                    first_b = false;
                    try writeJsonStrCapped(rw, lines.items[bi], MAX_LINE_BODY_BYTES);
                }
                try rw.writeAll("],\"context_after\":[");
                const after_end = @min(li + ctx_n + 1, lines.items.len);
                var first_a = true;
                var ai: usize = li + 1;
                while (ai < after_end) : (ai += 1) {
                    if (!first_a) try rw.writeByte(',');
                    first_a = false;
                    try writeJsonStrCapped(rw, lines.items[ai], MAX_LINE_BODY_BYTES);
                }
                try rw.writeAll("]}");
            }
        }
        const results_json = try results_buf.toOwnedSlice();
        defer self.alloc.free(results_json);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"query\":");
        try writeJsonStr(w, query);
        const results_truncated = total >= 100;
        const file_limit_hit = files_checked > 2000;
        try w.print(",\"total\":{d},\"has_more\":{s},\"offset\":{d},\"files_checked\":{d},\"results_truncated\":{s}", .{
            total,
            if (results_truncated) "true" else "false",
            offset,
            files_checked,
            if (file_limit_hit and !results_truncated) "true" else "false",
        });
        try w.writeAll(",\"results\":[");
        try w.writeAll(results_json);
        try w.writeAll("]}");
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolI18nLookup(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const query = getStrArg(args, "query") orelse return self.buildToolError(id, "missing 'query'");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;
        const like_pat = std.fmt.allocPrint(self.alloc, "%{s}%", .{query}) catch return self.buildToolError(id, "OOM");
        defer self.alloc.free(like_pat);

        const stmt = self.db.prepare(
            \\SELECT key, value, locale FROM i18n_keys WHERE key LIKE ? ORDER BY key LIMIT 101 OFFSET ?
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, like_pat);
        stmt.bind_int(2, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"keys\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 100) break;
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const key = stmt.column_text(0);
            const value = stmt.column_text(1);
            const locale = stmt.column_text(2);
            try w.writeAll("{\"key\":");
            try writeJsonStr(w, key);
            try w.writeAll(",\"value\":");
            if (value.len > 0) try writeJsonStr(w, value) else try w.writeAll("null");
            try w.writeAll(",\"locale\":");
            try writeJsonStr(w, locale);
            try w.writeByte('}');
        }
        const has_more = stmt.step() catch false;
        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolListByKind(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const kind = getStrArg(args, "kind") orelse return self.buildToolError(id, "missing 'kind'");
        const allowed_kinds = [_][]const u8{ "class", "module", "def", "constant", "association", "route_helper" };
        var kind_ok = false;
        for (allowed_kinds) |k| {
            if (std.mem.eql(u8, kind, k)) {
                kind_ok = true;
                break;
            }
        }
        if (!kind_ok) return self.buildToolError(id, "invalid 'kind' (expected class|module|def|constant|association|route_helper)");
        const name_filter = getStrArg(args, "name_filter");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        const like_pat: ?[]u8 = if (name_filter) |nf|
            std.fmt.allocPrint(self.alloc, "{s}%", .{nf}) catch null
        else
            null;
        defer if (like_pat) |lp| self.alloc.free(lp);

        const stmt = self.db.prepare(
            \\SELECT DISTINCT s.name, f.path, s.line
            \\FROM symbols s JOIN files f ON f.id = s.file_id
            \\WHERE s.kind = ? AND (? IS NULL OR s.name LIKE ?) AND f.is_gem = 0
            \\ORDER BY s.name LIMIT 201 OFFSET ?
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, kind);
        if (like_pat) |lp| {
            stmt.bind_text(2, lp);
            stmt.bind_text(3, lp);
        } else {
            stmt.bind_null(2);
            stmt.bind_null(3);
        }
        stmt.bind_int(4, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"kind\":");
        try writeJsonStr(w, kind);
        try w.writeAll(",\"symbols\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 200) break;
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const sname = stmt.column_text(0);
            const spath = stmt.column_text(1);
            const sline = stmt.column_int(2);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, sname);
            try w.writeAll(",\"file\":");
            try writeJsonStr(w, spath);
            try w.print(",\"line\":{d}}}", .{sline});
        }
        const has_more = stmt.step() catch false;
        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolFindUnused(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const kind_filter = getStrArg(args, "kind");
        const parent_filter = getStrArg(args, "parent_name");

        const stmt = self.db.prepare(
            \\SELECT s.name, s.kind, s.parent_name, f.path, s.line
            \\FROM symbols s JOIN files f ON f.id = s.file_id
            \\LEFT JOIN refs r ON r.name = s.name
            \\WHERE r.name IS NULL
            \\  AND s.kind = COALESCE(?, 'def')
            \\  AND (? IS NULL OR s.parent_name = ?)
            \\  AND f.is_gem = 0
            \\  AND s.visibility != 'private'
            \\ORDER BY f.path, s.line LIMIT 100
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        if (kind_filter) |kf| stmt.bind_text(1, kf) else stmt.bind_null(1);
        if (parent_filter) |pf| {
            stmt.bind_text(2, pf);
            stmt.bind_text(3, pf);
        } else {
            stmt.bind_null(2);
            stmt.bind_null(3);
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"unused\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const sname = stmt.column_text(0);
            const skind = stmt.column_text(1);
            const sparent = stmt.column_text(2);
            const spath = stmt.column_text(3);
            const sline = stmt.column_int(4);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, sname);
            try w.writeAll(",\"kind\":");
            try writeJsonStr(w, skind);
            try w.writeAll(",\"parent_name\":");
            if (sparent.len > 0) try writeJsonStr(w, sparent) else try w.writeAll("null");
            try w.writeAll(",\"file\":");
            try writeJsonStr(w, spath);
            try w.print(",\"line\":{d}}}", .{sline});
        }
        try w.print("],\"has_more\":{s},\"note\":\"static approximation only\"}}", .{if (row_count >= 100) "true" else "false"});
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolGetFileOverview(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file = getStrArg(args, "file") orelse return self.buildToolError(id, "missing 'file'");
        const resolved = normalizeFileArg(self.alloc, file) orelse return self.buildToolError(id, "cannot resolve file path");
        defer self.alloc.free(resolved);

        const stmt = self.db.prepare(
            \\SELECT name, kind, line, parent_name, return_type, visibility
            \\FROM symbols
            \\WHERE file_id = (SELECT id FROM files WHERE path = ?)
            \\ORDER BY line
            \\LIMIT 500
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, resolved);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"file\":");
        try writeJsonStr(w, file);
        try w.writeAll(",\"symbols\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const sname = stmt.column_text(0);
            const skind = stmt.column_text(1);
            const sline = stmt.column_int(2);
            const sparent = stmt.column_text(3);
            const sret = stmt.column_text(4);
            const svis = stmt.column_text(5);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, sname);
            try w.writeAll(",\"kind\":");
            try writeJsonStr(w, skind);
            try w.print(",\"line\":{d},\"parent_name\":", .{sline});
            if (sparent.len > 0) try writeJsonStr(w, sparent) else try w.writeAll("null");
            try w.writeAll(",\"return_type\":");
            if (sret.len > 0) try writeJsonStr(w, sret) else try w.writeAll("null");
            try w.writeAll(",\"visibility\":");
            try writeJsonStr(w, svis);
            try w.writeByte('}');
        }
        try w.print("],\"has_more\":{s}}}", .{if (row_count >= 500) "true" else "false"});
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolListValidations(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const class_name = getStrArg(args, "class_name") orelse return self.buildToolError(id, "missing 'class_name'");

        const stmt = self.db.prepare(
            \\SELECT r.name, r.line, r.col, f.path
            \\FROM refs r
            \\JOIN files f ON f.id = r.file_id
            \\JOIN symbols s ON s.file_id = f.id AND s.name = ? AND s.kind IN ('class','module')
            \\WHERE r.file_id = s.file_id
            \\  AND r.name IN ('validates','validate','validates_presence_of','validates_uniqueness_of',
            \\                 'validates_format_of','validates_length_of','validates_numericality_of',
            \\                 'validates_inclusion_of','validates_exclusion_of','validates_with',
            \\                 'validates_presence','validates_unique','validates_format',
            \\                 'validates_type','validates_not_null','validates_exact_length',
            \\                 'validates_min_length','validates_max_length','validates_integer',
            \\                 'validates_numeric','validates_includes','validates_schema_types')
            \\ORDER BY r.line
            \\LIMIT 100
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, class_name);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"class\":");
        try writeJsonStr(w, class_name);
        try w.writeAll(",\"validations\":[");

        var file_cache = std.StringHashMap([]const u8).init(self.alloc);
        defer {
            var it = file_cache.iterator();
            while (it.next()) |entry| {
                self.alloc.free(entry.key_ptr.*);
                self.alloc.free(entry.value_ptr.*);
            }
            file_cache.deinit();
        }

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const vname = stmt.column_text(0);
            const vline = stmt.column_int(1);
            const vcol = stmt.column_int(2);
            const vpath = stmt.column_text(3);
            try w.print("{{\"name\":", .{});
            try writeJsonStr(w, vname);
            try w.print(",\"line\":{d},\"col\":{d}", .{ vline, vcol });
            const ctx_line = self.readFileLineFromCache(&file_cache, vpath, vline);
            defer if (ctx_line) |cl| self.alloc.free(cl);
            if (ctx_line) |cl| {
                try w.writeAll(",\"context\":");
                try writeJsonStr(w, cl);
            }
            try w.writeByte('}');
        }
        try w.print("],\"has_more\":{s}}}", .{if (row_count >= 100) "true" else "false"});
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn handleResourcesList(self: *Server, id: ?std.json.Value) !?[]u8 {
        const result =
            \\{"resources":[
            \\{"uri":"refract://workspace/summary","name":"Workspace Summary","description":"File count, symbol count, schema version, and indexed gem count","mimeType":"application/json"},
            \\{"uri":"refract://class/{ClassName}","name":"Class Documentation","description":"All methods with types and docs for a class","mimeType":"text/markdown"}
            \\]}
        ;
        return self.buildResult(id, result);
    }

    fn handleResourcesRead(self: *Server, id: ?std.json.Value, params: ?std.json.Value) !?[]u8 {
        const params_obj = switch (params orelse return self.buildError(id, -32602, "missing params")) {
            .object => |o| o,
            else => return self.buildError(id, -32602, "params must be object"),
        };
        const uri_val = params_obj.get("uri") orelse return self.buildError(id, -32602, "missing uri");
        const uri = switch (uri_val) {
            .string => |s| s,
            else => return self.buildError(id, -32602, "uri must be string"),
        };

        if (std.mem.eql(u8, uri, "refract://workspace/summary")) {
            return self.readWorkspaceSummary(id);
        }
        if (std.mem.startsWith(u8, uri, "refract://class/")) {
            const class_name = uri["refract://class/".len..];
            return self.readClassDoc(id, class_name);
        }
        return self.buildError(id, -32002, "Resource not found");
    }

    fn readWorkspaceSummary(self: *Server, id: ?std.json.Value) !?[]u8 {
        var file_count: i64 = 0;
        var gem_count: i64 = 0;
        var sym_count: i64 = 0;
        var schema_ver: []const u8 = "unknown";
        var schema_ver_alloc = false;
        defer if (schema_ver_alloc) self.alloc.free(schema_ver);

        if (self.db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=0")) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) file_count = s.column_int(0);
        } else |_| {}
        if (self.db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=1")) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) gem_count = s.column_int(0);
        } else |_| {}
        if (self.db.prepare("SELECT COUNT(*) FROM symbols")) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) sym_count = s.column_int(0);
        } else |_| {}
        if (self.db.prepare("SELECT value FROM meta WHERE key='schema_version'")) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) {
                schema_ver = self.alloc.dupe(u8, s.column_text(0)) catch "unknown";
                schema_ver_alloc = !std.mem.eql(u8, schema_ver, "unknown");
            }
        } else |_| {}

        // Build the inner JSON text first, then embed it as an escaped string
        var inner = std.Io.Writer.Allocating.init(self.alloc);
        errdefer inner.deinit();
        const iw = &inner.writer;
        try iw.writeAll("{\"files\":");
        try iw.print("{d}", .{file_count});
        try iw.writeAll(",\"gems\":");
        try iw.print("{d}", .{gem_count});
        try iw.writeAll(",\"symbols\":");
        try iw.print("{d}", .{sym_count});
        try iw.writeAll(",\"schema_version\":");
        try writeJsonStr(iw, schema_ver);
        try iw.writeByte('}');
        const inner_json = try inner.toOwnedSlice();
        defer self.alloc.free(inner_json);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"contents\":[{\"uri\":\"refract://workspace/summary\"");
        try w.writeAll(",\"mimeType\":\"application/json\",\"text\":");
        try writeJsonStr(w, inner_json);
        try w.writeAll("}]}");
        const result = try aw.toOwnedSlice();
        defer self.alloc.free(result);
        return self.buildResult(id, result);
    }

    fn readClassDoc(self: *Server, id: ?std.json.Value, class_name: []const u8) !?[]u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;

        var doc_buf = std.Io.Writer.Allocating.init(self.alloc);
        errdefer doc_buf.deinit();
        const dw = &doc_buf.writer;
        try dw.print("# {s}\n\n", .{class_name});

        const loc_stmt = self.db.prepare(
            \\SELECT f.path, s.line FROM symbols s JOIN files f ON f.id=s.file_id
            \\WHERE s.name=? AND s.kind IN ('class','module') LIMIT 1
        ) catch null;
        if (loc_stmt) |ls| {
            defer ls.finalize();
            ls.bind_text(1, class_name);
            if (ls.step() catch |e| stepLog(e)) {
                try dw.print("**Location**: {s}:{d}\n\n", .{ ls.column_text(0), ls.column_int(1) });
            }
        }

        const stmt = self.db.prepare(
            \\SELECT name, kind, return_type, doc FROM symbols
            \\WHERE parent_name = ? AND kind IN ('def','classdef')
            \\ORDER BY kind DESC, name LIMIT 50
        ) catch {
            try dw.writeAll("(no methods indexed)\n");
            const doc_text = try doc_buf.toOwnedSlice();
            defer self.alloc.free(doc_text);
            const uri = try std.fmt.allocPrint(self.alloc, "refract://class/{s}", .{class_name});
            defer self.alloc.free(uri);
            try w.writeAll("{\"contents\":[{\"uri\":");
            try writeJsonStr(w, uri);
            try w.writeAll(",\"mimeType\":\"text/markdown\",\"text\":");
            try writeJsonStr(w, doc_text);
            try w.writeAll("}]}");
            const result = try aw.toOwnedSlice();
            defer self.alloc.free(result);
            return self.buildResult(id, result);
        };
        defer stmt.finalize();
        stmt.bind_text(1, class_name);

        var meth_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            meth_count += 1;
            const mname = stmt.column_text(0);
            const mkind = stmt.column_text(1);
            const mret = stmt.column_text(2);
            const mdoc = stmt.column_text(3);
            const prefix: []const u8 = if (std.mem.eql(u8, mkind, "classdef")) "self." else "";
            if (mret.len > 0) {
                try dw.print("- `{s}{s}` → `{s}`", .{ prefix, mname, mret });
            } else {
                try dw.print("- `{s}{s}`", .{ prefix, mname });
            }
            if (mdoc.len > 0) {
                try dw.print(" — {s}", .{mdoc});
            }
            try dw.writeByte('\n');
        }
        if (meth_count > 0) try dw.writeByte('\n');

        const assoc_stmt = self.db.prepare(
            \\SELECT name, kind, return_type FROM symbols
            \\WHERE parent_name=? AND kind IN ('association','scope')
            \\ORDER BY name LIMIT 30
        ) catch null;
        if (assoc_stmt) |as| {
            defer as.finalize();
            as.bind_text(1, class_name);
            var assoc_first = true;
            while (as.step() catch |e| stepLog(e)) {
                if (assoc_first) {
                    try dw.writeAll("## Associations\n\n| Name | Type | Class |\n|------|------|-------|\n");
                    assoc_first = false;
                }
                const an = as.column_text(0);
                const ak = as.column_text(1);
                const ar = as.column_text(2);
                try dw.print("| {s} | {s} | {s} |\n", .{ an, ak, if (ar.len > 0) ar else "—" });
            }
            if (!assoc_first) try dw.writeByte('\n');
        }

        const mix_stmt = self.db.prepare(
            \\SELECT m.module_name, m.kind FROM mixins m JOIN symbols s ON s.id=m.class_id
            \\WHERE s.name=? LIMIT 15
        ) catch null;
        if (mix_stmt) |ms| {
            defer ms.finalize();
            ms.bind_text(1, class_name);
            var mix_first = true;
            while (ms.step() catch |e| stepLog(e)) {
                if (mix_first) {
                    try dw.writeAll("## Mixins\n\n");
                    mix_first = false;
                }
                try dw.print("- {s} ({s})\n", .{ ms.column_text(0), ms.column_text(1) });
            }
            if (!mix_first) try dw.writeByte('\n');
        }

        const doc_text = try doc_buf.toOwnedSlice();
        defer self.alloc.free(doc_text);

        const uri = try std.fmt.allocPrint(self.alloc, "refract://class/{s}", .{class_name});
        defer self.alloc.free(uri);

        try w.writeAll("{\"contents\":[{\"uri\":");
        try writeJsonStr(w, uri);
        try w.writeAll(",\"mimeType\":\"text/markdown\",\"text\":");
        try writeJsonStr(w, doc_text);
        try w.writeAll("}]}");
        const result = try aw.toOwnedSlice();
        defer self.alloc.free(result);
        return self.buildResult(id, result);
    }

    fn buildResult(self: *Server, id: ?std.json.Value, result_json: []const u8) !?[]u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |iv| try writeJsonValue(w, iv) else try w.writeAll("null");
        try w.writeAll(",\"result\":");
        try w.writeAll(result_json);
        try w.writeByte('}');
        return @as(?[]u8, try aw.toOwnedSlice());
    }

    fn buildError(self: *Server, id: ?std.json.Value, code: i32, message: []const u8) !?[]u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |iv| try writeJsonValue(w, iv) else try w.writeAll("null");
        try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
        try writeJsonStr(w, message);
        try w.writeAll("}}");
        return @as(?[]u8, try aw.toOwnedSlice());
    }

    fn buildToolResult(self: *Server, id: ?std.json.Value, text: []const u8) !?[]u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try writeJsonStr(w, text);
        try w.writeAll("}]}");
        const result = try aw.toOwnedSlice();
        defer self.alloc.free(result);
        return self.buildResult(id, result);
    }

    fn buildToolError(self: *Server, id: ?std.json.Value, text: []const u8) !?[]u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try writeJsonStr(w, text);
        try w.writeAll("}],\"isError\":true}");
        const result = try aw.toOwnedSlice();
        defer self.alloc.free(result);
        return self.buildResult(id, result);
    }

    fn toolListCallbacks(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const class_name = getStrArg(args, "class_name") orelse return self.buildToolError(id, "missing 'class_name'");
        const callback_type = getStrArg(args, "callback_type");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        const stmt = self.db.prepare(
            \\SELECT name, doc, line FROM symbols
            \\WHERE parent_name = ? AND kind = 'callback'
            \\  AND (? IS NULL OR name = ?)
            \\ORDER BY line LIMIT 101 OFFSET ?
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, class_name);
        if (callback_type) |ct| {
            stmt.bind_text(2, ct);
            stmt.bind_text(3, ct);
        } else {
            stmt.bind_null(2);
            stmt.bind_null(3);
        }
        stmt.bind_int(4, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"class\":");
        try writeJsonStr(w, class_name);
        try w.writeAll(",\"callbacks\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 100) break;
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const cname = stmt.column_text(0);
            const cdoc = stmt.column_text(1);
            const cline = stmt.column_int(2);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, cname);
            try w.writeAll(",\"callback_type\":");
            if (cdoc.len > 0) try writeJsonStr(w, cdoc) else try w.writeAll("null");
            try w.print(",\"line\":{d}}}", .{cline});
        }
        const has_more = stmt.step() catch false;
        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolConcernUsage(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const module_name = getStrArg(args, "module_name") orelse return self.buildToolError(id, "missing 'module_name'");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        const stmt = self.db.prepare(
            \\SELECT s.name, f.path, m.kind FROM symbols s
            \\JOIN files f ON f.id = s.file_id
            \\JOIN mixins m ON m.class_id = s.id
            \\WHERE (m.module_name = ? OR m.module_name LIKE '%::' || ?)
            \\  AND m.kind IN ('include','prepend','extend')
            \\ORDER BY s.name LIMIT 101 OFFSET ?
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, module_name);
        stmt.bind_text(2, module_name);
        stmt.bind_int(3, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"module\":");
        try writeJsonStr(w, module_name);
        try w.writeAll(",\"used_by\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 100) break;
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const sname = stmt.column_text(0);
            const fpath = stmt.column_text(1);
            const mkind = stmt.column_text(2);
            try w.writeAll("{\"class\":");
            try writeJsonStr(w, sname);
            try w.writeAll(",\"file\":");
            try writeJsonStr(w, fpath);
            try w.writeAll(",\"kind\":");
            try writeJsonStr(w, mkind);
            try w.writeByte('}');
        }
        const has_more = stmt.step() catch false;
        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolFindReferences(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const name = getStrArg(args, "name") orelse return self.buildToolError(id, "missing 'name'");
        const ref_kind = getStrArg(args, "ref_kind");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;

        const stmt = if (ref_kind != null)
            self.db.prepare(
                \\SELECT f.path, r.line, r.col FROM refs r
                \\JOIN files f ON f.id = r.file_id
                \\WHERE r.name = ? AND r.kind = ?
                \\ORDER BY f.path, r.line LIMIT 201 OFFSET ?
            ) catch return self.buildToolError(id, "database error")
        else
            self.db.prepare(
                \\SELECT f.path, r.line, r.col FROM refs r
                \\JOIN files f ON f.id = r.file_id
                \\WHERE r.name = ?
                \\ORDER BY f.path, r.line LIMIT 201 OFFSET ?
            ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        var param_idx: c_int = 1;
        stmt.bind_text(param_idx, name);
        param_idx += 1;
        if (ref_kind) |kind| {
            stmt.bind_text(param_idx, kind);
            param_idx += 1;
        }
        stmt.bind_int(param_idx, offset);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, name);
        try w.writeAll(",\"references\":[");

        var file_cache = std.StringHashMap([]const u8).init(self.alloc);
        defer {
            var it = file_cache.iterator();
            while (it.next()) |entry| {
                self.alloc.free(entry.key_ptr.*);
                self.alloc.free(entry.value_ptr.*);
            }
            file_cache.deinit();
        }

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 200) break;
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const fpath = stmt.column_text(0);
            const rline = stmt.column_int(1);
            const rcol = stmt.column_int(2);
            try w.writeAll("{\"file\":");
            try writeJsonStr(w, fpath);
            try w.print(",\"line\":{d},\"col\":{d}", .{ rline, rcol });
            const ctx_line = self.readFileLineFromCache(&file_cache, fpath, rline);
            defer if (ctx_line) |cl| self.alloc.free(cl);
            if (ctx_line) |cl| {
                try w.writeAll(",\"context\":");
                try writeJsonStr(w, cl);
            }
            try w.writeByte('}');
        }
        const has_more = stmt.step() catch false;
        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolExplainSymbol(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        var class_name: []const u8 = "";
        var method_name: []const u8 = "";
        if (getStrArg(args, "symbol")) |sym| {
            if (splitQualified(sym)) |q| {
                class_name = q.class_name;
                method_name = q.method_name;
            } else return self.buildToolError(id, "'symbol' must be 'Class#method'");
        } else {
            class_name = getStrArg(args, "class_name") orelse return self.buildToolError(id, "missing 'class_name' (or pass 'symbol':'Class#method')");
            method_name = getStrArg(args, "method_name") orelse return self.buildToolError(id, "missing 'method_name' (or pass 'symbol':'Class#method')");
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"class\":");
        try writeJsonStr(w, class_name);
        try w.writeAll(",\"method\":");
        try writeJsonStr(w, method_name);

        // Signature fields — resolve directly or via ancestors/mixins.
        const resolved = self.resolveMethodSym(class_name, method_name);
        if (resolved == null) {
            try w.writeAll(",\"found\":false}");
            const text = try aw.toOwnedSlice();
            defer self.alloc.free(text);
            return self.buildToolResult(id, text);
        }
        const rm = resolved.?;
        defer if (rm.owner) |o| self.alloc.free(o);

        const sym_stmt = self.db.prepare(
            \\SELECT s.return_type, s.visibility, f.path, s.line, s.doc
            \\FROM symbols s JOIN files f ON f.id = s.file_id
            \\WHERE s.id = ? LIMIT 1
        ) catch {
            try w.writeAll(",\"found\":false}");
            const text = try aw.toOwnedSlice();
            defer self.alloc.free(text);
            return self.buildToolResult(id, text);
        };
        defer sym_stmt.finalize();
        sym_stmt.bind_int(1, rm.sym_id);

        var def_file: []const u8 = "";
        var def_line: i64 = 0;
        if (sym_stmt.step() catch |e| stepLog(e)) {
            const ret = sym_stmt.column_text(0);
            const vis = sym_stmt.column_text(1);
            def_file = sym_stmt.column_text(2);
            def_line = sym_stmt.column_int(3);
            const yard = sym_stmt.column_text(4);
            // Overlay correction: type-override on this method's return type wins.
            const ctx = self.overlayCtx();
            defer if (ctx) |c| c.deinit();
            const qualified = try std.fmt.allocPrint(self.alloc, "{s}#{s}", .{ class_name, method_name });
            defer self.alloc.free(qualified);
            const ov_ret: ?[]u8 = if (ctx) |c| overlay.effectiveType(self.db, self.alloc, c.pid, c.branch, qualified, null, -1) else null;
            defer if (ov_ret) |o| self.alloc.free(o);
            try w.writeAll(",\"found\":true,\"inherited_from\":");
            if (rm.owner) |o| try writeJsonStr(w, o) else try w.writeAll("null");
            try w.writeAll(",\"return_type\":");
            if (ov_ret) |o| {
                try writeJsonStr(w, o);
                try w.writeAll(",\"return_type_source\":\"overlay\"");
            } else if (ret.len > 0) try writeJsonStr(w, ret) else try w.writeAll("null");
            try w.writeAll(",\"visibility\":");
            try writeJsonStr(w, vis);
            try w.writeAll(",\"defined_at\":{\"file\":");
            try writeJsonStr(w, def_file);
            try w.print(",\"line\":{d}}}", .{def_line});
            if (yard.len > 0) {
                try w.writeAll(",\"yard_doc\":");
                try writeJsonStr(w, yard);
            }
        } else {
            try w.writeAll(",\"found\":false}");
            const text = try aw.toOwnedSlice();
            defer self.alloc.free(text);
            return self.buildToolResult(id, text);
        }

        // Parameter list (shared helper; queries by symbol_id).
        try w.writeAll(",\"params\":[");
        try self.writeMethodParams(w, rm.sym_id);
        try w.writeByte(']');

        // Caller count + up to 3 sample sites
        var caller_count: i64 = 0;
        if (self.db.prepare(
            \\SELECT COUNT(*) FROM refs r WHERE r.name = ?
        )) |cs| {
            defer cs.finalize();
            cs.bind_text(1, method_name);
            if (cs.step() catch |e| stepLog(e)) caller_count = cs.column_int(0);
        } else |_| {}
        try w.print(",\"caller_count\":{d}", .{caller_count});

        const sample_stmt = self.db.prepare(
            \\SELECT f.path, r.line FROM refs r
            \\JOIN files f ON f.id = r.file_id
            \\WHERE r.name = ?
            \\ORDER BY f.path, r.line LIMIT 3
        ) catch null;
        try w.writeAll(",\"sample_callers\":[");
        if (sample_stmt) |ss| {
            defer ss.finalize();
            ss.bind_text(1, method_name);
            var sfirst = true;
            while (ss.step() catch |e| stepLog(e)) {
                if (!sfirst) try w.writeByte(',');
                sfirst = false;
                try w.writeAll("{\"file\":");
                try writeJsonStr(w, ss.column_text(0));
                try w.print(",\"line\":{d}}}", .{ss.column_int(1)});
            }
        }
        try w.writeByte(']');

        // Diagnostics on the defining file
        try w.writeAll(",\"diagnostics\":[");
        if (def_file.len > 0) {
            if (self.db.prepare(
                \\SELECT d.message, d.severity, d.line FROM diagnostics d
                \\JOIN files f ON f.id = d.file_id
                \\WHERE f.path = ? ORDER BY d.line LIMIT 10
            )) |ds| {
                defer ds.finalize();
                ds.bind_text(1, def_file);
                var dfirst = true;
                while (ds.step() catch |e| stepLog(e)) {
                    if (!dfirst) try w.writeByte(',');
                    dfirst = false;
                    try w.writeAll("{\"message\":");
                    try writeJsonStr(w, ds.column_text(0));
                    try w.writeAll(",\"severity\":");
                    try writeJsonStr(w, ds.column_text(1));
                    try w.print(",\"line\":{d}}}", .{ds.column_int(2)});
                }
            } else |_| {}
        }
        try w.writeAll("]}");
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolBatchResolve(self: *Server, id: ?std.json.Value, args_val: ?std.json.Value) !?[]u8 {
        const positions_val = switch (args_val orelse return self.buildToolError(id, "missing arguments")) {
            .object => |o| o.get("positions") orelse return self.buildToolError(id, "missing 'positions'"),
            else => return self.buildToolError(id, "arguments must be object"),
        };
        const positions = switch (positions_val) {
            .array => |a| a,
            else => return self.buildToolError(id, "'positions' must be array"),
        };
        if (positions.items.len > 20) return self.buildToolError(id, "too many positions (max 20)");

        const stmt = self.db.prepare(
            \\SELECT lv.name, lv.type_hint, lv.confidence
            \\FROM local_vars lv JOIN files f ON f.id = lv.file_id
            \\WHERE f.path = ? AND lv.line = ? AND lv.type_hint IS NOT NULL
            \\ORDER BY ABS(lv.col - ?) LIMIT 1
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"results\":[");

        for (positions.items, 0..) |pos_val, pi| {
            if (pi > 0) try w.writeByte(',');
            const pos = switch (pos_val) {
                .object => |o| o,
                else => {
                    try w.writeAll("{\"error\":\"position must be object\"}");
                    continue;
                },
            };
            const file = switch (pos.get("file") orelse {
                try w.writeAll("{\"error\":\"missing file\"}");
                continue;
            }) {
                .string => |s| s,
                else => {
                    try w.writeAll("{\"error\":\"file must be string\"}");
                    continue;
                },
            };
            const line = switch (pos.get("line") orelse {
                try w.writeAll("{\"error\":\"missing line\"}");
                continue;
            }) {
                .integer => |i| i,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => {
                    try w.writeAll("{\"error\":\"line must be integer\"}");
                    continue;
                },
            };
            const col: i64 = if (pos.get("col")) |cv| switch (cv) {
                .integer => |i| i,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => 0,
            } else 0;

            stmt.reset();
            stmt.bind_text(1, file);
            stmt.bind_int(2, line);
            stmt.bind_int(3, col);

            try w.print("{{\"line\":{d},\"col\":{d}", .{ line, col });
            if (stmt.step() catch |e| stepLog(e)) {
                try w.writeAll(",\"type\":");
                try writeJsonStr(w, stmt.column_text(1));
                try w.print(",\"confidence\":{d}", .{stmt.column_int(2)});
            } else {
                try w.writeAll(",\"type\":null,\"confidence\":0");
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolWorkspaceHealth(self: *Server, id: ?std.json.Value) !?[]u8 {
        var total_files: i64 = 0;
        var total_symbols: i64 = 0;
        var typed_vars: i64 = 0;
        var total_vars: i64 = 0;
        var unused_defs: i64 = 0;
        var schema_ver: []const u8 = "unknown";
        var schema_ver_allocated = false;
        defer if (schema_ver_allocated) self.alloc.free(schema_ver);

        if (self.db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=0")) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) total_files = s.column_int(0);
        } else |_| {}
        if (self.db.prepare("SELECT COUNT(*) FROM symbols")) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) total_symbols = s.column_int(0);
        } else |_| {}
        if (self.db.prepare("SELECT COUNT(*) FROM local_vars WHERE type_hint IS NOT NULL")) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) typed_vars = s.column_int(0);
        } else |_| {}
        if (self.db.prepare("SELECT COUNT(*) FROM local_vars")) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) total_vars = s.column_int(0);
        } else |_| {}
        if (self.db.prepare(
            \\SELECT COUNT(*) FROM symbols s
            \\WHERE s.kind = 'def' AND s.visibility = 'public'
            \\  AND NOT EXISTS (SELECT 1 FROM refs r WHERE r.name = s.name)
        )) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) unused_defs = s.column_int(0);
        } else |_| {}
        if (self.db.prepare("SELECT value FROM meta WHERE key='schema_version'")) |s| {
            defer s.finalize();
            if (s.step() catch |e| stepLog(e)) {
                schema_ver = self.alloc.dupe(u8, s.column_text(0)) catch "unknown";
                schema_ver_allocated = !std.mem.eql(u8, schema_ver, "unknown");
            }
        } else |_| {}

        const typed_pct: f64 = if (total_vars > 0)
            @as(f64, @floatFromInt(typed_vars)) / @as(f64, @floatFromInt(total_vars)) * 100.0
        else
            0.0;

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\"total_files\":{d},\"total_symbols\":{d},\"typed_local_var_pct\":{d:.1},\"unused_def_count\":{d}", .{
            total_files, total_symbols, typed_pct, unused_defs,
        });

        // Diagnostics by severity
        try w.writeAll(",\"diagnostic_count_by_severity\":{");
        if (self.db.prepare("SELECT severity, COUNT(*) FROM diagnostics GROUP BY severity ORDER BY severity")) |ds| {
            defer ds.finalize();
            var dfirst = true;
            while (ds.step() catch |e| stepLog(e)) {
                if (!dfirst) try w.writeByte(',');
                dfirst = false;
                try writeJsonStr(w, ds.column_text(0));
                try w.print(":{d}", .{ds.column_int(1)});
            }
        } else |_| {}
        try w.writeAll("},\"schema_version\":");
        try writeJsonStr(w, schema_ver);
        try w.writeByte('}');

        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolTestSummary(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file = getStrArg(args, "file") orelse return self.buildToolError(id, "missing 'file' argument");
        const resolved = normalizeFileArg(self.alloc, file) orelse return self.buildToolError(id, "cannot resolve file path");
        defer self.alloc.free(resolved);
        const stmt = self.db.prepare(
            \\SELECT s.name, s.kind, s.line, s.end_line
            \\FROM symbols s JOIN files f ON f.id = s.file_id
            \\WHERE f.path = ? AND s.kind = 'test'
            \\ORDER BY s.line LIMIT 500
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, resolved);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"file\":");
        try writeJsonStr(w, file);
        try w.writeAll(",\"tests\":[");
        var first = true;
        while (stmt.step() catch |e| stepLog(e)) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, stmt.column_text(0));
            try w.writeAll(",\"kind\":");
            try writeJsonStr(w, stmt.column_text(1));
            try w.print(",\"line\":{d}", .{stmt.column_int(2)});
            if (stmt.column_type(3) != 5) {
                try w.print(",\"end_line\":{d}", .{stmt.column_int(3)});
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        const txt = try aw.toOwnedSlice();
        defer self.alloc.free(txt);
        return self.buildToolResult(id, txt);
    }

    fn toolListRoutes(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const prefix = getStrArg(args, "prefix");
        var offset = getIntArg(args, "offset") orelse 0;
        if (offset < 0) offset = 0;
        const limit: i64 = 100;

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"routes\":[");

        var has_more = false;
        if (prefix) |pfx| {
            var pat_buf: [256]u8 = undefined;
            const pat_len = @min(pfx.len, pat_buf.len - 2);
            @memcpy(pat_buf[0..pat_len], pfx[0..pat_len]);
            pat_buf[pat_len] = '%';
            const pattern = pat_buf[0 .. pat_len + 1];

            const stmt = self.db.prepare(
                \\SELECT r.helper_name, r.http_method, r.path_pattern, r.controller, r.action, r.line
                \\FROM routes r WHERE r.helper_name LIKE ? ESCAPE '\'
                \\ORDER BY r.helper_name LIMIT ? OFFSET ?
            ) catch return self.buildToolError(id, "database error");
            defer stmt.finalize();
            stmt.bind_text(1, pattern);
            stmt.bind_int(2, limit + 1);
            stmt.bind_int(3, offset);

            var row_count: usize = 0;
            var first = true;
            while (stmt.step() catch |e| stepLog(e)) {
                if (row_count >= limit) {
                    has_more = true;
                    break;
                }
                if (!first) try w.writeByte(',');
                first = false;
                row_count += 1;
                try w.writeAll("{\"helper\":");
                try writeJsonStr(w, stmt.column_text(0));
                const method = stmt.column_text(1);
                if (method.len > 0) {
                    try w.writeAll(",\"method\":");
                    try writeJsonStr(w, method);
                }
                const ctrl = stmt.column_text(3);
                if (ctrl.len > 0) {
                    try w.writeAll(",\"controller\":");
                    try writeJsonStr(w, ctrl);
                }
                const action = stmt.column_text(4);
                if (action.len > 0) {
                    try w.writeAll(",\"action\":");
                    try writeJsonStr(w, action);
                }
                try w.print(",\"line\":{d}}}", .{stmt.column_int(5)});
            }
        } else {
            const stmt = self.db.prepare(
                \\SELECT r.helper_name, r.http_method, r.path_pattern, r.controller, r.action, r.line
                \\FROM routes r ORDER BY r.helper_name LIMIT ? OFFSET ?
            ) catch return self.buildToolError(id, "database error");
            defer stmt.finalize();
            stmt.bind_int(1, limit + 1);
            stmt.bind_int(2, offset);

            var row_count: usize = 0;
            var first = true;
            while (stmt.step() catch |e| stepLog(e)) {
                if (row_count >= limit) {
                    has_more = true;
                    break;
                }
                if (!first) try w.writeByte(',');
                first = false;
                row_count += 1;
                try w.writeAll("{\"helper\":");
                try writeJsonStr(w, stmt.column_text(0));
                const method = stmt.column_text(1);
                if (method.len > 0) {
                    try w.writeAll(",\"method\":");
                    try writeJsonStr(w, method);
                }
                const ctrl = stmt.column_text(3);
                if (ctrl.len > 0) {
                    try w.writeAll(",\"controller\":");
                    try writeJsonStr(w, ctrl);
                }
                const action = stmt.column_text(4);
                if (action.len > 0) {
                    try w.writeAll(",\"action\":");
                    try writeJsonStr(w, action);
                }
                try w.print(",\"line\":{d}}}", .{stmt.column_int(5)});
            }
        }

        try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
        const txt = try aw.toOwnedSlice();
        defer self.alloc.free(txt);
        return self.buildToolResult(id, txt);
    }

    fn toolRefactor(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file = getStrArg(args, "file") orelse return self.buildToolError(id, "missing 'file'");
        const start_line = getIntArg(args, "start_line") orelse return self.buildToolError(id, "missing 'start_line'");
        const end_line = getIntArg(args, "end_line") orelse return self.buildToolError(id, "missing 'end_line'");
        const kind = getStrArg(args, "kind") orelse return self.buildToolError(id, "missing 'kind'");

        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file, self.alloc, std.Io.Limit.limited(1 << 20)) catch return self.buildToolError(id, "cannot read file");
        defer self.alloc.free(source);

        var result = if (std.mem.eql(u8, kind, "extract_method"))
            refactor_mod.extractMethod(self.alloc, source, @intCast(start_line), @intCast(end_line), "extracted_method") catch return self.buildToolError(id, "refactor failed")
        else if (std.mem.eql(u8, kind, "extract_variable"))
            refactor_mod.extractVariable(self.alloc, source, @intCast(start_line), 0, @intCast(end_line), 0, "extracted_var") catch return self.buildToolError(id, "refactor failed")
        else
            return self.buildToolError(id, "unsupported kind");

        defer result.deinit();

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("[");

        for (result.edits, 0..) |edit, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"start_line\":{d},\"start_col\":{d},\"end_line\":{d},\"end_col\":{d},\"new_text\":", .{
                edit.start_line, edit.start_col, edit.end_line, edit.end_col,
            });
            try writeJsonStr(w, edit.new_text);
            try w.writeAll("}");
        }
        try w.writeAll("]");

        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolAvailableCodeActions(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file = getStrArg(args, "file") orelse return self.buildToolError(id, "missing 'file'");
        const line = getIntArg(args, "line") orelse return self.buildToolError(id, "missing 'line'");
        _ = getIntArg(args, "character");

        const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file, self.alloc, std.Io.Limit.limited(1 << 20)) catch return self.buildToolError(id, "cannot read file");
        defer self.alloc.free(source);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("[");

        var first = true;
        if (@as(u32, @intCast(line)) < countLines(source)) {
            if (!first) try w.writeByte(',');
            try writeJsonStr(w, "extract_method");
            first = false;
        }

        var has_pragma = false;
        var line_iter = std.mem.splitSequence(u8, source, "\n");
        var line_num: u32 = 0;
        while (line_iter.next()) |l| : (line_num += 1) {
            if (std.mem.indexOf(u8, l, "frozen_string_literal")) |_| {
                has_pragma = true;
                break;
            }
        }

        if (!has_pragma and std.mem.endsWith(u8, file, ".rb")) {
            if (!first) try w.writeByte(',');
            try writeJsonStr(w, "add_frozen_string_literal");
            first = false;
        }

        try w.writeAll("]");
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolDiagnosticSummary(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file_filter = getStrArg(args, "file");
        const severity_filter = getStrArg(args, "severity_filter");
        const code_filter = getStrArg(args, "code_filter");

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("[");

        if (self.db.prepare(
            \\SELECT d.line, d.col, d.message, d.severity, d.code, f.path
            \\FROM diagnostics d JOIN files f ON f.id = d.file_id
            \\ORDER BY f.path, d.line
        )) |stmt| {
            defer stmt.finalize();

            var first = true;
            var result_count: u32 = 0;
            const max_results: u32 = 500;
            while (stmt.step() catch |e| stepLog(e)) {
                const line = stmt.column_int(0);
                const col = stmt.column_int(1);
                const msg = stmt.column_text(2);
                const severity = stmt.column_int(3);
                const code = stmt.column_text(4);
                const fpath = stmt.column_text(5);

                if (file_filter) |ff| {
                    if (!std.mem.eql(u8, fpath, ff)) continue;
                }

                if (severity_filter) |sf| {
                    var sev_match = false;
                    if (std.mem.eql(u8, sf, "error") and severity == 1) sev_match = true;
                    if (std.mem.eql(u8, sf, "warning") and severity == 2) sev_match = true;
                    if (std.mem.eql(u8, sf, "info") and severity == 3) sev_match = true;
                    if (!sev_match) continue;
                }

                if (code_filter) |cf| {
                    if (!std.mem.eql(u8, code, cf)) continue;
                }

                if (result_count >= max_results) break;

                if (!first) try w.writeByte(',');
                first = false;
                try w.print("{{\"file\":", .{});
                try writeJsonStr(w, fpath);
                try w.print(",\"line\":{d},\"col\":{d},\"severity\":{d},\"message\":", .{ line, col, severity });
                try writeJsonStr(w, msg);
                try w.writeAll(",\"code\":");
                if (code.len > 0) try writeJsonStr(w, code) else try w.writeAll("null");
                try w.writeAll("}");
                result_count += 1;
            }
        } else |_| {}

        try w.writeAll("]");
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolExplainTypeChain(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file = getStrArg(args, "file") orelse return self.buildToolError(id, "missing 'file' argument");
        const line = getIntArg(args, "line") orelse return self.buildToolError(id, "missing 'line' argument");
        const col = getIntArg(args, "col") orelse 0;

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"chain\":[");

        const stmt = self.db.prepare(
            \\SELECT lv.name, lv.type_hint, lv.confidence, lv.line, lv.col
            \\FROM local_vars lv JOIN files f ON f.id = lv.file_id
            \\WHERE (f.path = ? OR f.path LIKE '%/' || ?) AND lv.name = (
            \\  SELECT lv2.name FROM local_vars lv2 JOIN files f2 ON f2.id = lv2.file_id
            \\  WHERE (f2.path = ? OR f2.path LIKE '%/' || ?) AND lv2.line = ? ORDER BY ABS(lv2.col - ?) LIMIT 1
            \\) AND lv.type_hint IS NOT NULL
            \\ORDER BY lv.confidence DESC, lv.line ASC
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, file);
        stmt.bind_text(2, file);
        stmt.bind_text(3, file);
        stmt.bind_text(4, file);
        stmt.bind_int(5, line);
        stmt.bind_int(6, col);

        var first = true;
        while (stmt.step() catch false) {
            if (!first) try w.writeByte(',');
            first = false;
            const var_name = stmt.column_text(0);
            const type_hint = stmt.column_text(1);
            const confidence = stmt.column_int(2);
            const src_line = stmt.column_int(3);
            const source_label: []const u8 = if (confidence >= 90) "rbs" else if (confidence >= 85) "literal_or_guard" else if (confidence >= 75) "method_return" else if (confidence >= 55) "chain_1_level" else if (confidence >= 30) "chain_multi_level" else "inferred";
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, var_name);
            try w.writeAll(",\"type\":");
            try writeJsonStr(w, type_hint);
            try w.print(",\"confidence\":{d},\"source\":", .{confidence});
            try writeJsonStr(w, source_label);
            try w.print(",\"line\":{d}}}", .{src_line});
        }
        if (first) {
            try w.writeAll("],\"note\":\"No type information found at this location. The indexer may not have resolved the type for this assignment.\"}");
        } else {
            try w.writeAll("]}");
        }
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolSuggestTypes(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file = getStrArg(args, "file") orelse return self.buildToolError(id, "missing 'file' argument");
        const limit_raw = getIntArg(args, "limit");
        const limit: i64 = if (limit_raw) |l| (if (l > 0 and l <= 100) l else 20) else 20;
        const resolved = normalizeFileArg(self.alloc, file) orelse return self.buildToolError(id, "cannot resolve file path");
        defer self.alloc.free(resolved);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"suggestions\":[");

        const stmt = self.db.prepare(
            \\SELECT s.name, s.kind, s.line, s.return_type
            \\FROM symbols s JOIN files f ON f.id = s.file_id
            \\WHERE f.path = ? AND s.kind = 'def' AND s.return_type IS NULL
            \\ORDER BY s.line LIMIT ?
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, resolved);
        stmt.bind_int(2, limit);

        var first = true;
        while (stmt.step() catch false) {
            if (!first) try w.writeByte(',');
            first = false;
            const method_name = stmt.column_text(0);
            const method_line = stmt.column_int(2);

            // Try to infer from return statements or callers
            var suggested_buf: ?[]u8 = null;
            defer if (suggested_buf) |b| self.alloc.free(b);
            const ret_stmt = self.db.prepare("SELECT lv.type_hint FROM local_vars lv WHERE lv.name = ? AND lv.type_hint IS NOT NULL ORDER BY lv.confidence DESC LIMIT 1") catch null;
            if (ret_stmt) |rs| {
                defer rs.finalize();
                rs.bind_text(1, method_name);
                if (rs.step() catch false) {
                    suggested_buf = self.alloc.dupe(u8, rs.column_text(0)) catch null;
                }
            }
            const suggested: []const u8 = suggested_buf orelse "untyped";

            try w.writeAll("{\"method\":");
            try writeJsonStr(w, method_name);
            try w.print(",\"line\":{d},\"suggested_return_type\":", .{method_line});
            try writeJsonStr(w, suggested);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolTypeCoverage(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file_filter = if (args) |a| if (a.get("file")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null else null;
        const min_cov: f64 = if (args) |a| if (a.get("min_coverage")) |v| switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 100.0,
        } else 100.0 else 100.0;

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeAll("{\"files\":[");

        const query = if (file_filter != null)
            "SELECT f.path, " ++
                "(SELECT COUNT(*) FROM symbols WHERE file_id=f.id AND kind='def') as total, " ++
                "(SELECT COUNT(*) FROM symbols WHERE file_id=f.id AND kind='def' AND return_type IS NOT NULL) as typed " ++
                "FROM files f WHERE f.is_gem=0 AND f.path=? ORDER BY f.path"
        else
            "SELECT f.path, " ++
                "(SELECT COUNT(*) FROM symbols WHERE file_id=f.id AND kind='def') as total, " ++
                "(SELECT COUNT(*) FROM symbols WHERE file_id=f.id AND kind='def' AND return_type IS NOT NULL) as typed " ++
                "FROM files f WHERE f.is_gem=0 ORDER BY f.path";

        const stmt = self.db.prepare(query) catch return self.buildError(id, -32603, "DB error");
        defer stmt.finalize();
        if (file_filter) |ff| stmt.bind_text(1, ff);

        var first = true;
        var ws_total: u32 = 0;
        var ws_typed: u32 = 0;
        while (stmt.step() catch false) {
            const fpath = stmt.column_text(0);
            const total: u32 = @intCast(stmt.column_int(1));
            const typed: u32 = @intCast(stmt.column_int(2));
            if (total == 0) continue;
            const pct: f64 = @as(f64, @floatFromInt(typed)) / @as(f64, @floatFromInt(total)) * 100.0;
            if (pct > min_cov) continue;
            ws_total += total;
            ws_typed += typed;
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"file\":");
            try writeJsonStr(w, fpath);
            try w.print(",\"total_methods\":{d},\"typed_methods\":{d},\"coverage_pct\":{d:.1}}}", .{ total, typed, pct });
        }
        const ws_pct: f64 = if (ws_total > 0) @as(f64, @floatFromInt(ws_typed)) / @as(f64, @floatFromInt(ws_total)) * 100.0 else 0.0;
        try w.print("],\"workspace_total\":{d},\"workspace_typed\":{d},\"workspace_coverage_pct\":{d:.1}}}", .{ ws_total, ws_typed, ws_pct });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolFindSimilar(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const method_name = if (args) |a| if (a.get("method_name")) |v| switch (v) {
            .string => |s| s,
            else => return self.buildError(id, -32602, "method_name required"),
        } else return self.buildError(id, -32602, "method_name required") else return self.buildError(id, -32602, "method_name required");

        const max_dist: u32 = if (args) |a| if (a.get("max_distance")) |v| switch (v) {
            .integer => |i| if (i > 0 and i <= 10) @intCast(i) else 3,
            else => 3,
        } else 3 else 3;

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeAll("{\"query\":");
        try writeJsonStr(w, method_name);
        try w.writeAll(",\"similar\":[");

        // Use LIKE for prefix filtering, then edit distance for ranking
        const stmt = self.db.prepare("SELECT DISTINCT name, parent_name, kind FROM symbols WHERE kind='def' AND name != ? AND file_id IN (SELECT id FROM files WHERE is_gem=0) LIMIT 5000") catch return self.buildError(id, -32603, "DB error");
        defer stmt.finalize();
        stmt.bind_text(1, method_name);

        var first = true;
        var count: u32 = 0;
        while (stmt.step() catch false) {
            if (count >= 50) break;
            const cand = stmt.column_text(0);
            if (cand.len == 0) continue;
            const dist = editDistance(method_name, cand);
            const is_substring = method_name.len >= 3 and cand.len >= 3 and
                (std.mem.indexOf(u8, cand, method_name) != null or
                    std.mem.indexOf(u8, method_name, cand) != null);
            if (dist <= max_dist or is_substring) {
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll("{\"name\":");
                try writeJsonStr(w, cand);
                const parent = stmt.column_text(1);
                if (parent.len > 0) {
                    try w.writeAll(",\"class\":");
                    try writeJsonStr(w, parent);
                }
                const match_kind: []const u8 = if (dist <= max_dist) "edit_distance" else "substring";
                try w.print(",\"distance\":{d},\"match\":", .{dist});
                try writeJsonStr(w, match_kind);
                try w.writeByte('}');
                count += 1;
            }
        }
        try w.writeAll("]}");
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolCoverageGapAnalyzer(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file_filter = getStrArg(args, "file");
        const threshold = getIntArg(args, "threshold") orelse 1;

        const stmt = self.db.prepare(
            \\SELECT s.name, s.parent_name, f.path, s.line, COUNT(r.name) as ref_count
            \\FROM symbols s
            \\JOIN files f ON f.id = s.file_id
            \\LEFT JOIN refs r ON r.name = s.name AND EXISTS (
            \\  SELECT 1 FROM files rf WHERE rf.id = r.file_id AND (rf.path LIKE '%_test.rb' OR rf.path LIKE '%_spec.rb')
            \\)
            \\WHERE s.kind = 'def' AND f.is_gem = 0
            \\  AND (? IS NULL OR f.path = ?)
            \\GROUP BY s.id
            \\HAVING ref_count < ?
            \\ORDER BY f.path, s.line LIMIT 100
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        if (file_filter) |ff| {
            stmt.bind_text(1, ff);
            stmt.bind_text(2, ff);
        } else {
            stmt.bind_null(1);
            stmt.bind_null(2);
        }
        stmt.bind_int(3, threshold);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"gaps\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const name = stmt.column_text(0);
            const parent_name = stmt.column_text(1);
            const file_path = stmt.column_text(2);
            const line = stmt.column_int(3);
            const ref_count = stmt.column_int(4);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, name);
            try w.writeAll(",\"parent_name\":");
            if (parent_name.len > 0) try writeJsonStr(w, parent_name) else try w.writeAll("null");
            try w.writeAll(",\"file\":");
            try writeJsonStr(w, file_path);
            try w.print(",\"line\":{d},\"test_ref_count\":{d}", .{ line, ref_count });
            try w.writeByte('}');
        }
        try w.print("],\"threshold\":{d},\"note\":\"finds defs with <threshold test refs\"}}", .{threshold});
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolSecurityAuditSummary(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const file_filter = getStrArg(args, "file");

        const stmt = self.db.prepare(
            \\SELECT f.path, b.code, b.severity, b.message, 'brakeman' as tool_type
            \\FROM brakeman_findings b
            \\JOIN files f ON f.id = b.file_id
            \\WHERE (? IS NULL OR f.path = ?)
            \\UNION ALL
            \\SELECT f.path, s.rule_id, s.severity, s.message, 'semgrep' as tool_type
            \\FROM semgrep_findings s
            \\JOIN files f ON f.id = s.file_id
            \\WHERE (? IS NULL OR f.path = ?)
            \\ORDER BY f.path
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        if (file_filter) |ff| {
            stmt.bind_text(1, ff);
            stmt.bind_text(2, ff);
            stmt.bind_text(3, ff);
            stmt.bind_text(4, ff);
        } else {
            stmt.bind_null(1);
            stmt.bind_null(2);
            stmt.bind_null(3);
            stmt.bind_null(4);
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"findings\":[");

        var row_count: usize = 0;
        var total_risk: i32 = 0;
        var high_count: i32 = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= 100) break;
            const file_path = stmt.column_text(0);
            const code = stmt.column_text(1);
            const severity = stmt.column_int(2);
            const message = stmt.column_text(3);
            const tool_type = stmt.column_text(4);

            const cvss_score: i32 = switch (severity) {
                10 => 10,
                9 => 9,
                8 => 8,
                7 => 7,
                6 => 6,
                5 => 5,
                4 => 4,
                3 => 3,
                2 => 2,
                else => 1,
            };
            total_risk += cvss_score;
            if (cvss_score >= 7) high_count += 1;

            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            try w.writeAll("{\"file\":");
            try writeJsonStr(w, file_path);
            try w.writeAll(",\"code\":");
            try writeJsonStr(w, code);
            try w.print(",\"severity\":{d},\"cvss_score\":{d},\"message\":", .{ severity, cvss_score });
            try writeJsonStr(w, message);
            try w.writeAll(",\"tool\":");
            try writeJsonStr(w, tool_type);
            try w.writeByte('}');
        }
        try w.print("],\"summary\":{{\"total_risk\":{d},\"high_count\":{d},\"note\":\"top 100 findings\"}}}}", .{ total_risk, high_count });
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolMigrationChainAnalyzer(self: *Server, id: ?std.json.Value, _: ?std.json.ObjectMap) !?[]u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;

        // Per-migration-file hazards: scan refs for hazard call names inside
        // db/migrate/*.rb. Detects change_column / remove_column / execute as
        // potentially non-reversible operations.
        const stmt = self.db.prepare(
            \\SELECT f.path,
            \\       MAX(CASE WHEN r.name = 'change_column' THEN 1 ELSE 0 END) AS h_change,
            \\       MAX(CASE WHEN r.name = 'remove_column' THEN 1 ELSE 0 END) AS h_remove,
            \\       MAX(CASE WHEN r.name = 'execute'       THEN 1 ELSE 0 END) AS h_execute,
            \\       (SELECT s.name FROM symbols s WHERE s.file_id = f.id AND s.kind = 'classdef' LIMIT 1) AS class_name
            \\FROM files f
            \\LEFT JOIN refs r ON r.file_id = f.id
            \\WHERE f.path LIKE '%db/migrate/%.rb'
            \\GROUP BY f.id
            \\ORDER BY f.path
            \\LIMIT 500
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();

        try w.writeAll("{\"migrations\":[");
        var row_count: usize = 0;
        var hazard_count: usize = 0;

        while (stmt.step() catch |e| stepLog(e)) {
            const file_path = stmt.column_text(0);
            const h_change = stmt.column_int(1) != 0;
            const h_remove = stmt.column_int(2) != 0;
            const h_execute = stmt.column_int(3) != 0;
            const class_name = stmt.column_text(4);

            if (row_count > 0) try w.writeByte(',');
            row_count += 1;

            try w.writeAll("{\"file\":");
            try writeJsonStr(w, file_path);
            try w.writeAll(",\"class_name\":");
            if (class_name.len > 0) try writeJsonStr(w, class_name) else try w.writeAll("null");

            if (h_change) hazard_count += 1;
            if (h_remove) hazard_count += 1;
            if (h_execute) hazard_count += 1;

            try w.print(",\"hazard_change_column\":{s},\"hazard_remove_column\":{s},\"hazard_execute\":{s}}}", .{
                if (h_change) "true" else "false",
                if (h_remove) "true" else "false",
                if (h_execute) "true" else "false",
            });
        }

        try w.print("],\"rollback_hazards\":{d},\"note\":\"flags change_column / remove_column / execute calls per migration\"}}", .{hazard_count});
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolDependencyTreeResolver(self: *Server, id: ?std.json.Value, _: ?std.json.ObjectMap) !?[]u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;

        var gem_count: usize = 0;
        var transitive_count: usize = 0;

        const cwd = std.Io.Dir.cwd();
        const gemfile_content = cwd.readFileAlloc(std.Options.debug_io, "Gemfile.lock", self.alloc, std.Io.Limit.limited(1_000_000)) catch {
            try w.writeAll("{\"dependencies\":[],\"transitive_count\":0,\"note\":\"Gemfile.lock not found\"}");
            const text = try aw.toOwnedSlice();
            defer self.alloc.free(text);
            return self.buildToolResult(id, text);
        };
        defer self.alloc.free(gemfile_content);

        try w.writeAll("{\"dependencies\":[");

        var lines = std.mem.splitSequence(u8, gemfile_content, "\n");
        var in_gem_section = false;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, trimmed, "GEM")) {
                in_gem_section = true;
                continue;
            }
            if (in_gem_section and trimmed.len == 0) break;
            if (!in_gem_section) continue;

            if (std.mem.startsWith(u8, trimmed, "remote:") or std.mem.startsWith(u8, trimmed, "specs:")) continue;

            if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, " ")) {
                const paren_pos = std.mem.indexOf(u8, trimmed, "(");
                if (paren_pos) |pp| {
                    const name = std.mem.trim(u8, trimmed[0..pp], " ");
                    const version_end = std.mem.lastIndexOf(u8, trimmed, ")") orelse trimmed.len;
                    const version = std.mem.trim(u8, trimmed[pp + 1 .. version_end], " ()");

                    if (gem_count > 0) try w.writeByte(',');
                    gem_count += 1;
                    if (gem_count > 100) break;

                    try w.writeAll("{\"name\":");
                    try writeJsonStr(w, name);
                    try w.writeAll(",\"version\":");
                    try writeJsonStr(w, version);
                    try w.writeByte('}');
                }
            } else if (std.mem.startsWith(u8, trimmed, "dependencies:")) {
                transitive_count += 1;
            }
        }

        try w.print("],\"transitive_count\":{d},\"note\":\"top 100 gems from Gemfile.lock\"}}", .{transitive_count});
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }

    fn toolUnusedAssociationChain(self: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
        const class_name = getStrArg(args, "class_name");

        const stmt = self.db.prepare(
            \\SELECT s.name, s.line, f.path, COUNT(r.name) as ref_count
            \\FROM symbols s
            \\JOIN files f ON f.id = s.file_id
            \\LEFT JOIN refs r ON r.name = s.name
            \\WHERE s.kind IN ('association', 'has_many', 'belongs_to', 'has_one', 'has_and_belongs_to_many')
            \\  AND f.is_gem = 0
            \\  AND (? IS NULL OR s.parent_name = ?)
            \\GROUP BY s.id
            \\HAVING ref_count = 0
            \\ORDER BY f.path, s.line
            \\LIMIT 100
        ) catch return self.buildToolError(id, "database error");
        defer stmt.finalize();
        if (class_name) |cn| {
            stmt.bind_text(1, cn);
            stmt.bind_text(2, cn);
        } else {
            stmt.bind_null(1);
            stmt.bind_null(2);
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"unused_associations\":[");

        var row_count: usize = 0;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count > 0) try w.writeByte(',');
            row_count += 1;
            const name = stmt.column_text(0);
            const line = stmt.column_int(1);
            const file_path = stmt.column_text(2);
            const ref_count = stmt.column_int(3);
            try w.writeAll("{\"name\":");
            try writeJsonStr(w, name);
            try w.print(",\"line\":{d},\"file\":", .{line});
            try writeJsonStr(w, file_path);
            try w.print(",\"ref_count\":{d}}}", .{ref_count});
        }
        try w.print("],\"note\":\"associations with 0 references in workspace\"}}", .{});
        const text = try aw.toOwnedSlice();
        defer self.alloc.free(text);
        return self.buildToolResult(id, text);
    }
};

fn editDistance(a: []const u8, b: []const u8) u32 {
    if (a.len > 64 or b.len > 64) return 99;
    if (a.len == 0) return @intCast(b.len);
    if (b.len == 0) return @intCast(a.len);
    var prev: [65]u32 = undefined;
    var curr: [65]u32 = undefined;
    for (0..b.len + 1) |j| prev[j] = @intCast(j);
    for (a, 0..) |ca, i| {
        curr[0] = @intCast(i + 1);
        for (b, 0..) |cb, j| {
            const cost: u32 = if (ca == cb) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

fn countLines(source: []const u8) u32 {
    var count: u32 = 1;
    for (source) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn writeJsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try writeJsonEscaped(w, s);
    try w.writeByte('"');
}

fn writeJsonStrCapped(w: *std.Io.Writer, s: []const u8, max_bytes: usize) !void {
    try w.writeByte('"');
    if (s.len <= max_bytes) {
        try writeJsonEscaped(w, s);
    } else {
        try writeJsonEscaped(w, s[0..max_bytes]);
        try w.writeAll("\\u2026");
    }
    try w.writeByte('"');
}

fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try w.print("\\u{x:0>4}", .{ch}),
            else => try w.writeByte(ch),
        }
    }
}

fn writeJsonValue(w: *std.Io.Writer, val: std.json.Value) !void {
    switch (val) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeJsonStr(w, s),
        else => try w.writeAll("null"),
    }
}

fn getStrArg(args: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const map = args orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

const QualifiedSymbol = struct { class_name: []const u8, method_name: []const u8 };

fn splitQualified(s: []const u8) ?QualifiedSymbol {
    const i = std.mem.lastIndexOfScalar(u8, s, '#') orelse return null;
    if (i == 0 or i + 1 >= s.len) return null;
    return .{ .class_name = s[0..i], .method_name = s[i + 1 ..] };
}

/// Wrap a user query as an FTS5 double-quoted string literal so the trigram
/// tokenizer matches it as a literal substring (any embedded special chars,
/// including `"`, are neutralized). Caller frees.
fn ftsQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '"');
    for (s) |c| {
        if (c == '"') try buf.append(alloc, '"');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '"');
    return buf.toOwnedSlice(alloc);
}

fn normalizeFileArg(alloc: std.mem.Allocator, file: []const u8) ?[:0]u8 {
    if (file.len == 0) return null;
    // Reject parent-dir traversal segments outright. Even though SQL bindings
    // and file reads are downstream-scoped to the indexed workspace, refusing
    // "../" up front gives a uniform answer regardless of where the value
    // flows.
    if (containsTraversalSegment(file)) return null;
    // Absolute paths: trust as-is (indexer records absolute paths and we
    // look them up parametrized). Relative paths: resolve against cwd.
    if (file[0] == '/') return alloc.dupeZ(u8, file) catch null;
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, file, alloc) catch null;
}

fn containsTraversalSegment(file: []const u8) bool {
    var i: usize = 0;
    while (i < file.len) {
        const start = i;
        while (i < file.len and file[i] != '/') i += 1;
        const seg = file[start..i];
        if (std.mem.eql(u8, seg, "..")) return true;
        if (i < file.len) i += 1;
    }
    return false;
}

fn getIntArg(args: ?std.json.ObjectMap, key: []const u8) ?i64 {
    const map = args orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| blk: {
            if (@abs(f) > 1_000_000_000_000.0) return null;
            break :blk @as(i64, @intFromFloat(f));
        },
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn stepLog(err: anyerror) bool {
    std.debug.print("{s}", .{"refract: mcp sql step: "});
    std.debug.print("{s}", .{@errorName(err)});
    std.debug.print("{s}", .{"\n"});
    return false;
}

fn regexCharMatch(ch: u8, pat: u8) bool {
    return pat == '.' or ch == pat;
}

fn regexAt(line: []const u8, li: usize, pat: []const u8, pi: usize) bool {
    if (pi >= pat.len) return true;
    if (pat[pi] == '$') return li == line.len;

    const has_quant = pi + 1 < pat.len and (pat[pi + 1] == '*' or pat[pi + 1] == '+');
    if (has_quant) {
        const is_plus = pat[pi + 1] == '+';
        var count: usize = 0;
        while (li + count < line.len and regexCharMatch(line[li + count], pat[pi])) {
            count += 1;
        }
        const min_c: usize = if (is_plus) 1 else 0;
        if (count < min_c) return false;
        var k: usize = count;
        while (true) {
            if (regexAt(line, li + k, pat, pi + 2)) return true;
            if (k == 0) break;
            k -= 1;
        }
        return false;
    }

    if (li >= line.len) return false;
    if (!regexCharMatch(line[li], pat[pi])) return false;
    return regexAt(line, li + 1, pat, pi + 1);
}

fn regexMatchLine(line: []const u8, pattern: []const u8) bool {
    if (pattern.len > 0 and pattern[0] == '^') {
        return regexAt(line, 0, pattern[1..], 0);
    }
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        if (regexAt(line, i, pattern, 0)) return true;
    }
    return false;
}

fn validateGlobPattern(pattern: []const u8) ?[]const u8 {
    for (pattern) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '/', '.', '*', '?', '[', ']', '!' => {},
            else => {
                return "contains invalid character";
            },
        }
    }
    return null;
}

fn logAuditDbError(self: *Server) void {
    // Log once per process (stderr; stdout carries the JSON-RPC stream).
    if (self.audit_lock_err_logged.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
        std.debug.print("refract: audit_log database write failed (locked or unavailable)\n", .{});
    }
}

test "validateGlobPattern" {
    try std.testing.expect(validateGlobPattern("*.rb") == null);
    try std.testing.expect(validateGlobPattern("models/*.rb") == null);
    try std.testing.expect(validateGlobPattern("app/[mc]*/**.rb") == null);
    try std.testing.expect(validateGlobPattern("test-*.rb") == null);
    try std.testing.expect(validateGlobPattern("lib_name.rb") == null);
    try std.testing.expect(validateGlobPattern("path/!-name") == null);

    try std.testing.expect(validateGlobPattern("*.rb;malware") != null);
    try std.testing.expect(validateGlobPattern("$(touch file)") != null);
    try std.testing.expect(validateGlobPattern("path&other") != null);
    try std.testing.expect(validateGlobPattern("cmd|pipe") != null);
    try std.testing.expect(validateGlobPattern("`backtick`") != null);
}
