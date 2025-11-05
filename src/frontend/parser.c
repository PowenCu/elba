#include "parser.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Initialize parser
Parser* parser_init(Lexer* lexer, const char* source, size_t source_len,
                    const ErrorReporter* error_reporter, Arena* arena) {
    Parser* parser = (Parser*)malloc(sizeof(Parser));
    if (!parser) return NULL;
    
    parser->lexer = lexer;
    parser->source = source;
    parser->source_len = source_len;
    parser->error_reporter = error_reporter;
    parser->arena = arena;
    parser->current = lexer_next(lexer);
    
    return parser;
}

void parser_free(Parser* parser) {
    free(parser);
}

// Advance to next token
void parser_advance(Parser* parser) {
    parser->current = lexer_next(parser->lexer);
}

// Check if current token matches expected tag
bool parser_check(Parser* parser, TokenTag tag) {
    return parser->current.tag == tag;
}

// Match and consume token if it matches
bool parser_match(Parser* parser, TokenTag tag) {
    if (parser_check(parser, tag)) {
        parser_advance(parser);
        return true;
    }
    return false;
}

// Expect specific token and advance
ParseError parser_expect(Parser* parser, TokenTag expected_tag) {
    if (parser->current.tag != expected_tag) {
        error_reporter_report_expected_error(parser->error_reporter, 
                                              token_tag_to_string(expected_tag),
                                              parser->current);
        return (ParseError){PARSE_ERROR_UNEXPECTED_TOKEN, "Unexpected token"};
    }
    parser_advance(parser);
    return (ParseError){PARSE_OK, NULL};
}

// Forward declarations for recursive parsing
static ParseError parse_expr_impl(Parser* parser, Expr** out_expr);
static ParseError parse_primary(Parser* parser, Expr** out_expr);
static ParseError parse_binary_expr(Parser* parser, Expr* left, int min_precedence, Expr** out_expr);
static ParseError parse_type_annotation(Parser* parser, Type** out_type);

// Get operator precedence
static int get_precedence(TokenTag tag) {
    switch (tag) {
        case TOKEN_PIPE_PIPE: return 1;
        case TOKEN_AMPERSAND_AMPERSAND: return 2;
        case TOKEN_EQUAL_EQUAL:
        case TOKEN_BANG_EQUAL: return 3;
        case TOKEN_LESS:
        case TOKEN_LESS_EQUAL:
        case TOKEN_GREATER:
        case TOKEN_GREATER_EQUAL: return 4;
        case TOKEN_PLUS:
        case TOKEN_MINUS: return 5;
        case TOKEN_STAR:
        case TOKEN_SLASH:
        case TOKEN_PERCENT: return 6;
        case TOKEN_STAR_STAR: return 7;
        default: return -1;
    }
}

// Convert token to binary operator
static BinaryOp token_to_binop(TokenTag tag) {
    switch (tag) {
        case TOKEN_PLUS: return BINOP_ADD;
        case TOKEN_MINUS: return BINOP_SUB;
        case TOKEN_STAR: return BINOP_MUL;
        case TOKEN_SLASH: return BINOP_DIV;
        case TOKEN_PERCENT: return BINOP_MOD;
        case TOKEN_STAR_STAR: return BINOP_POW;
        case TOKEN_EQUAL_EQUAL: return BINOP_EQUAL;
        case TOKEN_BANG_EQUAL: return BINOP_NOT_EQUAL;
        case TOKEN_LESS: return BINOP_LESS;
        case TOKEN_LESS_EQUAL: return BINOP_LESS_EQUAL;
        case TOKEN_GREATER: return BINOP_GREATER;
        case TOKEN_GREATER_EQUAL: return BINOP_GREATER_EQUAL;
        case TOKEN_AMPERSAND_AMPERSAND: return BINOP_LOGICAL_AND;
        case TOKEN_PIPE_PIPE: return BINOP_LOGICAL_OR;
        default: return BINOP_ADD; // Shouldn't happen
    }
}

