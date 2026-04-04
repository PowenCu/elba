# Development Guide for Elba Contributors

This guide provides an overview of the Elba codebase structure and how to contribute improvements.

## Project Structure

```
elba/
├── src/
│   ├── main.zig              # Entry point and CLI handling
│   ├── frontend/             # Compiler frontend
│   │   ├── lexer.zig         # Tokenization
│   │   ├── parser.zig        # Parsing (tokens → AST)
│   │   ├── ast.zig           # Abstract syntax tree definitions
│   │   └── typechecker.zig   # Type checking and inference
│   ├── backend/              # IR and execution backends
│   │   ├── ir.zig            # Intermediate representation (IR) opcodes and builder
│   │   ├── ir_gen.zig        # AST to IR code generation
│   │   ├── ir_optimizer.zig  # IR optimization passes
│   │   ├── interpreter.zig   # AST direct interpreter
│   │   ├── ir_interpreter.zig # IR stack-based interpreter
│   │   └── llvm_codegen.zig  # LLVM IR generation and compilation
│   ├── codegen/
│   │   └── c_codegen.zig     # C code generation backend
│   └── utils/                # Utility modules
│       ├── cli.zig           # Command-line interface
│       ├── error_reporter.zig # Error reporting with line/column info
│       ├── repl.zig          # Interactive REPL mode
│       └── benchmark.zig     # Performance benchmarking
├── std/                      # Standard library (math, strings, etc.)
├── examples/                 # Example programs
├── tests/                    # Test suite
├── build.zig                 # Zig build configuration
└── run_tests.ps1             # Automated test runner
```

## Compilation Pipeline

```
Source Code (*.elba)
    ↓
Lexer (lexer.zig)
    ↓ [Tokens]
Parser (parser.zig)
    ↓ [AST]
Type Checker (typechecker.zig)
    ↓ [Checked AST]
IR Generator (ir_gen.zig)
    ↓ [IR Instructions]
IR Optimizer (ir_optimizer.zig)  [Optional]
    ↓ [Optimized IR]
    ├→ AST Interpreter (interpreter.zig)
    ├→ IR Interpreter (ir_interpreter.zig)
    ├→ C Code Generator (c_codegen.zig) → C Code → Compiler → Binary
    └→ LLVM Codegen (llvm_codegen.zig) → LLVM IR → llc → Binary
```

## Building and Running

```bash
# Build the compiler
zig build

# Run an example
./zig-out/bin/elba examples/hello_world.elba

# Run the REPL
./zig-out/bin/elba repl

# Type check without executing
./zig-out/bin/elba --check program.elba

# Run with verbose output
./zig-out/bin/elba --verbose program.elba

# Compile with optimizations
./zig-out/bin/elba --compile -O program.elba
```

## Testing

```bash
# Run all tests
powershell -ExecutionPolicy Bypass -File "run_tests.ps1"

# Run tests with verbose output
powershell -ExecutionPolicy Bypass -File "run_tests.ps1" -Verbose

# Benchmark examples
powershell -ExecutionPolicy Bypass -File "benchmark_examples.ps1"
```

## Key Data Structures

### Type System (`frontend/ast.zig`)

```zig
pub const Type = union(enum) {
    int,                          // i64
    float,                        // f64
    string,                       // str
    bool,
    unit,
    unknown,
    user_type: []const u8,
    generic_param: []const u8,
    generic_instance: struct {
        base_type: []const u8,
        type_args: []Type,
    },
    array: *Type,
    optional: *Type,
    union_type: []Type,
};
```

### Abstract Syntax Tree (`frontend/ast.zig`)

```zig
pub const Stmt = union(enum) {
    const_decl: struct { name: []const u8, type_annotation: ?Type, value: *Expr },
    let_decl: struct { name: []const u8, type_annotation: ?Type, value: *Expr },
    fn_decl: struct { name: []const u8, parameters: []Parameter, body: *Expr, ... },
    struct_decl: struct { name: []const u8, fields: []FieldDecl, methods: []MethodDecl },
    return_stmt: *Expr,
    expr_stmt: *Expr,
    // ... more statement types
};
```

### Intermediate Representation (`backend/ir.zig`)

```zig
pub const Instruction = struct {
    op: Opcode,           // Operation type
    operand1: i64,        // First operand
    operand2: i64,        // Second operand
    operand3: i64,        // Third operand
    string_data: ?[]const u8,  // For string/variable names
};
```

## Common Patterns

### Adding a New Language Feature

1. **Lexer** (`frontend/lexer.zig`): Add token type
2. **Parser** (`frontend/parser.zig`): Add grammar rule
3. **Type Checker** (`frontend/typechecker.zig`): Add type checking logic
4. **IR Generator** (`backend/ir_gen.zig`): Generate IR code
5. **IR Interpreter** (`backend/ir_interpreter.zig`): Implement execution
6. **Backends**: Add to C codegen, LLVM codegen, etc.
7. **Tests**: Add test files in `tests/`

### Memory Management

Elba uses arena allocators for most allocations:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Use allocator for all allocations
const my_data = try allocator.alloc(u8, 1024);
defer allocator.free(my_data);
```

### Error Handling

Use Zig's error handling:

```zig
pub fn parseFile(path: []const u8) ![]Stmt {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(source);
    
    // Parse...
}
```

## Code Style Guidelines

1. **Naming**: Use snake_case for variables/functions, PascalCase for types
2. **Comments**: Add docstrings to public functions using `///`
3. **Error Handling**: Always use Zig's error sets, not panics
4. **Memory**: Use defer for cleanup, track allocations carefully
5. **Testing**: Create test files for new features in `tests/`

## Performance Considerations

- **IR Interpreter**: 5x faster than AST interpreter
- **LLVM Backend**: 100x faster than AST interpreter
- **Optimization**: Use `-O` flag to enable IR optimizations
- **Benchmarking**: Use `benchmark_examples.ps1` to measure improvements

## Debugging Tips

```bash
# Show AST structure
./zig-out/bin/elba --ast program.elba

# Show IR code
./zig-out/bin/elba --compile --show-ir program.elba

# Type checking only
./zig-out/bin/elba --check program.elba

# Verbose output
./zig-out/bin/elba --verbose program.elba
```

## Known Issues and Limitations

1. **No Garbage Collection**: Manual memory management required in Elba programs
2. **Error Handling**: No try-catch or Result types yet
3. **Module System**: Simple file-based imports, no namespacing
4. **Generic Constraints**: No trait bounds for generic types
5. **LLVM Backend**: Some features (recursion, complex generics) may be unstable

See `IMPROVEMENTS.md` for a detailed analysis of areas for improvement.

## Contributing

When making improvements:

1. Test thoroughly (`run_tests.ps1`)
2. Benchmark if applicable (`benchmark_examples.ps1`)
3. Verify no regressions (all examples still work)
4. Update documentation if needed
5. Keep commits focused and well-documented

Happy contributing!
