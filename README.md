# 🚀 Elba Programming Language

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
- 🛡️ **Explicit Optional Values** - Optional and union types make nullable state visible in signatures
- 🔧 **Modern Tooling** - Interactive REPL, error reporting, benchmarks
- 📦 **Module System** - Organize code effectively

## ✨ Features

### Language Features
- ✅ Static type checking with type inference
- ✅ Generic functions and structs with type parameters
- ✅ Optional types (`T?`) for null safety
- ✅ Union types (`A | B | C`)
- ✅ Type aliases for better code documentation
- ✅ Functions, recursion, and generic calls
- ✅ Checked 64-bit integer arithmetic and exact integer exponentiation
- ✅ Arrays with indexing, mutation, iteration, and functional helpers
- ✅ Structs with methods and typed scalar fields across native backends
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
- 📐 **Math Support** - Numeric helpers plus a source-level math module
- 📝 **String Support** - Concatenation, slicing, splitting, trimming, search, padding, and repetition

## 🚀 Installation

### Prerequisites
- **Zig 0.15.2** or later ([Download](https://ziglang.org/download/))
- **LLVM 22** for the currently linked compiler backend
- (Optional) **GCC or Clang** for C code compilation

### Building from Source

```bash
# Clone the repository
git clone https://github.com/powencu/elba.git
cd elba

# Build the compiler
zig build

# Verify installation
./zig-out/bin/elba --version
```

### Quick Test

```bash
# Run an example
./zig-out/bin/elba examples/hello_world.elba

# Start the REPL
./zig-out/bin/elba repl

# Run the test suite
powershell -ExecutionPolicy Bypass -File "run_tests.ps1"

# Check exact AST, IR, C, and LLVM output parity
powershell -ExecutionPolicy Bypass -File "verify_examples.ps1"

# Check expected failures across every backend
powershell -ExecutionPolicy Bypass -File "verify_failures.ps1"
```

## 🔧 Developer Tools

**New in this release:**

- **Test Runner** (`run_tests.ps1`) - Automated test suite with reporting
- **Backend Parity Runner** (`verify_examples.ps1`) - Exact example-output comparison across AST, IR, C, and LLVM
- **Failure Parity Runner** (`verify_failures.ps1`) - Expected compile/runtime failure checks across AST, IR, C, and LLVM
- **Benchmark Tool** (`benchmark_examples.ps1`) - Performance measurement
- **Development Guide** (`DEVELOPMENT.md`) - Architecture and contribution guide
- **Language Status** (`LANGUAGE_STATUS.md`) - Verified features and explicitly tracked implementation gaps
- **Improvements Document** (`IMPROVEMENTS.md`) - Recent enhancements and roadmap

## 📊 Quick Start

See full documentation in [CONTRIBUTING.md](CONTRIBUTING.md) and examples in the `examples/` directory.
`examples/aggregate_floats.elba` is the focused reference for float arrays, struct fields, methods, and generic scalar/array results across every backend.
`examples/checked_arithmetic.elba` covers exact integer power and signed endpoint behavior.
`examples/tagged_values.elba` covers zero-bit optional payloads, union type identity, and aggregate payload equality.
`examples/optional_operations.elba` demonstrates explicit `value!` unwrap and lazy `value ?? fallback` coalescing.
`examples/match_expr.elba` covers signed numeric patterns, dynamic string matching, and exhaustive boolean and full-domain integer matches.
`examples/contextual_arrays.elba` demonstrates empty and nested array literals in every expected-type position.
The array and struct examples include recursive structural equality across independently allocated values; `arrays.elba` also demonstrates nested contextual empty arrays.

## 📜 License

Elba is released under the [MIT License](LICENSE).

---

<div align="center">

**Made with ❤️ by the Elba Community**

</div>