// Parse type annotation
static ParseError parse_type_annotation(Parser* parser, Type** out_type) {
    // Handle array types: []int, []str, etc.
    if (parser_check(parser, TOKEN_LBRACKET)) {
        parser_advance(parser);
        ParseError err = parser_expect(parser, TOKEN_RBRACKET);
        if (err.code != PARSE_OK) return err;
        
        Type* elem_type;
        err = parse_type_annotation(parser, &elem_type);
        if (err.code != PARSE_OK) return err;
        
        *out_type = type_create_array(elem_type);
        return (ParseError){PARSE_OK, NULL};
    }
    
    // Basic types
    Type* base_type = NULL;
    switch (parser->current.tag) {
        case TOKEN_INT_KW:
            parser_advance(parser);
            base_type = type_create_int();
            break;
        case TOKEN_FLOAT_KW:
            parser_advance(parser);
            base_type = type_create_float();
            break;
        case TOKEN_STR_KW:
            parser_advance(parser);
            base_type = type_create_string();
            break;
        case TOKEN_BOOL_KW:
            parser_advance(parser);
            base_type = type_create_bool();
            break;
        case TOKEN_IDENTIFIER: {
            Slice type_name = slice_from_ptr_len(
                parser->source + parser->current.loc.start,
                parser->current.loc.end - parser->current.loc.start
            );
            parser_advance(parser);
            base_type = type_create_user(type_name.data, type_name.length);
            break;
        }
        default:
            error_reporter_report_token_error(parser->error_reporter, "error",
                "Expected type annotation", parser->current);
            return (ParseError){PARSE_ERROR_UNEXPECTED_TOKEN, "Expected type"};
    }
    
    // Check for optional type (type?)
    if (parser_match(parser, TOKEN_QUESTION)) {
        base_type = type_create_optional(base_type);
    }
    
    *out_type = base_type;
    return (ParseError){PARSE_OK, NULL};
}

