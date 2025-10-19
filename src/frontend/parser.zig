const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("lexer.zig").Token;
const Expr = @import("ast.zig").Expr;
const Stmt = @import("ast.zig").Stmt;
const Type = @import("ast.zig").Type;
const ErrorReporter = @import("../utils/error_reporter.zig").ErrorReporter;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: *Lexer,
    current: Token,
    source: []const u8,
    error_reporter: *const ErrorReporter,

    pub fn init(allocator: std.mem.Allocator, lexer: *Lexer, source: []const u8, error_reporter: *const ErrorReporter) !Parser {
        var parser = Parser{
            .allocator = allocator,
            .lexer = lexer,
            .current = undefined,
            .source = source,
            .error_reporter = error_reporter,
        };
        parser.current = lexer.next();
        return parser;
    }

    fn advance(self: *Parser) void {
        self.current = self.lexer.next();
    }

    fn expect(self: *Parser, tag: Token.Tag) !void {
        if (self.current.tag != tag) {
            const expected_name = @tagName(tag);
            self.error_reporter.reportExpectedError(expected_name, self.current);
            return error.UnexpectedToken;
        }
        self.advance();
    }

    pub fn parseStmt(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!?Stmt {
        // Check for invalid tokens from lexer
        if (self.current.tag == .invalid) {
            const char_text = self.source[self.current.loc.start..self.current.loc.end];
            self.error_reporter.reportTokenError(
                "error",
                if (char_text.len > 0)
                    std.fmt.allocPrint(
                        std.heap.page_allocator,
                        "Unexpected character: '{s}'",
                        .{char_text},
                    ) catch "Unexpected character"
                else
                    "Unexpected character",
                self.current,
            );
            return error.InvalidCharacter;
        }

        // Skip EOF
        if (self.current.tag == .eof) {
            return null;
        }

        // Function declarations
        if (self.current.tag == .fn_kw) {
            return try self.parseFnDecl();
        }

        // Struct declarations
        if (self.current.tag == .struct_kw) {
            return try self.parseStructDecl();
        }

        // Type alias declarations
        if (self.current.tag == .type_kw) {
            return try self.parseTypeAlias();
        }

        // Import statements
        if (self.current.tag == .take_kw) {
            return try self.parseImport();
        }

        // Return statements
        if (self.current.tag == .return_kw) {
            self.advance();
            const expr = try self.parseExpr();
            try self.expect(.semicolon);
            return Stmt{ .return_stmt = expr };
        }

        // const or let declarations
        if (self.current.tag == .const_kw or self.current.tag == .let_kw) {
            const is_const = self.current.tag == .const_kw;
            const decl_token = self.current;
            self.advance();

            if (self.current.tag != .identifier) {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected identifier after variable declaration",
                    decl_token,
                );
                return error.UnexpectedToken;
            }
            const name = self.source[self.current.loc.start..self.current.loc.end];
            self.advance();

            // Optional type annotation
            var type_annotation: ?Type = null;
            if (self.current.tag == .colon) {
                self.advance();
                type_annotation = try self.parseTypeAnnotation();
            }

            try self.expect(.equal);

            const value = try self.parseExpr();

            try self.expect(.semicolon);

            if (is_const) {
                return Stmt{ .const_decl = .{ .name = name, .type_annotation = type_annotation, .value = value } };
            } else {
                return Stmt{ .let_decl = .{ .name = name, .type_annotation = type_annotation, .value = value } };
            }
        }

        // Expression statement
        const expr = try self.parseExpr();

        // Semicolons are optional after block expressions (if, while, blocks)
        const needs_semicolon = switch (expr.*) {
            .if_expr, .while_expr, .block => false,
            else => true,
        };

        if (needs_semicolon) {
            try self.expect(.semicolon);
        } else if (self.current.tag == .semicolon) {
            // Allow optional semicolon after block expressions
            self.advance();
        }

        return Stmt{ .expr_stmt = expr };
    }

    fn parseTypeAnnotation(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!Type {
        // Handle array types: []int, []str, etc.
        if (self.current.tag == .lbracket) {
            self.advance(); // consume '['

            if (self.current.tag != .rbracket) {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected ']' immediately after '[' in array type (syntax: []int, []str, etc.)",
                    self.current,
                );
                return error.UnexpectedToken;
            }
            self.advance(); // consume ']'

            // Now parse the element type
            const elem_type = try self.parseTypeAnnotation();

            // Allocate the element type on the heap
            const elem_type_ptr = try self.allocator.create(Type);
            elem_type_ptr.* = elem_type;

            return Type{ .array = elem_type_ptr };
        }

        const type_tag = switch (self.current.tag) {
            .int_kw => blk: {
                self.advance();
                break :blk Type.int;
            },
            .float_kw => blk: {
                self.advance();
                break :blk Type.float;
            },
            .str_kw => blk: {
                self.advance();
                break :blk Type.string;
            },
            .bool_kw => blk: {
                self.advance();
                break :blk Type.bool;
            },
            .identifier => blk: {
                // User-defined type (struct) - may have generic type arguments
                const type_name = self.source[self.current.loc.start..self.current.loc.end];
                self.advance();

                // Check for generic type arguments like Box<int>
                const type_args = try self.parseTypeArgs(true); // true = in type context

                if (type_args.len > 0) {
                    // Generic instance like Box<int>
                    break :blk Type{ .generic_instance = .{
                        .base_type = type_name,
                        .type_args = type_args,
                    } };
                } else {
                    // Simple user type
                    break :blk Type{ .user_type = type_name };
                }
            },
            else => {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected type annotation (int, float, str, bool, or struct name)",
                    self.current,
                );
                return error.UnexpectedToken;
            },
        };

        // Check for optional type syntax (type?)
        if (self.current.tag == .question) {
            self.advance(); // consume '?'
            const inner_type_ptr = try self.allocator.create(Type);
            inner_type_ptr.* = type_tag;
            return Type{ .optional = inner_type_ptr };
        }

        // Check for union type syntax (type | type | ...)
        if (self.current.tag == .pipe) {
            var types = try std.ArrayList(Type).initCapacity(self.allocator, 2);
            errdefer types.deinit(self.allocator);

            try types.append(self.allocator, type_tag);

            while (self.current.tag == .pipe) {
                self.advance(); // consume '|'
                const next_type = try self.parseBasicType();
                try types.append(self.allocator, next_type);
            }

            return Type{ .union_type = try types.toOwnedSlice(self.allocator) };
        }

        return type_tag;
    }

    // Parse a basic type without union or optional
    fn parseBasicType(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!Type {
        // Handle array types: []int, []str, etc.
        if (self.current.tag == .lbracket) {
            self.advance(); // consume '['

            if (self.current.tag != .rbracket) {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected ']' immediately after '[' in array type (syntax: []int, []str, etc.)",
                    self.current,
                );
                return error.UnexpectedToken;
            }
            self.advance(); // consume ']'

            // Now parse the element type
            const elem_type = try self.parseBasicType();

            // Allocate the element type on the heap
            const elem_type_ptr = try self.allocator.create(Type);
            elem_type_ptr.* = elem_type;

            return Type{ .array = elem_type_ptr };
        }

        return switch (self.current.tag) {
            .int_kw => blk: {
                self.advance();
                break :blk Type.int;
            },
            .float_kw => blk: {
                self.advance();
                break :blk Type.float;
            },
            .str_kw => blk: {
                self.advance();
                break :blk Type.string;
            },
            .bool_kw => blk: {
                self.advance();
                break :blk Type.bool;
            },
            .identifier => blk: {
                // User-defined type (struct) - may have generic type arguments
                const type_name = self.source[self.current.loc.start..self.current.loc.end];
                self.advance();

                // Check for generic type arguments like Box<int>
                const type_args = try self.parseTypeArgs(true); // true = in type context

                if (type_args.len > 0) {
                    // Generic instance like Box<int>
                    break :blk Type{ .generic_instance = .{
                        .base_type = type_name,
                        .type_args = type_args,
                    } };
                } else {
                    // Simple user type
                    break :blk Type{ .user_type = type_name };
                }
            },
            else => {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected type annotation (int, float, str, bool, or struct name)",
                    self.current,
                );
                return error.UnexpectedToken;
            },
        };
    }

    // Parse generic type parameters like <T, U, V>
    fn parseTypeParams(self: *Parser) error{ UnexpectedToken, OutOfMemory }![][]const u8 {
        var type_params = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        errdefer type_params.deinit(self.allocator);

        // Check if there are type parameters
        if (self.current.tag != .less) {
            return try type_params.toOwnedSlice(self.allocator);
        }

        self.advance(); // consume '<'

        while (self.current.tag != .greater) {
            if (self.current.tag != .identifier) {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected type parameter name",
                    self.current,
                );
                return error.UnexpectedToken;
            }

            const param_name = self.source[self.current.loc.start..self.current.loc.end];
            try type_params.append(self.allocator, param_name);
            self.advance();

            if (self.current.tag == .comma) {
                self.advance();
            } else if (self.current.tag != .greater) {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected ',' or '>' in type parameter list",
                    self.current,
                );
                return error.UnexpectedToken;
            }
        }

        try self.expect(.greater);
        return try type_params.toOwnedSlice(self.allocator);
    }

    // Parse type arguments like <int, str>
    // in_type_context: true when parsing types (allows identifiers as type params)
    fn parseTypeArgs(self: *Parser, in_type_context: bool) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }![]Type {
        var type_args = try std.ArrayList(Type).initCapacity(self.allocator, 0);
        errdefer type_args.deinit(self.allocator);

        // Check if there are type arguments
        if (self.current.tag != .less) {
            return try type_args.toOwnedSlice(self.allocator);
        }

        // Use context to decide how to parse:
        // - In TYPE context: < always starts type args, identifiers allowed
        // - In EXPRESSION context: < starts type args only if followed by concrete types

        const saved_index = self.lexer.index;
        const saved_current = self.current;

        self.advance(); // consume '<'

        // In expression context, only accept concrete type keywords OR identifiers
        // (identifiers could be type parameters in generic contexts)
        // We'll validate by checking if the full pattern is `Name<...> {` (struct init)
        const is_valid_start = switch (self.current.tag) {
            .int_kw, .float_kw, .str_kw, .bool_kw, .lbracket => true,
            .identifier => true, // Allow identifiers, will validate pattern later
            else => false,
        };

        if (!is_valid_start) {
            // Not a type argument, backtrack
            self.lexer.index = saved_index;
            self.current = saved_current;
            return try type_args.toOwnedSlice(self.allocator);
        }

        // Parse the type argument list
        while (self.current.tag != .greater) {
            const type_arg = try self.parseTypeAnnotation();
            try type_args.append(self.allocator, type_arg);

            if (self.current.tag == .comma) {
                self.advance();
            } else if (self.current.tag != .greater) {
                // Failed to parse as type args, backtrack if in expression context
                if (!in_type_context) {
                    self.lexer.index = saved_index;
                    self.current = saved_current;
                    type_args.deinit(self.allocator);
                    var empty = try std.ArrayList(Type).initCapacity(self.allocator, 0);
                    return try empty.toOwnedSlice(self.allocator);
                }
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected ',' or '>' in type argument list",
                    self.current,
                );
                return error.UnexpectedToken;
            }
        }

        try self.expect(.greater);

        // In expression context with identifiers, validate the pattern
        // If not followed by `{` (struct init) or `(` (function call), it's likely a comparison
        if (!in_type_context and type_args.items.len > 0) {
            // Check if any type arg was an identifier (could be type param or variable)
            var has_identifier = false;
            for (type_args.items) |type_arg| {
                if (type_arg == .user_type) {
                    has_identifier = true;
                    break;
                }
            }

            if (has_identifier and self.current.tag != .lbrace and self.current.tag != .lparen) {
                // Pattern doesn't match struct init or function call, likely a comparison
                self.lexer.index = saved_index;
                self.current = saved_current;
                type_args.deinit(self.allocator);
                var empty = try std.ArrayList(Type).initCapacity(self.allocator, 0);
                return try empty.toOwnedSlice(self.allocator);
            }
        }

        return try type_args.toOwnedSlice(self.allocator);
    }

    fn parseFnDecl(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!Stmt {
        try self.expect(.fn_kw);

        // Function name
        if (self.current.tag != .identifier) {
            self.error_reporter.reportTokenError(
                "error",
                "Expected function name after 'fn'",
                self.current,
            );
            return error.UnexpectedToken;
        }
        const name = self.source[self.current.loc.start..self.current.loc.end];
        self.advance();

        // Optional generic type parameters <T, U>
        const type_params = try self.parseTypeParams();

        // Parameters
        try self.expect(.lparen);
        var parameters = try std.ArrayList(Stmt.Parameter).initCapacity(self.allocator, 0);
        defer parameters.deinit(self.allocator);

        while (self.current.tag != .rparen) {
            if (self.current.tag != .identifier) {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected parameter name",
                    self.current,
                );
                return error.UnexpectedToken;
            }
            const param_name = self.source[self.current.loc.start..self.current.loc.end];
            self.advance();

            try self.expect(.colon);
            const param_type = try self.parseTypeAnnotation();

            try parameters.append(self.allocator, .{ .name = param_name, .typ = param_type });

            if (self.current.tag == .comma) {
                self.advance();
            } else if (self.current.tag != .rparen) {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected ',' or ')' in parameter list",
                    self.current,
                );
                return error.UnexpectedToken;
            }
        }
        try self.expect(.rparen);

        // Return type (colon or arrow)
        var return_type: Type = .unit;
        if (self.current.tag == .colon) {
            self.advance();
            return_type = try self.parseTypeAnnotation();
        } else if (self.current.tag == .arrow) {
            self.advance();
            return_type = try self.parseTypeAnnotation();
        }

        // Function body (block expression)
        const body = try self.parseBlock();

        return Stmt{ .fn_decl = .{
            .name = name,
            .type_params = type_params,
            .parameters = try parameters.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .body = body,
        } };
    }

    fn parseTypeAlias(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!Stmt {
        try self.expect(.type_kw);

        // Alias name
        if (self.current.tag != .identifier) {
            self.error_reporter.reportTokenError(
                "error",
                "Expected type alias name after 'type'",
                self.current,
            );
            return error.UnexpectedToken;
        }
        const alias_name = self.source[self.current.loc.start..self.current.loc.end];
        self.advance();

        // Expect '='
        try self.expect(.equal);

        // Parse the target type
        const target_type = try self.parseTypeAnnotation();

        // Expect semicolon
        try self.expect(.semicolon);

        return Stmt{ .type_alias = .{
            .name = alias_name,
            .target_type = target_type,
        } };
    }

    fn parseImport(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!Stmt {
        try self.expect(.take_kw);

        // Check if it's selective import: take { name1, name2 } from "file"
        if (self.current.tag == .lbrace) {
            self.advance(); // consume '{'

            var import_names = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
            defer import_names.deinit(self.allocator);

            while (self.current.tag != .rbrace) {
                if (self.current.tag != .identifier) {
                    self.error_reporter.reportTokenError(
                        "error",
                        "Expected identifier in import list",
                        self.current,
                    );
                    return error.UnexpectedToken;
                }
                const name = self.source[self.current.loc.start..self.current.loc.end];
                try import_names.append(self.allocator, name);
                self.advance();

                if (self.current.tag == .comma) {
                    self.advance();
                } else if (self.current.tag != .rbrace) {
                    self.error_reporter.reportTokenError(
                        "error",
                        "Expected ',' or '}' in import list",
                        self.current,
                    );
                    return error.UnexpectedToken;
                }
            }
            try self.expect(.rbrace);

            // Expect 'from'
            try self.expect(.from_kw);

            // Expect string literal for module path
            if (self.current.tag != .string) {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected string literal for module path",
                    self.current,
                );
                return error.UnexpectedToken;
            }
            const module_path = self.source[self.current.loc.start + 1 .. self.current.loc.end - 1]; // Strip quotes
            self.advance();

            try self.expect(.semicolon);

            return Stmt{ .import_stmt = .{
                .module_path = module_path,
                .imports = try import_names.toOwnedSlice(self.allocator),
            } };
        }

        // Otherwise, it's a full import: take "file"
        if (self.current.tag != .string) {
            self.error_reporter.reportTokenError(
                "error",
                "Expected string literal for module path",
                self.current,
            );
            return error.UnexpectedToken;
        }
        const module_path = self.source[self.current.loc.start + 1 .. self.current.loc.end - 1]; // Strip quotes
        self.advance();

        try self.expect(.semicolon);

        return Stmt{
            .import_stmt = .{
                .module_path = module_path,
                .imports = null, // null means import all
            },
        };
    }

    fn parseStructDecl(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!Stmt {
        try self.expect(.struct_kw);

        // Struct name
        if (self.current.tag != .identifier) {
            self.error_reporter.reportTokenError(
                "error",
                "Expected struct name after 'struct'",
                self.current,
            );
            return error.UnexpectedToken;
        }
        const struct_name = self.source[self.current.loc.start..self.current.loc.end];
        self.advance();

        // Optional generic type parameters <T, U>
        const type_params = try self.parseTypeParams();

        // Fields and methods
        try self.expect(.lbrace);
        var fields = try std.ArrayList(Stmt.FieldDecl).initCapacity(self.allocator, 0);
        defer fields.deinit(self.allocator);
        var methods = try std.ArrayList(Stmt.MethodDecl).initCapacity(self.allocator, 0);
        defer methods.deinit(self.allocator);

        while (self.current.tag != .rbrace) {
            // Check if it's a method (fn keyword) or field (identifier)
            if (self.current.tag == .fn_kw) {
                // Parse method
                self.advance();

                if (self.current.tag != .identifier) {
                    self.error_reporter.reportTokenError(
                        "error",
                        "Expected method name after 'fn'",
                        self.current,
                    );
                    return error.UnexpectedToken;
                }
                const method_name = self.source[self.current.loc.start..self.current.loc.end];
                self.advance();

                // Parameters
                try self.expect(.lparen);
                var parameters = try std.ArrayList(Stmt.Parameter).initCapacity(self.allocator, 0);
                defer parameters.deinit(self.allocator);

                while (self.current.tag != .rparen) {
                    if (self.current.tag != .identifier) {
                        self.error_reporter.reportTokenError(
                            "error",
                            "Expected parameter name in method",
                            self.current,
                        );
                        return error.UnexpectedToken;
                    }
                    const param_name = self.source[self.current.loc.start..self.current.loc.end];
                    self.advance();

                    try self.expect(.colon);

                    // Parse the type annotation
                    const param_type = try self.parseTypeAnnotation();

                    try parameters.append(self.allocator, .{ .name = param_name, .typ = param_type });

                    if (self.current.tag == .comma) {
                        self.advance();
                    } else if (self.current.tag != .rparen) {
                        self.error_reporter.reportTokenError(
                            "error",
                            "Expected ',' or ')' in method parameter list",
                            self.current,
                        );
                        return error.UnexpectedToken;
                    }
                }
                try self.expect(.rparen);

                // Return type
                var return_type: Type = .unit;
                if (self.current.tag == .arrow) {
                    self.advance();
                    return_type = try self.parseTypeAnnotation();
                }

                // Body (parseBlock expects and consumes the lbrace)
                const body = try self.parseBlock();

                try methods.append(self.allocator, .{
                    .name = method_name,
                    .parameters = try parameters.toOwnedSlice(self.allocator),
                    .return_type = return_type,
                    .body = body,
                });

                // Semicolon after method is optional (for consistency with optional semicolons after blocks)
                if (self.current.tag == .semicolon) {
                    self.advance();
                }
            } else if (self.current.tag == .identifier) {
                // Parse field
                const field_name = self.source[self.current.loc.start..self.current.loc.end];
                self.advance();

                try self.expect(.colon);
                const field_type = try self.parseTypeAnnotation();

                try fields.append(self.allocator, .{ .name = field_name, .typ = field_type });

                // Require semicolon after field
                try self.expect(.semicolon);
            } else {
                self.error_reporter.reportTokenError(
                    "error",
                    "Expected field or method declaration in struct",
                    self.current,
                );
                return error.UnexpectedToken;
            }
        }
        try self.expect(.rbrace);

        // Optional semicolon after struct declaration
        if (self.current.tag == .semicolon) {
            self.advance();
        }

        return Stmt{ .struct_decl = .{
            .name = struct_name,
            .type_params = type_params,
            .fields = try fields.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
        } };
    }

    pub fn parseExpr(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        return try self.parseAssignment();
    }

    // Assignment (lowest precedence in expressions)
    fn parseAssignment(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        const left = try self.parseLogicalOr();

        // Check if this is an assignment
        if (self.current.tag == .equal) {
            // Left side must be a variable
            if (left.* != .variable) {
                std.debug.print("Assignment target must be a variable\n", .{});
                return error.UnexpectedToken;
            }

            self.advance();
            const value = try self.parseAssignment(); // Right associative

            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .assignment = .{
                    .name = left.variable,
                    .value = value,
                },
            };
            return expr;
        }

        return left;
    }

    // Logical OR
    fn parseLogicalOr(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        var left = try self.parseLogicalAnd();

        while (self.current.tag == .pipe_pipe) {
            self.advance();
            const right = try self.parseLogicalAnd();

            const new_left = try self.allocator.create(Expr);
            new_left.* = left.*;
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .binary = .{
                    .left = new_left,
                    .op = .logical_or,
                    .right = right,
                },
            };
            left = expr;
        }

        return left;
    }

    // Logical AND
    fn parseLogicalAnd(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        var left = try self.parseEquality();

        while (self.current.tag == .ampersand_ampersand) {
            self.advance();
            const right = try self.parseEquality();

            const new_left = try self.allocator.create(Expr);
            new_left.* = left.*;
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .binary = .{
                    .left = new_left,
                    .op = .logical_and,
                    .right = right,
                },
            };
            left = expr;
        }

        return left;
    }

    // Equality (==, !=)
    fn parseEquality(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        var left = try self.parseComparison();

        while (true) {
            const op: Expr.BinaryOp = switch (self.current.tag) {
                .equal_equal => .equal,
                .bang_equal => .not_equal,
                else => break,
            };
            self.advance();
            const right = try self.parseComparison();

            const new_left = try self.allocator.create(Expr);
            new_left.* = left.*;
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .binary = .{
                    .left = new_left,
                    .op = op,
                    .right = right,
                },
            };
            left = expr;
        }

        return left;
    }

    // Comparison (<, <=, >, >=) and Type Checking (is, is not)
    fn parseComparison(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        var left = try self.parseAddSub();

        while (true) {
            // Check for "is" type checking
            if (self.current.tag == .is_kw) {
                self.advance(); // consume 'is'

                // Check for "is not"
                const is_not = if (self.current.tag == .not_kw) blk: {
                    self.advance(); // consume 'not'
                    break :blk true;
                } else false;

                // Parse the type to check against
                const check_type = try self.parseTypeAnnotation();

                const new_left = try self.allocator.create(Expr);
                new_left.* = left.*;
                const expr = try self.allocator.create(Expr);
                expr.* = .{
                    .is_check = .{
                        .expr = new_left,
                        .check_type = check_type,
                        .is_not = is_not,
                    },
                };
                left = expr;
                continue;
            }

            const op: Expr.BinaryOp = switch (self.current.tag) {
                .less => .less,
                .less_equal => .less_equal,
                .greater => .greater,
                .greater_equal => .greater_equal,
                else => break,
            };
            self.advance();
            const right = try self.parseAddSub();

            const new_left = try self.allocator.create(Expr);
            new_left.* = left.*;
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .binary = .{
                    .left = new_left,
                    .op = op,
                    .right = right,
                },
            };
            left = expr;
        }

        return left;
    }

    // Addition and Subtraction
    // Addition and Subtraction
    fn parseAddSub(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        var left = try self.parseMulDiv();

        while (true) {
            const op: Expr.BinaryOp = switch (self.current.tag) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            self.advance();
            const right = try self.parseMulDiv();

            const new_left = try self.allocator.create(Expr);
            new_left.* = left.*;
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .binary = .{
                    .left = new_left,
                    .op = op,
                    .right = right,
                },
            };
            left = expr;
        }

        return left;
    }

    fn parseMulDiv(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        var left = try self.parsePower();

        while (true) {
            const op: Expr.BinaryOp = switch (self.current.tag) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => break,
            };
            self.advance();
            const right = try self.parsePower();

            const new_left = try self.allocator.create(Expr);
            new_left.* = left.*;
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .binary = .{
                    .left = new_left,
                    .op = op,
                    .right = right,
                },
            };
            left = expr;
        }

        return left;
    }

    fn parsePower(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        const left = try self.parseUnary();

        if (self.current.tag == .star_star) {
            self.advance();
            const right = try self.parsePower(); // Right associative

            const new_left = try self.allocator.create(Expr);
            new_left.* = left.*;
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .binary = .{
                    .left = new_left,
                    .op = .pow,
                    .right = right,
                },
            };
            return expr;
        }

        return left;
    }

    // Unary operators (!, -)
    fn parseUnary(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        if (self.current.tag == .bang) {
            self.advance();
            const operand = try self.parseUnary();
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .unary = .{
                    .op = .logical_not,
                    .operand = operand,
                },
            };
            return expr;
        }

        if (self.current.tag == .minus) {
            self.advance();
            const operand = try self.parseUnary();
            const expr = try self.allocator.create(Expr);
            expr.* = .{
                .unary = .{
                    .op = .negate,
                    .operand = operand,
                },
            };
            return expr;
        }

        return try self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        var expr = try self.parsePrimary();

        // Handle field access, method calls, and array indexing
        while (true) {
            if (self.current.tag == .dot) {
                self.advance();
                if (self.current.tag != .identifier) {
                    self.error_reporter.reportTokenError(
                        "error",
                        "Expected field or method name after '.'",
                        self.current,
                    );
                    return error.UnexpectedToken;
                }
                const name = self.source[self.current.loc.start..self.current.loc.end];
                self.advance();

                // Check if it's a method call (has parentheses)
                if (self.current.tag == .lparen) {
                    self.advance();

                    // Parse arguments
                    var arguments = try std.ArrayList(*Expr).initCapacity(self.allocator, 0);
                    defer arguments.deinit(self.allocator);

                    while (self.current.tag != .rparen) {
                        const arg = try self.parseExpr();
                        try arguments.append(self.allocator, arg);

                        if (self.current.tag == .comma) {
                            self.advance();
                        } else if (self.current.tag != .rparen) {
                            self.error_reporter.reportTokenError(
                                "error",
                                "Expected ',' or ')' in method call argument list",
                                self.current,
                            );
                            return error.UnexpectedToken;
                        }
                    }
                    try self.expect(.rparen);

                    const method_call_expr = try self.allocator.create(Expr);
                    method_call_expr.* = .{ .method_call = .{
                        .receiver = expr,
                        .method_name = name,
                        .arguments = try arguments.toOwnedSlice(self.allocator),
                    } };
                    expr = method_call_expr;
                } else {
                    // It's a field access
                    const field_access_expr = try self.allocator.create(Expr);
                    field_access_expr.* = .{ .field_access = .{
                        .object = expr,
                        .field_name = name,
                    } };
                    expr = field_access_expr;
                }
            } else if (self.current.tag == .lbracket) {
                // Array indexing: arr[index]
                self.advance(); // consume '['

                const index = try self.parseExpr();

                try self.expect(.rbracket);

                const access_expr = try self.allocator.create(Expr);
                access_expr.* = .{ .array_access = .{
                    .array = expr,
                    .index = index,
                } };
                expr = access_expr;
            } else {
                break;
            }
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        switch (self.current.tag) {
            .number => {
                const value = try std.fmt.parseInt(i64, self.source[self.current.loc.start..self.current.loc.end], 10);
                self.advance();
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .int_literal = value };
                return expr;
            },
            .float => {
                const value = try std.fmt.parseFloat(f64, self.source[self.current.loc.start..self.current.loc.end]);
                self.advance();
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .float_literal = value };
                return expr;
            },
            .string => {
                // Skip the quotes
                const value = self.source[self.current.loc.start + 1 .. self.current.loc.end - 1];
                self.advance();
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .string_literal = value };
                return expr;
            },
            .true_kw, .false_kw => {
                const value = self.current.tag == .true_kw;
                self.advance();
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .bool_literal = value };
                return expr;
            },
            .null_kw => {
                self.advance();
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .null_literal = {} };
                return expr;
            },
            .identifier => {
                const name = self.source[self.current.loc.start..self.current.loc.end];
                self.advance();

                // Parse optional type arguments <T, U>
                const type_args = try self.parseTypeArgs(false); // false = in expression context

                // Check if this is a struct initialization
                if (self.current.tag == .lbrace) {
                    self.advance();
                    var field_inits = try std.ArrayList(Expr.FieldInit).initCapacity(self.allocator, 0);
                    defer field_inits.deinit(self.allocator);

                    while (self.current.tag != .rbrace) {
                        if (self.current.tag != .identifier) {
                            self.error_reporter.reportTokenError(
                                "error",
                                "Expected field name in struct initialization",
                                self.current,
                            );
                            return error.UnexpectedToken;
                        }
                        const field_name = self.source[self.current.loc.start..self.current.loc.end];
                        self.advance();

                        try self.expect(.colon);

                        const field_value = try self.parseExpr();
                        try field_inits.append(self.allocator, .{ .name = field_name, .value = field_value });

                        // Require semicolon after each field in struct init
                        if (self.current.tag == .semicolon) {
                            self.advance();
                        } else if (self.current.tag != .rbrace) {
                            self.error_reporter.reportTokenError(
                                "error",
                                "Expected ';' or '}' in struct initialization",
                                self.current,
                            );
                            return error.UnexpectedToken;
                        }
                    }
                    try self.expect(.rbrace);

                    const expr = try self.allocator.create(Expr);
                    expr.* = .{ .struct_init = .{
                        .type_name = name,
                        .type_args = type_args,
                        .fields = try field_inits.toOwnedSlice(self.allocator),
                    } };
                    return expr;
                }

                // Check if this is a function call
                if (self.current.tag == .lparen) {
                    self.advance();
                    var arguments = try std.ArrayList(*Expr).initCapacity(self.allocator, 0);
                    defer arguments.deinit(self.allocator);

                    while (self.current.tag != .rparen) {
                        const arg = try self.parseExpr();
                        try arguments.append(self.allocator, arg);

                        if (self.current.tag == .comma) {
                            self.advance();
                        } else if (self.current.tag != .rparen) {
                            self.error_reporter.reportTokenError(
                                "error",
                                "Expected ',' or ')' in function call argument list",
                                self.current,
                            );
                            return error.UnexpectedToken;
                        }
                    }
                    try self.expect(.rparen);

                    const expr = try self.allocator.create(Expr);
                    expr.* = .{ .fn_call = .{
                        .name = name,
                        .type_args = type_args,
                        .arguments = try arguments.toOwnedSlice(self.allocator),
                    } };
                    return expr;
                }

                // Otherwise it's just a variable
                const expr = try self.allocator.create(Expr);
                expr.* = .{ .variable = name };
                return expr;
            },
            .lparen => {
                self.advance();
                const expr = try self.parseExpr();
                try self.expect(.rparen);
                return expr;
            },
            .lbrace => {
                return try self.parseBlock();
            },
            .lbracket => {
                // Parse array literal: [1, 2, 3]
                self.advance(); // consume '['

                var elements = try std.ArrayList(*Expr).initCapacity(self.allocator, 0);
                defer elements.deinit(self.allocator);

                while (self.current.tag != .rbracket and self.current.tag != .eof) {
                    const elem = try self.parseExpr();
                    try elements.append(self.allocator, elem);

                    if (self.current.tag == .comma) {
                        self.advance();
                    } else if (self.current.tag != .rbracket) {
                        self.error_reporter.reportTokenError(
                            "error",
                            "Expected ',' or ']' in array literal",
                            self.current,
                        );
                        return error.UnexpectedToken;
                    }
                }

                try self.expect(.rbracket);

                const expr = try self.allocator.create(Expr);
                expr.* = .{ .array_literal = .{
                    .elements = try elements.toOwnedSlice(self.allocator),
                } };
                return expr;
            },
            .if_kw => {
                return try self.parseIf();
            },
            .while_kw => {
                return try self.parseWhile();
            },
            else => {
                std.debug.print("Unexpected token in primary: {s}\n", .{@tagName(self.current.tag)});
                return error.UnexpectedToken;
            },
        }
    }

    fn parseBlock(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        try self.expect(.lbrace);

        var statements = try std.ArrayList(Stmt).initCapacity(self.allocator, 0);
        defer statements.deinit(self.allocator);
        var return_expr: ?*Expr = null;

        while (self.current.tag != .rbrace and self.current.tag != .eof) {
            // Try to parse a statement first (const/let/fn/return/expr with semicolon)
            if (self.current.tag == .const_kw or self.current.tag == .let_kw or self.current.tag == .return_kw) {
                const stmt = (try self.parseStmt()).?;
                try statements.append(self.allocator, stmt);
            } else {
                // Try to parse as expression
                const expr = try self.parseExpr();

                if (self.current.tag == .semicolon) {
                    self.advance();
                    try statements.append(self.allocator, Stmt{ .expr_stmt = expr });
                } else if (self.current.tag == .rbrace) {
                    // This is the return expression
                    return_expr = expr;
                    break;
                } else {
                    // If not followed by semicolon or rbrace, treat as expression statement
                    // This handles cases where control flow expressions (if/while) are followed by other statements
                    try statements.append(self.allocator, Stmt{ .expr_stmt = expr });
                }
            }
        }

        try self.expect(.rbrace);

        const expr = try self.allocator.create(Expr);
        expr.* = .{
            .block = .{
                .statements = try statements.toOwnedSlice(self.allocator),
                .return_expr = return_expr,
            },
        };
        return expr;
    }

    fn parseIf(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        try self.expect(.if_kw);
        try self.expect(.lparen);
        const condition = try self.parseExpr();
        try self.expect(.rparen);

        const then_block = try self.parseBlock();

        var else_block: ?*Expr = null;
        if (self.current.tag == .else_kw) {
            self.advance();
            if (self.current.tag == .if_kw) {
                else_block = try self.parseIf();
            } else {
                else_block = try self.parseBlock();
            }
        }

        const expr = try self.allocator.create(Expr);
        expr.* = .{
            .if_expr = .{
                .condition = condition,
                .then_block = then_block,
                .else_block = else_block,
            },
        };
        return expr;
    }

    fn parseWhile(self: *Parser) error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow }!*Expr {
        try self.expect(.while_kw);
        try self.expect(.lparen);
        const condition = try self.parseExpr();
        try self.expect(.rparen);

        const body = try self.parseBlock();

        const expr = try self.allocator.create(Expr);
        expr.* = .{
            .while_expr = .{
                .condition = condition,
                .body = body,
            },
        };
        return expr;
    }
};
