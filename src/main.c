#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "common.h"
#include "frontend/lexer.h"
#include "utils/error_reporter.h"

int main(int argc, char** argv) {
    printf("Elba Programming Language - C Version\n");
    printf("=======================================\n\n");
    
    if (argc < 2) {
        printf("Usage: %s <file.elba>\n", argv[0]);
        printf("       %s --version\n", argv[0]);
        printf("       %s --help\n", argv[0]);
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
        return 0;
    }
    
    // Test lexer with simple input
    const char* test_source = "let x = 42;\nlet y = 3.14;\nif (x > 10) { return true; }";
    size_t source_len = strlen(test_source);
    
    printf("Testing lexer with:\n%s\n\n", test_source);
    printf("Tokens:\n");
    
    Lexer lexer = lexer_init(test_source, source_len);
    Token token;
    
    do {
        token = lexer_next(&lexer);
        const char* tag_str = token_tag_to_string(token.tag);
        Slice text = slice_from_ptr_len(
            test_source + token.loc.start,
            token.loc.end - token.loc.start
        );
        
        printf("  %-20s at %zu:%zu  ", tag_str, token.loc.start, token.loc.end);
        if (text.length > 0) {
            printf("'%.*s'", (int)text.length, text.data);
        }
        printf("\n");
    } while (token.tag != TOKEN_EOF);
    
    printf("\n");
    
    // Test error reporter
    printf("Testing error reporter:\n");
    ErrorReporter reporter = error_reporter_init(test_source, source_len, "test.elba");
    TokenLoc error_loc = { 4, 5 };  // Point to 'x' in "let x"
    error_reporter_report_error(&reporter, "warning", "This is a test warning", error_loc);
    
    printf("\nNote: Full compiler functionality (parser, typechecker, backends) not yet implemented.\n");
    printf("This is a demonstration of the C port infrastructure.\n");
    
    return 0;
}