// Parse primary expression
static ParseError parse_primary(Parser* parser, Expr** out_expr) {
    // Integer literal
    if (parser_check(parser, TOKEN_NUMBER)) {
        Slice text = slice_from_ptr_len(
            parser->source + parser->current.loc.start,
            parser->current.loc.end - parser->current.loc.start
        );
        char buf[64];
        if (text.length < sizeof(buf)) {
            memcpy(buf, text.data, text.length);
            buf[text.length] = '\0';
            int64_t val = atoll(buf);
            parser_advance(parser);
            *out_expr = expr_create_int_literal(val);
            return (ParseError){PARSE_OK, NULL};
        }
        return (ParseError){PARSE_ERROR_OVERFLOW, "Number too large"};
    }
    
    // Float literal
    if (parser_check(parser, TOKEN_FLOAT)) {
        Slice text = slice_from_ptr_len(
            parser->source + parser->current.loc.start,
            parser->current.loc.end - parser->current.loc.start
        );
        char buf[64];
        if (text.length < sizeof(buf)) {
            memcpy(buf, text.data, text.length);
            buf[text.length] = '\0';
            double val = atof(buf);
            parser_advance(parser);
            *out_expr = expr_create_float_literal(val);
            return (ParseError){PARSE_OK, NULL};
        }
        return (ParseError){PARSE_ERROR_OVERFLOW, "Float too large"};
    }
    
    // String literal
    if (parser_check(parser, TOKEN_STRING)) {
        // Skip quotes
        Slice text = slice_from_ptr_len(
            parser->source + parser->current.loc.start + 1,
            parser->current.loc.end - parser->current.loc.start - 2
        );
        parser_advance(parser);
        *out_expr = expr_create_string_literal(text.data, text.length);
        return (ParseError){PARSE_OK, NULL};
    }
    
    // Boolean literals
    if (parser_check(parser, TOKEN_TRUE_KW)) {
        parser_advance(parser);
        *out_expr = expr_create_bool_literal(true);
        return (ParseError){PARSE_OK, NULL};
    }
    if (parser_check(parser, TOKEN_FALSE_KW)) {
        parser_advance(parser);
        *out_expr = expr_create_bool_literal(false);
        return (ParseError){PARSE_OK, NULL};
    }
    
    // Null literal
    if (parser_check(parser, TOKEN_NULL_KW)) {
        parser_advance(parser);
        *out_expr = expr_create_null_literal();
        return (ParseError){PARSE_OK, NULL};
    }
    
    // Identifier or function call
    if (parser_check(parser, TOKEN_IDENTIFIER)) {
        Slice name = slice_from_ptr_len(
            parser->source + parser->current.loc.start,
            parser->current.loc.end - parser->current.loc.start
        );
        parser_advance(parser);
        
        // Check for function call
        if (parser_check(parser, TOKEN_LPAREN)) {
            parser_advance(parser);
            
            // Parse arguments
            DynamicArray* args = dyn_array_create(sizeof(Expr*));
            
            while (!parser_check(parser, TOKEN_RPAREN) && !parser_check(parser, TOKEN_EOF)) {
                Expr* arg;
                ParseError err = parse_expr_impl(parser, &arg);
                if (err.code != PARSE_OK) {
                    dyn_array_free(args);
                    return err;
                }
                dyn_array_append(args, &arg);
                
                if (!parser_match(parser, TOKEN_COMMA)) {
                    break;
                }
            }
            
            ParseError err = parser_expect(parser, TOKEN_RPAREN);
            if (err.code != PARSE_OK) {
                dyn_array_free(args);
                return err;
            }
            
            // Create function call expression
            Expr* fn_call = (Expr*)arena_alloc(parser->arena, sizeof(Expr));
            fn_call->kind = EXPR_FN_CALL;
            fn_call->data.fn_call.name = name;
            fn_call->data.fn_call.type_args = NULL;
            fn_call->data.fn_call.type_args_count = 0;
            fn_call->data.fn_call.arguments = (Expr**)args->items;
            fn_call->data.fn_call.arg_count = args->length;
            
            *out_expr = fn_call;
            // Don't free args, ownership transferred
            free(args);  // Free container only
            return (ParseError){PARSE_OK, NULL};
        }
        
        // Just a variable reference
        *out_expr = expr_create_variable(name.data, name.length);
        return (ParseError){PARSE_OK, NULL};
    }
    
    // Parenthesized expression
    if (parser_match(parser, TOKEN_LPAREN)) {
        Expr* expr;
        ParseError err = parse_expr_impl(parser, &expr);
        if (err.code != PARSE_OK) return err;
        
        err = parser_expect(parser, TOKEN_RPAREN);
        if (err.code != PARSE_OK) return err;
        
        *out_expr = expr;
        return (ParseError){PARSE_OK, NULL};
    }
    
    // Unary operators
    if (parser_check(parser, TOKEN_MINUS) || parser_check(parser, TOKEN_BANG)) {
        UnaryOp op = parser_check(parser, TOKEN_MINUS) ? UNOP_NEGATE : UNOP_LOGICAL_NOT;
        parser_advance(parser);
        
        Expr* operand;
        ParseError err = parse_primary(parser, &operand);
        if (err.code != PARSE_OK) return err;
        
        *out_expr = expr_create_unary(op, operand);
        return (ParseError){PARSE_OK, NULL};
    }
    
    error_reporter_report_token_error(parser->error_reporter, "error",
        "Expected expression", parser->current);
    return (ParseError){PARSE_ERROR_UNEXPECTED_TOKEN, "Expected expression"};
}

// Parse binary expression with precedence climbing
static ParseError parse_binary_expr(Parser* parser, Expr* left, int min_precedence, Expr** out_expr) {
    while (true) {
        int precedence = get_precedence(parser->current.tag);
        if (precedence < min_precedence) {
            *out_expr = left;
            return (ParseError){PARSE_OK, NULL};
        }
        
        TokenTag op_token = parser->current.tag;
        parser_advance(parser);
        
        Expr* right;
        ParseError err = parse_primary(parser, &right);
        if (err.code != PARSE_OK) return err;
        
        int next_precedence = get_precedence(parser->current.tag);
        if (next_precedence > precedence) {
            err = parse_binary_expr(parser, right, precedence + 1, &right);
            if (err.code != PARSE_OK) return err;
        }
        
        left = expr_create_binary(left, token_to_binop(op_token), right);
    }
}

