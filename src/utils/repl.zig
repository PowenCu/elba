const std = @import("std");
const Lexer = @import("../frontend/lexer.zig").Lexer;
const Parser = @import("../frontend/parser.zig").Parser;
const interpreter = @import("../backend/interpreter.zig");
const typechecker = @import("../frontend/typechecker.zig");
const Value = @import("../frontend/ast.zig").Value;
const Stmt = @import("../frontend/ast.zig").Stmt;
const ErrorReporter = @import("error_reporter.zig").ErrorReporter;
const cli = @import("cli.zig");

pub fn printValue(value: Value) void {
    switch (value) {
        .int => |val| std.debug.print("{d}", .{val}),
        .float => |val| std.debug.print("{d}", .{val}),
        .string => |val| std.debug.print("\"{s}\"", .{val}),
        .bool => |val| std.debug.print("{}", .{val}),
        .unit => std.debug.print("()", .{}),
        .null_value => std.debug.print("null", .{}),
        .struct_instance => |instance| {
            std.debug.print("{s} {{", .{instance.type_name});
            var it = instance.fields.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) std.debug.print(", ", .{});
                first = false;
                std.debug.print("{s}: ", .{entry.key_ptr.*});
                printValue(entry.value_ptr.*);
            }
            std.debug.print("}}", .{});
        },
        .array => |array_value| {
            std.debug.print("[", .{});
            for (array_value.elements, 0..) |elem, i| {
                if (i > 0) std.debug.print(", ", .{});
                printValue(elem);
            }
            std.debug.print("]", .{});
        },
    }
}

pub fn run(allocator: std.mem.Allocator) !void {
    cli.printBanner();

    // Arena allocator for AST
    var ast_arena = std.heap.ArenaAllocator.init(allocator);
    defer ast_arena.deinit();
    const ast_allocator = ast_arena.allocator();

    // Arena allocator for runtime
    var runtime_arena = std.heap.ArenaAllocator.init(allocator);
    defer runtime_arena.deinit();
    const runtime_allocator = runtime_arena.allocator();

    var env = interpreter.Environment.init(runtime_allocator);
    defer env.deinit();

    // Register builtin functions
    try interpreter.registerBuiltins(&env);

    var type_env = typechecker.TypeEnvironment.init(allocator);
    defer type_env.deinit();

    // Register builtin function signatures
    try typechecker.registerBuiltins(&type_env);

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var line_buffer: [4096]u8 = undefined;
    var line_num: usize = 1;

    while (true) {
        // Print prompt
        var prompt_buffer: [32]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buffer, "elba:{d}> ", .{line_num}) catch "elba> ";
        try stdout.writeAll(prompt);

        // Read input
        const bytes_read = try stdin.read(&line_buffer);
        if (bytes_read == 0) break; // EOF

        const input = line_buffer[0..bytes_read];

        // Trim whitespace
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Check for REPL commands
        const cmd = cli.ReplCommand.parse(trimmed);
        switch (cmd) {
            .help => {
                cli.printReplHelp();
                continue;
            },
            .exit => {
                std.debug.print("Goodbye!\n", .{});
                break;
            },
            .clear => {
                // ANSI escape code to clear screen
                try stdout.writeAll("\x1B[2J\x1B[H");
                cli.printBanner();
                continue;
            },
            .vars => {
                if (env.binding_order.items.len == 0) {
                    std.debug.print("No variables defined.\n", .{});
                } else {
                    std.debug.print("Defined variables:\n", .{});
                    for (env.binding_order.items) |name| {
                        const value = env.bindings.get(name).?;
                        std.debug.print("  {s} = ", .{name});
                        printValue(value);
                        std.debug.print("\n", .{});
                    }
                }
                continue;
            },
            .reset => {
                // Clear the environment
                env.deinit();
                type_env.deinit();

                // Reset arenas
                _ = ast_arena.reset(.retain_capacity);
                _ = runtime_arena.reset(.retain_capacity);

                // Reinitialize
                env = interpreter.Environment.init(runtime_allocator);
                try interpreter.registerBuiltins(&env);

                type_env = typechecker.TypeEnvironment.init(allocator);
                try typechecker.registerBuiltins(&type_env);

                std.debug.print("Environment reset.\n", .{});
                line_num = 1;
                continue;
            },
            .none => {},
        }

        // Try to parse and execute as Elba code
        const error_reporter = ErrorReporter.init(trimmed, "<repl>");
        var lexer = Lexer.init(trimmed);
        var parser = Parser.init(ast_allocator, &lexer, trimmed, &error_reporter) catch |err| {
            std.debug.print("Parser initialization failed: {s}\n", .{@errorName(err)});
            continue;
        };

        // Try to parse a statement
        const stmt = parser.parseStmt() catch {
            // Error reporting already done by error_reporter in parser
            continue;
        };

        if (stmt) |s| {
            // Type check
            typechecker.checkStmt(&s, &type_env) catch |err| {
                std.debug.print("Type error: {s}\n", .{@errorName(err)});
                continue;
            };

            // Execute
            interpreter.evalStmt(&s, &env) catch |err| {
                switch (err) {
                    error.EarlyReturn => std.debug.print("Error: 'return' statement outside of function\n", .{}),
                    error.UndefinedVariable => {}, // Already printed by interpreter
                    error.IndexOutOfBounds => std.debug.print("Error: Array index out of bounds\n", .{}),
                    error.InvalidArguments => std.debug.print("Error: Invalid function arguments\n", .{}),
                    error.TypeError => std.debug.print("Error: Type mismatch at runtime\n", .{}),
                    else => std.debug.print("Runtime error: {s}\n", .{@errorName(err)}),
                }
                continue;
            };

            // If it was an expression statement, show the result
            if (s == .expr_stmt) {
                // Evaluate the expression to show its value
                const result = interpreter.evalExpr(s.expr_stmt, &env) catch |err| {
                    std.debug.print("Expression evaluation error: {s}\n", .{@errorName(err)});
                    continue;
                };

                // Don't print unit values
                if (result != .unit) {
                    std.debug.print("=> ", .{});
                    printValue(result);
                    std.debug.print("\n", .{});
                }
            }

            line_num += 1;
        } else {
            std.debug.print("No statement parsed.\n", .{});
        }
    }
}
