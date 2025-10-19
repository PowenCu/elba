# Contributing to Elba

Thank you for your interest in contributing to Elba! This document provides guidelines and instructions for contributing to the project.

## Table of Contents
- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [How to Contribute](#how-to-contribute)
- [Code Style](#code-style)
- [Testing](#testing)
- [Pull Request Process](#pull-request-process)

## Code of Conduct

### Our Pledge
We are committed to providing a welcoming and inspiring community for all. Please be respectful and constructive in all interactions.

### Expected Behavior
- Use welcoming and inclusive language
- Be respectful of differing viewpoints and experiences
- Gracefully accept constructive criticism
- Focus on what is best for the community
- Show empathy towards other community members

## Getting Started

### Prerequisites
- Zig 0.15.2 or later
- Git
- (Optional) LLVM 20 for LLVM backend
- (Optional) GCC or Clang for C compilation

### Building from Source
```bash
git clone https://github.com/yourusername/elba.git
cd elba
zig build
```

### Running Tests
```bash
# Run all examples
./zig-out/bin/elba examples/hello_world.elba

# Run with different backends
./zig-out/bin/elba --compile --run-ir examples/fibonacci.elba
./zig-out/bin/elba --compile --compile-c examples/arrays.elba
./zig-out/bin/elba --compile --compile-llvm examples/llvm_demo.elba
```

## Development Setup

### Project Structure
```
elba/
├── src/
│   ├── main.zig              # Entry point
│   ├── frontend/             # Lexer, parser, type checker
│   ├── backend/              # Interpreters, IR, optimizers
│   ├── codegen/              # C and LLVM code generators
│   └── utils/                # CLI, REPL, error reporting
├── std/                      # Standard library
├── examples/                 # Example programs
├── tests/                    # Test suite
└── build.zig                 # Build configuration
```

### Key Components
1. **Frontend**: Lexer → Parser → Type Checker → AST
2. **IR Layer**: IR Generator → Optimizer → IR
3. **Backends**: AST Interpreter, IR Interpreter, C Codegen, LLVM Codegen

## How to Contribute

### Reporting Bugs
1. Check if the bug has already been reported in Issues
2. If not, create a new issue with:
   - Clear, descriptive title
   - Steps to reproduce
   - Expected vs actual behavior
   - Elba version and environment details
   - Minimal code example demonstrating the issue

### Suggesting Features
1. Check if the feature has been suggested in Issues
2. Create a new issue tagged with `enhancement`
3. Explain:
   - The problem you're trying to solve
   - Your proposed solution
   - Alternative solutions considered
   - How it benefits Elba users

### Submitting Code

#### Areas We Need Help
- 🐛 Bug fixes
- ✨ New language features
- 📚 Documentation improvements
- 🧪 Test coverage
- ⚡ Performance optimizations
- 🛠️ Developer tools
- 📦 Standard library expansion

#### Good First Issues
Look for issues tagged with `good first issue` - these are ideal for newcomers.

## Code Style

### Zig Code Style
Follow the Zig style guide:
```zig
// Good
const MyStruct = struct {
    field_name: i32,
    
    pub fn init(allocator: std.mem.Allocator) !MyStruct {
        return MyStruct{
            .field_name = 0,
        };
    }
};

// Use descriptive names
fn calculateFibonacci(n: i32) i32 {
    // Implementation
}

// Add comments for complex logic
fn optimizeIR(program: *Program) !void {
    // First pass: constant folding
    // Second pass: dead code elimination
}
```

### Elba Code Style
```elba
// Functions: camelCase
fn calculateSum(a: int, b: int) -> int {
    a + b
}

// Types: PascalCase
struct Person {
    name: str;
    age: int;
}

// Constants: snake_case or camelCase
const MAX_SIZE: int = 100;
const defaultName: str = "Unknown";
```

### Formatting
- Run `zig fmt` before committing Zig code
- Use 4 spaces for indentation
- Keep lines under 100 characters when reasonable
- Add blank lines between logical sections

## Testing

### Running Tests
```bash
# Test AST interpreter
./zig-out/bin/elba tests/test_functions.elba

# Test IR interpreter
./zig-out/bin/elba --compile --run-ir tests/test_arrays.elba

# Test C codegen
./zig-out/bin/elba --compile --compile-c tests/test_loops.elba

# Test LLVM backend
./zig-out/bin/elba --compile --compile-llvm examples/llvm_demo.elba
```

### Writing Tests
Add test files to the `tests/` directory:
```elba
// tests/test_new_feature.elba
// Test description
println("Testing new feature...");

const result: int = newFeature(42);
assert(result == 84, "newFeature should double the input");

println("✓ All tests passed!");
```

### Test Coverage
Aim to test:
- ✅ Normal cases
- ✅ Edge cases
- ✅ Error conditions
- ✅ Integration with existing features

## Pull Request Process

### Before Submitting
1. ✅ Code builds successfully (`zig build`)
2. ✅ All existing tests pass
3. ✅ New tests added for new features
4. ✅ Code formatted (`zig fmt`)
5. ✅ Documentation updated
6. ✅ CHANGELOG.md updated

### PR Description Template
```markdown
## Description
Brief description of changes

## Motivation
Why is this change needed?

## Changes
- Added/Changed/Fixed X
- Added/Changed/Fixed Y

## Testing
How was this tested?

## Checklist
- [ ] Code builds
- [ ] Tests pass
- [ ] Documentation updated
- [ ] CHANGELOG updated
```

### Review Process
1. Submit PR with clear description
2. Automated checks run (if configured)
3. Maintainer reviews code
4. Address feedback
5. PR merged when approved

### Commit Messages
Use clear, descriptive commit messages:
```
Good:
- "Add LLVM backend support for user-defined functions"
- "Fix type inference for generic functions"
- "Improve error messages for undefined variables"

Bad:
- "fix bug"
- "update code"
- "changes"
```

## Development Tips

### Debugging
```bash
# Show AST
./zig-out/bin/elba --ast program.elba

# Show IR
./zig-out/bin/elba --compile --show-ir program.elba

# Verbose mode
./zig-out/bin/elba --verbose program.elba

# REPL for quick testing
./zig-out/bin/elba repl
```

### Performance Profiling
```bash
# Benchmark
./zig-out/bin/elba benchmark
```

### Adding New IR Instructions
1. Add to `Opcode` enum in `src/backend/ir.zig`
2. Handle in `IrGenerator` in `src/backend/ir_gen.zig`
3. Implement in `Interpreter` in `src/backend/ir_interpreter.zig`
4. (Optional) Add to LLVM codegen in `src/backend/llvm_codegen.zig`
5. (Optional) Add to C codegen in `src/codegen/c_codegen.zig`

### Adding New Language Features
1. Update lexer (if new tokens needed)
2. Update parser
3. Update type checker
4. Update IR generator
5. Add tests
6. Update documentation

## Questions?

- 💬 Open a GitHub Discussion
- 📧 Email: [maintainer email]
- 🐛 Report bugs in Issues

## Recognition

Contributors will be:
- Listed in CONTRIBUTORS.md
- Mentioned in release notes
- Credited in documentation

Thank you for helping make Elba better! 🚀
