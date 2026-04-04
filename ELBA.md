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

return_stmt ::= "return" expr ";"

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
              | logical_or

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

for_expr    ::= "for" "(" IDENT "in" IDENT ")" block

match_expr  ::= "match" "(" IDENT ")" "{" match_arm ( "," match_arm )* ","? "}"

match_arm   ::= pattern "=>" expr

pattern     ::= "_"                         (* wildcard    *)
              | IDENT                        (* binding     *)
              | INT_LIT ( ".." INT_LIT )?   (* literal / range *)
              | FLOAT_LIT
              | STRING_LIT
              | "true" | "false"
              | "null"
```

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

STRING_LIT  ::= '"' ( [^"\n] )* '"'

IDENT       ::= [a-zA-Z_] [a-zA-Z0-9_]*

COMMENT     ::= "//" [^\n]* "\n"      (* ignored *)

WHITESPACE  ::= [ \t\r\n]+            (* ignored *)
```

### Keywords (reserved — cannot be used as identifiers)

```
const   let     fn      return  struct  type
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
| `\|` | union type / pipe |
| `(` `)` `{` `}` `[` `]` | grouping / blocks |
| `;` `:` `,` `.` | punctuation |

---

## Operator Precedence Summary

| Level | Operators | Associativity |
|-------|-----------|---------------|
| 1 (lowest) | `=` | Right |
| 2 | `\|\|` | Left |
| 3 | `&&` | Left |
| 4 | `==` `!=` | Left |
| 5 | `<` `<=` `>` `>=` `is` `is not` | Left |
| 6 | `+` `-` | Left |
| 7 | `*` `/` `%` | Left |
| 8 | `**` | Right |
| 9 | `!` `-` (unary) | Right |
| 10 | `.field` `.method()` `[index]` | Left |
| 11 (highest) | literals, identifiers, `()`, blocks | — |

---

## Notes & Constraints

- **Mutability:** `const` bindings are immutable. `let` bindings are mutable and may be reassigned with `=`.
- **Semicolons:** Required after most statements, but optional after block-valued expressions (`if`, `while`, `for`, `match`, `{ … }`).
- **Struct initialisation:** Fields are separated by `;` (not `,`), e.g. `Point { x: 1; y: 2 }`.
- **Generic type args in expressions:** `<…>` is parsed as type arguments only when immediately followed by `{` (struct init) or `(` (function call); otherwise `<` is treated as a comparison operator.
- **`is` / `is not`:** Type-check expressions; always evaluate to `bool`. Example: `x is int`, `x is not str`.
- **`for` loops:** Currently support array iteration only (`for (elem in array_var)`). Range iteration is reserved for future implementation.
- **Negative number literals:** Represented as unary negation applied to a positive literal (e.g., `0 - 5` or `-5`). There is no standalone negative integer token.
- **Module paths:** Must be string literals; resolved relative to the importing file's directory.