const std = @import("std");
const Token = @import("../frontend/lexer.zig").Token;

pub const ErrorReporter = struct {
    source: []const u8,
    file_path: []const u8,

    pub fn init(source: []const u8, file_path: []const u8) ErrorReporter {
        return .{
            .source = source,
            .file_path = file_path,
        };
    }

    /// Convert byte offset to line and column numbers (1-indexed)
    pub fn getLineCol(self: *const ErrorReporter, offset: usize) struct { line: usize, col: usize } {
        var line: usize = 1;
        var col: usize = 1;
        var i: usize = 0;

        while (i < offset and i < self.source.len) : (i += 1) {
            if (self.source[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }

        return .{ .line = line, .col = col };
    }

    /// Get the line content at a specific offset
    pub fn getLine(self: *const ErrorReporter, offset: usize) []const u8 {
        // Find start of line
        var start = offset;
        while (start > 0 and self.source[start - 1] != '\n') {
            start -= 1;
        }

        // Find end of line
        var end = offset;
        while (end < self.source.len and self.source[end] != '\n') {
            end += 1;
        }

        return self.source[start..end];
    }

    /// Print an error with source context
    pub fn reportError(
        self: *const ErrorReporter,
        error_type: []const u8,
        message: []const u8,
        loc: Token.Loc,
    ) void {
        const pos = self.getLineCol(loc.start);
        const line_content = self.getLine(loc.start);

        // Calculate column position relative to line start
        const col_in_line = pos.col - 1;

        // Calculate error span length
        const error_len = @min(loc.end - loc.start, line_content.len - col_in_line);

        std.debug.print("\n{s}:{d}:{d}: {s}: {s}\n", .{
            self.file_path,
            pos.line,
            pos.col,
            error_type,
            message,
        });

        // Print the source line
        std.debug.print("{d} | {s}\n", .{ pos.line, line_content });

        // Print caret(s) pointing to the error
        std.debug.print("  | ", .{});
        var i: usize = 0;
        while (i < col_in_line) : (i += 1) {
            std.debug.print(" ", .{});
        }
        i = 0;
        while (i < error_len) : (i += 1) {
            std.debug.print("^", .{});
        }
        std.debug.print("\n", .{});
    }

    /// Report error at a specific token location
    pub fn reportTokenError(
        self: *const ErrorReporter,
        error_type: []const u8,
        message: []const u8,
        token: Token,
    ) void {
        self.reportError(error_type, message, token.loc);
    }

    /// Report error with expected vs got information
    pub fn reportExpectedError(
        self: *const ErrorReporter,
        expected: []const u8,
        got: Token,
    ) void {
        const got_text = self.source[got.loc.start..got.loc.end];

        const message = std.fmt.allocPrint(
            std.heap.page_allocator,
            "Expected {s}, but got '{s}'",
            .{ expected, got_text },
        ) catch "Expected token not found";
        defer std.heap.page_allocator.free(message);

        self.reportTokenError("error", message, got);
    }
};
