#include "error_reporter.h"
#include <stdio.h>
#include <string.h>

// Initialize error reporter
ErrorReporter error_reporter_init(const char* source, size_t source_len, const char* file_path) {
    ErrorReporter reporter;
    reporter.source = source;
    reporter.source_len = source_len;
    reporter.file_path = file_path;
    return reporter;
}

// Convert byte offset to line and column numbers (1-indexed)
LineCol error_reporter_get_line_col(const ErrorReporter* reporter, size_t offset) {
    LineCol result;
    result.line = 1;
    result.col = 1;
    
    for (size_t i = 0; i < offset && i < reporter->source_len; i++) {
        if (reporter->source[i] == '\n') {
            result.line++;
            result.col = 1;
        } else {
            result.col++;
        }
    }
    
    return result;
}

// Get the line content at a specific offset
Slice error_reporter_get_line(const ErrorReporter* reporter, size_t offset) {
    // Find start of line
    size_t start = offset;
    while (start > 0 && reporter->source[start - 1] != '\n') {
        start--;
    }
    
    // Find end of line
    size_t end = offset;
    while (end < reporter->source_len && reporter->source[end] != '\n') {
        end++;
    }
    
    return slice_from_ptr_len(reporter->source + start, end - start);
}

// Print an error with source context
void error_reporter_report_error(const ErrorReporter* reporter, const char* error_type,
                                   const char* message, TokenLoc loc) {
    LineCol pos = error_reporter_get_line_col(reporter, loc.start);
    Slice line_content = error_reporter_get_line(reporter, loc.start);
    
    // Calculate column position relative to line start
    size_t col_in_line = pos.col - 1;
    
    // Calculate error span length
    size_t error_len = loc.end - loc.start;
    if (error_len > line_content.length - col_in_line) {
        error_len = line_content.length - col_in_line;
    }
    
    // Print error location and message
    fprintf(stderr, "\n%s:%zu:%zu: %s: %s\n",
            reporter->file_path, pos.line, pos.col, error_type, message);
    
    // Print the source line
    fprintf(stderr, "%zu | %.*s\n", pos.line, (int)line_content.length, line_content.data);
    
    // Print caret(s) pointing to the error
    fprintf(stderr, "  | ");
    for (size_t i = 0; i < col_in_line; i++) {
        fprintf(stderr, " ");
    }
    for (size_t i = 0; i < error_len; i++) {
        fprintf(stderr, "^");
    }
    fprintf(stderr, "\n");
}

// Report error at a specific token location
void error_reporter_report_token_error(const ErrorReporter* reporter, const char* error_type,
                                         const char* message, Token token) {
    error_reporter_report_error(reporter, error_type, message, token.loc);
}

// Report error with expected vs got information
void error_reporter_report_expected_error(const ErrorReporter* reporter, const char* expected,
                                            Token got) {
    Slice got_text = slice_from_ptr_len(
        reporter->source + got.loc.start,
        got.loc.end - got.loc.start
    );
    
    // Use a stack buffer for the error message
    char buf[256];
    int written = snprintf(buf, sizeof(buf), "Expected %s, but got '%.*s'",
                          expected, (int)got_text.length, got_text.data);
    
    const char* message;
    if (written < 0 || (size_t)written >= sizeof(buf)) {
        message = "Expected token (message too long)";
    } else {
        message = buf;
    }
    
    error_reporter_report_token_error(reporter, "error", message, got);
}
