# Elba Language Grammar

Formal grammar specification for the Elba programming language.  
Notation: Extended Backus–Naur Form (EBNF). `*` = zero or more, `+` = one or more, `?` = optional, `|` = alternation, `( )` = grouping.

---

## Top Level

```ebnf
program     ::= statement* EOF

statement   ::= const_decl
              | let_decl
              | fn_decl
              | struct_decl
              | type_alias
              | import_stmt
              | return_stmt
              | expr_stmt
```

---

## Declarations

```ebnf
const_decl  ::= "const" IDENT ( ":" type )? "=" expr ";"

let_decl    ::= "let" IDENT ( ":" type )? "=" expr ";"

fn_decl     ::= "fn" IDENT type_params? "(" param_list? ")" ( "->" type )? block

struct_decl ::= "struct" IDENT type_params? "{" struct_member* "}"

struct_member ::= field_decl | method_decl

field_decl  ::= IDENT ":" type ";"

method_decl ::= "fn" IDENT "(" param_list? ")" ( "->" type )? block ";"?

type_alias  ::= "type" IDENT "=" type ";"

import_stmt ::= "take" STRING ";"
              | "take" "{" import_list "}" "from" STRING ";"

import_list ::= IDENT ( "," IDENT )*

return_stmt ::= "return" expr? ";"

break_stmt  ::= "break" ";"

continue_stmt ::= "continue" ";"

expr_stmt   ::= expr ( ";" )?
```

> Note: The trailing semicolon is optional after block expressions (`if`, `while`, `for`, `match`, bare blocks).

---

## Parameters & Type Parameters

```ebnf
param_list  ::= param ( "," param )*

param       ::= IDENT ":" type

type_params ::= "<" IDENT ( "," IDENT )* ">"
```

---

## Types

```ebnf
type        ::= base_type "?"?          (* optional wrapping *)
              | base_type ( "|" base_type )+   (* union type *)
              | base_type

base_type   ::= "int"
              | "float"
              | "str"
              | "bool"
              | "[" "]" base_type       (* array type:  []int, []str, … *)
              | IDENT type_args?        (* user-defined / generic instance *)

type_args   ::= "<" type ( "," type )* ">"
```

---

## Expressions (lowest to highest precedence)

```ebnf
expr        ::= assignment

assignment  ::= IDENT "=" assignment
              | coalesce

coalesce    ::= logical_or ( "??" coalesce )?

logical_or  ::= logical_and ( "||" logical_and )*

logical_and ::= equality ( "&&" equality )*

equality    ::= comparison ( ( "==" | "!=" ) comparison )*

comparison  ::= add_sub ( comp_op add_sub )*
              | add_sub "is" "not"? type

comp_op     ::= "<" | "<=" | ">" | ">="

add_sub     ::= mul_div ( ( "+" | "-" ) mul_div )*

mul_div     ::= power ( ( "*" | "/" | "%" ) power )*

power       ::= unary ( "**" power )?      (* right-associative *)

unary       ::= "!" unary
              | "-" unary
              | postfix

postfix     ::= primary ( postfix_op )*

postfix_op  ::= "." IDENT "(" arg_list? ")"   (* method call *)
              | "." IDENT                       (* field access *)
              | "[" expr "]"                    (* array index  *)
              | "!"                              (* optional unwrap *)

primary     ::= INT_LIT
              | FLOAT_LIT
              | STRING_LIT
              | "true" | "false"
              | "null"
              | IDENT type_args? "{" field_init_list "}"   (* struct init *)
              | IDENT type_args? "(" arg_list? ")"         (* fn call     *)
              | IDENT                                       (* variable    *)
              | "(" expr ")"
              | "[" ( expr ( "," expr )* )? "]"            (* array lit   *)
              | block
              | if_expr
              | while_expr
              | for_expr
              | match_expr
```

---

## Compound Expressions

```ebnf
block       ::= "{" statement* expr? "}"

if_expr     ::= "if" "(" expr ")" block ( "else" ( if_expr | block ) )?

while_expr  ::= "while" "(" expr ")" block

for_expr    ::= "for" "(" IDENT "in" expr ( ".." "="? expr )? ")" block

match_expr  ::= "match" "(" expr ")" "{" match_arm ( "," match_arm )* ","? "}"

match_arm   ::= pattern "=>" expr

pattern     ::= "_"                              (* wildcard *)
              | IDENT                             (* binding *)
              | signed_int ( ".." signed_int )? (* integer literal / range *)
              | signed_float                     (* float literal *)
              | STRING_LIT
              | "true" | "false"
              | "null"

signed_int   ::= "-"? INT_LIT
signed_float ::= "-"? FLOAT_LIT
```

Integer ranges choose their direction from their bounds: `1..5` increments and `5..1` decrements. Adding `=` includes the final bound. `break;` and `continue;` always target the nearest enclosing loop.
Match arms are checked in source order. Boolean matches may omit a catch-all after covering both values, and integer matches may omit one when their literal/range union covers the full signed 64-bit domain. Other subject types currently require a wildcard or binding catch-all.

---

## Initializer Helpers

```ebnf
field_init_list ::= field_init ( ";" field_init )* ";"?

field_init  ::= IDENT ":" expr

arg_list    ::= expr ( "," expr )*
```

---

## Tokens (Lexical Rules)

