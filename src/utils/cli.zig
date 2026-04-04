const std = @import("std");

pub const Command = enum {
    run, // Run a file
    repl, // Interactive REPL
    check, // Type check only
    compile, // Compile to IR
    benchmark, // Run benchmarks
    help, // Show help
    version, // Show version
};

pub const Options = struct {
    command: Command,
    file_path: ?[]const u8,
    verbose: bool,
    no_execute: bool, // Type check only
    show_ast: bool,
    show_bindings: bool,
    show_ir: bool, // Show IR output
    optimize: bool, // Enable IR optimizations
    run_ir: bool, // Execute IR directly
    output_file: ?[]const u8, // Output file for compilation
    generate_c: bool, // Generate C code
    compile_c: bool, // Compile C code to executable
    generate_llvm: bool, // Generate LLVM IR
    compile_llvm: bool, // Compile LLVM IR to object file
    allocator: std.mem.Allocator, // Store allocator for cleanup

    pub fn init(allocator: std.mem.Allocator) Options {
        return .{
            .command = .run,
            .file_path = null,
            .verbose = false,
            .no_execute = false,
            .show_ast = false,
            .show_bindings = true,
            .show_ir = false,
            .optimize = false,
            .run_ir = false,
            .output_file = null,
            .generate_c = false,
            .compile_c = false,
            .generate_llvm = false,
            .compile_llvm = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Options) void {
        if (self.file_path) |path| {
            self.allocator.free(path);
        }
        if (self.output_file) |output| {
            self.allocator.free(output);
        }
    }
};

pub fn parseArgs(allocator: std.mem.Allocator) !Options {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = Options.init(allocator);

    if (args.len < 2) {
        options.command = .help;
        return options;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.command = .help;
            return options;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            options.command = .version;
            return options;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "--check") or std.mem.eql(u8, arg, "-c")) {
            options.command = .check;
            options.no_execute = true;
        } else if (std.mem.eql(u8, arg, "--compile")) {
            options.command = .compile;
        } else if (std.mem.eql(u8, arg, "--show-ir")) {
            options.show_ir = true;
        } else if (std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "--optimize")) {
            options.optimize = true;
        } else if (std.mem.eql(u8, arg, "--run-ir")) {
            options.run_ir = true;
        } else if (std.mem.eql(u8, arg, "--emit-c")) {
            options.generate_c = true;
        } else if (std.mem.eql(u8, arg, "--compile-c")) {
            options.generate_c = true;
            options.compile_c = true;
        } else if (std.mem.eql(u8, arg, "--emit-llvm")) {
            options.generate_llvm = true;
        } else if (std.mem.eql(u8, arg, "--compile-llvm")) {
            options.generate_llvm = true;
            options.compile_llvm = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) {
                options.output_file = try allocator.dupe(u8, args[i]);
            } else {
                std.debug.print("Error: -o/--output requires a filename\n", .{});
                options.command = .help;
                return options;
            }
        } else if (std.mem.eql(u8, arg, "--ast")) {
            options.show_ast = true;
        } else if (std.mem.eql(u8, arg, "--no-bindings")) {
            options.show_bindings = false;
        } else if (std.mem.eql(u8, arg, "repl")) {
            options.command = .repl;
            return options;
        } else if (std.mem.eql(u8, arg, "benchmark")) {
            options.command = .benchmark;
            return options;
        } else if (arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            options.command = .help;
            return options;
        } else {
            // Assume it's a file path - duplicate it since args will be freed
            options.file_path = try allocator.dupe(u8, arg);
            // Only set to run if no other command was specified
            if (options.command != .compile and options.command != .check) {
                options.command = .run;
            }
        }
    }

    if (options.command == .run and options.file_path == null) {
        std.debug.print("Error: No input file specified\n\n", .{});
        options.command = .help;
    }

    return options;
}

