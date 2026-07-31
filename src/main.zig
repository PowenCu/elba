const std = @import("std");
// Frontend
const Lexer = @import("frontend/lexer.zig").Lexer;
const Parser = @import("frontend/parser.zig").Parser;
const typechecker = @import("frontend/typechecker.zig");
const Value = @import("frontend/ast.zig").Value;
const Stmt = @import("frontend/ast.zig").Stmt;
// Backend
const interpreter = @import("backend/interpreter.zig");
const ir = @import("backend/ir.zig");
const ir_gen = @import("backend/ir_gen.zig");
const ir_optimizer = @import("backend/ir_optimizer.zig");
const ir_interpreter = @import("backend/ir_interpreter.zig");
const llvm_codegen = @import("backend/llvm_codegen.zig");
// Codegen
const c_codegen = @import("codegen/c_codegen.zig");
// Utils
const ErrorReporter = @import("utils/error_reporter.zig").ErrorReporter;
const cli = @import("utils/cli.zig");
const repl = @import("utils/repl.zig");
const benchmark = @import("utils/benchmark.zig");

// Helper to load and parse a module file
fn loadModule(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    source_dir: []const u8,
) ![]Stmt {
    // Construct full path relative to source directory
    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ source_dir, module_path });
    defer allocator.free(full_path);

    const file = try std.fs.cwd().openFile(full_path, .{});
    defer file.close();

    const module_source = try file.readToEndAlloc(allocator, 1024 * 1024);
    // Don't free module_source - the arena allocator will handle it

    const module_error_reporter = ErrorReporter.init(module_source, module_path);

    var module_lexer = Lexer.init(module_source);
    var module_parser = try Parser.init(allocator, &module_lexer, module_source, &module_error_reporter);

    var statements = try std.ArrayList(Stmt).initCapacity(allocator, 0);
    while (try module_parser.parseStmt()) |stmt| {
        try statements.append(allocator, stmt);
    }

    return try statements.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var options = try cli.parseArgs(allocator);
    defer options.deinit();

    switch (options.command) {
        .help => {
            cli.printHelp();
            return;
        },
        .version => {
            cli.printVersion();
            return;
        },
        .repl => {
            try repl.run(allocator);
            return;
        },
        .benchmark => {
            var bench = benchmark.Benchmark.init(allocator);
            try bench.runSuite();
            return;
        },
        .compile => {
            const file_path = options.file_path orelse {
                std.debug.print("Error: No input file specified\n", .{});
                cli.printHelp();
                return;
            };
            try compileFile(allocator, file_path, options);
        },
        .run, .check => {
            const file_path = options.file_path orelse {
                std.debug.print("Error: No input file specified\n", .{});
                cli.printHelp();
                return;
            };
            try runFile(allocator, file_path, options);
        },
    }
}

