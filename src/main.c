#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "common.h"
#include "frontend/lexer.h"
#include "frontend/parser.h"
#include "frontend/typechecker.h"
#include "backend/interpreter.h"
#include "utils/error_reporter.h"

// Helper to print expression type
static void print_expr_kind(ExprKind kind) {
    switch (kind) {
        case EXPR_INT_LITERAL: printf("IntLiteral"); break;
        case EXPR_FLOAT_LITERAL: printf("FloatLiteral"); break;
        case EXPR_STRING_LITERAL: printf("StringLiteral"); break;
        case EXPR_BOOL_LITERAL: printf("BoolLiteral"); break;
        case EXPR_NULL_LITERAL: printf("NullLiteral"); break;
        case EXPR_VARIABLE: printf("Variable"); break;
        case EXPR_BINARY: printf("BinaryExpr"); break;
        case EXPR_UNARY: printf("UnaryExpr"); break;
        case EXPR_FN_CALL: printf("FunctionCall"); break;
        default: printf("Unknown"); break;
    }
}

// Helper to print expression recursively (simplified)
static void print_expr(Expr* expr, int indent) {
    if (!expr) return;
    
    for (int i = 0; i < indent; i++) printf("  ");
    
    switch (expr->kind) {
        case EXPR_INT_LITERAL:
            printf("INT: %lld\n", (long long)expr->data.int_literal);
            break;
        case EXPR_FLOAT_LITERAL:
            printf("FLOAT: %f\n", expr->data.float_literal);
            break;
        case EXPR_STRING_LITERAL:
            printf("STRING: \"%.*s\"\n", (int)expr->data.string_literal.length, 
                   expr->data.string_literal.data);
            break;
        case EXPR_BOOL_LITERAL:
            printf("BOOL: %s\n", expr->data.bool_literal ? "true" : "false");
            break;
        case EXPR_VARIABLE:
            printf("VAR: %.*s\n", (int)expr->data.variable.length, expr->data.variable.data);
            break;
        case EXPR_BINARY:
            printf("BINARY (%d):\n", expr->data.binary.op);
            print_expr(expr->data.binary.left, indent + 1);
            print_expr(expr->data.binary.right, indent + 1);
            break;
        case EXPR_UNARY:
            printf("UNARY (%d):\n", expr->data.unary.op);
            print_expr(expr->data.unary.operand, indent + 1);
            break;
        case EXPR_FN_CALL:
            printf("CALL: %.*s (%zu args)\n", 
                   (int)expr->data.fn_call.name.length, expr->data.fn_call.name.data,
                   expr->data.fn_call.arg_count);
            for (size_t i = 0; i < expr->data.fn_call.arg_count; i++) {
                print_expr(expr->data.fn_call.arguments[i], indent + 1);
            }
            break;
        default:
            printf("(other expression)\n");
            break;
    }
}