pub fn printHelp() void {
    const help_text =
        \\Elba Programming Language
        \\
        \\USAGE:
        \\    elba [OPTIONS] <file>
        \\    elba repl
        \\    elba benchmark
        \\    elba --help
        \\
        \\COMMANDS:
        \\    <file>              Run an Elba source file
        \\    repl                Start interactive REPL mode
        \\    benchmark           Run performance benchmarks
        \\
        \\OPTIONS:
        \\    -h, --help          Show this help message
        \\    -v, --version       Show version information
        \\    -c, --check         Type check only, don't execute
        \\    --compile           Compile to IR (intermediate representation)
        \\    --show-ir           Show IR output
        \\    -O, --optimize      Enable IR optimizations
        \\    --run-ir            Execute IR directly (with optimizations)
        \\    --emit-c            Generate C code from IR
        \\    --compile-c         Generate and compile C code to executable
        \\    --emit-llvm         Generate LLVM IR
        \\    --compile-llvm      Generate LLVM IR and compile to object file
        \\    -o, --output FILE   Output file for compilation
        \\    --verbose           Show detailed execution information
        \\    --ast               Show parsed AST (debug mode)
        \\    --no-bindings       Don't print variable bindings after execution
        \\
        \\EXAMPLES:
        \\    elba program.elba                      Run a program
        \\    elba --check program.elba              Type check without running
        \\    elba --compile --show-ir program.elba  Compile and show IR
        \\    elba --compile -O program.elba         Compile with optimizations
        \\    elba --compile --emit-c program.elba   Generate C code
        \\    elba --compile --compile-c program.elba    Generate and compile C to exe
        \\    elba --compile --emit-llvm program.elba    Generate LLVM IR
        \\    elba --compile --compile-llvm program.elba Compile to object file via LLVM
        \\    elba --compile -o output.elbr program.elba   Compile to file
        \\    elba repl                              Start REPL
        \\    elba benchmark                         Run benchmarks
        \\    elba --verbose program.elba            Run with verbose output
        \\
        \\For more information, visit: https://github.com/powencu/elba
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

pub fn printVersion() void {
    const version_text =
        \\Elba Programming Language
        \\Version: 0.1.0
        \\Build: Development
        \\
        \\A statically-typed programming language with:
        \\  - Generics and type inference
        \\  - Pattern matching
        \\  - Module system
        \\  - REPL mode
        \\
    ;
    std.debug.print("{s}", .{version_text});
}

pub fn printBanner() void {
    const banner =
        \\=========================================
        \\    Elba Programming Language v0.1
        \\         Interactive REPL
        \\=========================================
        \\
        \\Type 'help' for available commands
        \\Type 'exit' or press Ctrl+C to quit
        \\
    ;
    std.debug.print("{s}\n", .{banner});
}

pub const ReplCommand = enum {
    help,
    exit,
    clear,
    vars,
    reset,
    none,

    pub fn parse(input: []const u8) ReplCommand {
        const trimmed = std.mem.trim(u8, input, " \t\n\r");
        if (std.mem.eql(u8, trimmed, "help")) return .help;
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) return .exit;
        if (std.mem.eql(u8, trimmed, "clear")) return .clear;
        if (std.mem.eql(u8, trimmed, "vars")) return .vars;
        if (std.mem.eql(u8, trimmed, "reset")) return .reset;
        return .none;
    }
};

pub fn printReplHelp() void {
    const help_text =
        \\REPL Commands:
        \\  help      - Show this help message
        \\  exit      - Exit the REPL
        \\  clear     - Clear the screen
        \\  vars      - Show all defined variables
        \\  reset     - Reset the environment (clear all variables)
        \\
        \\You can also type any Elba expression or statement:
        \\  const x: int = 42;
        \\  println("Hello, World!");
        \\  fn add(a: int, b: int) -> int { a + b }
        \\
    ;
    std.debug.print("{s}\n", .{help_text});
}
