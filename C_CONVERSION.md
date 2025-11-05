# Zig to C Conversion Guide

## Overview

This document tracks the conversion of the Elba programming language compiler from Zig to C. This is a major undertaking involving the conversion of approximately 11,000 lines of code across 16 Zig source files.

## Progress Status

### Completed (~5,000 lines converted - 45%)

1. **Build System** - Makefile with proper C11 compilation
2. **Common Utilities** (src/common.c/.h) - Memory management, dynamic arrays, slices, error handling
3. **Lexer** (src/frontend/lexer.c/.h) - Complete tokenization with all Elba keywords and operators
4. **AST** (src/frontend/ast.c/.h) - Full abstract syntax tree with types, values, expressions, and statements
5. **Parser** (src/frontend/parser.c/.h) - Parse tokens into AST with precedence climbing for expressions
6. **Error Reporter** (src/utils/error_reporter.c/.h) - Source error reporting with context
7. **Main Entry Point** (src/main.c) - CLI with version/help/demo modes

### Pending Conversion (~6,000 lines remaining - 55%)

1. **Build System**
   - Created Makefile replacing build.zig
   - Configured GCC build with proper flags
   - Set up directory structure (build/, bin/, obj/)

2. **Common Utilities** (`src/common.c/.h`)
   - Arena allocator (similar to Zig's arena)
   - Dynamic array implementation (similar to ArrayList)
   - String slice type (replacing Zig slices)
   - Error handling types and functions

3. **Lexer** (`src/frontend/lexer.c/.h`)
   - Complete token type definitions
   - Full lexer implementation
   - Keyword identification
   - Number and float parsing
   - String literal support
   - All operators and punctuation
   - Token location tracking

4. **AST** (`src/frontend/ast.c/.h`)
   - Complete type system (int, float, string, bool, user types, generics, arrays, optionals, unions)
   - Value system (all value types)
   - Expression system (literals, variables, binary/unary ops, blocks, if/while/for, functions, structs, arrays, etc.)
   - Statement system (declarations, functions, structs, type aliases, imports, returns)
   - Memory management functions (create/free for all AST nodes)
   - Type equality and numeric checks

5. **Parser** (`src/frontend/parser.c/.h`)
   - Complete parser initialization and token management
   - Expression parsing with precedence climbing algorithm
   - Primary expressions (literals, variables, function calls, parenthesized)
   - Binary operators with correct precedence
   - Unary operators (negation, logical not)
   - Type annotation parsing (primitives, arrays, optionals, user types)
   - Statement parsing (const/let declarations, return, expression statements)
   - Error handling and reporting integration

6. **Error Reporter** (`src/utils/error_reporter.c/.h`)
   - Line/column calculation
   - Error message formatting
   - Source context display
   - Caret positioning under errors

7. **Main Entry Point** (`src/main.c`)
   - Basic CLI argument handling
   - Version and help commands
   - Demo/test mode for lexer, parser and error reporter
   - AST visualization for parsed statements
   - Basic CLI argument handling
   - Version and help commands
   - Demo/test mode for lexer and error reporter

### Pending Conversion 🔄

The following components still need to be converted from Zig to C:

#### Frontend Components
- [x] **Parser** (1,623 lines) - Parse tokens into AST
- [x] **AST** (320 lines) - Abstract syntax tree definitions
- [ ] **Typechecker** (1,751 lines) - Type checking and inference

#### Backend Components
- [ ] **Interpreter** (1,138 lines) - AST interpreter
- [ ] **IR** (410 lines) - Intermediate representation structures
- [ ] **IR Generator** (601 lines) - Convert AST to IR
- [ ] **IR Optimizer** (418 lines) - Optimize IR
- [ ] **IR Interpreter** (584 lines) - Execute IR
- [ ] **LLVM Codegen** (1,004 lines) - Generate LLVM IR

#### Codegen Components
- [ ] **C Codegen** (1,375 lines) - Generate C code from AST/IR

#### Utility Components
- [ ] **CLI** (262 lines) - Command-line interface
- [ ] **REPL** (198 lines) - Read-eval-print loop
- [ ] **Benchmark** (267 lines) - Performance testing

## Conversion Patterns

### Memory Management

**Zig:**
```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();
const data = try allocator.alloc(u8, 100);
```

**C:**
```c
Arena* arena = arena_create(1024);
void* data = arena_alloc(arena, 100);
// ... use data ...
arena_free(arena);
```

### Error Handling

**Zig:**
```zig
fn doSomething() !void {
    return error.SomethingFailed;
}
const result = try doSomething();
```

**C:**
```c
Error doSomething(void) {
    return error_new(ERR_SOMETHING_FAILED, "Something failed");
}
Error result = doSomething();
if (!error_is_ok(result)) {
    // handle error
}
```

### Slices

**Zig:**
```zig
const slice: []const u8 = "hello";
const len = slice.len;
```

**C:**
```c
Slice slice = slice_from_cstr("hello");
size_t len = slice.length;
```

### Dynamic Arrays

**Zig:**
```zig
var list = std.ArrayList(i32).init(allocator);
try list.append(42);
const item = list.items[0];
```

**C:**
```c
DynamicArray* list = dyn_array_create(sizeof(int32_t));
int32_t value = 42;
dyn_array_append(list, &value);
int32_t* item = (int32_t*)dyn_array_get(list, 0);
```

### Defer Statements

**Zig:**
```zig
const file = try std.fs.cwd().openFile(path, .{});
defer file.close();
// use file
```

**C:**
```c
FILE* file = fopen(path, "r");
if (!file) return error_new(ERR_FILE_NOT_FOUND, "Cannot open file");
// use file
fclose(file);
```

## Building

### C Version (Current)
```bash
make              # Build
make clean        # Clean build artifacts
./bin/elba --version
./bin/elba test   # Run lexer demo
```

### Zig Version (Original)
```bash
zig build         # Build
./zig-out/bin/elba --version
```

## Testing Strategy

1. **Unit Testing**: Each converted module should maintain the same behavior
2. **Integration Testing**: Use existing .elba example files
3. **Comparison Testing**: Run both Zig and C versions side-by-side during transition
4. **Performance Testing**: Benchmark critical paths

## Key Challenges

### 1. Generic Programming
Zig's compile-time generics need to be replaced with:
- C macros for simple cases
- Code generation for complex cases
- Manual specialization for performance-critical code

### 2. Comptime Features
Zig's comptime features used for:
- Type reflection → Manual implementation
- Compile-time computations → Runtime or preprocessor
- Generic instantiation → Manual or code generation

### 3. Optional Types
Zig: `?T`
C: Struct with `has_value` flag + value field

### 4. Error Unions
Zig: `!T`
C: Return `Error`, pass result via pointer parameter

### 5. Tagged Unions
Zig: Built-in tagged unions
C: Struct with tag enum + union

## Dependencies

- **C Compiler**: GCC 7.0+ or Clang 6.0+
- **Standard Library**: C11
- **LLVM** (optional): For LLVM backend
- **Make**: GNU Make 3.82+

## File Structure

```
/home/runner/work/elba/elba/
├── Makefile                    # New C build system
├── build.zig                   # Original Zig build system
├── src/
│   ├── main.c                  # ✅ C entry point
│   ├── main.zig                # Original Zig entry point
│   ├── common.h/.c             # ✅ Common utilities
│   ├── frontend/
│   │   ├── lexer.h/.c          # ✅ Lexer (converted)
│   │   ├── lexer.zig           # Original Zig lexer
│   │   ├── parser.c/.h         # 🔄 TODO
│   │   ├── parser.zig          # Original
│   │   ├── ast.c/.h            # 🔄 TODO
│   │   ├── ast.zig             # Original
│   │   ├── typechecker.c/.h    # 🔄 TODO
│   │   └── typechecker.zig     # Original
│   ├── backend/
│   │   └── ...                 # 🔄 All TODO
│   ├── codegen/
│   │   └── ...                 # 🔄 All TODO
│   └── utils/
│       ├── error_reporter.h/.c # ✅ Converted
│       ├── error_reporter.zig  # Original
│       └── ...                 # 🔄 Others TODO
└── bin/
    └── elba                    # ✅ C executable
```

## Next Steps

1. **Convert Parser** - Most critical next component
   - Define AST structures in C
   - Port parser logic from Zig
   - Maintain compatibility with existing .elba files

2. **Convert AST** - Required for parser
   - Define all node types
   - Implement visitor pattern if needed
   - Memory management for tree structures

3. **Continue with remaining components** in dependency order

## Notes

- Both Zig and C versions can coexist during transition
- Original Zig files are kept for reference
- Each C module is fully functional before moving to next
- Testing against original behavior at each step

## Contributors

This conversion is a community effort. See CONTRIBUTING.md for guidelines.
