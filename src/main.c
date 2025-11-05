#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "common.h"
#include "frontend/lexer.h"
#include "frontend/parser.h"
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
        printf("Elba version 0.1.0 (C port)\n");
        return 0;
    }
    
    if (strcmp(argv[1], "--help") == 0) {
        printf("Elba - A modern, statically-typed programming language\n\n");
        printf("Usage:\n");
        printf("  elba <file>      Run an Elba source file\n");
        printf("  elba --version   Show version information\n");
        printf("  elba --help      Show this help message\n");
        printf("  elba --test      Run parser demo\n");
        return 0;
    }
    
    if (strcmp(argv[1], "--test") == 0) {
        // Test parser with simple input
        const char* test_source = 
            "const x = 42;\n"
            "let y = 3.14;\n"
            "let z = x + y * 2;\n"
            "let result = add(10, 20);";
        size_t source_len = strlen(test_source);
        
        printf("Testing parser with:\n%s\n\n", test_source);
        printf("=== Parsing ===\n");
        
        Lexer lexer = lexer_init(test_source, source_len);
        ErrorReporter reporter = error_reporter_init(test_source, source_len, "test.elba");
        Arena* arena = arena_create(4096);
        
        Parser* parser = parser_init(&lexer, test_source, source_len, &reporter, arena);
        
        // Parse statements
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
            printf("\nStatement %d: ", stmt_count);
            
            switch (stmt->kind) {
                case STMT_CONST_DECL:
                    printf("CONST %.*s = ", 
                           (int)stmt->data.var_decl.name.length,
                           stmt->data.var_decl.name.data);
                    print_expr_kind(stmt->data.var_decl.value->kind);
                    printf("\n");
                    print_expr(stmt->data.var_decl.value, 1);
                    break;
                case STMT_LET_DECL:
                    printf("LET %.*s = ",
                           (int)stmt->data.var_decl.name.length,
                           stmt->data.var_decl.name.data);
                    print_expr_kind(stmt->data.var_decl.value->kind);
                    printf("\n");
                    print_expr(stmt->data.var_decl.value, 1);
                    break;
                case STMT_RETURN:
                    printf("RETURN\n");
                    print_expr(stmt->data.return_stmt, 1);
                    break;
                case STMT_EXPR:
                    printf("EXPR\n");
                    print_expr(stmt->data.expr_stmt, 1);
                    break;
                default:
                    printf("(other statement)\n");
                    break;
            }
        }
        
        printf("\n=== Successfully parsed %d statements ===\n", stmt_count);
        
        parser_free(parser);
        arena_free(arena);
        
        printf("\nNote: Full compiler functionality (typechecker, backends) not yet implemented.\n");
        printf("This demonstrates the C port with working lexer and parser.\n");
        
        return 0;
    }
    
    printf("Error: File reading not yet implemented. Use --test to run demo.\n");
    return 1;
}

