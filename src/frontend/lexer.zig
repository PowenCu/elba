const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Tag = enum {
        eof,
        number,
        float,
        string,
        identifier,
        const_kw,
        let_kw,
        true_kw,
        false_kw,
        null_kw,
        if_kw,
        else_kw,
        while_kw,
        for_kw,
        in_kw,
        match_kw,
        int_kw,
        float_kw,
        str_kw,
        bool_kw,
        fn_kw,
        return_kw,
        struct_kw,
        is_kw,
        not_kw,
        type_kw,
        take_kw,
        from_kw,
        plus,
        minus,
        star,
        slash,
        percent,
        star_star,
        lparen,
        rparen,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        equal,
        equal_equal,
        bang,
        bang_equal,
        less,
        less_equal,
        greater,
        greater_equal,
        ampersand_ampersand,
        pipe,
        pipe_pipe,
        semicolon,
        colon,
        comma,
        arrow,
        fat_arrow,
        dot,
        dot_dot,
        question,
        invalid, // For lexer errors
    };

    pub const Loc = struct {
        start: usize,
        end: usize,
    };
};

pub const Lexer = struct {
    source: []const u8,
    index: usize,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .index = 0,
        };
    }

    pub fn next(self: *Lexer) Token {
        while (self.index < self.source.len) {
            const c = self.source[self.index];

            // Skip whitespace
            if (std.ascii.isWhitespace(c)) {
                self.index += 1;
                continue;
            }

            // Skip comments
            if (c == '/' and self.index + 1 < self.source.len and self.source[self.index + 1] == '/') {
                // Skip until end of line or end of source
                while (self.index < self.source.len and self.source[self.index] != '\n') {
                    self.index += 1;
                }
                continue;
            }

            const start = self.index;

            // String literals
            if (c == '"') {
                self.index += 1;
                while (self.index < self.source.len and self.source[self.index] != '"') {
                    self.index += 1;
                }
                if (self.index < self.source.len) {
                    self.index += 1; // Skip closing quote
                }
                return .{
                    .tag = .string,
                    .loc = .{ .start = start, .end = self.index },
                };
            }

            // Numbers (including floats)
            if (std.ascii.isDigit(c)) {
                var has_dot = false;
                while (self.index < self.source.len) {
                    const ch = self.source[self.index];
                    if (std.ascii.isDigit(ch)) {
                        self.index += 1;
                    } else if (ch == '.' and !has_dot and self.index + 1 < self.source.len and std.ascii.isDigit(self.source[self.index + 1])) {
                        has_dot = true;
                        self.index += 1;
                    } else {
                        break;
                    }
                }
                return .{
                    .tag = if (has_dot) .float else .number,
                    .loc = .{ .start = start, .end = self.index },
                };
            }

            // Identifiers and keywords
            if (std.ascii.isAlphabetic(c) or c == '_') {
                while (self.index < self.source.len) {
                    const ch = self.source[self.index];
                    if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                        self.index += 1;
                    } else {
                        break;
                    }
                }
                const text = self.source[start..self.index];
                const tag: Token.Tag = if (std.mem.eql(u8, text, "const"))
                    .const_kw
                else if (std.mem.eql(u8, text, "let"))
                    .let_kw
                else if (std.mem.eql(u8, text, "true"))
                    .true_kw
                else if (std.mem.eql(u8, text, "false"))
                    .false_kw
                else if (std.mem.eql(u8, text, "null"))
                    .null_kw
                else if (std.mem.eql(u8, text, "if"))
                    .if_kw
                else if (std.mem.eql(u8, text, "else"))
                    .else_kw
                else if (std.mem.eql(u8, text, "while"))
                    .while_kw
                else if (std.mem.eql(u8, text, "for"))
                    .for_kw
                else if (std.mem.eql(u8, text, "in"))
                    .in_kw
                else if (std.mem.eql(u8, text, "match"))
                    .match_kw
                else if (std.mem.eql(u8, text, "int"))
                    .int_kw
                else if (std.mem.eql(u8, text, "float"))
                    .float_kw
                else if (std.mem.eql(u8, text, "str"))
                    .str_kw
                else if (std.mem.eql(u8, text, "bool"))
                    .bool_kw
                else if (std.mem.eql(u8, text, "fn"))
                    .fn_kw
                else if (std.mem.eql(u8, text, "return"))
                    .return_kw
                else if (std.mem.eql(u8, text, "struct"))
                    .struct_kw
                else if (std.mem.eql(u8, text, "is"))
                    .is_kw
                else if (std.mem.eql(u8, text, "not"))
                    .not_kw
                else if (std.mem.eql(u8, text, "type"))
                    .type_kw
                else if (std.mem.eql(u8, text, "take"))
                    .take_kw
                else if (std.mem.eql(u8, text, "from"))
                    .from_kw
                else
                    .identifier;
                return .{
                    .tag = tag,
                    .loc = .{ .start = start, .end = self.index },
                };
            }

            // Operators and punctuation
            self.index += 1;
            return switch (c) {
                '+' => .{ .tag = .plus, .loc = .{ .start = start, .end = self.index } },
                '-' => blk: {
                    if (self.index < self.source.len and self.source[self.index] == '>') {
                        self.index += 1;
                        break :blk .{ .tag = .arrow, .loc = .{ .start = start, .end = self.index } };
                    }
                    break :blk .{ .tag = .minus, .loc = .{ .start = start, .end = self.index } };
                },
                '*' => blk: {
                    if (self.index < self.source.len and self.source[self.index] == '*') {
                        self.index += 1;
                        break :blk .{ .tag = .star_star, .loc = .{ .start = start, .end = self.index } };
                    }
                    break :blk .{ .tag = .star, .loc = .{ .start = start, .end = self.index } };
                },
                '/' => .{ .tag = .slash, .loc = .{ .start = start, .end = self.index } },
                '%' => .{ .tag = .percent, .loc = .{ .start = start, .end = self.index } },
                '(' => .{ .tag = .lparen, .loc = .{ .start = start, .end = self.index } },
                ')' => .{ .tag = .rparen, .loc = .{ .start = start, .end = self.index } },
                '{' => .{ .tag = .lbrace, .loc = .{ .start = start, .end = self.index } },
                '}' => .{ .tag = .rbrace, .loc = .{ .start = start, .end = self.index } },
                '[' => .{ .tag = .lbracket, .loc = .{ .start = start, .end = self.index } },
                ']' => .{ .tag = .rbracket, .loc = .{ .start = start, .end = self.index } },
                '=' => blk: {
                    if (self.index < self.source.len and self.source[self.index] == '=') {
                        self.index += 1;
                        break :blk .{ .tag = .equal_equal, .loc = .{ .start = start, .end = self.index } };
                    }
                    if (self.index < self.source.len and self.source[self.index] == '>') {
                        self.index += 1;
                        break :blk .{ .tag = .fat_arrow, .loc = .{ .start = start, .end = self.index } };
                    }
                    break :blk .{ .tag = .equal, .loc = .{ .start = start, .end = self.index } };
                },
                '!' => blk: {
                    if (self.index < self.source.len and self.source[self.index] == '=') {
                        self.index += 1;
                        break :blk .{ .tag = .bang_equal, .loc = .{ .start = start, .end = self.index } };
                    }
                    break :blk .{ .tag = .bang, .loc = .{ .start = start, .end = self.index } };
                },
                '<' => blk: {
                    if (self.index < self.source.len and self.source[self.index] == '=') {
                        self.index += 1;
                        break :blk .{ .tag = .less_equal, .loc = .{ .start = start, .end = self.index } };
                    }
                    break :blk .{ .tag = .less, .loc = .{ .start = start, .end = self.index } };
                },
                '>' => blk: {
                    if (self.index < self.source.len and self.source[self.index] == '=') {
                        self.index += 1;
                        break :blk .{ .tag = .greater_equal, .loc = .{ .start = start, .end = self.index } };
                    }
                    break :blk .{ .tag = .greater, .loc = .{ .start = start, .end = self.index } };
                },
                '&' => blk: {
                    if (self.index < self.source.len and self.source[self.index] == '&') {
                        self.index += 1;
                        break :blk .{ .tag = .ampersand_ampersand, .loc = .{ .start = start, .end = self.index } };
                    }
                    break :blk .{ .tag = .invalid, .loc = .{ .start = start, .end = self.index } };
                },
                '|' => blk: {
                    if (self.index < self.source.len and self.source[self.index] == '|') {
                        self.index += 1;
                        break :blk .{ .tag = .pipe_pipe, .loc = .{ .start = start, .end = self.index } };
                    }
                    break :blk .{ .tag = .pipe, .loc = .{ .start = start, .end = self.index } };
                },
                ';' => .{ .tag = .semicolon, .loc = .{ .start = start, .end = self.index } },
                ':' => .{ .tag = .colon, .loc = .{ .start = start, .end = self.index } },
                ',' => .{ .tag = .comma, .loc = .{ .start = start, .end = self.index } },
                '.' => blk: {
                    if (self.index < self.source.len and self.source[self.index] == '.') {
                        self.index += 1;
                        break :blk .{ .tag = .dot_dot, .loc = .{ .start = start, .end = self.index } };
                    }
                    break :blk .{ .tag = .dot, .loc = .{ .start = start, .end = self.index } };
                },
                '?' => .{ .tag = .question, .loc = .{ .start = start, .end = self.index } },
                else => .{ .tag = .invalid, .loc = .{ .start = start, .end = self.index } },
            };
        }

        return .{
            .tag = .eof,
            .loc = .{ .start = self.index, .end = self.index },
        };
    }
};