// Parse expression
static ParseError parse_expr_impl(Parser* parser, Expr** out_expr) {
    Expr* left;
    ParseError err = parse_primary(parser, &left);
    if (err.code != PARSE_OK) return err;
    
    return parse_binary_expr(parser, left, 0, out_expr);
}

ParseError parser_parse_expr(Parser* parser, Expr** out_expr) {
    return parse_expr_impl(parser, out_expr);
}

ParseError parser_parse_type(Parser* parser, Type** out_type) {
    return parse_type_annotation(parser, out_type);
}

// Parse statement
ParseError parser_parse_stmt(Parser* parser, Stmt** out_stmt) {
    // Check for invalid tokens
    if (parser_check(parser, TOKEN_INVALID)) {
        error_reporter_report_token_error(parser->error_reporter, "error",
            "Unexpected character", parser->current);
        return (ParseError){PARSE_ERROR_INVALID_CHARACTER, "Invalid character"};
    }
    
    // EOF
    if (parser_check(parser, TOKEN_EOF)) {
        *out_stmt = NULL;
        return (ParseError){PARSE_OK, NULL};
    }
    
    // Return statement
    if (parser_match(parser, TOKEN_RETURN_KW)) {
        Expr* expr;
        ParseError err = parser_parse_expr(parser, &expr);
        if (err.code != PARSE_OK) return err;
        
        err = parser_expect(parser, TOKEN_SEMICOLON);
        if (err.code != PARSE_OK) return err;
        
        *out_stmt = stmt_create_return(expr);
        return (ParseError){PARSE_OK, NULL};
    }
    
    // Variable declarations (const/let)
    if (parser_check(parser, TOKEN_CONST_KW) || parser_check(parser, TOKEN_LET_KW)) {
        bool is_const = parser_check(parser, TOKEN_CONST_KW);
        parser_advance(parser);
        
        if (!parser_check(parser, TOKEN_IDENTIFIER)) {
            error_reporter_report_token_error(parser->error_reporter, "error",
                "Expected identifier after variable declaration", parser->current);
            return (ParseError){PARSE_ERROR_UNEXPECTED_TOKEN, "Expected identifier"};
        }
        
        Slice name = slice_from_ptr_len(
            parser->source + parser->current.loc.start,
            parser->current.loc.end - parser->current.loc.start
        );
        parser_advance(parser);
        
        // Optional type annotation
        Type* type_annotation = NULL;
        if (parser_match(parser, TOKEN_COLON)) {
            ParseError err = parse_type_annotation(parser, &type_annotation);
            if (err.code != PARSE_OK) return err;
        }
        
        ParseError err = parser_expect(parser, TOKEN_EQUAL);
        if (err.code != PARSE_OK) return err;
        
        Expr* value;
        err = parser_parse_expr(parser, &value);
        if (err.code != PARSE_OK) return err;
        
        err = parser_expect(parser, TOKEN_SEMICOLON);
        if (err.code != PARSE_OK) return err;
        
        if (is_const) {
            *out_stmt = stmt_create_const_decl(name.data, name.length, type_annotation, value);
        } else {
            *out_stmt = stmt_create_let_decl(name.data, name.length, type_annotation, value);
        }
        return (ParseError){PARSE_OK, NULL};
    }
    
    // Expression statement
    Expr* expr;
    ParseError err = parser_parse_expr(parser, &expr);
    if (err.code != PARSE_OK) return err;
    
    // Semicolon (required for now, can make optional later for block expressions)
    if (parser_check(parser, TOKEN_SEMICOLON)) {
        parser_advance(parser);
    }
    
    *out_stmt = stmt_create_expr(expr);
    return (ParseError){PARSE_OK, NULL};
}
