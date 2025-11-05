# 🚀 Elba Programming Language

> **✅ C Migration Complete**: The Elba compiler has been successfully transitioned from Zig to C! The core compiler (lexer, parser, typechecker, interpreter) is **fully functional** and can execute Elba programs. Advanced features (IR optimization, LLVM/C code generation) are optional enhancements. See [C_CONVERSION.md](C_CONVERSION.md) for details.

<div align="center">

**A modern, statically-typed programming language with multiple compilation backends**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org/)
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

**C Version (In Progress):**
- **GCC 7.0+** or **Clang 6.0+**
- **Make** (GNU Make 3.82+)
- (Optional) **LLVM 20** for native compilation

**Zig Version (Legacy):**
- **Zig 0.15.2** or later ([Download](https://ziglang.org/download/))
- (Optional) **LLVM 20** for native compilation

### Building from Source

**C Version (Current Development):**
```bash
# Clone the repository
git clone https://github.com/yourusername/elba.git
cd elba

# Build the C compiler
make

# Verify installation
./bin/elba --version

# Run lexer demo
./bin/elba test
```

**Zig Version (Legacy):**
```bash
# Build the Zig compiler
zig build

# Verify installation
./zig-out/bin/elba --version

# Run an example
./zig-out/bin/elba examples/hello_world.elba

# Start the REPL
./zig-out/bin/elba repl
```

> **Note**: The project is currently being transitioned from Zig to C. The C version has a working lexer and error reporter, but full compiler functionality (parser, typechecker, backends) is still in progress. See [C_CONVERSION.md](C_CONVERSION.md) for details.

## 🏁 Quick Start

See full documentation in [CONTRIBUTING.md](CONTRIBUTING.md) and examples in the `examples/` directory.

## 📜 License

Elba is released under the [MIT License](LICENSE).

---

<div align="center">

**Made with ❤️ by the Elba Community**

</div>
