# Elba Language Status

This file separates working language behavior from syntax or IR operations that are still partial. The executable examples are the compatibility contract: `verify_examples.ps1` runs each one through the AST interpreter, IR interpreter, generated C, and LLVM, then compares their output exactly.

## Verified across every backend

- Checked integer arithmetic, exact integer power, mixed numeric coercion, float arithmetic, comparisons, boolean operators, and precedence for typed scalar expressions
- `const` and `let`, assignment, lexical block scope, and recursive calls
- `if`/`else`, `while`, array `for`, ascending/descending integer-range `for`, and nearest-loop `break`/`continue`
- Functions, early returns, recursion, and generic functions with concrete call-site scalar/array return representations
- Arrays, recursively context-typed empty literals in expected-type and unambiguous tagged-payload positions, exact `is []T` identity, checked indexing, mutable element assignment, length-based iteration, functional push/pop/slice helpers, typed scalar element loads, and recursive structural equality
- Struct construction, field access, mutable field assignment, methods, generic structs, concrete scalar field/method representations (including `Box<float>`-style instances), and recursive structural equality
- String literals, supported escapes, value equality, concatenation, substring bounds, split/trim/search, scalar printing, parsing, formatting, and numeric conversions
- Numeric `abs`/`min`/`max`, square root, floor, and ceiling
- Match subjects including computed expressions and calls; signed integer/float, string, boolean, and null literals; integer ranges; wildcard arms; variable capture; and exhaustive boolean/full-`i64` interval analysis
- Primitive `is` / `is not` checks plus concrete struct and generic-instance checks for tagged union payloads
- Type aliases, tagged optional/union storage with distinct `null` and zero-bit payloads, postfix optional unwrap, lazy null coalescing, optional/union equality, selective imports, full imports, and stdlib imports

The full AST test corpus also has matching IR-interpreter output. Native C/LLVM parity is enforced for the programs in `examples/`.

## Partial or not yet implemented

- String, float, optional, and union matches still require a catch-all arm. Type-destructuring patterns and union-variant exhaustiveness are not implemented.
- Tagged unions retain precise primitive, user-struct, and concrete generic-instance payload identity. Type-pattern destructuring is not yet available for binding a tagged payload inside `match`.
- Generic code uses type erasure in IR/native code. Concrete call-site scalar and array results retain their representation, but tagged optional/union values constructed inside generic function bodies do not yet carry a monomorphized payload descriptor.
- Typed IR metadata preserves scalar arithmetic and call representations through literals, locals, parameters, generic call-site results, struct fields, array indexing, and tagged optional/union boundaries.
- All registered builtins have AST, IR, C, and LLVM lowering. Output is intentionally limited to `int`, `float`, `str`, and `bool`; aggregate pretty-printing is interpreter-only and not part of the typed language surface.
- LLVM lowering still uses a simple value-stack model across branches. Complex control-flow programs outside the parity examples can require additional SSA join handling to avoid dominance errors.
- First-class functions, closures, async behavior, and exception-style error propagation are not language features yet.

## Verification

```powershell
# Frontend unit tests
zig build test-frontend

# Language test corpus
powershell -ExecutionPolicy Bypass -File .\run_tests.ps1

# Exact output parity for all executable examples
powershell -ExecutionPolicy Bypass -File .\verify_examples.ps1

# Rejection/runtime-failure parity for every expected-failure fixture
powershell -ExecutionPolicy Bypass -File .\verify_failures.ps1
```

Elba currently targets Zig 0.15.2. Newer Zig versions may require build-system migration before the compiler itself can be tested.