```ebnf
INT_LIT     ::= [0-9]+

FLOAT_LIT   ::= [0-9]+ "." [0-9]+

STRING_LIT  ::= '"' ( [^"\\\r\n] | "\\" ( '"' | "\\" | "n" | "r" | "t" ) )* '"'

IDENT       ::= [a-zA-Z_] [a-zA-Z0-9_]*

COMMENT     ::= "//" [^\n]* "\n"      (* ignored *)

WHITESPACE  ::= [ \t\r\n]+            (* ignored *)
```

### Keywords (reserved — cannot be used as identifiers)

```
const   let     fn      return  break   continue
struct  type
if      else    while   for     in      match
true    false   null    is      not
int     float   str     bool
take    from
```

### Operators & Punctuation

| Token | Literal |
|-------|---------|
| `+` `-` `*` `/` `%` `**` | arithmetic |
| `==` `!=` `<` `<=` `>` `>=` | comparison |
| `&&` `\|\|` `!` | logical |
| `=` | assignment |
| `->` | return type arrow |
| `=>` | match arm arrow |
| `..` | range separator (in patterns) |
| `?` | optional type modifier |
| `??` | lazy null coalescing |
| `\|` | union type / pipe |
| `(` `)` `{` `}` `[` `]` | grouping / blocks |
| `;` `:` `,` `.` | punctuation |

---

## Operator Precedence Summary

| Level | Operators | Associativity |
|-------|-----------|---------------|
| 1 (lowest) | `=` | Right |
| 2 | `??` | Right |
| 3 | `\|\|` | Left |
| 4 | `&&` | Left |
| 5 | `==` `!=` | Left |
| 6 | `<` `<=` `>` `>=` `is` `is not` | Left |
| 7 | `+` `-` | Left |
| 8 | `*` `/` `%` | Left |
| 9 | `**` | Right |
| 10 | `!` `-` (prefix unary) | Right |
| 11 | `.field` `.method()` `[index]` postfix `!` | Left |
| 12 (highest) | literals, identifiers, `()`, blocks | — |

---

## Built-in Functions

| Category | Signatures |
|----------|------------|
| Output | `print(int | float | str | bool) -> unit`, `println(int | float | str | bool) -> unit` |
| Strings | `str_len(str) -> int`, `str_concat(str, str) -> str`, `str_substring(str, int, int) -> str` |
| String helpers | `str_split(str, str) -> []str`, `str_trim(str) -> str`, `str_contains(str, str) -> bool` |
| Parsing | `str_to_int(str) -> int`, `str_to_float(str) -> float` |
| Formatting | `int_to_str(int) -> str`, `float_to_str(float) -> str`, `bool_to_str(bool) -> str` |
| Conversion | `int_to_float(int) -> float`, `float_to_int(float) -> int` |
| Math | `abs(T) -> T`, `min(T, T) -> T`, `max(T, T) -> T`, where `T` is `int` or `float` |
| Float math | `sqrt(float) -> float`, `floor(float) -> float`, `ceil(float) -> float` |
| Arrays | `array_len([]T) -> int`, `array_push([]T, T) -> []T`, `array_pop([]T) -> []T`, `array_slice([]T, int, int) -> []T` |

Substring and array-slice end indices are exclusive. `str_split` treats its delimiter as a complete string and rejects an empty delimiter. Parsing consumes the entire input; leading whitespace, trailing characters, overflow, and non-finite float results are runtime errors. `float_to_int` truncates toward zero and rejects non-finite or out-of-range values. Integer `abs` rejects the minimum signed integer because its positive value is not representable. Array helpers are functional: they return a new array and leave the input array unchanged. `array_pop` rejects an empty array.

---

## Notes & Constraints

- **Mutability:** `const` bindings are immutable. `let` bindings are mutable and may be reassigned with `=`.
- **Semicolons:** Required after most statements, but optional after block-valued expressions (`if`, `while`, `for`, `match`, `{ … }`).
- **Struct initialisation:** Fields are separated by `;` (not `,`), e.g. `Point { x: 1; y: 2 }`.
- **Generic type args in expressions:** `<…>` is parsed as type arguments only when immediately followed by `{` (struct init) or `(` (function call); otherwise `<` is treated as a comparison operator.
- **Empty arrays:** An empty literal needs an expected array type, for example `const values: []int = [];`. Context propagates through nested literals, calls, returns, control-flow results, assignments, fields, methods, array helpers, and unambiguous optional/union payloads. `const rows: [][]int = [[1], []];` is valid; `[]int | []str = []` is ambiguous and rejected.
- **`is` / `is not`:** Type-check expressions and always evaluate to `bool`. Array checks compare the complete element type, including nested arrays and aliases. Example: `x is int`, `rows is [][]int`.
- **Optional and union values:** `T?` is the nullable form and may contain `null`; `A | B` contains one listed non-null payload. `null` is not implicitly a member of a union.
- **Optional operations:** `value!` unwraps a present optional and fails at runtime for `null`. `value ?? fallback` evaluates and returns the fallback only when `value` is `null`.
- **Equality:** Arrays and structs compare recursively by value. Optional and union equality compares both the active payload type and its value.
- **`for` loops:** Support arrays and integer ranges. Ranges may be ascending or descending and may use an inclusive end (`..=`).
- **Negative number literals:** Represented as unary negation applied to a positive literal (e.g., `0 - 5` or `-5`). There is no standalone negative integer token.
- **String escapes:** String literals support `\n`, `\r`, `\t`, `\\`, and `\"`. Other escape sequences are compile errors, and raw newlines are not allowed inside a string literal.
- **Module paths:** Must be string literals; resolved relative to the importing file's directory.
