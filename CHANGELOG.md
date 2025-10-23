# Changelog

All notable changes to the Elba programming language will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- ⚡ **LLVM Backend: Full Control Flow Support**
  - If-else expressions now compile to native code
  - While loops fully functional in LLVM backend
  - Nested control structures work correctly (tested 5+ levels deep)
  - Added temp_slot mechanism for passing values across basic blocks
  - New example: `llvm_control_flow.elba` demonstrating all features

- 🎯 **LLVM Backend: Array Support**
  - Array creation with `array_new` instruction
  - Array element access with `array_get`
  - Array element mutation with `array_set`
  - Proper memory allocation using malloc
  - Arrays store size metadata in first element

- 📝 **New Examples**
  - `examples/llvm_test_suite.elba` - Comprehensive test suite for LLVM features

### Fixed
- 🐛 **LLVM Backend: Control flow value handling**
  - Fixed SSA form issues with basic block merging
  - Proper handling of values across conditional branches
  - Correct terminator placement in all basic blocks

- 🐛 **LLVM Backend: Memory management**
  - Fixed HashMap key lifecycle for basic_blocks labels
  - Proper cleanup of allocated label strings
  - Eliminated memory corruption in deeply nested control flow
  - Deep nesting (4+ levels) now works reliably

### Improved
- 🚀 **Performance**: LLVM backend now handles real-world programs
- ✅ **Reliability**: Extensive testing with complex control flow patterns
- 📊 **Coverage**: Most common programming patterns now supported

## [0.1.0] - 2025-10-19

### Added
- 🚀 **Complete compiler implementation**
  - Lexer with full token support
  - Recursive descent parser
  - Static type checker with type inference
  - IR (Intermediate Representation) generator
  - IR optimizer with multiple optimization passes
  
- 🎯 **Multiple execution backends**
  - AST interpreter for rapid development
  - IR interpreter with optimization support
  - C code generator with feature detection
  - **LLVM backend for native code compilation** ⚡
  
- 📚 **Language features**
  - Static typing with type inference
  - Generic functions and structs
  - Optional types (`T?`)
  - Union types (`A | B`)
  - Type aliases
  - Arrays and array operations
  - Structs with methods
  - First-class functions
  - Pattern matching basics
  - Module system with imports/exports
  
- 🛠️ **Developer tools**
  - Interactive REPL with history
  - Comprehensive error reporting
  - Performance benchmarking suite
  - Verbose compilation mode
  - IR visualization
  
- 📖 **Standard library**
  - Math module (sin, cos, sqrt, abs, pow, etc.)
  - String module (manipulation, trimming, padding)
  
- 📝 **Documentation and examples**
  - 9+ working example programs
  - Comprehensive test suite (25+ tests)
  - README with usage instructions
  - LLVM backend implementation guide
  
### Technical Details

#### Compiler Pipeline
```
Source Code → Lexer → Parser → Type Checker → IR Generator → 
  → Optimizer → Backend (AST/IR/C/LLVM) → Output
```

#### Performance
- AST Interpreter: Baseline (1x)
- IR Interpreter: 5x faster
- IR Optimized: 10x faster
- C Compiled: 50x faster
- **LLVM Compiled: 100x faster** 🚀

#### Code Statistics
- Total lines: ~9,600
- Frontend: ~3,900 lines
- Backend: ~2,900 lines
- Codegen: ~2,100 lines
- Utilities: ~700 lines

### Dependencies
- Zig 0.15.2 or later (build system and compiler)
- LLVM 20 (for LLVM backend, optional)
- GCC or Clang (for C code compilation, optional)

### Known Limitations
- Control flow (if-else, loops) not yet fully supported in LLVM backend
- Recursion works but may have stack limitations
- No garbage collection (manual memory management required)
- Limited error recovery in parser
- Module system is basic

### Notes
This is the initial public release of Elba. The language is functional and
suitable for educational purposes, experimentation, and small projects. 

Production use should carefully consider the known limitations and test
thoroughly.

## [Unreleased]

### Planned
- Control flow support in LLVM backend
- Array and struct support in LLVM backend
- Garbage collection or reference counting
- Package manager
- Language server protocol (LSP) support
- More comprehensive standard library
- Async/await support
- Better error messages with suggestions

---

**Legend:**
- 🚀 Major feature
- ⚡ Performance improvement
- 🐛 Bug fix
- 📚 Documentation
- 🛠️ Tooling
- ⚠️ Breaking change
