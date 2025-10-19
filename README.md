# 🚀 Elba Programming Language# 🚀 Elba Programming Language# Elba Programming Language



<div align="center">



**A modern, statically-typed programming language with multiple compilation backends**<div align="center">A statically-typed programming language with generics, type inference, and a powerful module system.



[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org/)

[![Status](https://img.shields.io/badge/Status-Alpha-yellow.svg)]()**A modern, statically-typed programming language with multiple compilation backends**## Features



[Features](#-features) •

[Installation](#-installation) •

[Quick Start](#-quick-start) •[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)- ✅ **Static Type System** - Compile-time type checking with inference

[Examples](#-examples) •

[Contributing](#-contributing)[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org/)- ✅ **Generics** - Full support for generic functions and structs with type parameters



</div>[![Status](https://img.shields.io/badge/Status-Alpha-yellow.svg)]()- ✅ **Type Aliases** - Define custom type names for clarity



---- ✅ **Optional Types** - Built-in null safety with `T?` syntax



## 📖 About[Features](#-features) •- ✅ **Union Types** - Express values that can be one of multiple types



Elba is a statically-typed programming language designed for clarity, performance, and developer productivity. It features a powerful type system with generics, type inference, and multiple compilation backends including **LLVM for native code generation**.[Installation](#-installation) •- ✅ **Module System** - Organize code with imports and exports



### Why Elba?[Quick Start](#-quick-start) •- ✅ **REPL Mode** - Interactive programming environment



- 🎯 **Static Typing with Inference** - Type safety without verbose annotations[Examples](#-examples) •- ✅ **Standard Library** - Built-in functions for common tasks

- ⚡ **Multiple Backends** - From rapid prototyping to native performance  

- 🧩 **Generics** - Write reusable, type-safe code[Contributing](#-contributing)- ✅ **IR Optimization** - Intermediate representation with optimization passes

- 🛡️ **Null Safety** - Optional types prevent null reference errors

- 🔧 **Modern Tooling** - Interactive REPL, error reporting, benchmarks- ✅ **C Code Generation** - Compile to optimized C code

- 📦 **Module System** - Organize code effectively

</div>- ✅ **LLVM Backend** - Compile to native machine code via LLVM

## ✨ Features

- ✅ **Multiple Backends** - AST interpreter, IR interpreter, C code, or LLVM

### Language Features

- ✅ Static type checking with type inference---

- ✅ Generic functions and structs with type parameters

- ✅ Optional types (`T?`) for null safety## Quick Start

- ✅ Union types (`A | B | C`)

- ✅ Type aliases for better code documentation## 📖 About

- ✅ First-class functions

- ✅ Arrays with rich operations### Installation

- ✅ Structs with methods

- ✅ Module system with imports and exportsElba is a statically-typed programming language designed for clarity, performance, and developer productivity. It features a powerful type system with generics, type inference, and multiple compilation backends including **LLVM for native code generation**.



### Compiler & ToolingRequires Zig 0.15.2 or later.

- 🚀 **Multiple Execution Backends**

  - AST Interpreter (instant execution)### Why Elba?

  - IR Interpreter (5x faster)

  - C Code Generator (50x faster)```bash

  - **LLVM Backend (100x faster)** ⚡

  - 🎯 **Static Typing with Inference** - Type safety without verbose annotations# Clone the repository

- 🛠️ **Developer Tools**

  - Interactive REPL with history- ⚡ **Multiple Backends** - From rapid prototyping to native performance  git clone https://github.com/yourusername/elba.git

  - Comprehensive error messages

  - Performance benchmarking- 🧩 **Generics** - Write reusable, type-safe codecd elba

  - IR visualization

  - Verbose debugging mode- 🛡️ **Null Safety** - Optional types prevent null reference errors



### Standard Library- 🔧 **Modern Tooling** - Interactive REPL, error reporting, benchmarks# Build the project

- 📐 **Math Module** - Trigonometry, power, square root, abs, etc.

- 📝 **String Module** - Manipulation, trimming, padding, repetition- 📦 **Module System** - Organize code effectivelyzig build



## 🚀 Installation



### Prerequisites## ✨ Features# Run the REPL

- **Zig 0.15.2** or later ([Download](https://ziglang.org/download/))

- (Optional) **LLVM 20** for native compilation./zig-out/bin/elba repl

- (Optional) **GCC or Clang** for C code compilation

### Language Features

### Building from Source

- ✅ Static type checking with type inference# Run a file

```bash

# Clone the repository- ✅ Generic functions and structs with type parameters./zig-out/bin/elba examples/hello_world.elba

git clone https://github.com/yourusername/elba.git

cd elba- ✅ Optional types (`T?`) for null safety```



# Build the compiler- ✅ Union types (`A | B | C`)

zig build

- ✅ Type aliases for better code documentation## Usage

# Verify installation

./zig-out/bin/elba --version- ✅ First-class functions

```

- ✅ Arrays with rich operations### Command Line Interface

### Quick Test

- ✅ Structs with methods

```bash

# Run an example- ✅ Module system with imports and exports```bash

./zig-out/bin/elba examples/hello_world.elba

# Show help

# Start the REPL

./zig-out/bin/elba repl### Compiler & Toolingelba --help

```

- 🚀 **Multiple Execution Backends**

## 🏁 Quick Start

  - AST Interpreter (instant execution)# Run a program (AST interpreter)

### Hello World

  - IR Interpreter (5x faster)elba program.elba

```elba

// hello_world.elba  - C Code Generator (50x faster)

println("Hello, World!");

```  - **LLVM Backend (100x faster)** ⚡# Run with IR interpreter



Run it:  elba --ir program.elba

```bash

./zig-out/bin/elba hello_world.elba- 🛠️ **Developer Tools**

```

  - Interactive REPL with history# Type check only (no execution)

### Functions and Types

  - Comprehensive error messageselba --check program.elba

```elba

// Calculate Fibonacci numbers  - Performance benchmarking

fn fibonacci(n: int) -> int {

    if (n <= 1) {  - IR visualization# Compile to C

        n

    } else {  - Verbose debugging modeelba --compile --emit-c program.elba

        fibonacci(n - 1) + fibonacci(n - 2)

    }# This generates program.c

}

### Standard Library

const result: int = fibonacci(10);

println(int_to_str(result));  // Output: 55- 📐 **Math Module** - Trigonometry, power, square root, abs, etc.# Compile to C and build executable (requires gcc)

```

- 📝 **String Module** - Manipulation, trimming, padding, repetitionelba --compile --compile-c program.elba

### Generics

# This generates program.c and program.exe

```elba

// Generic function## 🚀 Installation

fn identity<T>(x: T) -> T {

    x# Compile to LLVM IR

}

### Prerequisiteselba --compile --emit-llvm program.elba

// Generic struct

struct Box<T> {- **Zig 0.15.2** or later ([Download](https://ziglang.org/download/))# This generates program.ll

    value: T;

}- (Optional) **LLVM 20** for native compilation



const int_box: Box<int> = Box { value: 42; };- (Optional) **GCC or Clang** for C code compilation# Compile to native binary via LLVM (requires llc and gcc)

const str_box: Box<str> = Box { value: "Hello"; };

```elba --compile --compile-llvm program.elba



## 📚 Usage### Building from Source# This generates program.ll, program.o, and program.exe



### Command Line Interface



```bash```bash# Show IR (intermediate representation)

# Basic execution (AST Interpreter)

elba program.elba# Clone the repositoryelba --show-ir program.elba



# Type check onlygit clone https://github.com/yourusername/elba.git

elba --check program.elba

cd elba# Optimize and show IR

# Execute with IR interpreter (faster)

elba --compile --run-ir program.elbaelba --optimize --show-ir program.elba



# Compile to C# Build the compiler

elba --compile --emit-c program.elba       # Generates program.c

elba --compile --compile-c program.elba    # Generates and compiles to .exezig build# Start interactive REPL



# Compile to LLVM IRelba repl

elba --compile --emit-llvm program.elba    # Generates program.ll

elba --compile --compile-llvm program.elba # Compiles to native binary# Verify installation



# Optimization./zig-out/bin/elba --version# Show version

elba --compile -O --run-ir program.elba    # Run with optimizations

```elba --version

# Debugging

elba --verbose program.elba                # Verbose output```

elba --compile --show-ir program.elba      # Show IR representation

### Quick Test

# Interactive mode

elba repl                                   # Start REPL## Compilation Backends



# Benchmarking```bash

elba benchmark                              # Run performance tests

```# Run an exampleElba supports multiple execution backends:



### Compilation Backends Comparison./zig-out/bin/elba examples/hello_world.elba



| Backend | Speed | Compile Time | Use Case |### 1. AST Interpreter (Default)

|---------|-------|--------------|----------|

| **AST Interpreter** | 1x | Instant | Development, debugging |# Start the REPLFast startup, no compilation needed. Best for development and testing.

| **IR Interpreter** | 5x | Instant | Testing, prototyping |

| **IR Optimized** | 10x | Instant | Fast interpretation |./zig-out/bin/elba repl```bash

| **C Compiled** | 50x | ~1-2s | Production (portable) |

| **LLVM Compiled** | 100x | ~0.5s | Production (native) |```elba program.elba



### Interactive REPL```



```bash## 🏁 Quick Start

$ elba repl

Elba REPL v0.1.0### 2. IR Interpreter

Type 'help' for help, 'exit' to quit

### Hello WorldOptimized intermediate representation. Good balance of speed and startup time.

>>> const x: int = 42

>>> const y: int = x * 2```bash

>>> println(int_to_str(y))

84```elbaelba --ir program.elba

>>> fn double(n: int) -> int { n * 2 }

>>> double(21)// hello_world.elba```

42

```println("Hello, World!");



## 💡 Examples```### 3. C Code Generation



### Arrays and LoopsCompiles to C code for maximum portability. Requires GCC.



```elbaRun it:```bash

const numbers: []int = [1, 2, 3, 4, 5];

```bash# Generate C code only

let sum: int = 0;

for (num in numbers) {./zig-out/bin/elba hello_world.elbaelba --compile --emit-c program.elba  # Creates program.c

    sum = sum + num;

}```



println(int_to_str(sum));  // Output: 15# Compile to executable

```

### Functions and Typeselba --compile --compile-c program.elba  # Creates program.exe

### Structs

```

```elba

struct Point {```elba

    x: int;

    y: int;// Calculate Fibonacci numbers### 4. LLVM Native Compilation ⚡

}

fn fibonacci(n: int) -> int {Compiles directly to native machine code via LLVM. Best performance!

const p1: Point = Point { x: 0; y: 0; };

const p2: Point = Point { x: 3; y: 4; };    if (n <= 1) {Requires LLVM tools (`llc`) and GCC.

```

        n```bash

### Module System

    } else {# Generate LLVM IR only

```elba

// math_utils.elba        fibonacci(n - 1) + fibonacci(n - 2)elba --compile --emit-llvm program.elba  # Creates program.ll

export fn square(x: int) -> int {

    x * x    }

}

}# Compile to native executable

// main.elba

import "math_utils" as math;elba --compile --compile-llvm program.elba  # Creates program.exe



const result: int = math.square(5);const result: int = fibonacci(10);```

println(int_to_str(result));  // Output: 25

```println(int_to_str(result));  // Output: 55



### More Examples```**Performance Comparison:**



Check out the `examples/` directory:- AST Interpreter: ~1x (baseline)

- `hello_world.elba` - Basic hello world

- `fibonacci.elba` - Recursive Fibonacci### Generics- IR Interpreter: ~5x faster

- `arrays.elba` - Array operations

- `generics.elba` - Generic programming- C Compiled: ~50x faster

- `structs.elba` - Struct usage

- `llvm_demo.elba` - LLVM backend demonstration```elba- LLVM Compiled: ~100x faster

- And more!

// Generic function

## 🏗️ Architecture

fn identity<T>(x: T) -> T {### Hello World

```

Source Code → Lexer → Parser → Type Checker → IR Generator →     x

  → Optimizer → Backend (AST/IR/C/LLVM) → Output

```}```elba



## 🧪 Testing// hello_world.elba



```bash// Generic structprintln("Hello, World!");

# Run examples

./zig-out/bin/elba examples/fibonacci.elbastruct Box<T> {```



# Run tests    value: T;

./zig-out/bin/elba tests/test_functions.elba

```}### Variables and Types



## 🤝 Contributing



We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.const int_box: Box<int> = Box { value: 42; };```elba



## 📊 Project Statusconst str_box: Box<str> = Box { value: "Hello"; };// Constant declaration



**Current Version:** 0.1.0 (Alpha)```const x: int = 42;



### What Worksconst message: str = "Hello";

- ✅ Core language features

- ✅ Type system with generics## 📚 Usage

- ✅ Multiple backends (AST, IR, C, LLVM)

- ✅ REPL and tooling// Mutable variables

- ✅ Standard library basics

### Command Line Interfacelet counter: int = 0;

### Known Limitations

- ⚠️ Control flow limited in LLVM backendcounter = counter + 1;

- ⚠️ No garbage collection yet

- ⚠️ Module system is basic```bash

- ⚠️ Standard library needs expansion

# Basic execution (AST Interpreter)// Type inference

## 📜 License

elba program.elbaconst y = 10;  // inferred as int

Elba is released under the [MIT License](LICENSE).

const name = "Alice";  // inferred as str

## 🙏 Acknowledgments

# Type check only```

- Built with [Zig](https://ziglang.org/)

- Powered by [LLVM](https://llvm.org/)elba --check program.elba

- Inspired by Rust, TypeScript, and ML-family languages

### Functions

---

# Execute with IR interpreter (faster)

<div align="center">

elba --compile --run-ir program.elba```elba

**Made with ❤️ by the Elba Community**

// Function definition

[⬆ Back to top](#-elba-programming-language)

# Compile to Cfn add(a: int, b: int) -> int {

</div>

elba --compile --emit-c program.elba       # Generates program.c    a + b

elba --compile --compile-c program.elba    # Generates and compiles to .exe}



# Compile to LLVM IR// Generic function

elba --compile --emit-llvm program.elba    # Generates program.llfn identity<T>(x: T) -> T {

elba --compile --compile-llvm program.elba # Compiles to native binary    x

}

# Optimization

elba --compile -O --run-ir program.elba    # Run with optimizations// Calling functions

const sum = add(5, 3);

# Debuggingconst value = identity<int>(42);

elba --verbose program.elba                # Verbose output```

elba --compile --show-ir program.elba      # Show IR representation

### Structs

# Interactive mode

elba repl                                   # Start REPL```elba

// Struct definition

# Benchmarkingstruct Point {

elba benchmark                              # Run performance tests    x: int;

```    y: int;

}

### Compilation Backends Comparison

// Struct with methods

| Backend | Speed | Compile Time | Use Case |struct Rectangle {

|---------|-------|--------------|----------|    width: int;

| **AST Interpreter** | 1x | Instant | Development, debugging |    height: int;

| **IR Interpreter** | 5x | Instant | Testing, prototyping |    

| **IR Optimized** | 10x | Instant | Fast interpretation |    fn area(self: Rectangle) -> int {

| **C Compiled** | 50x | ~1-2s | Production (portable) |        self.width * self.height

| **LLVM Compiled** | 100x | ~0.5s | Production (native) |    }

}

### Interactive REPL

// Creating instances

```bashconst p = Point { x: 10; y: 20 };

$ elba replconst rect = Rectangle { width: 5; height: 10 };

Elba REPL v0.1.0const area = rect.area();

Type 'help' for help, 'exit' to quit```



>>> const x: int = 42### Generics

>>> const y: int = x * 2

>>> println(int_to_str(y))```elba

84// Generic struct

>>> fn double(n: int) -> int { n * 2 }struct Box<T> {

>>> double(21)    value: T;

42    

```    fn get(self: Box<T>) -> T {

        self.value

## 💡 Examples    }

}

### Arrays and Loops

// Using generics

```elbaconst int_box: Box<int> = Box<int> { value: 42 };

const numbers: []int = [1, 2, 3, 4, 5];const str_box: Box<str> = Box<str> { value: "hello" };

```

let sum: int = 0;

for (num in numbers) {### Optional Types

    sum = sum + num;

}```elba

// Optional type with ?

println(int_to_str(sum));  // Output: 15let maybe: int? = 42;

```maybe = null;



### Structs// Checking for null

if (maybe != null) {

```elba    println("Has value");

struct Point {} else {

    x: int;    println("Is null");

    y: int;}

}```



const p1: Point = Point { x: 0; y: 0; };### Control Flow

const p2: Point = Point { x: 3; y: 4; };

``````elba

// If expressions

### Module Systemconst max = if (a > b) { a } else { b };



```elba// While loops

// math_utils.elbalet i = 0;

export fn square(x: int) -> int {while (i < 10) {

    x * x    println(int_to_str(i));

}    i = i + 1;

}

// main.elba```

import "math_utils" as math;

### Modules

const result: int = math.square(5);

println(int_to_str(result));  // Output: 25```elba

```// math.elba

export fn add(a: int, b: int) -> int {

### More Examples    a + b

}

Check out the `examples/` directory:

- `hello_world.elba` - Basic hello worldexport fn multiply(a: int, b: int) -> int {

- `fibonacci.elba` - Recursive Fibonacci    a * b

- `arrays.elba` - Array operations}

- `generics.elba` - Generic programming

- `structs.elba` - Struct usage// main.elba

- `llvm_demo.elba` - LLVM backend demonstrationimport "math.elba";

- And more!

const sum = add(5, 3);

## 🏗️ Architectureconst product = multiply(4, 6);

```

```

Source Code → Lexer → Parser → Type Checker → IR Generator → ## Standard Library

  → Optimizer → Backend (AST/IR/C/LLVM) → Output

```### Built-in Functions



## 🧪 Testing- `println(str)` - Print with newline

- `print(str)` - Print without newline

```bash- `int_to_str(int) -> str` - Convert integer to string

# Run examples- `float_to_str(float) -> str` - Convert float to string

./zig-out/bin/elba examples/fibonacci.elba- `str_len(str) -> int` - Get string length

- `str_concat(str, str) -> str` - Concatenate strings

# Run tests- `str_substr(str, int, int) -> str` - Extract substring

./zig-out/bin/elba tests/test_functions.elba

```### Math Library (`std/math.elba`)



## 🤝 Contributing- `PI` - Pi constant (3.14159265359)

- `E` - Euler's number (2.71828182846)

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.- `abs(int) -> int` - Absolute value

- `min(int, int) -> int` - Minimum of two values

## 📊 Project Status- `max(int, int) -> int` - Maximum of two values

- `pow(int, int) -> int` - Power function

**Current Version:** 0.1.0 (Alpha)- `sqrt(float) -> float` - Square root

- `floor(float) -> int` - Floor function

### What Works- `ceil(float) -> int` - Ceiling function

- ✅ Core language features

- ✅ Type system with generics### String Library (`std/string.elba`)

- ✅ Multiple backends (AST, IR, C, LLVM)

- ✅ REPL and tooling- `is_empty(str) -> bool` - Check if string is empty

- ✅ Standard library basics- `starts_with(str, str) -> bool` - Check prefix

- `ends_with(str, str) -> bool` - Check suffix

### Known Limitations- `repeat(str, int) -> str` - Repeat string n times

- ⚠️ Control flow limited in LLVM backend- `trim(str) -> str` - Trim whitespace

- ⚠️ No garbage collection yet- `pad_left(str, int, str) -> str` - Pad on left

- ⚠️ Module system is basic- `pad_right(str, int, str) -> str` - Pad on right

- ⚠️ Standard library needs expansion

## REPL Commands

## 📜 License

```

Elba is released under the [MIT License](LICENSE).help      - Show REPL help

exit/quit - Exit the REPL

## 🙏 Acknowledgmentsclear     - Clear the screen

vars      - Show all defined variables

- Built with [Zig](https://ziglang.org/)reset     - Reset the environment

- Powered by [LLVM](https://llvm.org/)```

- Inspired by Rust, TypeScript, and ML-family languages

## Examples

---

See the `examples/` directory for comprehensive examples:

<div align="center">

- `hello_world.elba` - Basic hello world

**Made with ❤️ by the Elba Community**- `fibonacci.elba` - Fibonacci calculator  

- `generics.elba` - Generic data structures

[⬆ Back to top](#-elba-programming-language)- `arrays.elba` - Array operations and iteration

- `structs.elba` - Struct definitions and usage

</div>- `control_flow.elba` - If expressions, while loops, nested loops

- `strings.elba` - String manipulation and formatting
- `math_algorithms.elba` - Mathematical operations and algorithms
- `recursion.elba` - Recursive function examples
- `llvm_demo.elba` - LLVM backend demonstration

Run any example with:
```bash
# Interpret
./zig-out/bin/elba examples/<filename>.elba

# Compile to C
./zig-out/bin/elba --compile --compile-c examples/<filename>.elba

# Compile to native code via LLVM
./zig-out/bin/elba --compile --compile-llvm examples/<filename>.elba
```

## Language Grammar

### Types

- Primitives: `int`, `float`, `str`, `bool`
- Arrays: `[]int`, `[]str`, etc.
- Structs: User-defined types
- Generics: `Box<T>`, `Pair<A, B>`, etc.
- Optional: `int?`, `str?`, etc.
- Union: `int | str`, `int | float | str`, etc.

### Operators

- Arithmetic: `+`, `-`, `*`, `/`, `%`, `**` (power)
- Comparison: `<`, `>`, `<=`, `>=`, `==`, `!=`
- Logical: `&&`, `||`, `!`
- Type checking: `is`, `is not`

### Statements

- Variable declaration: `const x = 42;`, `let y = 0;`
- Assignment: `x = 10;`
- Function definition: `fn name(params) -> type { body }`
- Struct definition: `struct Name { fields }`
- If statement: `if (condition) { } else { }`
- While loop: `while (condition) { }`
- Return: `return value;`
- Import: `import "module.elba";`

## Testing

Run the test suite:

```bash
# Function tests
./zig-out/bin/elba tests/test_functions.elba

# Array tests
./zig-out/bin/elba tests/test_arrays.elba

# Loop and control flow tests
./zig-out/bin/elba tests/test_loops.elba

# Advanced tests
./zig-out/bin/elba tests/test_edge_cases.elba
./zig-out/bin/elba tests/test_generics_advanced.elba
./zig-out/bin/elba tests/test_type_aliases.elba
./zig-out/bin/elba tests/test_error_handling.elba
```

## Project Structure

```
elba/
├── src/
│   ├── main.zig              # Entry point
│   ├── frontend/             # Frontend components
│   │   ├── lexer.zig         # Lexical analysis
│   │   ├── parser.zig        # Syntax analysis
│   │   ├── ast.zig           # Abstract Syntax Tree
│   │   └── typechecker.zig   # Type checking
│   ├── backend/              # Backend components
│   │   ├── interpreter.zig   # AST interpreter
│   │   ├── ir.zig            # Intermediate Representation
│   │   ├── ir_gen.zig        # IR generation
│   │   ├── ir_interpreter.zig # IR interpreter
│   │   └── ir_optimizer.zig  # IR optimization
│   ├── codegen/              # Code generation
│   │   └── c_codegen.zig     # C code generator
│   └── utils/                # Utilities
│       ├── cli.zig           # CLI interface
│       ├── repl.zig          # REPL mode
│       ├── benchmark.zig     # Performance benchmarks
│       └── error_reporter.zig # Error reporting
├── std/
│   ├── math.elba             # Math library
│   └── string.elba           # String utilities
├── examples/
│   ├── hello_world.elba
│   ├── fibonacci.elba
│   ├── arrays.elba
│   ├── structs.elba
│   ├── control_flow.elba
│   ├── strings.elba
│   ├── math_algorithms.elba
│   ├── recursion.elba
│   └── generics.elba
├── tests/
│   ├── test_functions.elba
│   ├── test_arrays.elba
│   ├── test_loops.elba
│   └── *.elba                # More test files
└── build.zig                 # Build configuration
```

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

MIT License - See LICENSE file for details.

## Acknowledgments

Built with Zig programming language.
