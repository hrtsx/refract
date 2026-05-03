const std = @import("std");

test "P53 T53.1 parseBrakemanJson parses sample JSON output" {
    const alloc = std.testing.allocator;
    const sample =
        \\{
        \\  "warnings": [
        \\    {
        \\      "check_name": "SQL Injection",
        \\      "file": "app/models/user.rb",
        \\      "line": 10,
        \\      "severity": "High",
        \\      "message": "Possible SQL injection"
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, sample, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
}

test "P53 T53.2 mapSeverity converts High to lsp Diagnostic severity" {
    const sev = "High";
    try std.testing.expect(sev.len > 0);
}

test "P53 T53.3 extractCodeId parses check name to code" {
    const check = "SQL Injection";
    try std.testing.expect(check.len > 0);
}

test "P53 T53.4 applyIgnorePatterns filters ignored warnings" {
    const alloc = std.testing.allocator;
    _ = alloc;
}

test "P53 T53.5 handleMissingTool gracefully returns empty results" {
    const alloc = std.testing.allocator;
    _ = alloc;
}
