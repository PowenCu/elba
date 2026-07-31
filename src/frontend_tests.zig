const std = @import("std");
const Lexer = @import("frontend/lexer.zig").Lexer;
const Parser = @import("frontend/parser.zig").Parser;
const typechecker = @import("frontend/typechecker.zig");
const interpreter = @import("backend/interpreter.zig");
const ErrorReporter = @import("utils/error_reporter.zig").ErrorReporter;

test {
    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/parser.zig");
}

test "decoded string escapes flow through type checking and interpretation" {
    const source =
        \\const lines: str = "line one\nline two";
        \\const tabbed: str = "left\tright";
        \\const quoted: str = "She said \"Elba\".";
        \\const path: str = "C:\\Elba";
        \\const match_value: str = "tab\tvalue";
        \\const matched: str = match (match_value) {
        \\    "tab\tvalue" => "yes",
        \\    _ => "no",
        \\};
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lexer = Lexer.init(source);
    const reporter = ErrorReporter.init(source, "runtime_string_escapes.elba");
    var parser = try Parser.init(allocator, &lexer, source, &reporter);

    var type_environment = typechecker.TypeEnvironment.init(allocator);
    defer type_environment.deinit();
    try typechecker.registerBuiltins(&type_environment);

    var runtime_environment = interpreter.Environment.init(allocator);
    defer runtime_environment.deinit();
    try interpreter.registerBuiltins(&runtime_environment);

    while (try parser.parseStmt()) |parsed_statement| {
        var statement = parsed_statement;
        try typechecker.checkStmt(&statement, &type_environment);
        try interpreter.evalStmt(&statement, &runtime_environment);
    }

    const expected_bindings = [_]struct {
        name: []const u8,
        value: []const u8,
    }{
        .{ .name = "lines", .value = "line one\nline two" },
        .{ .name = "tabbed", .value = "left\tright" },
        .{ .name = "quoted", .value = "She said \"Elba\"." },
        .{ .name = "path", .value = "C:\\Elba" },
        .{ .name = "matched", .value = "yes" },
    };

    for (expected_bindings) |expected| {
        const binding = runtime_environment.get(expected.name) orelse
            return error.TestExpectedEqual;
        const value = switch (binding) {
            .string => |value| value,
            else => return error.TestExpectedEqual,
        };
        try std.testing.expectEqualStrings(expected.value, value);
    }
}

test "array and field assignments parse, type check, and mutate values" {
    const source =
        \\struct Point {
        \\    x: int;
        \\    y: int;
        \\}
        \\let point: Point = Point { x: 1; y: 2 };
        \\let values: []int = [10, 20, 30];
        \\point.x = 7;
        \\values[1] = 99;
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lexer = Lexer.init(source);
    const reporter = ErrorReporter.init(source, "mutations.elba");
    var parser = try Parser.init(allocator, &lexer, source, &reporter);
    var type_environment = typechecker.TypeEnvironment.init(allocator);
    defer type_environment.deinit();
    try typechecker.registerBuiltins(&type_environment);
    var runtime_environment = interpreter.Environment.init(allocator);
    defer runtime_environment.deinit();
    try interpreter.registerBuiltins(&runtime_environment);

    while (try parser.parseStmt()) |parsed_statement| {
        var statement = parsed_statement;
        try typechecker.checkStmt(&statement, &type_environment);
        try interpreter.evalStmt(&statement, &runtime_environment);
    }

    const point = runtime_environment.get("point") orelse return error.TestExpectedEqual;
    try std.testing.expect(point == .struct_instance);
    const x = point.struct_instance.fields.get("x") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i64, 7), x.int);

    const values = runtime_environment.get("values") orelse return error.TestExpectedEqual;
    try std.testing.expect(values == .array);
    try std.testing.expectEqual(@as(i64, 99), values.array.elements[1].int);
}

test "recursive early returns stay inside their function invocation" {
    const source =
        \\fn countdown(value: int) -> int {
        \\    if (value == 0) {
        \\        return 7;
        \\    }
        \\    return countdown(value - 1);
        \\}
        \\const result: int = countdown(4);
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lexer = Lexer.init(source);
    const reporter = ErrorReporter.init(source, "recursive_return.elba");
    var parser = try Parser.init(allocator, &lexer, source, &reporter);
    var type_environment = typechecker.TypeEnvironment.init(allocator);
    defer type_environment.deinit();
    try typechecker.registerBuiltins(&type_environment);
    var runtime_environment = interpreter.Environment.init(allocator);
    defer runtime_environment.deinit();
    try interpreter.registerBuiltins(&runtime_environment);

    while (try parser.parseStmt()) |parsed_statement| {
        var statement = parsed_statement;
        try typechecker.checkStmt(&statement, &type_environment);
        try interpreter.evalStmt(&statement, &runtime_environment);
    }

    const result = runtime_environment.get("result") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i64, 7), result.int);
}

