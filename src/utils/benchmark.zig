const std = @import("std");
const ir = @import("../backend/ir.zig");
const ir_gen = @import("../backend/ir_gen.zig");
const ir_optimizer = @import("../backend/ir_optimizer.zig");
const ir_interpreter = @import("../backend/ir_interpreter.zig");

/// Performance metrics for a single benchmark run
pub const Metrics = struct {
    name: []const u8,
    duration_ns: u64,
    instruction_count: usize,
    optimized_instruction_count: usize,
    optimization_reduction: f64,
    allocator: std.mem.Allocator,

    pub fn format(self: Metrics, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Benchmark: {s}\n", .{self.name});
        try writer.print("  Duration: {d} ns ({d:.2} ms)\n", .{ self.duration_ns, @as(f64, @floatFromInt(self.duration_ns)) / 1_000_000.0 });
        try writer.print("  Instructions: {d} → {d} ({d:.1}% reduction)\n", .{
            self.instruction_count,
            self.optimized_instruction_count,
            self.optimization_reduction * 100.0,
        });
    }
};

/// Benchmark suite for Elba IR system
pub const Benchmark = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Benchmark {
        return .{ .allocator = allocator };
    }

    /// Run a complete benchmark suite
    pub fn runSuite(self: *Benchmark) !void {
        std.debug.print("\n", .{});
        std.debug.print("================================================================\n", .{});
        std.debug.print("            Elba IR Performance Benchmark Suite                \n", .{});
        std.debug.print("================================================================\n", .{});
        std.debug.print("\n", .{});

        // Benchmark 1: Simple arithmetic
        try self.benchmarkArithmetic();

        // Benchmark 2: Constant folding effectiveness
        try self.benchmarkConstantFolding();

        // Benchmark 3: Control flow
        try self.benchmarkControlFlow();

        // Benchmark 4: Variable operations
        try self.benchmarkVariables();

        // Summary
        std.debug.print("\n", .{});
        std.debug.print("================================================================\n", .{});
        std.debug.print("                    Benchmark Complete                          \n", .{});
        std.debug.print("================================================================\n", .{});
    }

    /// Benchmark arithmetic operations
    fn benchmarkArithmetic(self: *Benchmark) !void {
        const source =
            \\const a: int = 10 + 20;
            \\const b: int = 5 * 6;
            \\const c: int = 100 - 50;
            \\const d: int = 80 / 4;
            \\const e: int = 17 % 5;
        ;

        try self.runBenchmark("Arithmetic Operations", source);
    }

    /// Benchmark constant folding
    fn benchmarkConstantFolding(self: *Benchmark) !void {
        const source =
            \\const x: int = 10 + 20 + 30 + 40;
            \\const y: int = 5 * 0;
            \\const z: int = 100 * 1;
            \\let a: int = 50;
            \\const b: int = a - a;
        ;

        try self.runBenchmark("Constant Folding", source);
    }

    /// Benchmark control flow
    fn benchmarkControlFlow(self: *Benchmark) !void {
        const source =
            \\let x: int = 5;
            \\let y: int = 10;
            \\const result: int = if (x < y) { 100 } else { 50 };
        ;

        try self.runBenchmark("Control Flow", source);
    }

    /// Benchmark variable operations
    fn benchmarkVariables(self: *Benchmark) !void {
        const source =
            \\let x: int = 10;
            \\let y: int = 20;
            \\let z: int = 30;
            \\const sum: int = x + y + z;
            \\x = sum;
            \\y = x * 2;
            \\z = y + sum;
        ;

        try self.runBenchmark("Variable Operations", source);
    }

    /// Run a single benchmark
    fn runBenchmark(self: *Benchmark, name: []const u8, source: []const u8) !void {
        std.debug.print("----------------------------------------------------------------\n", .{});
        std.debug.print("Benchmark: {s}\n", .{name});
        std.debug.print("----------------------------------------------------------------\n", .{});

        // Use arena allocator for temporary allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // Parse and generate IR
        const Lexer = @import("../frontend/lexer.zig").Lexer;
        const Parser = @import("../frontend/parser.zig").Parser;
        const typechecker = @import("../frontend/typechecker.zig");
        const ErrorReporter = @import("error_reporter.zig").ErrorReporter;

        var error_reporter = ErrorReporter.init(source, "<benchmark>");

        var lexer = Lexer.init(source);
        var parser = try Parser.init(arena_allocator, &lexer, source, &error_reporter);

        var statements = try std.ArrayList(@import("../frontend/ast.zig").Stmt).initCapacity(arena_allocator, 10);

        while (try parser.parseStmt()) |stmt| {
            try statements.append(arena_allocator, stmt);
        }

        // Type check
        var type_env = typechecker.TypeEnvironment.init(arena_allocator);
        defer type_env.deinit();

        for (statements.items) |*stmt| {
            try typechecker.checkStmt(stmt, &type_env);
        }

        // Generate IR (unoptimized)
        var generator = ir_gen.IrGenerator.init(arena_allocator);
        defer generator.deinit();

        var program_unopt = try generator.generate(statements.items);
        defer program_unopt.deinit(arena_allocator);

        const unopt_count = countInstructions(program_unopt);

        // Generate IR (optimized)
        var generator2 = ir_gen.IrGenerator.init(arena_allocator);
        defer generator2.deinit();

        var program_opt = try generator2.generate(statements.items);
        defer program_opt.deinit(arena_allocator);

        var optimizer = ir_optimizer.Optimizer.init(arena_allocator);
        defer optimizer.deinit();

        try optimizer.optimize(&program_opt);

        const opt_count = countInstructions(program_opt);
        const reduction = if (unopt_count > 0)
            1.0 - (@as(f64, @floatFromInt(opt_count)) / @as(f64, @floatFromInt(unopt_count)))
        else
            0.0;

        std.debug.print("  Instructions: {d} -> {d} ({d:.1}% reduction)\n", .{
            unopt_count,
            opt_count,
            reduction * 100.0,
        });

        // Benchmark execution (unoptimized)
        var timer_unopt = try std.time.Timer.start();
        var interp_unopt = try ir_interpreter.Interpreter.init(arena_allocator, program_unopt, false);
        defer interp_unopt.deinit();
        try interp_unopt.execute();
        const duration_unopt = timer_unopt.read();

        std.debug.print("  Execution (unoptimized): {d} ns ({d:.2} us)\n", .{
            duration_unopt,
            @as(f64, @floatFromInt(duration_unopt)) / 1000.0,
        });

        // Benchmark execution (optimized)
        var timer_opt = try std.time.Timer.start();
        var interp_opt = try ir_interpreter.Interpreter.init(arena_allocator, program_opt, false);
        defer interp_opt.deinit();
        try interp_opt.execute();
        const duration_opt = timer_opt.read();

        std.debug.print("  Execution (optimized): {d} ns ({d:.2} us)\n", .{
            duration_opt,
            @as(f64, @floatFromInt(duration_opt)) / 1000.0,
        });

        const speedup = @as(f64, @floatFromInt(duration_unopt)) / @as(f64, @floatFromInt(duration_opt));
        std.debug.print("  Speedup: {d:.2}x\n", .{speedup});

        std.debug.print("\n", .{});
    }

    /// Count total instructions in a program
    fn countInstructions(program: ir.Program) usize {
        var total: usize = 0;
        for (program.functions) |func| {
            total += func.instructions.len;
        }
        return total;
    }
};

/// Compare different optimization strategies
pub fn compareOptimizations(_: std.mem.Allocator) !void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║            Optimization Strategy Comparison                  ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const test_cases = [_]struct { name: []const u8, code: []const u8 }{
        .{
            .name = "Heavy Arithmetic",
            .code =
            \\const a: int = 10 + 20 + 30;
            \\const b: int = 5 * 6 * 7;
            \\const c: int = 100 - 50 - 25;
            \\const d: int = a + b + c;
            ,
        },
        .{
            .name = "Algebraic Simplifications",
            .code =
            \\let x: int = 10;
            \\const a: int = x - x;
            \\const b: int = x * 0;
            \\const c: int = 0 * x;
            ,
        },
        .{
            .name = "Mixed Operations",
            .code =
            \\const x: int = 10 + 5 * 2;
            \\const y: int = x * 1;
            \\const z: int = y + 0;
            \\let a: int = 100;
            \\const b: int = a - a;
            ,
        },
    };

    for (test_cases) |test_case| {
        std.debug.print("Test: {s}\n", .{test_case.name});
        std.debug.print("Code: {s}\n", .{test_case.code});
        std.debug.print("\n", .{});
    }
}
