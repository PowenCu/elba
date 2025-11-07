#ifndef ELBA_LEXER_H
#define ELBA_LEXER_H

#include "../common.h"

// Token types (enums)
typedef enum {
    TOKEN_EOF,
    TOKEN_NUMBER,
    TOKEN_FLOAT,
    TOKEN_STRING,
    TOKEN_IDENTIFIER,
    TOKEN_CONST_KW,
    TOKEN_LET_KW,
    TOKEN_TRUE_KW,
    TOKEN_FALSE_KW,
    TOKEN_NULL_KW,
    TOKEN_IF_KW,
    TOKEN_ELSE_KW,
    TOKEN_WHILE_KW,
    TOKEN_FOR_KW,
    TOKEN_IN_KW,
    TOKEN_MATCH_KW,
    TOKEN_INT_KW,
    TOKEN_FLOAT_KW,
    TOKEN_STR_KW,
    TOKEN_BOOL_KW,
    TOKEN_FN_KW,
    TOKEN_RETURN_KW,
    TOKEN_STRUCT_KW,
    TOKEN_IS_KW,
    TOKEN_NOT_KW,
    TOKEN_TYPE_KW,
    TOKEN_TAKE_KW,
    TOKEN_FROM_KW,
    TOKEN_PLUS,
    TOKEN_MINUS,
    TOKEN_STAR,
    TOKEN_SLASH,
    TOKEN_PERCENT,
    TOKEN_STAR_STAR,
    TOKEN_LPAREN,
    TOKEN_RPAREN,
    TOKEN_LBRACE,
    TOKEN_RBRACE,
    TOKEN_LBRACKET,
    TOKEN_RBRACKET,
    TOKEN_EQUAL,
    TOKEN_EQUAL_EQUAL,
    TOKEN_BANG,
    TOKEN_BANG_EQUAL,
    TOKEN_LESS,
    TOKEN_LESS_EQUAL,
    TOKEN_GREATER,
    TOKEN_GREATER_EQUAL,
    TOKEN_AMPERSAND_AMPERSAND,
    TOKEN_PIPE,
    TOKEN_PIPE_PIPE,
    TOKEN_SEMICOLON,
    TOKEN_COLON,
    TOKEN_COMMA,
    TOKEN_ARROW,
    TOKEN_FAT_ARROW,
    TOKEN_DOT,
    TOKEN_DOT_DOT,
    TOKEN_QUESTION,
    TOKEN_INVALID,
} TokenTag;

// Token location
typedef struct {
    size_t start;
    size_t end;
} TokenLoc;

// Token structure
typedef struct {
    TokenTag tag;
    TokenLoc loc;
} Token;

// Lexer structure
typedef struct {
    const char* source;
    size_t source_len;
    size_t index;
} Lexer;

// Function declarations
Lexer lexer_init(const char* source, size_t source_len);
Token lexer_next(Lexer* lexer);
Token lexer_peek(Lexer* lexer);
const char* token_tag_to_string(TokenTag tag);

#endif // ELBA_LEXER_H
