#include "lexer.h"
#include <ctype.h>
#include <string.h>
#include <stdbool.h>

// Helper functions
static bool is_whitespace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static bool is_digit(char c) {
    return c >= '0' && c <= '9';
}

static bool is_alpha(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static bool is_alnum(char c) {
    return is_alpha(c) || is_digit(c);
}

static TokenTag identify_keyword(const char* source, size_t start, size_t end) {
    size_t len = end - start;
    const char* text = source + start;
    
    if (len == 2 && memcmp(text, "if", 2) == 0) return TOKEN_IF_KW;
    if (len == 2 && memcmp(text, "in", 2) == 0) return TOKEN_IN_KW;
    if (len == 2 && memcmp(text, "fn", 2) == 0) return TOKEN_FN_KW;
    if (len == 2 && memcmp(text, "is", 2) == 0) return TOKEN_IS_KW;
    
    if (len == 3 && memcmp(text, "let", 3) == 0) return TOKEN_LET_KW;
    if (len == 3 && memcmp(text, "int", 3) == 0) return TOKEN_INT_KW;
    if (len == 3 && memcmp(text, "str", 3) == 0) return TOKEN_STR_KW;
    if (len == 3 && memcmp(text, "for", 3) == 0) return TOKEN_FOR_KW;
    if (len == 3 && memcmp(text, "not", 3) == 0) return TOKEN_NOT_KW;
    
    if (len == 4 && memcmp(text, "true", 4) == 0) return TOKEN_TRUE_KW;
    if (len == 4 && memcmp(text, "null", 4) == 0) return TOKEN_NULL_KW;
    if (len == 4 && memcmp(text, "else", 4) == 0) return TOKEN_ELSE_KW;
    if (len == 4 && memcmp(text, "bool", 4) == 0) return TOKEN_BOOL_KW;
    if (len == 4 && memcmp(text, "type", 4) == 0) return TOKEN_TYPE_KW;
    if (len == 4 && memcmp(text, "take", 4) == 0) return TOKEN_TAKE_KW;
    if (len == 4 && memcmp(text, "from", 4) == 0) return TOKEN_FROM_KW;
    
    if (len == 5 && memcmp(text, "const", 5) == 0) return TOKEN_CONST_KW;
    if (len == 5 && memcmp(text, "false", 5) == 0) return TOKEN_FALSE_KW;
    if (len == 5 && memcmp(text, "while", 5) == 0) return TOKEN_WHILE_KW;
    if (len == 5 && memcmp(text, "match", 5) == 0) return TOKEN_MATCH_KW;
    if (len == 5 && memcmp(text, "float", 5) == 0) return TOKEN_FLOAT_KW;
    
    if (len == 6 && memcmp(text, "return", 6) == 0) return TOKEN_RETURN_KW;
    if (len == 6 && memcmp(text, "struct", 6) == 0) return TOKEN_STRUCT_KW;
    
    return TOKEN_IDENTIFIER;
}

// Initialize lexer
Lexer lexer_init(const char* source, size_t source_len) {
    Lexer lexer;
    lexer.source = source;
    lexer.source_len = source_len;
    lexer.index = 0;
    return lexer;
}

// Get next token
Token lexer_next(Lexer* lexer) {
    // Skip whitespace and comments
    while (lexer->index < lexer->source_len) {
        char c = lexer->source[lexer->index];
        
        // Skip whitespace
        if (is_whitespace(c)) {
            lexer->index++;
            continue;
        }
        
        // Skip comments
        if (c == '/' && lexer->index + 1 < lexer->source_len && 
            lexer->source[lexer->index + 1] == '/') {
            while (lexer->index < lexer->source_len && 
                   lexer->source[lexer->index] != '\n') {
                lexer->index++;
            }
            continue;
        }
        
        break;
    }
    
    if (lexer->index >= lexer->source_len) {
        Token token;
        token.tag = TOKEN_EOF;
        token.loc.start = lexer->index;
        token.loc.end = lexer->index;
        return token;
    }
    
    size_t start = lexer->index;
    char c = lexer->source[lexer->index];
    
    // String literals
    if (c == '"') {
        lexer->index++;
        while (lexer->index < lexer->source_len && 
               lexer->source[lexer->index] != '"') {
            lexer->index++;
        }
        if (lexer->index < lexer->source_len) {
            lexer->index++; // Skip closing quote
        }
        Token token;
        token.tag = TOKEN_STRING;
        token.loc.start = start;
        token.loc.end = lexer->index;
        return token;
    }
    
    // Numbers (including floats)
    if (is_digit(c)) {
        bool has_dot = false;
        while (lexer->index < lexer->source_len) {
            char ch = lexer->source[lexer->index];
            if (is_digit(ch)) {
                lexer->index++;
            } else if (ch == '.' && !has_dot && 
                      lexer->index + 1 < lexer->source_len && 
                      is_digit(lexer->source[lexer->index + 1])) {
                has_dot = true;
                lexer->index++;
            } else {
                break;
            }
        }
        Token token;
        token.tag = has_dot ? TOKEN_FLOAT : TOKEN_NUMBER;
        token.loc.start = start;
        token.loc.end = lexer->index;
        return token;
    }
    
    // Identifiers and keywords
    if (is_alpha(c) || c == '_') {
        while (lexer->index < lexer->source_len) {
            char ch = lexer->source[lexer->index];
            if (is_alnum(ch) || ch == '_') {
                lexer->index++;
            } else {
                break;
            }
        }
        Token token;
        token.tag = identify_keyword(lexer->source, start, lexer->index);
        token.loc.start = start;
        token.loc.end = lexer->index;
        return token;
    }
    
    // Operators and punctuation
    lexer->index++;
    Token token;
    token.loc.start = start;
    token.loc.end = lexer->index;
    
    switch (c) {
        case '+': token.tag = TOKEN_PLUS; break;
        case '-':
            if (lexer->index < lexer->source_len && 
                lexer->source[lexer->index] == '>') {
                lexer->index++;
                token.tag = TOKEN_ARROW;
                token.loc.end = lexer->index;
            } else {
                token.tag = TOKEN_MINUS;
            }
            break;
        case '*':
            if (lexer->index < lexer->source_len && 
                lexer->source[lexer->index] == '*') {
                lexer->index++;
                token.tag = TOKEN_STAR_STAR;
                token.loc.end = lexer->index;
            } else {
                token.tag = TOKEN_STAR;
            }
            break;
        case '/': token.tag = TOKEN_SLASH; break;
        case '%': token.tag = TOKEN_PERCENT; break;
        case '(': token.tag = TOKEN_LPAREN; break;
        case ')': token.tag = TOKEN_RPAREN; break;
        case '{': token.tag = TOKEN_LBRACE; break;
        case '}': token.tag = TOKEN_RBRACE; break;
        case '[': token.tag = TOKEN_LBRACKET; break;
        case ']': token.tag = TOKEN_RBRACKET; break;
        case '=':
            if (lexer->index < lexer->source_len) {
                if (lexer->source[lexer->index] == '=') {
                    lexer->index++;
                    token.tag = TOKEN_EQUAL_EQUAL;
                    token.loc.end = lexer->index;
                } else if (lexer->source[lexer->index] == '>') {
                    lexer->index++;
                    token.tag = TOKEN_FAT_ARROW;
                    token.loc.end = lexer->index;
                } else {
                    token.tag = TOKEN_EQUAL;
                }
            } else {
                token.tag = TOKEN_EQUAL;
            }
            break;
        case '!':
            if (lexer->index < lexer->source_len && 
                lexer->source[lexer->index] == '=') {
                lexer->index++;
                token.tag = TOKEN_BANG_EQUAL;
                token.loc.end = lexer->index;
            } else {
                token.tag = TOKEN_BANG;
            }
            break;
        case '<':
            if (lexer->index < lexer->source_len && 
                lexer->source[lexer->index] == '=') {
                lexer->index++;
                token.tag = TOKEN_LESS_EQUAL;
                token.loc.end = lexer->index;
            } else {
                token.tag = TOKEN_LESS;
            }
            break;
        case '>':
            if (lexer->index < lexer->source_len && 
                lexer->source[lexer->index] == '=') {
                lexer->index++;
                token.tag = TOKEN_GREATER_EQUAL;
                token.loc.end = lexer->index;
            } else {
                token.tag = TOKEN_GREATER;
            }
            break;
        case '&':
            if (lexer->index < lexer->source_len && 
                lexer->source[lexer->index] == '&') {
                lexer->index++;
                token.tag = TOKEN_AMPERSAND_AMPERSAND;
                token.loc.end = lexer->index;
            } else {
                token.tag = TOKEN_INVALID;
            }
            break;
        case '|':
            if (lexer->index < lexer->source_len && 
                lexer->source[lexer->index] == '|') {
                lexer->index++;
                token.tag = TOKEN_PIPE_PIPE;
                token.loc.end = lexer->index;
            } else {
                token.tag = TOKEN_PIPE;
            }
            break;
        case ';': token.tag = TOKEN_SEMICOLON; break;
        case ':': token.tag = TOKEN_COLON; break;
        case ',': token.tag = TOKEN_COMMA; break;
        case '.':
            if (lexer->index < lexer->source_len && 
                lexer->source[lexer->index] == '.') {
                lexer->index++;
                token.tag = TOKEN_DOT_DOT;
                token.loc.end = lexer->index;
            } else {
                token.tag = TOKEN_DOT;
            }
            break;
        case '?': token.tag = TOKEN_QUESTION; break;
        default: token.tag = TOKEN_INVALID; break;
    }
    
    return token;
}

// Peek at next token without advancing
Token lexer_peek(Lexer* lexer) {
    Lexer copy = *lexer;
    return lexer_next(&copy);
}

// Convert token tag to string for debugging
const char* token_tag_to_string(TokenTag tag) {
    switch (tag) {
        case TOKEN_EOF: return "EOF";
        case TOKEN_NUMBER: return "NUMBER";
        case TOKEN_FLOAT: return "FLOAT";
        case TOKEN_STRING: return "STRING";
        case TOKEN_IDENTIFIER: return "IDENTIFIER";
        case TOKEN_CONST_KW: return "CONST";
        case TOKEN_LET_KW: return "LET";
        case TOKEN_TRUE_KW: return "TRUE";
        case TOKEN_FALSE_KW: return "FALSE";
        case TOKEN_NULL_KW: return "NULL";
        case TOKEN_IF_KW: return "IF";
        case TOKEN_ELSE_KW: return "ELSE";
        case TOKEN_WHILE_KW: return "WHILE";
        case TOKEN_FOR_KW: return "FOR";
        case TOKEN_IN_KW: return "IN";
        case TOKEN_MATCH_KW: return "MATCH";
        case TOKEN_INT_KW: return "INT";
        case TOKEN_FLOAT_KW: return "FLOAT_KW";
        case TOKEN_STR_KW: return "STR";
        case TOKEN_BOOL_KW: return "BOOL";
        case TOKEN_FN_KW: return "FN";
        case TOKEN_RETURN_KW: return "RETURN";
        case TOKEN_STRUCT_KW: return "STRUCT";
        case TOKEN_IS_KW: return "IS";
        case TOKEN_NOT_KW: return "NOT";
        case TOKEN_TYPE_KW: return "TYPE";
        case TOKEN_TAKE_KW: return "TAKE";
        case TOKEN_FROM_KW: return "FROM";
        case TOKEN_PLUS: return "+";
        case TOKEN_MINUS: return "-";
        case TOKEN_STAR: return "*";
        case TOKEN_SLASH: return "/";
        case TOKEN_PERCENT: return "%";
        case TOKEN_STAR_STAR: return "**";
        case TOKEN_LPAREN: return "(";
        case TOKEN_RPAREN: return ")";
        case TOKEN_LBRACE: return "{";
        case TOKEN_RBRACE: return "}";
        case TOKEN_LBRACKET: return "[";
        case TOKEN_RBRACKET: return "]";
        case TOKEN_EQUAL: return "=";
        case TOKEN_EQUAL_EQUAL: return "==";
        case TOKEN_BANG: return "!";
        case TOKEN_BANG_EQUAL: return "!=";
        case TOKEN_LESS: return "<";
        case TOKEN_LESS_EQUAL: return "<=";
        case TOKEN_GREATER: return ">";
        case TOKEN_GREATER_EQUAL: return ">=";
        case TOKEN_AMPERSAND_AMPERSAND: return "&&";
        case TOKEN_PIPE: return "|";
        case TOKEN_PIPE_PIPE: return "||";
        case TOKEN_SEMICOLON: return ";";
        case TOKEN_COLON: return ":";
        case TOKEN_COMMA: return ",";
        case TOKEN_ARROW: return "->";
        case TOKEN_FAT_ARROW: return "=>";
        case TOKEN_DOT: return ".";
        case TOKEN_DOT_DOT: return "..";
        case TOKEN_QUESTION: return "?";
        case TOKEN_INVALID: return "INVALID";
        default: return "UNKNOWN";
    }
}