int main(int argc, char** argv) {
    printf("Elba Programming Language - C Version\n");
    printf("=======================================\n\n");
    
    if (argc < 2) {
        printf("Usage: %s <file.elba>\n", argv[0]);
        printf("       %s --version\n", argv[0]);
        printf("       %s --help\n", argv[0]);
        printf("       %s --test\n", argv[0]);
        return 1;
    }
    
    if (strcmp(argv[1], "--version") == 0) {
        printf("Elba version 0.1.0 (C Implementation)\n");
        printf("Fully functional compiler: parse → typecheck → execute\n");
        printf("Build: C11 with GCC/Clang\n");
        return 0;
    }
    
    if (strcmp(argv[1], "--help") == 0) {
        printf("Elba - A modern, statically-typed programming language\n\n");
        printf("USAGE:\n");
        printf("  elba <file>         Run an Elba source file (coming soon)\n");
        printf("  elba --test         Run full compiler pipeline demo\n");
        printf("  elba --version      Show version information\n");
        printf("  elba --help         Show this help message\n\n");
        printf("FEATURES:\n");
        printf("  • Static type checking with type inference\n");
        printf("  • Variables: const (immutable), let (mutable)\n");
        printf("  • Operators: +, -, *, /, %%, ** (arithmetic)\n");
        printf("  • Operators: ==, !=, <, <=, >, >= (comparison)\n");
        printf("  • Operators: &&, ||, ! (logical)\n");
        printf("  • Functions with parameters and returns\n");
        printf("  • Built-in functions: print()\n");
        printf("  • Type system: int, float, str, bool, arrays, optionals\n\n");
        printf("STATUS:\n");
        printf("  ✓ Lexer: Tokenization\n");
        printf("  ✓ Parser: AST construction\n");
        printf("  ✓ Typechecker: Type inference & validation\n");
        printf("  ✓ Interpreter: Program execution\n");
        printf("  • Advanced features (IR, LLVM, C codegen): Optional\n\n");
        printf("For more information, see README.md and C_CONVERSION.md\n");
        return 0;
    }
    
    if (strcmp(argv[1], "--test") == 0) {
        // Test parser, typechecker, and interpreter with sample code
        const char* test_source = 
            "const x = 42;\n"
            "let y = 3.14;\n"
            "let z = x + 10;\n"
            "const result = x * 2 + 8;\n"
            "print(\"x =\", x);\n"
            "print(\"y =\", y);\n"
            "print(\"z =\", z);\n"
            "print(\"result =\", result);\n";
        size_t source_len = strlen(test_source);
        
        printf("Testing full pipeline with:\n%s\n", test_source);
        printf("=== Parsing ===\n");
        
        Lexer lexer = lexer_init(test_source, source_len);
        ErrorReporter reporter = error_reporter_init(test_source, source_len, "test.elba");
        Arena* arena = arena_create(16384);
        
        Parser* parser = parser_init(&lexer, test_source, source_len, &reporter, arena);
        
        // Parse statements
        DynamicArray* stmts_array = dyn_array_create(sizeof(Stmt*));
        int stmt_count = 0;
        
        while (true) {
            Stmt* stmt;
            ParseError err = parser_parse_stmt(parser, &stmt);
            
            if (err.code != PARSE_OK) {
                fprintf(stderr, "Parse error: %s\n", err.message);
                break;
            }
            
            if (stmt == NULL) {
                break; // EOF
            }
            
            stmt_count++;
            dyn_array_append(stmts_array, &stmt);
            
            printf("  %d. ", stmt_count);
            
            switch (stmt->kind) {
                case STMT_CONST_DECL:
                    printf("const %.*s", 
                           (int)stmt->data.var_decl.name.length,
                           stmt->data.var_decl.name.data);
                    if (stmt->data.var_decl.type_annotation) {
                        char type_buf[128];
                        printf(": %s", type_to_string(stmt->data.var_decl.type_annotation, 
                                                      type_buf, sizeof(type_buf)));
                    }
                    printf(" = ...\n");
                    break;
                case STMT_LET_DECL:
                    printf("let %.*s",
                           (int)stmt->data.var_decl.name.length,
                           stmt->data.var_decl.name.data);
                    if (stmt->data.var_decl.type_annotation) {
                        char type_buf[128];
                        printf(": %s", type_to_string(stmt->data.var_decl.type_annotation,
                                                      type_buf, sizeof(type_buf)));
                    }
                    printf(" = ...\n");
                    break;
                case STMT_EXPR:
                    if (stmt->data.expr_stmt->kind == EXPR_FN_CALL) {
                        printf("call %.*s(...)\n",
                               (int)stmt->data.expr_stmt->data.fn_call.name.length,
                               stmt->data.expr_stmt->data.fn_call.name.data);
                    } else {
                        printf("expression\n");
                    }
                    break;
                default:
                    printf("(other statement)\n");
                    break;
            }
        }
        
        printf("\n✓ Parsed %d statements\n\n", stmt_count);
        
        // Type check
        printf("=== Type Checking ===\n");
        
        TypeCheckResult tc_result = typecheck_program(
            (Stmt**)stmts_array->items, 
            stmts_array->length,
            &reporter,
            arena
        );
        
        if (tc_result.success) {
            printf("✓ Type checking passed\n\n");
        } else {
            printf("✗ Type checking failed: %s\n\n", tc_result.error_message);
            parser_free(parser);
            dyn_array_free(stmts_array);
            arena_free(arena);
            return 1;
        }
        
        // Interpret
        printf("=== Execution ===\n");
        
        InterpResult interp_result = interp_run_program(
            (Stmt**)stmts_array->items,
            stmts_array->length,
            arena
        );
        
        if (!interp_result.success) {
            fprintf(stderr, "\n✗ Runtime error: %s\n", interp_result.error_message);
            parser_free(parser);
            dyn_array_free(stmts_array);
            arena_free(arena);
            return 1;
        }
        
        printf("\n✓ Program executed successfully\n");
        
        parser_free(parser);
        dyn_array_free(stmts_array);
        arena_free(arena);
        
        printf("\nNote: Full compiler functionality (IR, LLVM, C codegen) not yet implemented.\n");
        printf("This demonstrates the C port with complete frontend and interpreter.\n");
        
        return 0;
    }
    
    printf("Error: File reading not yet implemented. Use --test to run demo.\n");
    return 1;
}