fn runFile(allocator: std.mem.Allocator, file_path: []const u8, options: cli.Options) !void {
    // Get the directory of the source file for module resolution
    const source_dir = std.fs.path.dirname(file_path) orelse ".";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(source);

    // Arena allocator for AST
    var ast_arena = std.heap.ArenaAllocator.init(allocator);
    defer ast_arena.deinit();
    const ast_allocator = ast_arena.allocator();

    // Arena allocator for runtime (string concatenations, etc.)
    var runtime_arena = std.heap.ArenaAllocator.init(allocator);
    defer runtime_arena.deinit();
    const runtime_allocator = runtime_arena.allocator();

    var env = interpreter.Environment.init(runtime_allocator);
    defer env.deinit();

    // Register builtin functions in runtime environment
    try interpreter.registerBuiltins(&env);

    var type_env = typechecker.TypeEnvironment.init(allocator);
    defer type_env.deinit();

    // Register builtin function signatures in type environment
    try typechecker.registerBuiltins(&type_env);

    const error_reporter = ErrorReporter.init(source, file_path);

    var lexer = Lexer.init(source);
    var parser = try Parser.init(ast_allocator, &lexer, source, &error_reporter);

    if (options.verbose) {
        if (options.no_execute) {
            std.debug.print("Type checking '{s}'...\n", .{file_path});
        } else {
            std.debug.print("Type checking and executing '{s}'...\n", .{file_path});
        }
    }

    while (try parser.parseStmt()) |stmt| {
        // Handle import statements specially
        if (stmt == .import_stmt) {
            const import = stmt.import_stmt;

            // Load the module
            const module_stmts = try loadModule(ast_allocator, import.module_path, source_dir);

            // Process each statement in the module
            for (module_stmts) |module_stmt| {
                // Check if we should import this statement
                const should_import = blk: {
                    if (import.imports == null) {
                        // Full import - import everything
                        break :blk true;
                    }

                    // Selective import - only import specified names
                    const import_names = import.imports.?;
                    const stmt_name: ?[]const u8 = switch (module_stmt) {
                        .fn_decl => |decl| decl.name,
                        .const_decl => |decl| decl.name,
                        .let_decl => |decl| decl.name,
                        .struct_decl => |decl| decl.name,
                        .type_alias => |alias| alias.name,
                        else => null,
                    };

                    if (stmt_name) |name| {
                        for (import_names) |import_name| {
                            if (std.mem.eql(u8, name, import_name)) {
                                break :blk true;
                            }
                        }
                    }
                    break :blk false;
                };

                if (should_import) {
                    // Type check the imported statement
                    try typechecker.checkStmt(&module_stmt, &type_env);
                    // Execute the imported statement (if not check-only mode)
                    if (!options.no_execute) {
                        try interpreter.evalStmt(&module_stmt, &env);
                    }
                }
            }
            continue;
        }

        // Type check each statement
        typechecker.checkStmt(&stmt, &type_env) catch |err| {
            std.debug.print("Type check failed: {s}\n", .{@errorName(err)});
            return err;
        };

        // Execute if type check passed and not in check-only mode
        if (!options.no_execute) {
            interpreter.evalStmt(&stmt, &env) catch |err| {
                switch (err) {
                    error.EarlyReturn => {
                        std.debug.print("Error: 'return' statement outside of function\n", .{});
                        return err;
                    },
                    error.UndefinedVariable => return err, // Already printed by interpreter
                    error.IndexOutOfBounds => {
                        std.debug.print("Error: Array index out of bounds\n", .{});
                        return err;
                    },
                    error.InvalidArguments => {
                        std.debug.print("Error: Invalid function arguments\n", .{});
                        return err;
                    },
                    error.TypeError => {
                        std.debug.print("Error: Type mismatch at runtime\n", .{});
                        return err;
                    },
                    error.IntegerOverflow => {
                        std.debug.print("Error: Integer overflow\n", .{});
                        return err;
                    },
                    error.DivisionByZero => {
                        std.debug.print("Error: Division by zero\n", .{});
                        return err;
                    },
                    error.NegativeExponent => {
                        std.debug.print("Error: Integer exponent cannot be negative\n", .{});
                        return err;
                    },
                    else => return err,
                }
            };
        }
    }

    if (options.verbose or options.no_execute) {
        std.debug.print("✓ Type check passed!\n", .{});
    }

    // Print all bindings if not in check-only mode and bindings are enabled
    if (!options.no_execute and options.show_bindings and env.binding_order.items.len > 0) {
        if (options.verbose) {
            std.debug.print("\nVariable bindings:\n", .{});
        } else {
            std.debug.print("\n", .{});
        }

        for (env.binding_order.items) |name| {
            const value = env.bindings.get(name).?;
            std.debug.print("{s} = ", .{name});
            repl.printValue(value);
            std.debug.print("\n", .{});
        }
    }
}

/// Parse source code into AST statements
fn parseSource(allocator: std.mem.Allocator, source: []const u8, file_path: []const u8) !std.ArrayList(Stmt) {
    var lexer = Lexer.init(source);
    const error_reporter = ErrorReporter.init(source, file_path);
    var parser = try Parser.init(allocator, &lexer, source, &error_reporter);

    var statements = try std.ArrayList(Stmt).initCapacity(allocator, 0);
    while (try parser.parseStmt()) |stmt| {
        try statements.append(allocator, stmt);
    }

    return statements;
}

