const std = @import("std");
const db_mod = @import("../db.zig");
const refactor_mod = @import("../lsp/refactor.zig");
const overlay = @import("../lsp/overlay.zig");
const git_branch = @import("../lsp/git_branch.zig");
const indexer = @import("../indexer/index.zig");
const build_meta = @import("build_meta");
const tools_resolution = @import("tools_resolution.zig");
const tools_search = @import("tools_search.zig");
const tools_graph = @import("tools_graph.zig");
const tools_rails = @import("tools_rails.zig");
const tools_diagnostics = @import("tools_diagnostics.zig");
const tools_overlay = @import("tools_overlay.zig");

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
const schema_explain_type_chain =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"line":{"type":"integer","description":"1-based line number"},"col":{"type":"integer","description":"0-based column offset"}},"required":["file","line"]}
;
const schema_resolve_constant =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Constant reference as written: bare ('CONST'), qualified ('Foo::Bar'), or absolute ('::Foo::Bar')"},"nesting":{"type":"array","items":{"type":"string"},"description":"Lexical nesting at the reference site, outermost-first (e.g. ['Foo','Foo::Bar']); omit for top-level"}},"required":["name"]}
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
    .{ .name = "find_implementations", .description = "Find all classes that define a given method name", .schema = schema_find_implementations },
    .{ .name = "workspace_symbols", .description = "Search symbols across the entire workspace by name", .schema = schema_workspace_symbols },
    .{ .name = "type_hierarchy", .description = "Get ancestor chain and known descendants of a class", .schema = schema_type_hierarchy },
    .{ .name = "association_graph", .description = "Get ActiveRecord associations (has_many, belongs_to, etc) for a class", .schema = schema_association_graph },
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
    .{ .name = "workspace_health", .description = "Get workspace quality metrics: file counts, type coverage, diagnostic summary, schema version", .schema = schema_workspace_health },
    .{ .name = "test_summary", .description = "List discovered tests in a file with their kind (rspec/minitest) and line numbers", .schema = schema_test_summary },
    .{ .name = "list_routes", .description = "List all Rails route helpers with controller and action details", .schema = schema_list_routes },
    .{ .name = "refactor", .description = "Apply refactoring operations (extract_method, extract_variable) to source code", .schema = schema_refactor },
    .{ .name = "available_code_actions", .description = "Get list of available code actions at a specific location", .schema = schema_available_code_actions },
    .{ .name = "explain_type_chain", .description = "Explain how a local variable's type was inferred — shows chain from source (RBS, YARD, literal, chain)", .schema = schema_explain_type_chain },
    .{ .name = "resolve_constant", .description = "Resolve a constant reference to its declaration using Ruby's lexical+ancestor lookup (nesting-aware) — disambiguates same-named constants across namespaces", .schema = schema_resolve_constant },
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
    pub fn pathInWorkspace(self: *Server, fpath: []const u8) bool {
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

        if (std.mem.eql(u8, name, "resolve_type")) return tools_resolution.resolveType(self, id, args);
        if (std.mem.eql(u8, name, "class_summary")) return tools_resolution.classSummary(self, id, args);
        if (std.mem.eql(u8, name, "method_signature")) return tools_resolution.methodSignature(self, id, args);
        if (std.mem.eql(u8, name, "find_implementations")) return tools_graph.findImplementations(self, id, args);
        if (std.mem.eql(u8, name, "workspace_symbols")) return tools_search.workspaceSymbols(self, id, args);
        if (std.mem.eql(u8, name, "type_hierarchy")) return tools_graph.typeHierarchy(self, id, args);
        if (std.mem.eql(u8, name, "association_graph")) return tools_graph.associationGraph(self, id, args);
        if (std.mem.eql(u8, name, "diagnostics")) return tools_diagnostics.diagnostics(self, id, args);
        if (std.mem.eql(u8, name, "get_symbol_source")) return tools_search.getSymbolSource(self, id, args);
        if (std.mem.eql(u8, name, "grep_source")) return tools_search.grepSource(self, id, args);
        if (std.mem.eql(u8, name, "i18n_lookup")) return tools_search.i18nLookup(self, id, args);
        if (std.mem.eql(u8, name, "list_by_kind")) return tools_search.listByKind(self, id, args);
        if (std.mem.eql(u8, name, "find_unused")) return tools_graph.findUnused(self, id, args);
        if (std.mem.eql(u8, name, "get_file_overview")) return tools_search.getFileOverview(self, id, args);
        if (std.mem.eql(u8, name, "list_validations")) return tools_rails.listValidations(self, id, args);
        if (std.mem.eql(u8, name, "list_callbacks")) return tools_rails.listCallbacks(self, id, args);
        if (std.mem.eql(u8, name, "concern_usage")) return tools_graph.concernUsage(self, id, args);
        if (std.mem.eql(u8, name, "find_references")) return tools_graph.findReferences(self, id, args);
        if (std.mem.eql(u8, name, "explain_symbol")) return tools_resolution.explainSymbol(self, id, args);
        if (std.mem.eql(u8, name, "workspace_health")) return tools_diagnostics.workspaceHealth(self, id);
        if (std.mem.eql(u8, name, "test_summary")) return tools_diagnostics.testSummary(self, id, args);
        if (std.mem.eql(u8, name, "list_routes")) return tools_rails.listRoutes(self, id, args);
        if (std.mem.eql(u8, name, "refactor")) return tools_diagnostics.refactor(self, id, args);
        if (std.mem.eql(u8, name, "available_code_actions")) return tools_diagnostics.availableCodeActions(self, id, args);
        if (std.mem.eql(u8, name, "explain_type_chain")) return tools_resolution.explainTypeChain(self, id, args);
        if (std.mem.eql(u8, name, "resolve_constant")) return tools_graph.resolveConstant(self, id, args);

        if (std.mem.eql(u8, name, "overlay_annotate")) return tools_overlay.overlayAnnotate(self, id, args);
        if (std.mem.eql(u8, name, "overlay_list")) return tools_overlay.overlayList(self, id, args);
        if (std.mem.eql(u8, name, "overlay_revert")) return tools_overlay.overlayRevert(self, id, args);
        if (std.mem.eql(u8, name, "overlay_promote")) return tools_overlay.overlayPromote(self, id, args);

        return self.buildError(id, -32601, "Unknown tool");
    }

    // ---- overlay (agent/user-writable graph layer) ----

    const OverlayCtx = struct {
        pid: []u8,
        branch: ?[]u8,
        alloc: std.mem.Allocator,
        pub fn deinit(self: OverlayCtx) void {
            self.alloc.free(self.pid);
            if (self.branch) |b| self.alloc.free(b);
        }
    };

    /// Resolve project identity + current git branch for the workspace.
    pub fn overlayCtx(self: *Server) ?OverlayCtx {
        const root = self.workspace_root orelse return null;
        const pid = git_branch.projectId(self.alloc, root);
        var branch: ?[]u8 = null;
        if (git_branch.readHead(self.alloc, root)) |h| {
            if (h.branch) |b| branch = self.alloc.dupe(u8, b) catch null;
            h.deinit();
        }
        return .{ .pid = pid, .branch = branch, .alloc = self.alloc };
    }

    pub fn overlayTable(kind: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, kind, "node")) return "overlay_nodes";
        if (std.mem.eql(u8, kind, "edge")) return "overlay_edges";
        if (std.mem.eql(u8, kind, "type")) return "overlay_types";
        if (std.mem.eql(u8, kind, "suppress")) return "overlay_suppress";
        return null;
    }

    pub fn gateMsg(e: overlay.GateError) []const u8 {
        return switch (e) {
            overlay.GateError.ReasonRequired => "reason is required",
            overlay.GateError.ReasonTooLong => "reason exceeds size cap",
            overlay.GateError.PayloadTooLong => "payload exceeds size cap",
            overlay.GateError.BadOp => "unknown op",
            overlay.GateError.MissingTarget => "missing required target field",
        };
    }

    pub fn nowUs() i64 {
        return @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_us));
    }

    pub fn nowS() i64 {
        return @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_s));
    }

    pub fn auditOverlay(self: *Server, tool: []const u8, fqn: ?[]const u8, result_kind: []const u8) void {
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

    pub fn overlayOk(self: *Server, id: ?std.json.Value, new_id: i64, eff_branch: ?[]const u8, is_user: bool) !?[]u8 {
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

    const ResolvedMethod = struct { sym_id: i64, owner: ?[]u8 };

    /// Look up a method (`def`/`classdef`) directly owned by `class_name`.
    pub fn lookupMethodIn(self: *Server, class_name: []const u8, method_name: []const u8) ?i64 {
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
    pub fn resolveMethodSym(self: *Server, class_name: []const u8, method_name: []const u8) ?ResolvedMethod {
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

    pub fn enqueueAncestor(self: *Server, queue: *std.ArrayList([]u8), name: []const u8) void {
        if (name.len == 0) return;
        const dup = self.alloc.dupe(u8, name) catch return;
        queue.append(self.alloc, dup) catch self.alloc.free(dup);
    }

    /// Emit the comma-separated params array body for a method symbol_id into `w`.
    /// Shared by method_signature and explain_symbol (single source of truth for
    /// the param shape; querying by symbol_id, never the missing `default_val`).
    pub fn writeMethodParams(self: *Server, w: *std.Io.Writer, sym_id: i64) !void {
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

    pub fn readFileLine(self: *Server, path: []const u8, line_1based: i64) ?[]u8 {
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

    pub fn readFileLineFromCache(
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

    pub fn fileIdFor(self: *Server, path: []const u8) i64 {
        if (self.db.prepare("SELECT id FROM files WHERE path = ?")) |q| {
            defer q.finalize();
            q.bind_text(1, path);
            if (q.step() catch false) return q.column_int(0);
        } else |_| return 0;
        const rp = std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, path, self.alloc) catch return 0;
        defer self.alloc.free(rp);
        if (std.mem.eql(u8, rp, path)) return 0;
        if (self.db.prepare("SELECT id FROM files WHERE path = ?")) |q2| {
            defer q2.finalize();
            q2.bind_text(1, rp);
            if (q2.step() catch false) return q2.column_int(0);
        } else |_| return 0;
        return 0;
    }

    pub fn fileDiags(self: *Server, path: []const u8) std.ArrayList(indexer.DiagEntry) {
        var out: std.ArrayList(indexer.DiagEntry) = .empty;
        const parse = indexer.getDiags(path, self.alloc) catch &.{};
        defer self.alloc.free(parse); // entries' `.message` ownership moves into `out`
        for (parse) |d| out.append(self.alloc, d) catch self.alloc.free(d.message);
        const fid = self.fileIdFor(path);
        if (fid == 0) return out; // not indexed → parse diags only
        var sem = indexer.runSemanticChecks(self.db, fid, self.alloc) catch return out;
        defer sem.deinit(self.alloc);
        for (sem.items) |d| out.append(self.alloc, d) catch self.alloc.free(d.message);
        return out;
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

    pub fn buildPromptContext(self: *Server, name: []const u8, arguments: ?std.json.ObjectMap, w: *std.Io.Writer) !void {
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

            var fb_diags = self.fileDiags(file);
            defer {
                for (fb_diags.items) |d| self.alloc.free(d.message);
                fb_diags.deinit(self.alloc);
            }
            var diag_count: usize = 0;
            for (fb_diags.items) |d| {
                if (diag_count == 0) try w.writeAll("Diagnostics:\n");
                diag_count += 1;
                try w.print("  line {d}: {s}\n", .{ d.line, d.message });
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

    pub fn readWorkspaceSummary(self: *Server, id: ?std.json.Value) !?[]u8 {
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

    pub fn readClassDoc(self: *Server, id: ?std.json.Value, class_name: []const u8) !?[]u8 {
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

    pub fn buildResult(self: *Server, id: ?std.json.Value, result_json: []const u8) !?[]u8 {
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

    pub fn buildError(self: *Server, id: ?std.json.Value, code: i32, message: []const u8) !?[]u8 {
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

    pub fn buildToolResult(self: *Server, id: ?std.json.Value, text: []const u8) !?[]u8 {
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

    pub fn buildToolError(self: *Server, id: ?std.json.Value, text: []const u8) !?[]u8 {
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
};

const mcp_utils = @import("mcp_utils.zig");
pub const countLines = mcp_utils.countLines;
pub const writeJsonStr = mcp_utils.writeJsonStr;
pub const writeJsonStrCapped = mcp_utils.writeJsonStrCapped;
pub const writeJsonValue = mcp_utils.writeJsonValue;
pub const getStrArg = mcp_utils.getStrArg;
pub const QualifiedSymbol = mcp_utils.QualifiedSymbol;
pub const splitQualified = mcp_utils.splitQualified;
pub const ftsQuote = mcp_utils.ftsQuote;
pub const normalizeFileArg = mcp_utils.normalizeFileArg;
pub const getIntArg = mcp_utils.getIntArg;
pub const stepLog = mcp_utils.stepLog;
pub const regexMatchLine = mcp_utils.regexMatchLine;
pub const validateGlobPattern = mcp_utils.validateGlobPattern;

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
