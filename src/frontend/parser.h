#ifndef ELBA_PARSER_H
#define ELBA_PARSER_H

#include "../common.h"
#include "lexer.h"
#include "ast.h"
#include "../utils/error_reporter.h"

// Parser structure
typedef struct {
    Lexer* lexer;
    Token current;
    const char* source;
    size_t source_len;
    const ErrorReporter* error_reporter;
    Arena* arena;  // For allocating AST nodes
} Parser;

// Parser error codes
typedef enum {
    PARSE_OK = 0,
    PARSE_ERROR_UNEXPECTED_TOKEN,
    PARSE_ERROR_OUT_OF_MEMORY,
    PARSE_ERROR_INVALID_CHARACTER,
    PARSE_ERROR_OVERFLOW,
} ParseErrorCode;

typedef struct {
    ParseErrorCode code;
    const char* message;
} ParseError;

// Parser functions
Parser* parser_init(Lexer* lexer, const char* source, size_t source_len, 
                    const ErrorReporter* error_reporter, Arena* arena);
void parser_free(Parser* parser);

// Main parsing functions
ParseError parser_parse_stmt(Parser* parser, Stmt** out_stmt);
ParseError parser_parse_expr(Parser* parser, Expr** out_expr);
ParseError parser_parse_type(Parser* parser, Type** out_type);

// Helper functions
void parser_advance(Parser* parser);
ParseError parser_expect(Parser* parser, TokenTag expected_tag);
bool parser_match(Parser* parser, TokenTag tag);
bool parser_check(Parser* parser, TokenTag tag);

#endif // ELBA_PARSER_H