fn statementName(statement: Stmt) ?[]const u8 {
    return switch (statement) {
        .fn_decl => |decl| decl.name,
        .const_decl => |decl| decl.name,
        .let_decl => |decl| decl.name,
        .struct_decl => |decl| decl.name,
        .type_alias => |alias| alias.name,
        else => null,
    };
}

fn importSelects(import: Stmt.ImportStmt, statement: Stmt) bool {
    const imports = import.imports orelse return true;
    const name = statementName(statement) orelse return false;
    for (imports) |import_name| {
        if (std.mem.eql(u8, name, import_name)) return true;
    }
    return false;
}

fn appendExpandedImports(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(Stmt),
    statements: []const Stmt,
    source_dir: []const u8,
) !void {
    for (statements) |statement| {
        if (statement != .import_stmt) {
            try output.append(allocator, statement);
            continue;
        }

        const import = statement.import_stmt;
        const module_statements = try loadModule(allocator, import.module_path, source_dir);
        const module_path = try std.fs.path.join(allocator, &[_][]const u8{ source_dir, import.module_path });
        const module_dir = std.fs.path.dirname(module_path) orelse source_dir;

        for (module_statements) |module_statement| {
            // Dependencies declared by the imported module must be expanded even
            // when the outer import selects only one exported declaration.
            if (module_statement == .import_stmt) {
                try appendExpandedImports(allocator, output, &[_]Stmt{module_statement}, module_dir);
            } else if (importSelects(import, module_statement)) {
                try output.append(allocator, module_statement);
            }
        }
    }
}

fn expandImports(
    allocator: std.mem.Allocator,
    statements: []const Stmt,
    source_dir: []const u8,
) !std.ArrayList(Stmt) {
    var expanded = try std.ArrayList(Stmt).initCapacity(allocator, statements.len);
    try appendExpandedImports(allocator, &expanded, statements, source_dir);
    return expanded;
}

/// Type check all statements
fn typeCheckProgram(allocator: std.mem.Allocator, statements: []Stmt) !void {
    var type_env = typechecker.TypeEnvironment.init(allocator);
    defer type_env.deinit();
    try typechecker.registerBuiltins(&type_env);

    for (statements) |*stmt| {
        try typechecker.checkStmt(stmt, &type_env);
    }
}

/// Generate IR from AST statements
fn generateIR(allocator: std.mem.Allocator, statements: []Stmt) !ir.Program {
    var generator = ir_gen.IrGenerator.init(allocator);
    defer generator.deinit();

    return try generator.generate(statements);
}

/// Optimize IR program
fn optimizeIR(allocator: std.mem.Allocator, program: *ir.Program) !void {
    var optimizer = ir_optimizer.Optimizer.init(allocator);
    defer optimizer.deinit();

    try optimizer.optimize(program);
}

