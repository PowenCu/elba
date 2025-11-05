#ifndef ELBA_ERROR_REPORTER_H
#define ELBA_ERROR_REPORTER_H

#include "../common.h"
#include "../frontend/lexer.h"

typedef struct {
    const char* source;
    size_t source_len;
    const char* file_path;
} ErrorReporter;

typedef struct {
    size_t line;
    size_t col;
} LineCol;

// Function declarations
ErrorReporter error_reporter_init(const char* source, size_t source_len, const char* file_path);
LineCol error_reporter_get_line_col(const ErrorReporter* reporter, size_t offset);
Slice error_reporter_get_line(const ErrorReporter* reporter, size_t offset);
void error_reporter_report_error(const ErrorReporter* reporter, const char* error_type, 
                                  const char* message, TokenLoc loc);
void error_reporter_report_token_error(const ErrorReporter* reporter, const char* error_type,
                                        const char* message, Token token);
void error_reporter_report_expected_error(const ErrorReporter* reporter, const char* expected,
                                           Token got);

#endif // ELBA_ERROR_REPORTER_H
