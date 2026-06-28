// MCP tool input JSON Schemas. Extracted from server.zig to keep the tool
// registry/dispatch file focused; referenced as schemas.schema_X in the TOOLS table.

pub const schema_resolve_type =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"line":{"type":"integer","description":"1-based line number"},"col":{"type":"integer","description":"0-based column offset (optional)"}},"required":["file","line"]}
;

pub const schema_class_summary =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Fully qualified class or module name"}},"required":["class_name"]}
;

pub const schema_method_signature =
    \\{"type":"object","properties":{"symbol":{"type":"string","description":"Qualified form 'Class#method' (preferred)"},"class_name":{"type":"string","description":"Class or module name (legacy, use 'symbol' instead)"},"method_name":{"type":"string","description":"Method name (legacy, use 'symbol' instead)"}},"required":[]}
;

pub const schema_find_implementations =
    \\{"type":"object","properties":{"method_name":{"type":"string","description":"Method name to find implementations of"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["method_name"]}
;

pub const schema_workspace_symbols =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Name prefix or substring to search for"},"kind":{"type":"string","description":"Optional kind filter: class, def, module, constant"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["query"]}
;

pub const schema_type_hierarchy =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Class or module name"},"ancestors_offset":{"type":"integer","description":"Pagination offset for ancestors list, default 0"},"descendants_offset":{"type":"integer","description":"Pagination offset for descendants list, default 0"}},"required":["class_name"]}
;

pub const schema_association_graph =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"ActiveRecord class name"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["class_name"]}
;

pub const schema_diagnostics =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the file (omit for all files)"},"offset":{"type":"integer","description":"Pagination offset for workspace mode, default 0"}},"required":[]}
;

pub const schema_get_symbol_source =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Fully qualified class or module name"},"method_name":{"type":"string","description":"Method name"}},"required":["class_name","method_name"]}
;

pub const schema_grep_source =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Text to search for (literal or regex)"},"file_pattern":{"type":"string","description":"Optional glob-style path filter, e.g. 'models/*.rb'"},"context_lines":{"type":"integer","description":"Lines of context around each match (default 1, max 5)"},"use_regex":{"type":"boolean","description":"If true, treat query as regex supporting ^ $ . * +"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["query"]}
;

pub const schema_i18n_lookup =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Key prefix or substring (case-insensitive), e.g. 'models.user'"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["query"]}
;

pub const schema_list_by_kind =
    \\{"type":"object","properties":{"kind":{"type":"string","enum":["class","module","def","constant","association","route_helper"],"description":"Symbol kind to list"},"name_filter":{"type":"string","description":"Optional name prefix"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["kind"]}
;

pub const schema_find_unused =
    \\{"type":"object","properties":{"kind":{"type":"string","description":"Symbol kind to check, default 'def'"},"parent_name":{"type":"string","description":"Optional class filter"}},"required":[]}
;

pub const schema_get_file_overview =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Path to the source file (absolute or relative to workspace root)"}},"required":["file"]}
;

pub const schema_list_validations =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Class or module name to list validations for"}},"required":["class_name"]}
;

pub const schema_list_callbacks =
    \\{"type":"object","properties":{"class_name":{"type":"string","description":"Class or module name"},"callback_type":{"type":"string","description":"Optional callback name filter, e.g. 'before_save'"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["class_name"]}
;

pub const schema_concern_usage =
    \\{"type":"object","properties":{"module_name":{"type":"string","description":"Module or concern name to find usages of"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["module_name"]}
;

pub const schema_find_references =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Method or symbol name to find references to"},"ref_kind":{"type":"string","description":"Optional kind filter: call, assign, decl, super, yield, alias"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":["name"]}
;

pub const schema_explain_symbol =
    \\{"type":"object","properties":{"symbol":{"type":"string","description":"Qualified form 'Class#method' (preferred)"},"class_name":{"type":"string","description":"Fully qualified class or module name (legacy, use 'symbol' instead)"},"method_name":{"type":"string","description":"Method name (legacy, use 'symbol' instead)"}},"required":[]}
;

pub const schema_workspace_health =
    \\{"type":"object","properties":{},"required":[]}
;

pub const schema_test_summary =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the test file"}},"required":["file"]}
;

pub const schema_list_routes =
    \\{"type":"object","properties":{"prefix":{"type":"string","description":"Optional helper name prefix filter"},"offset":{"type":"integer","description":"Pagination offset, default 0"}},"required":[]}
;

pub const schema_refactor =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"start_line":{"type":"integer","description":"0-based start line"},"end_line":{"type":"integer","description":"0-based end line"},"kind":{"type":"string","enum":["extract_method","extract_variable"],"description":"Type of refactoring to perform"}},"required":["file","start_line","end_line","kind"]}
;

pub const schema_available_code_actions =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"line":{"type":"integer","description":"0-based line number"},"character":{"type":"integer","description":"0-based column (default 0)"}},"required":["file","line"]}
;

pub const schema_explain_type_chain =
    \\{"type":"object","properties":{"file":{"type":"string","description":"Absolute path to the source file"},"line":{"type":"integer","description":"1-based line number"},"col":{"type":"integer","description":"0-based column offset"}},"required":["file","line"]}
;

pub const schema_resolve_constant =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Constant reference as written: bare ('CONST'), qualified ('Foo::Bar'), or absolute ('::Foo::Bar')"},"nesting":{"type":"array","items":{"type":"string"},"description":"Lexical nesting at the reference site, outermost-first (e.g. ['Foo','Foo::Bar']); omit for top-level"}},"required":["name"]}
;

pub const schema_overlay_annotate =
    \\{"type":"object","properties":{"op":{"type":"string","enum":["note","tag","concept","edge","override","suppress"],"description":"Overlay write kind"},"reason":{"type":"string","description":"Required justification (audited)"},"fqn":{"type":"string","description":"Target symbol 'Class#method' or 'Class' (note/tag/concept/override; or suppress target)"},"from":{"type":"string","description":"edge: source fqn"},"to":{"type":"string","description":"edge: target fqn"},"edge_kind":{"type":"string","description":"edge relation: depends_on|related_to|alias|overrides|custom (default related_to)"},"label":{"type":"string","description":"short label (concept/edge/tag)"},"content":{"type":"string","description":"note/comment body"},"method":{"type":"string","description":"override: method name (omit for class-level)"},"param_pos":{"type":"integer","description":"override: -1 return type, >=0 param index (default -1)"},"type":{"type":"string","description":"override: asserted type string"},"diag_code":{"type":"string","description":"suppress: diagnostic code"},"file":{"type":"string","description":"suppress: file path (alternative to fqn)"},"line":{"type":"integer","description":"suppress: optional line"},"source":{"type":"string","enum":["agent","user"],"description":"default agent (lower trust)"},"scope":{"type":"string","enum":["branch","global"],"description":"default branch (current git branch); global = all branches"},"branch":{"type":"string","description":"explicit branch to scope this tweak to (overrides scope/current branch)"}},"required":["op","reason"]}
;

pub const schema_overlay_list =
    \\{"type":"object","properties":{"kind":{"type":"string","enum":["node","edge","type","suppress"],"description":"Overlay table to list"},"all_branches":{"type":"boolean","description":"include every branch (default false = current branch + global)"}},"required":["kind"]}
;

pub const schema_overlay_revert =
    \\{"type":"object","properties":{"kind":{"type":"string","enum":["node","edge","type","suppress"],"description":"Overlay table"},"id":{"type":"integer","description":"overlay row id from overlay_list"},"reason":{"type":"string","description":"Required justification (audited)"}},"required":["kind","id","reason"]}
;

pub const schema_overlay_promote =
    \\{"type":"object","properties":{"from_branch":{"type":"string","description":"branch to promote from (default current branch)"},"reason":{"type":"string","description":"Required justification (audited)"}},"required":["reason"]}
;