fn compileFile(allocator: std.mem.Allocator, file_path: []const u8, options: cli.Options) !void {
    // Read source file
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(source);

    // Arena allocator for AST
    var ast_arena = std.heap.ArenaAllocator.init(allocator);
    defer ast_arena.deinit();
    const ast_allocator = ast_arena.allocator();

    if (options.verbose) {
        std.debug.print("Compiling '{s}' to IR...\n", .{file_path});
    }

    // Parse source into AST
    const parsed_statements = try parseSource(ast_allocator, source, file_path);
    const source_dir = std.fs.path.dirname(file_path) orelse ".";
    const statements = try expandImports(ast_allocator, parsed_statements.items, source_dir);

    // Type check
    try typeCheckProgram(allocator, statements.items);

    if (options.verbose) {
        std.debug.print("✓ Type check passed!\n", .{});
        std.debug.print("Generating IR...\n", .{});
    }

    // Generate IR
    var program = try generateIR(allocator, statements.items);
    defer program.deinit(allocator);

    if (options.verbose) {
        std.debug.print("✓ IR generation complete!\n", .{});
    }

    // Optimize if requested
    if (options.optimize) {
        if (options.verbose) {
            std.debug.print("Running optimizations...\n", .{});
        }

        try optimizeIR(allocator, &program);

        if (options.verbose) {
            std.debug.print("✓ Optimizations complete!\n", .{});
        }
    }

    // Print IR if requested
    if (options.show_ir) {
        std.debug.print("\n", .{});
        try ir.printProgram(program, undefined);
    }

    // Execute IR if requested
    if (options.run_ir) {
        if (options.verbose) {
            std.debug.print("\nRunning IR interpreter...\n", .{});
        }

        var ir_interp = try ir_interpreter.Interpreter.init(allocator, program, options.verbose);
        defer ir_interp.deinit();

        ir_interp.execute() catch |err| {
            switch (err) {
                error.IntegerOverflow => std.debug.print("Error: Integer overflow\n", .{}),
                error.DivisionByZero => std.debug.print("Error: Division by zero\n", .{}),
                error.NegativeExponent => std.debug.print("Error: Integer exponent cannot be negative\n", .{}),
                else => {},
            }
            return err;
        };

        if (options.verbose) {
            std.debug.print("✓ IR execution complete!\n", .{});
        }
        return; // Don't save to file if we're just running
    }

    // Generate C code if requested
    if (options.generate_c) {
        if (options.verbose) {
            std.debug.print("Generating C code...\n", .{});
        }

        var codegen = try c_codegen.CCodeGen.init(allocator);
        defer codegen.deinit();

        const c_code = try codegen.generate(program);

        if (options.verbose) {
            std.debug.print("✓ C code generation complete!\n", .{});
        }

        // Determine output filename for C code
        const c_output = if (options.output_file) |output_path| blk: {
            // If output has .c extension, use it; otherwise append .c
            if (std.mem.endsWith(u8, output_path, ".c")) {
                break :blk try allocator.dupe(u8, output_path);
            } else {
                break :blk try std.fmt.allocPrint(allocator, "{s}.c", .{output_path});
            }
        } else blk: {
            // Auto-generate output filename with .c extension
            const base_name = std.fs.path.basename(file_path);
            const name_no_ext = if (std.mem.lastIndexOf(u8, base_name, ".")) |dot_idx|
                base_name[0..dot_idx]
            else
                base_name;
            break :blk try std.fmt.allocPrint(allocator, "{s}.c", .{name_no_ext});
        };
        defer allocator.free(c_output);

        const c_file = try std.fs.cwd().createFile(c_output, .{});
        defer c_file.close();

        try c_file.writeAll(c_code);

        if (options.verbose) {
            std.debug.print("✓ C code written to '{s}'\n", .{c_output});
        } else {
            std.debug.print("Generated C code: '{s}'\n", .{c_output});
        }

        // Optionally compile the C code with gcc/clang
        if (options.compile_c) {
            if (options.verbose) {
                std.debug.print("Compiling C code with gcc...\n", .{});
            }

            const exe_name = if (std.mem.lastIndexOf(u8, c_output, ".")) |dot_idx|
                c_output[0..dot_idx]
            else
                c_output;

            const exe_output = try std.fmt.allocPrint(allocator, "{s}.exe", .{exe_name});
            defer allocator.free(exe_output);

            const compile_args = [_][]const u8{
                "gcc",
                c_output,
                "-o",
                exe_output,
                "-lm", // Link math library
            };

            var child = std.process.Child.init(&compile_args, allocator);
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            const term = try child.spawnAndWait();
            if (term.Exited == 0) {
                if (options.verbose) {
                    std.debug.print("✓ Compiled to '{s}'\n", .{exe_output});
                } else {
                    std.debug.print("Executable: '{s}'\n", .{exe_output});
                }
            } else {
                std.debug.print("Error: C compilation failed with exit code {d}\n", .{term.Exited});
                return error.CompilationFailed;
            }
        }

        return; // Don't save IR file if we're generating C
    }

    // Generate LLVM IR if requested
    if (options.generate_llvm) {
        if (options.verbose) {
            std.debug.print("Generating LLVM IR...\n", .{});
        }

        var llvm_gen = try llvm_codegen.LLVMCodeGen.init(allocator, "elba_module");
        defer llvm_gen.deinit();

        try llvm_gen.generate(program);

        if (options.verbose) {
            std.debug.print("✓ LLVM IR generation complete!\n", .{});
        }

        // Determine output filename for LLVM IR
        const llvm_output = if (options.output_file) |output_path| blk: {
            if (std.mem.endsWith(u8, output_path, ".ll")) {
                break :blk try allocator.dupe(u8, output_path);
            } else {
                break :blk try std.fmt.allocPrint(allocator, "{s}.ll", .{output_path});
            }
        } else blk: {
            const base_name = std.fs.path.basename(file_path);
            const name_no_ext = if (std.mem.lastIndexOf(u8, base_name, ".")) |dot_idx|
                base_name[0..dot_idx]
            else
                base_name;
            break :blk try std.fmt.allocPrint(allocator, "{s}.ll", .{name_no_ext});
        };
        defer allocator.free(llvm_output);

        // Print LLVM IR to file
        try llvm_gen.emitLLVMIR(llvm_output);

        if (options.verbose) {
            std.debug.print("✓ LLVM IR written to '{s}'\n", .{llvm_output});
        } else {
            std.debug.print("Generated LLVM IR: '{s}'\n", .{llvm_output});
        }

        // Optionally compile to object file
        if (options.compile_llvm) {
            if (options.verbose) {
                std.debug.print("Compiling LLVM IR to object file...\n", .{});
            }

            const obj_name = if (std.mem.lastIndexOf(u8, llvm_output, ".")) |dot_idx|
                llvm_output[0..dot_idx]
            else
                llvm_output;

            const obj_output = try std.fmt.allocPrint(allocator, "{s}.o", .{obj_name});
            defer allocator.free(obj_output);

            try llvm_gen.emitObjectFile(obj_output);

            if (options.verbose) {
                std.debug.print("✓ Object file written to '{s}'\n", .{obj_output});
            } else {
                std.debug.print("Object file: '{s}'\n", .{obj_output});
            }

            // Link to executable
            const exe_output = try std.fmt.allocPrint(allocator, "{s}.exe", .{obj_name});
            defer allocator.free(exe_output);

            const link_args = [_][]const u8{
                "gcc",
                obj_output,
                "-o",
                exe_output,
                "-lm",
            };

            var child = std.process.Child.init(&link_args, allocator);
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            const term = try child.spawnAndWait();
            if (term.Exited == 0) {
                if (options.verbose) {
                    std.debug.print("✓ Linked to '{s}'\n", .{exe_output});
                } else {
                    std.debug.print("Executable: '{s}'\n", .{exe_output});
                }
            } else {
                std.debug.print("Error: Linking failed with exit code {d}\n", .{term.Exited});
                return error.LinkingFailed;
            }
        }

        return; // Don't save IR file if we're generating LLVM
    }

    // Save to file if output path specified
    if (options.output_file) |output_path| {
        const output_file = try std.fs.cwd().createFile(output_path, .{});
        defer output_file.close();

        try ir.writeProgramToFile(program, output_file, allocator);

        if (options.verbose) {
            std.debug.print("✓ IR written to '{s}'\n", .{output_path});
        } else {
            std.debug.print("Compiled to '{s}'\n", .{output_path});
        }
    } else if (!options.show_ir) {
        // Auto-generate output filename with .elbr extension
        const base_name = std.fs.path.basename(file_path);
        const name_no_ext = if (std.mem.lastIndexOf(u8, base_name, ".")) |dot_idx|
            base_name[0..dot_idx]
        else
            base_name;

        const output_name = try std.fmt.allocPrint(allocator, "{s}.elbr", .{name_no_ext});
        defer allocator.free(output_name);

        const output_file = try std.fs.cwd().createFile(output_name, .{});
        defer output_file.close();

        // Write IR to file
        try ir.writeProgramToFile(program, output_file, allocator);

        std.debug.print("Compiled to '{s}'\n", .{output_name});
    }
}
