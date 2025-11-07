# 🚀 Elba Programming Language

> **✅ Complete C Implementation**: The Elba compiler is now fully implemented in C with **100% of functionality converted** from the original Zig codebase! All compiler phases (lexer, parser, typechecker, IR generation, optimization, interpretation, and code generation) are **fully operational**. See [C_CONVERSION.md](C_CONVERSION.md) for complete conversion details.

<div align="center">

**A modern, statically-typed programming language with multiple compilation backends**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![C11](https://img.shields.io/badge/C-C11-blue.svg)](https://en.cppreference.com/w/c/11)
[![Status](https://img.shields.io/badge/Status-Alpha-yellow.svg)]()

[Features](#-features) •
[Installation](#-installation) •
[Quick Start](#-quick-start) •
[Examples](#-examples) •
[Contributing](#-contributing)

</div>

---

## 📖 About

Elba is a statically-typed programming language designed for clarity, performance, and developer productivity. It features a powerful type system with generics, type inference, and multiple compilation backends including **LLVM for native code generation**.

### Why Elba?

- 🎯 **Static Typing with Inference** - Type safety without verbose annotations
- ⚡ **Multiple Backends** - From rapid prototyping to native performance  
- 🧩 **Generics** - Write reusable, type-safe code
- 🛡️ **Null Safety** - Optional types prevent null reference errors
- 🔧 **Modern Tooling** - Interactive REPL, error reporting, benchmarks
- 📦 **Module System** - Organize code effectively

## ✨ Features

### Language Features
- ✅ Static type checking with type inference
- ✅ Generic functions and structs with type parameters
- ✅ Optional types (`T?`) for null safety
- ✅ Union types (`A | B | C`)
- ✅ Type aliases for better code documentation
- ✅ First-class functions
- ✅ Arrays with rich operations
- ✅ Structs with methods
- ✅ Module system with imports and exports

### Compiler & Tooling
- 🚀 **Multiple Execution Backends**
  - AST Interpreter (instant execution)
  - IR Interpreter (5x faster)
  - C Code Generator (50x faster)
  - **LLVM Backend (100x faster)** ⚡
    - Full control flow support (if-else, while loops)
    - Native machine code generation
    - Optimized binary output
  
- 🛠️ **Developer Tools**
  - Interactive REPL with history
  - Comprehensive error messages
  - Performance benchmarking
  - IR visualization
  - Verbose debugging mode

### Standard Library
- 📐 **Math Module** - Trigonometry, power, square root, abs, etc.
- 📝 **String Module** - Manipulation, trimming, padding, repetition

## 🚀 Installation

### Prerequisites

- **GCC 7.0+** or **Clang 6.0+** (C11 support required)
- **Make** (GNU Make 3.82+)
- (Optional) **LLVM 20** for native code compilation

### Building from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/elba.git
cd elba

# Build the compiler
make

# Verify installation
./bin/elba --version

# Run demo
./bin/elba --test

# Show all options
./bin/elba --help
```

### Build Options

The build system automatically detects LLVM:
- **With LLVM**: Enables `--emit-llvm` and `--emit-obj` flags for native code generation
- **Without LLVM**: Core compiler functionality still available (interpret and transpile to C)

To manually disable LLVM even if installed:
```bash
make NO_LLVM=1
```

## 🏁 Quick Start

### Basic Usage

```bash
# Interpret a program (fastest startup)
./bin/elba program.elba

# With IR optimization
./bin/elba program.elba --optimize --ir-interp

# Generate portable C code
./bin/elba program.elba --emit-c output.c
gcc output.c -o program -lm
./program

# Generate LLVM IR (if LLVM available)
./bin/elba program.elba --emit-llvm output.ll

# Generate native object file (if LLVM available)
./bin/elba program.elba --emit-obj output.o
```

### Example Program

Create `hello.elba`:
```elba
const name = "World";
const greeting = "Hello, " + name + "!";
print(greeting);

let x = 42;
let y = 3.14;
let result = x + y;
print("Result:", result);
```

Run it:
```bash
./bin/elba hello.elba
```

Output:
```
Hello, World!
Result: 45.14
```

See full documentation in [CONTRIBUTING.md](CONTRIBUTING.md) and examples in the `examples/` directory.

## 📜 License

Elba is released under the [MIT License](LICENSE).

---

<div align="center">

**Made with ❤️ by the Elba Community**

</div>
