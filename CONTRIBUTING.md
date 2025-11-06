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
- GCC 7.0+ or Clang 6.0+ (C11 support required)
- Make (GNU Make 3.82+)
- Git
- (Optional) LLVM 20 for native code generation

### Building from Source
```bash
git clone https://github.com/yourusername/elba.git
cd elba
make
```

### Running Tests
```bash
# Run demo mode
./bin/elba --test

# Test with different execution modes
./bin/elba --test --optimize --ir-interp

# Test code generation
./bin/elba --test --emit-c output.c
./bin/elba --test --show-ir
```

## Development Setup

### Project Structure
```
elba/
├── src/
│   ├── main.c                 # Entry point
│   ├── common.{c,h}           # Shared utilities (arena, arrays, HashMap)
│   ├── frontend/              # Lexer, parser, type checker, AST
│   ├── backend/               # Interpreters, IR, optimizers, LLVM codegen
│   ├── codegen/               # C code generator
│   └── utils/                 # Error reporting
├── std/                       # Standard library (Elba files)
├── examples/                  # Example programs
├── tests/                     # Test suite
└── Makefile                   # Build configuration
```

### Key Components
1. **Frontend**: Lexer → Parser → Type Checker → AST
2. **IR Layer**: IR Generator → Optimizer → IR
3. **Backends**: AST Interpreter, IR Interpreter, C Codegen, LLVM Codegen (optional)

### Build System
The Makefile automatically detects LLVM:
- If LLVM is found via `llvm-config`, it enables LLVM codegen features
- Otherwise, builds core compiler without LLVM support
- All C files use C11 standard with `-Wall -Wextra` warnings

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

### C Code Style
Follow standard C11 conventions with these guidelines:

```c
// Use clear, descriptive names
typedef struct {
    int field_name;
    char* data;
} MyStruct;

// Function declarations with proper spacing
MyStruct* my_struct_create(Arena* arena, int value) {
    MyStruct* s = arena_alloc(arena, sizeof(MyStruct));
    s->field_name = value;
    s->data = NULL;
    return s;
}

// Use snake_case for functions and variables
int calculate_fibonacci(int n) {
    // Implementation
}

// Add comments for complex logic
void optimize_ir(IRProgram* program) {
    // First pass: constant folding
    // Second pass: dead code elimination
}

// Always check allocations and handle errors
void* ptr = malloc(size);
if (!ptr) {
    fprintf(stderr, "Memory allocation failed\n");
    return;
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
- Use 4 spaces for indentation (no tabs)
- Maximum line length: 100 characters
- Always use braces for control structures
- Run `make` to ensure code compiles without warnings
- Keep lines under 100 characters when reasonable
- Add blank lines between logical sections

## Testing

### Running Tests
```bash
# Test with demo mode
./bin/elba --test

# Test with optimization
./bin/elba --test --optimize --ir-interp

# Test code generation
./bin/elba --test --emit-c output.c

# Test a specific Elba program
./bin/elba examples/hello_world.elba

# Show IR for debugging
./bin/elba examples/fibonacci.elba --show-ir
```

### Writing Tests
Add test files to the `tests/` directory:
```elba
// tests/test_new_feature.elba
// Test description
print("Testing new feature...");

const result: int = newFeature(42);
// Add assertions as part of the test

print("✓ All tests passed!");
```

### Test Coverage
Aim to test:
- ✅ Normal cases
- ✅ Edge cases
- ✅ Error conditions
- ✅ Integration with existing features

## Pull Request Process

### Before Submitting
1. ✅ Code builds successfully (`make`)
2. ✅ All existing tests pass
3. ✅ New tests added for new features
4. ✅ Code compiles without warnings
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
# Show IR
./bin/elba program.elba --show-ir

# With optimization
./bin/elba program.elba --optimize --show-ir

# Generate C code to inspect
./bin/elba program.elba --emit-c output.c
cat output.c

# Test mode for quick validation
./bin/elba --test
```

### Adding New IR Instructions
1. Add to `IROpcode` enum in `src/backend/ir.h`
2. Handle in IR generator in `src/backend/ir_gen.c`
3. Implement in IR interpreter in `src/backend/ir_interp.c`
4. (Optional) Add to LLVM codegen in `src/backend/llvm_codegen.c`
5. (Optional) Add to C codegen in `src/codegen/c_codegen.c`
3. Implement in IR interpreter in `src/backend/ir_interp.c`
4. (Optional) Add to LLVM codegen in `src/backend/llvm_codegen.c`
5. (Optional) Add to C codegen in `src/codegen/c_codegen.c`

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