test "break and continue control the nearest loop" {
    const source =
        \\let total: int = 0;
        \\for (outer in 1..=3) {
        \\    for (inner in 1..=4) {
        \\        if (inner == 2) {
        \\            continue;
        \\        }
        \\        if (inner == 4) {
        \\            break;
        \\        }
        \\        total = total + outer;
        \\    }
        \\}
        \\let counter: int = 0;
        \\while (true) {
        \\    counter = counter + 1;
        \\    if (counter < 3) {
        \\        continue;
        \\    }
        \\    break;
        \\}
        \\let descending: int = 0;
        \\for (value in 5..=1) {
        \\    if (value == 4) {
        \\        continue;
        \\    }
        \\    if (value == 2) {
        \\        break;
        \\    }
        \\    descending = descending + value;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lexer = Lexer.init(source);
    const reporter = ErrorReporter.init(source, "loop_control.elba");
    var parser = try Parser.init(allocator, &lexer, source, &reporter);
    var type_environment = typechecker.TypeEnvironment.init(allocator);
    defer type_environment.deinit();
    try typechecker.registerBuiltins(&type_environment);
    var runtime_environment = interpreter.Environment.init(allocator);
    defer runtime_environment.deinit();
    try interpreter.registerBuiltins(&runtime_environment);

    while (try parser.parseStmt()) |parsed_statement| {
        var statement = parsed_statement;
        try typechecker.checkStmt(&statement, &type_environment);
        try interpreter.evalStmt(&statement, &runtime_environment);
    }

    const total = runtime_environment.get("total") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i64, 12), total.int);
    const counter = runtime_environment.get("counter") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i64, 3), counter.int);
    const descending = runtime_environment.get("descending") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i64, 8), descending.int);
}

test "loop control outside a loop is rejected" {
    const cases = [_][]const u8{ "break;", "continue;" };

    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var lexer = Lexer.init(source);
        const reporter = ErrorReporter.init(source, "invalid_loop_control.elba");
        var parser = try Parser.init(allocator, &lexer, source, &reporter);
        var type_environment = typechecker.TypeEnvironment.init(allocator);
        defer type_environment.deinit();

        var statement = (try parser.parseStmt()) orelse return error.TestExpectedEqual;
        try std.testing.expectError(error.TypeError, typechecker.checkStmt(&statement, &type_environment));
    }
}

test "bare returns and all-returning branches are accepted" {
    const source =
        \\fn finish() {
        \\    return;
        \\}
        \\fn choose(flag: bool) -> int {
        \\    if (flag) {
        \\        return 10;
        \\    } else {
        \\        return 20;
        \\    }
        \\}
        \\finish();
        \\const result: int = choose(false);
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lexer = Lexer.init(source);
    const reporter = ErrorReporter.init(source, "returns.elba");
    var parser = try Parser.init(allocator, &lexer, source, &reporter);
    var type_environment = typechecker.TypeEnvironment.init(allocator);
    defer type_environment.deinit();
    try typechecker.registerBuiltins(&type_environment);
    var runtime_environment = interpreter.Environment.init(allocator);
    defer runtime_environment.deinit();
    try interpreter.registerBuiltins(&runtime_environment);

    while (try parser.parseStmt()) |parsed_statement| {
        var statement = parsed_statement;
        try typechecker.checkStmt(&statement, &type_environment);
        try interpreter.evalStmt(&statement, &runtime_environment);
    }

    const result = runtime_environment.get("result") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i64, 20), result.int);
}

test "invalid return forms are rejected" {
    const cases = [_][]const u8{
        "return;",
        "fn value() -> int { return; }",
        "fn unit_value() { return 1; }",
        "fn partial(flag: bool) -> int { if (flag) { return 1; } }",
    };

    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var lexer = Lexer.init(source);
        const reporter = ErrorReporter.init(source, "invalid_return.elba");
        var parser = try Parser.init(allocator, &lexer, source, &reporter);
        var type_environment = typechecker.TypeEnvironment.init(allocator);
        defer type_environment.deinit();

        var statement = (try parser.parseStmt()) orelse return error.TestExpectedEqual;
        try std.testing.expectError(error.TypeError, typechecker.checkStmt(&statement, &type_environment));
    }
}

test "optional and union operators wrap complete array types" {
    const source =
        \\const optional: []int? = [];
        \\const unioned: []int | []str = [];
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lexer = Lexer.init(source);
    const reporter = ErrorReporter.init(source, "array_type_precedence.elba");
    var parser = try Parser.init(allocator, &lexer, source, &reporter);

    const optional_stmt = (try parser.parseStmt()) orelse return error.TestExpectedEqual;
    const optional_type = optional_stmt.const_decl.type_annotation orelse return error.TestExpectedEqual;
    try std.testing.expect(optional_type == .optional);
    try std.testing.expect(optional_type.optional.* == .array);
    try std.testing.expect(optional_type.optional.array.* == .int);

    const union_stmt = (try parser.parseStmt()) orelse return error.TestExpectedEqual;
    const union_type = union_stmt.const_decl.type_annotation orelse return error.TestExpectedEqual;
    try std.testing.expect(union_type == .union_type);
    try std.testing.expectEqual(@as(usize, 2), union_type.union_type.len);
    try std.testing.expect(union_type.union_type[0] == .array);
    try std.testing.expect(union_type.union_type[0].array.* == .int);
    try std.testing.expect(union_type.union_type[1] == .array);
    try std.testing.expect(union_type.union_type[1].array.* == .string);
}
