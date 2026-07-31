const std = @import("std");
const Expr = @import("ast.zig").Expr;
const Stmt = @import("ast.zig").Stmt;
const Type = @import("ast.zig").Type;
const Parameter = @import("ast.zig").Stmt.Parameter;
const FieldDecl = @import("ast.zig").Stmt.FieldDecl;

fn typeToString(typ: Type, buf: []u8) []const u8 {
    switch (typ) {
        .int => return "int",
        .float => return "float",
        .string => return "str",
        .bool => return "bool",
        .unit => return "unit",
        .unknown => return "unknown",
        .user_type => |name| {
            return std.fmt.bufPrint(buf, "{s}", .{name}) catch name;
        },
        .generic_param => |name| {
            return std.fmt.bufPrint(buf, "{s}", .{name}) catch name;
        },
        .generic_instance => |inst| {
            // Format as Base<T1, T2, ...>
            var offset: usize = 0;

            // Write base type and opening bracket
            const base_part = std.fmt.bufPrint(buf[offset..], "{s}<", .{inst.base_type}) catch return inst.base_type;
            offset += base_part.len;

            // Write each type argument
            for (inst.type_args, 0..) |arg, i| {
                if (i > 0) {
                    const comma = std.fmt.bufPrint(buf[offset..], ", ", .{}) catch return inst.base_type;
                    offset += comma.len;
                }
                var temp_buf: [256]u8 = undefined;
                const arg_str = typeToString(arg, &temp_buf);
                const copied = std.fmt.bufPrint(buf[offset..], "{s}", .{arg_str}) catch return inst.base_type;
                offset += copied.len;
            }

            // Write closing bracket
            const close = std.fmt.bufPrint(buf[offset..], ">", .{}) catch return inst.base_type;
            offset += close.len;

            return buf[0..offset];
        },
        .array => |elem_type| {
            var temp_buf: [256]u8 = undefined;
            const elem_str = typeToString(elem_type.*, &temp_buf);
            return std.fmt.bufPrint(buf, "[]{s}", .{elem_str}) catch "[]?";
        },
        .optional => |inner_type| {
            var temp_buf: [256]u8 = undefined;
            const inner_str = typeToString(inner_type.*, &temp_buf);
            return std.fmt.bufPrint(buf, "{s}?", .{inner_str}) catch "?";
        },
        .union_type => |types| {
            var offset: usize = 0;
            for (types, 0..) |t, i| {
                if (i > 0) {
                    const pipe = std.fmt.bufPrint(buf[offset..], " | ", .{}) catch return "union";
                    offset += pipe.len;
                }
                var temp_buf: [256]u8 = undefined;
                const type_str = typeToString(t, &temp_buf);
                const copied = std.fmt.bufPrint(buf[offset..], "{s}", .{type_str}) catch return "union";
                offset += copied.len;
            }
            return buf[0..offset];
        },
    }
}

pub const VarInfo = struct {
    typ: Type,
    mutable: bool,
};

pub const FnSignature = struct {
    param_types: []Type,
    return_type: Type,
};

// Generic function template
pub const GenericFnTemplate = struct {
    type_params: [][]const u8,
    parameters: []Stmt.Parameter,
    return_type: Type,
    body: *const Expr,
};

pub const MethodSignature = struct {
    param_types: []Type, // Includes 'self' as first parameter
    return_type: Type,
    body: *const Expr, // Store body for execution
};

pub const StructDef = struct {
    fields: std.StringHashMap(Type),
    methods: std.StringHashMap(MethodSignature),
};

// Generic struct template
pub const GenericStructTemplate = struct {
    type_params: [][]const u8,
    fields: []Stmt.FieldDecl,
    methods: []Stmt.MethodDecl,
};

pub const TypeEnvironment = struct {
    allocator: std.mem.Allocator,
    types: std.StringHashMap(VarInfo),
    functions: std.StringHashMap(FnSignature),
    generic_functions: std.StringHashMap(GenericFnTemplate),
    structs: std.StringHashMap(StructDef),
    generic_structs: std.StringHashMap(GenericStructTemplate),
    type_aliases: std.StringHashMap(Type),
    allocated_slices: std.ArrayList([]Type),
    allocated_params: std.ArrayList([]Parameter),
    allocated_fields: std.ArrayList([]FieldDecl),
    allocated_types: std.ArrayList(*Type), // For array element types
    parent: ?*TypeEnvironment,
    loop_depth: usize,
    expected_return_type: ?Type,

    pub fn init(allocator: std.mem.Allocator) TypeEnvironment {
        return .{
            .allocator = allocator,
            .types = std.StringHashMap(VarInfo).init(allocator),
            .functions = std.StringHashMap(FnSignature).init(allocator),
            .generic_functions = std.StringHashMap(GenericFnTemplate).init(allocator),
            .structs = std.StringHashMap(StructDef).init(allocator),
            .generic_structs = std.StringHashMap(GenericStructTemplate).init(allocator),
            .type_aliases = std.StringHashMap(Type).init(allocator),
            .allocated_slices = std.ArrayList([]Type).initCapacity(allocator, 0) catch unreachable,
            .allocated_params = std.ArrayList([]Parameter).initCapacity(allocator, 0) catch unreachable,
            .allocated_fields = std.ArrayList([]FieldDecl).initCapacity(allocator, 0) catch unreachable,
            .allocated_types = std.ArrayList(*Type).initCapacity(allocator, 0) catch unreachable,
            .parent = null,
            .loop_depth = 0,
            .expected_return_type = null,
        };
    }

    pub fn initScoped(allocator: std.mem.Allocator, parent: *TypeEnvironment) TypeEnvironment {
        return .{
            .allocator = allocator,
            .types = std.StringHashMap(VarInfo).init(allocator),
            .functions = std.StringHashMap(FnSignature).init(allocator),
            .generic_functions = std.StringHashMap(GenericFnTemplate).init(allocator),
            .structs = std.StringHashMap(StructDef).init(allocator),
            .generic_structs = std.StringHashMap(GenericStructTemplate).init(allocator),
            .type_aliases = std.StringHashMap(Type).init(allocator),
            .allocated_slices = std.ArrayList([]Type).initCapacity(allocator, 0) catch unreachable,
            .allocated_params = std.ArrayList([]Parameter).initCapacity(allocator, 0) catch unreachable,
            .allocated_fields = std.ArrayList([]FieldDecl).initCapacity(allocator, 0) catch unreachable,
            .allocated_types = std.ArrayList(*Type).initCapacity(allocator, 0) catch unreachable,
            .parent = parent,
            .loop_depth = parent.loop_depth,
            .expected_return_type = parent.expected_return_type,
        };
    }

    pub fn deinit(self: *TypeEnvironment) void {
        self.types.deinit();
        self.functions.deinit();
        self.generic_functions.deinit();
        self.type_aliases.deinit();
        // Deinit all struct field and method maps
        var struct_iter = self.structs.iterator();
        while (struct_iter.next()) |entry| {
            entry.value_ptr.fields.deinit();
            entry.value_ptr.methods.deinit();
        }
        self.structs.deinit();
        self.generic_structs.deinit();
        // Free all allocated slices
        for (self.allocated_slices.items) |slice| {
            self.allocator.free(slice);
        }
        self.allocated_slices.deinit(self.allocator);
        // Free all allocated parameter slices
        for (self.allocated_params.items) |slice| {
            self.allocator.free(slice);
        }
        self.allocated_params.deinit(self.allocator);
        // Free all allocated field slices
        for (self.allocated_fields.items) |slice| {
            self.allocator.free(slice);
        }
        self.allocated_fields.deinit(self.allocator);
        // Free all allocated type pointers
        for (self.allocated_types.items) |type_ptr| {
            self.allocator.destroy(type_ptr);
        }
        self.allocated_types.deinit(self.allocator);
    }

    pub fn set(self: *TypeEnvironment, name: []const u8, info: VarInfo) !void {
        try self.types.put(name, info);
    }

    pub fn get(self: *TypeEnvironment, name: []const u8) ?VarInfo {
        if (self.types.get(name)) |info| {
            return info;
        }
        if (self.parent) |parent| {
            return parent.get(name);
        }
        return null;
    }

    pub fn getType(self: *TypeEnvironment, name: []const u8) ?Type {
        if (self.get(name)) |info| {
            return info.typ;
        }
        return null;
    }

    pub fn setFn(self: *TypeEnvironment, name: []const u8, signature: FnSignature) !void {
        try self.functions.put(name, signature);
    }

    pub fn getFn(self: *TypeEnvironment, name: []const u8) ?FnSignature {
        if (self.functions.get(name)) |sig| {
            return sig;
        }
        if (self.parent) |parent| {
            return parent.getFn(name);
        }
        return null;
    }

    pub fn setStruct(self: *TypeEnvironment, name: []const u8, def: StructDef) !void {
        try self.structs.put(name, def);
    }

    pub fn getStruct(self: *TypeEnvironment, name: []const u8) ?StructDef {
        if (self.structs.get(name)) |def| {
            return def;
        }
        if (self.parent) |parent| {
            return parent.getStruct(name);
        }
        return null;
    }

    pub fn setGenericFn(self: *TypeEnvironment, name: []const u8, template: GenericFnTemplate) !void {
        try self.generic_functions.put(name, template);
    }

    pub fn getGenericFn(self: *TypeEnvironment, name: []const u8) ?GenericFnTemplate {
        if (self.generic_functions.get(name)) |template| {
            return template;
        }
        if (self.parent) |parent| {
            return parent.getGenericFn(name);
        }
        return null;
    }

    pub fn setGenericStruct(self: *TypeEnvironment, name: []const u8, template: GenericStructTemplate) !void {
        try self.generic_structs.put(name, template);
    }

    pub fn getGenericStruct(self: *TypeEnvironment, name: []const u8) ?GenericStructTemplate {
        if (self.generic_structs.get(name)) |template| {
            return template;
        }
        if (self.parent) |parent| {
            return parent.getGenericStruct(name);
        }
        return null;
    }

    pub fn setTypeAlias(self: *TypeEnvironment, name: []const u8, target_type: Type) !void {
        try self.type_aliases.put(name, target_type);
    }

    pub fn getTypeAlias(self: *TypeEnvironment, name: []const u8) ?Type {
        if (self.type_aliases.get(name)) |typ| {
            return typ;
        }
        if (self.parent) |parent| {
            return parent.getTypeAlias(name);
        }
        return null;
    }
};

// Resolve type aliases recursively
fn resolveTypeAlias(typ: Type, env: *TypeEnvironment) Type {
    switch (typ) {
        .user_type => |name| {
            // Check if this is a type alias
            if (env.getTypeAlias(name)) |resolved| {
                // Recursively resolve in case the alias points to another alias
                return resolveTypeAlias(resolved, env);
            }
            return typ;
        },
        .optional => |inner_ptr| {
            // Resolve the inner type
            const resolved_inner = resolveTypeAlias(inner_ptr.*, env);
            // If the inner type changed, create a new optional with resolved type
            if (!resolved_inner.eql(inner_ptr.*)) {
                const new_inner_ptr = env.allocator.create(Type) catch return typ;
                new_inner_ptr.* = resolved_inner;
                env.allocated_types.append(env.allocator, new_inner_ptr) catch return typ;
                return Type{ .optional = new_inner_ptr };
            }
            return typ;
        },
        .array => |elem_ptr| {
            // Resolve the element type
            const resolved_elem = resolveTypeAlias(elem_ptr.*, env);
            if (!resolved_elem.eql(elem_ptr.*)) {
                const new_elem_ptr = env.allocator.create(Type) catch return typ;
                new_elem_ptr.* = resolved_elem;
                env.allocated_types.append(env.allocator, new_elem_ptr) catch return typ;
                return Type{ .array = new_elem_ptr };
            }
            return typ;
        },
        .union_type => |types| {
            // Resolve each type in the union
            var any_changed = false;
            var new_types = std.ArrayList(Type).initCapacity(env.allocator, types.len) catch return typ;
            defer {
                if (!any_changed) {
                    new_types.deinit(env.allocator);
                }
            }
            for (types) |t| {
                const resolved = resolveTypeAlias(t, env);
                new_types.append(env.allocator, resolved) catch return typ;
                if (!resolved.eql(t)) {
                    any_changed = true;
                }
            }
            if (any_changed) {
                const owned_slice = new_types.toOwnedSlice(env.allocator) catch return typ;
                env.allocated_slices.append(env.allocator, owned_slice) catch return typ;
                return Type{ .union_type = owned_slice };
            }
            return typ;
        },
        .generic_instance => |inst| {
            // Resolve type arguments
            var any_changed = false;
            var new_args = std.ArrayList(Type).initCapacity(env.allocator, inst.type_args.len) catch return typ;
            defer {
                if (!any_changed) {
                    new_args.deinit(env.allocator);
                }
            }
            for (inst.type_args) |arg| {
                const resolved = resolveTypeAlias(arg, env);
                new_args.append(env.allocator, resolved) catch return typ;
                if (!resolved.eql(arg)) {
                    any_changed = true;
                }
            }
            if (any_changed) {
                const owned_slice = new_args.toOwnedSlice(env.allocator) catch return typ;
                env.allocated_slices.append(env.allocator, owned_slice) catch return typ;
                return Type{ .generic_instance = .{
                    .base_type = inst.base_type,
                    .type_args = owned_slice,
                } };
            }
            return typ;
        },
        else => return typ,
    }
}

// Convert user_type to generic_param if it matches a type parameter name
fn convertToGenericType(typ: Type, type_params: [][]const u8) Type {
    switch (typ) {
        .user_type => |type_name| {
            // Check if this user type is actually a generic parameter
            for (type_params) |param_name| {
                if (std.mem.eql(u8, type_name, param_name)) {
                    return Type{ .generic_param = param_name };
                }
            }
            return typ;
        },
        else => return typ,
    }
}

fn substituteType(typ: Type, type_params: [][]const u8, type_args: []Type) Type {
    // Note: This function doesn't have access to an allocator - returning types-by-value
    // For complex types like generic_instance, use substituteTypeAlloc
    switch (typ) {
        .generic_param => |param_name| {
            // Find the parameter index and return corresponding type argument
            for (type_params, 0..) |tp, i| {
                if (std.mem.eql(u8, tp, param_name)) {
                    return type_args[i];
                }
            }
            // If not found, return as-is (shouldn't happen in valid code)
            return typ;
        },
        .user_type => |type_name| {
            // Check if this user_type is actually a type parameter
            for (type_params, 0..) |tp, i| {
                if (std.mem.eql(u8, tp, type_name)) {
                    return type_args[i];
                }
            }
            return typ;
        },
        else => return typ,
    }
}

// Allocator-aware version that can handle complex generic instances
fn substituteTypeAlloc(allocator: std.mem.Allocator, typ: Type, type_params: [][]const u8, type_args: []Type, env: *TypeEnvironment) !Type {
    switch (typ) {
        .generic_param => |param_name| {
            for (type_params, 0..) |tp, i| {
                if (std.mem.eql(u8, tp, param_name)) {
                    return type_args[i];
                }
            }
            return typ;
        },
        .user_type => |type_name| {
            for (type_params, 0..) |tp, i| {
                if (std.mem.eql(u8, tp, type_name)) {
                    return type_args[i];
                }
            }
            return typ;
        },
        .optional => |inner_ptr| {
            // Recursively substitute the inner type of optional
            const substituted_inner = try substituteTypeAlloc(allocator, inner_ptr.*, type_params, type_args, env);
            if (!substituted_inner.eql(inner_ptr.*)) {
                const new_inner_ptr = try allocator.create(Type);
                new_inner_ptr.* = substituted_inner;
                try env.allocated_types.append(env.allocator, new_inner_ptr);
                return Type{ .optional = new_inner_ptr };
            }
            return typ;
        },
        .array => |elem_ptr| {
            // Recursively substitute the element type of array
            const substituted_elem = try substituteTypeAlloc(allocator, elem_ptr.*, type_params, type_args, env);
            if (!substituted_elem.eql(elem_ptr.*)) {
                const new_elem_ptr = try allocator.create(Type);
                new_elem_ptr.* = substituted_elem;
                try env.allocated_types.append(env.allocator, new_elem_ptr);
                return Type{ .array = new_elem_ptr };
            }
            return typ;
        },
        .generic_instance => |inst| {
            // Recursively substitute type arguments in the generic instance
            var new_args = try allocator.alloc(Type, inst.type_args.len);
            var any_changed = false;

            for (inst.type_args, 0..) |arg, i| {
                const substituted = try substituteTypeAlloc(allocator, arg, type_params, type_args, env);
                new_args[i] = substituted;
                if (!substituted.eql(arg)) {
                    any_changed = true;
                }
            }

            if (any_changed) {
                try env.allocated_slices.append(env.allocator, new_args);
                return Type{ .generic_instance = .{
                    .base_type = inst.base_type,
                    .type_args = new_args,
                } };
            } else {
                allocator.free(new_args);
                return typ;
            }
        },
        else => return typ,
    }
}

fn containsGenericType(typ: Type) bool {
    return switch (typ) {
        .generic_param => true,
        .array => |inner| containsGenericType(inner.*),
        .optional => |inner| containsGenericType(inner.*),
        .generic_instance => |instance| blk: {
            for (instance.type_args) |arg| {
                if (containsGenericType(arg)) break :blk true;
            }
            break :blk false;
        },
        .union_type => |members| blk: {
            for (members) |member| {
                if (containsGenericType(member)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

// Check if a value type is compatible with a target type (including union types)
fn isTypeCompatible(value_type: Type, target_type: Type) bool {
    // Unknown targets are used by unconstrained builtin/generic parameters.
    // An unknown value is the null literal and is accepted only by optionals.
    if (target_type == .unknown) return true;

    // Direct match
    if (value_type.eql(target_type)) {
        return true;
    }

    // Optional targets accept null and values compatible with their payload.
    if (target_type == .optional) {
        if (value_type == .unknown) return true;
        return isTypeCompatible(value_type, target_type.optional.*);
    }

    if (value_type == .unknown) return false;

    // Check if target is a union type and value matches any constituent
    if (target_type == .union_type) {
        for (target_type.union_type) |t| {
            if (value_type.eql(t)) {
                return true;
            }
        }
    }

    // Check if value is union and target matches any constituent
    if (value_type == .union_type) {
        for (value_type.union_type) |t| {
            if (t.eql(target_type)) {
                return true;
            }
        }
    }

    return false;
}

fn checkArrayLiteralAgainstType(value: *const Expr, expected_type: Type, env: *TypeEnvironment) !void {
    const elements = value.array_literal.elements;
    const expected_element = expected_type.array.*;
    value.array_literal.resolved_element_type.* = expected_element;
    value.array_literal.resolved_array_type.* = expected_type;

    for (elements, 0..) |element, index| {
        if (element.* == .array_literal and expected_element == .array) {
            try checkArrayLiteralAgainstType(element, expected_element, env);
            continue;
        }

        const actual_type = try inferExpr(element, env);
        if (!isTypeCompatible(actual_type, expected_element) and
            !(expected_element == .float and actual_type == .int))
        {
            var expected_buf: [256]u8 = undefined;
            var actual_buf: [256]u8 = undefined;
            std.debug.print(
                "Type error: Array element {d} expects '{s}' but got '{s}'\n",
                .{ index, typeToString(expected_element, &expected_buf), typeToString(actual_type, &actual_buf) },
            );
            return error.TypeError;
        }
    }
}

fn contextualArrayType(expected_type: Type, env: *TypeEnvironment) ?Type {
    const resolved = resolveTypeAlias(expected_type, env);
    return switch (resolved) {
        .array => resolved,
        .optional => |inner| contextualArrayType(inner.*, env),
        .union_type => |members| blk: {
            var candidate: ?Type = null;
            for (members) |member| {
                if (contextualArrayType(member, env)) |array_type| {
                    if (candidate != null and !candidate.?.eql(array_type)) break :blk null;
                    candidate = array_type;
                }
            }
            break :blk candidate;
        },
        else => null,
    };
}

fn inferExprWithExpected(expr: *const Expr, expected_type: Type, env: *TypeEnvironment) !Type {
    const resolved_expected = resolveTypeAlias(expected_type, env);
    if (contextualArrayType(resolved_expected, env)) |array_expected| {
        switch (expr.*) {
            .array_literal => {
                try checkArrayLiteralAgainstType(expr, array_expected, env);
                return array_expected;
            },
            .block => |block| {
                var scoped_env = TypeEnvironment.initScoped(env.allocator, env);
                defer scoped_env.deinit();
                for (block.statements) |*statement| try checkStmt(statement, &scoped_env);
                if (block.return_expr) |return_expr| {
                    return inferExprWithExpected(return_expr, resolved_expected, &scoped_env);
                }
                return .unit;
            },
            .if_expr => |if_expr| {
                const condition_type = try inferExpr(if_expr.condition, env);
                if (condition_type != .bool) {
                    std.debug.print("Type error: If condition must be bool\n", .{});
                    return error.TypeError;
                }
                const then_type = try inferExprWithExpected(if_expr.then_block, resolved_expected, env);
                const else_block = if_expr.else_block orelse return .unit;
                const else_type = try inferExprWithExpected(else_block, resolved_expected, env);
                if (!isTypeCompatible(then_type, resolved_expected) or
                    !isTypeCompatible(else_type, resolved_expected))
                {
                    std.debug.print("Type error: If branch does not satisfy the expected array-containing type\n", .{});
                    return error.TypeError;
                }
                return resolved_expected;
            },
            .match_expr => |match_expr| {
                const match_type = try inferExpr(match_expr.expr, env);
                if (match_expr.arms.len == 0) return error.TypeError;
                for (match_expr.arms) |arm| {
                    try checkPatternType(arm.pattern, match_type);
                    var arm_env = TypeEnvironment.initScoped(env.allocator, env);
                    defer arm_env.deinit();
                    if (arm.pattern == .variable) {
                        try arm_env.set(arm.pattern.variable, .{ .typ = match_type, .mutable = false });
                    }
                    const arm_type = try inferExprWithExpected(arm.body, resolved_expected, &arm_env);
                    if (!isTypeCompatible(arm_type, resolved_expected)) {
                        std.debug.print("Type error: Match arm does not satisfy the expected array type\n", .{});
                        return error.TypeError;
                    }
                }
                try checkMatchExhaustiveness(match_expr, match_type, env.allocator);
                return resolved_expected;
            },
            else => {},
        }
    }
    return inferExpr(expr, env);
}

/// Helper to check variable declaration (const or let) with the same type checking logic
fn checkVarDecl(name: []const u8, value: *const Expr, type_annotation: ?Type, mutable: bool, env: *TypeEnvironment) !void {
    // If type annotation is provided, check it matches the value type
    if (type_annotation) |annotated_type| {
        // Resolve type alias
        const resolved_type = resolveTypeAlias(annotated_type, env);

        const value_type = try inferExprWithExpected(value, resolved_type, env);

        // Allow null assignment to optional types
        if (value_type == .unknown and resolved_type == .optional) {
            try env.set(name, .{ .typ = resolved_type, .mutable = mutable });
            return;
        }
        // Allow assigning non-optional value to optional type
        if (resolved_type == .optional) {
            const inner_type = resolved_type.optional.*;
            if (inner_type.eql(value_type)) {
                try env.set(name, .{ .typ = resolved_type, .mutable = mutable });
                return;
            }
        }
        // Check union type compatibility
        if (isTypeCompatible(value_type, resolved_type)) {
            try env.set(name, .{ .typ = resolved_type, .mutable = mutable });
            return;
        }
        // Allow implicit int->float conversion
        if (resolved_type == .float and value_type == .int) {
            try env.set(name, .{ .typ = .float, .mutable = mutable });
            return;
        }
        var buf1: [256]u8 = undefined;
        var buf2: [256]u8 = undefined;
        std.debug.print("Type error: Variable '{s}' declared as '{s}' but initialized with '{s}'\n", .{ name, typeToString(resolved_type, &buf1), typeToString(value_type, &buf2) });
        return error.TypeError;
    } else {
        // No type annotation, use inferred type
        const value_type = try inferExpr(value, env);
        try env.set(name, .{ .typ = value_type, .mutable = mutable });
    }
}

fn statementAlwaysReturns(statement: Stmt) bool {
    return switch (statement) {
        .return_stmt => true,
        .expr_stmt => |expr| expressionAlwaysReturns(expr),
        else => false,
    };
}

fn expressionAlwaysReturns(expr: *const Expr) bool {
    return switch (expr.*) {
        .block => |block| blk: {
            for (block.statements) |statement| {
                if (statementAlwaysReturns(statement)) break :blk true;
            }
            if (block.return_expr) |return_expr| {
                break :blk expressionAlwaysReturns(return_expr);
            }
            break :blk false;
        },
        .if_expr => |if_expr| if_expr.else_block != null and
            expressionAlwaysReturns(if_expr.then_block) and
            expressionAlwaysReturns(if_expr.else_block.?),
        .match_expr => |match_expr| blk: {
            if (match_expr.arms.len == 0) break :blk false;
            for (match_expr.arms) |arm| {
                if (!expressionAlwaysReturns(arm.body)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

pub fn checkStmt(stmt: *const Stmt, env: *TypeEnvironment) error{ TypeError, UndefinedVariable, OutOfMemory }!void {
    switch (stmt.*) {
        .const_decl => |decl| {
            try checkVarDecl(decl.name, decl.value, decl.type_annotation, false, env);
        },
        .let_decl => |decl| {
            try checkVarDecl(decl.name, decl.value, decl.type_annotation, true, env);
        },
        .fn_decl => |decl| {
            // Check if this is a generic function
            if (decl.type_params.len > 0) {
                // Convert user_type references to generic_param if they match type parameter names
                var generic_params = try env.allocator.alloc(Parameter, decl.parameters.len);
                try env.allocated_params.append(env.allocator, generic_params);

                for (decl.parameters, 0..) |param, i| {
                    const converted_type = convertToGenericType(param.typ, decl.type_params);
                    generic_params[i] = .{
                        .name = param.name,
                        .typ = converted_type,
                    };
                }

                const converted_return = convertToGenericType(decl.return_type, decl.type_params);

                // Store as generic template with converted types
                try env.setGenericFn(decl.name, .{
                    .type_params = decl.type_params,
                    .parameters = generic_params,
                    .return_type = converted_return,
                    .body = decl.body,
                });
                return;
            }

            // Non-generic function - check immediately
            // Extract parameter types and resolve aliases
            var param_types = try env.allocator.alloc(Type, decl.parameters.len);
            try env.allocated_slices.append(env.allocator, param_types);

            for (decl.parameters, 0..) |param, i| {
                param_types[i] = resolveTypeAlias(param.typ, env);
            }

            // Resolve return type alias
            const resolved_return_type = resolveTypeAlias(decl.return_type, env);

            // Register function signature
            try env.setFn(decl.name, .{
                .param_types = param_types,
                .return_type = resolved_return_type,
            });

            // Type check function body in new scope with parameters
            var fn_env = TypeEnvironment.initScoped(env.allocator, env);
            defer fn_env.deinit();
            // Function bodies cannot target a loop surrounding the declaration.
            fn_env.loop_depth = 0;
            fn_env.expected_return_type = resolved_return_type;

            for (decl.parameters, 0..) |param, i| {
                try fn_env.set(param.name, .{ .typ = param_types[i], .mutable = false });
            }

            const body_type = try inferExprWithExpected(decl.body, resolved_return_type, &fn_env);

            if (!isTypeCompatible(body_type, resolved_return_type) and !expressionAlwaysReturns(decl.body)) {
                var buf1: [256]u8 = undefined;
                var buf2: [256]u8 = undefined;
                std.debug.print("Type error: Function '{s}' declared to return '{s}' but body returns '{s}'\n", .{ decl.name, typeToString(resolved_return_type, &buf1), typeToString(body_type, &buf2) });
                return error.TypeError;
            }
        },
        .type_alias => |alias| {
            // Store the type alias
            try env.setTypeAlias(alias.name, alias.target_type);
        },
        .import_stmt => |import| {
            // Module imports are handled at a higher level (in main.zig)
            // The actual module statements will be processed individually
            _ = import;
        },
        .struct_decl => |decl| {
            // Check if this is a generic struct
            if (decl.type_params.len > 0) {
                // Convert user_type references to generic_param in fields
                var generic_fields = try env.allocator.alloc(FieldDecl, decl.fields.len);
                try env.allocated_fields.append(env.allocator, generic_fields);

                for (decl.fields, 0..) |field, i| {
                    const converted_type = convertToGenericType(field.typ, decl.type_params);
                    generic_fields[i] = .{
                        .name = field.name,
                        .typ = converted_type,
                    };
                }

                // Store as generic template with converted types
                try env.setGenericStruct(decl.name, .{
                    .type_params = decl.type_params,
                    .fields = generic_fields,
                    .methods = decl.methods,
                });
                return;
            }

            // Non-generic struct - check immediately
            // Create a field map for this struct with resolved types
            var fields = std.StringHashMap(Type).init(env.allocator);
            for (decl.fields) |field| {
                const resolved_field_type = resolveTypeAlias(field.typ, env);
                try fields.put(field.name, resolved_field_type);
            }

            // Create an empty method map
            const methods = std.StringHashMap(MethodSignature).init(env.allocator);

            // Register struct definition BEFORE checking method bodies
            // so that methods can reference the struct type
            try env.setStruct(decl.name, .{ .fields = fields, .methods = methods });

            // Now type check and add methods
            for (decl.methods) |method| {
                // Validate method: first parameter must be 'self'
                if (method.parameters.len == 0 or !std.mem.eql(u8, method.parameters[0].name, "self")) {
                    std.debug.print("Type error: Method '{s}' must have 'self' as first parameter\n", .{method.name});
                    return error.TypeError;
                }

                // Build parameter type array
                const param_types = try env.allocator.alloc(Type, method.parameters.len);
                for (method.parameters, 0..) |param, i| {
                    param_types[i] = param.typ;
                }
                try env.allocated_slices.append(env.allocator, param_types);

                // Type check method body in a scoped environment
                var method_env = TypeEnvironment.initScoped(env.allocator, env);
                defer method_env.deinit();
                method_env.loop_depth = 0;
                method_env.expected_return_type = method.return_type;

                for (method.parameters) |param| {
                    try method_env.set(param.name, .{ .typ = param.typ, .mutable = false });
                }

                const body_type = try inferExprWithExpected(method.body, method.return_type, &method_env);

                if (!isTypeCompatible(body_type, method.return_type) and !expressionAlwaysReturns(method.body)) {
                    var buf1: [256]u8 = undefined;
                    var buf2: [256]u8 = undefined;
                    std.debug.print("Type error: Method '{s}' declared to return '{s}' but body returns '{s}'\n", .{ method.name, typeToString(method.return_type, &buf1), typeToString(body_type, &buf2) });
                    return error.TypeError;
                }

                // Get the struct definition and add the method to it
                var struct_def = env.structs.getPtr(decl.name).?;
                try struct_def.methods.put(method.name, .{
                    .param_types = param_types,
                    .return_type = method.return_type,
                    .body = method.body,
                });
            }
        },
        .return_stmt => |maybe_expr| {
            const expected_type = env.expected_return_type orelse {
                std.debug.print("Type error: 'return' can only be used inside a function or method\n", .{});
                return error.TypeError;
            };

            if (maybe_expr) |expr| {
                const actual_type = try inferExprWithExpected(expr, expected_type, env);
                if (!isTypeCompatible(actual_type, expected_type)) {
                    var expected_buf: [256]u8 = undefined;
                    var actual_buf: [256]u8 = undefined;
                    std.debug.print(
                        "Type error: Return expects '{s}' but got '{s}'\n",
                        .{ typeToString(expected_type, &expected_buf), typeToString(actual_type, &actual_buf) },
                    );
                    return error.TypeError;
                }
            } else if (expected_type != .unit) {
                var expected_buf: [256]u8 = undefined;
                std.debug.print("Type error: Bare return cannot satisfy return type '{s}'\n", .{typeToString(expected_type, &expected_buf)});
                return error.TypeError;
            }
        },
        .break_stmt => {
            if (env.loop_depth == 0) {
                std.debug.print("Type error: 'break' can only be used inside a loop\n", .{});
                return error.TypeError;
            }
        },
        .continue_stmt => {
            if (env.loop_depth == 0) {
                std.debug.print("Type error: 'continue' can only be used inside a loop\n", .{});
                return error.TypeError;
            }
        },
        .expr_stmt => |expr| {
            _ = try inferExpr(expr, env);
        },
    }
}

fn assignmentRootName(expr: *const Expr) ?[]const u8 {
    return switch (expr.*) {
        .variable => |name| name,
        .field_access => |access| assignmentRootName(access.object),
        .array_access => |access| assignmentRootName(access.array),
        else => null,
    };
}

fn requireMutableTarget(expr: *const Expr, env: *TypeEnvironment) !void {
    const name = assignmentRootName(expr) orelse {
        std.debug.print("Type error: Assignment target is not backed by a variable\n", .{});
        return error.TypeError;
    };
    const variable = env.get(name) orelse return error.UndefinedVariable;
    if (!variable.mutable) {
        std.debug.print("Type error: Cannot mutate const variable '{s}'\n", .{name});
        return error.TypeError;
    }
}

fn checkPatternType(pattern: Expr.Pattern, match_type: Type) !void {
    switch (pattern) {
        .wildcard, .variable => {},
        .range => {
            if (match_type != .int) {
                std.debug.print("Type error: Range patterns can only match int values\n", .{});
                return error.TypeError;
            }
        },
        .literal => |literal| {
            const literal_type: Type = switch (literal) {
                .int => .int,
                .float => .float,
                .string => .string,
                .bool => .bool,
                .unit => .unit,
                .null_value => .unknown,
                .struct_instance, .array => return error.TypeError,
            };
            const null_matches = literal == .null_value and
                (match_type == .optional or match_type == .unknown);
            if (!null_matches and !isTypeCompatible(literal_type, match_type)) {
                var literal_buf: [256]u8 = undefined;
                var match_buf: [256]u8 = undefined;
                std.debug.print(
                    "Type error: Pattern type '{s}' cannot match value type '{s}'\n",
                    .{ typeToString(literal_type, &literal_buf), typeToString(match_type, &match_buf) },
                );
                return error.TypeError;
            }
        },
    }
}

const MatchInterval = struct {
    start: i128,
    end: i128,
};

fn patternInterval(pattern: Expr.Pattern) ?MatchInterval {
    return switch (pattern) {
        .literal => |literal| switch (literal) {
            .int => |value| .{ .start = value, .end = value },
            else => null,
        },
        .range => |range| blk: {
            const start: i128 = range.start;
            const end: i128 = if (range.inclusive) range.end else @as(i128, range.end) - 1;
            break :blk if (start <= end) .{ .start = start, .end = end } else null;
        },
        else => null,
    };
}

fn intervalLessThan(_: void, left: MatchInterval, right: MatchInterval) bool {
    return left.start < right.start or (left.start == right.start and left.end < right.end);
}

fn intervalCovered(interval: MatchInterval, covered: []const MatchInterval) bool {
    var cursor = interval.start;
    for (covered) |item| {
        if (item.end < cursor) continue;
        if (item.start > cursor) return false;
        cursor = item.end + 1;
        if (cursor > interval.end) return true;
    }
    return false;
}

fn addCoveredInterval(covered: *std.ArrayList(MatchInterval), allocator: std.mem.Allocator, interval: MatchInterval) !void {
    try covered.append(allocator, interval);
    std.mem.sort(MatchInterval, covered.items, {}, intervalLessThan);
    var merged_len: usize = 0;
    for (covered.items) |item| {
        if (merged_len == 0 or item.start > covered.items[merged_len - 1].end + 1) {
            covered.items[merged_len] = item;
            merged_len += 1;
        } else if (item.end > covered.items[merged_len - 1].end) {
            covered.items[merged_len - 1].end = item.end;
        }
    }
    covered.shrinkRetainingCapacity(merged_len);
}

fn checkMatchExhaustiveness(match_expr: Expr.Match, match_type: Type, allocator: std.mem.Allocator) !void {
    var intervals = try std.ArrayList(MatchInterval).initCapacity(allocator, match_expr.arms.len);
    defer intervals.deinit(allocator);
    var strings = std.StringHashMap(void).init(allocator);
    defer strings.deinit();
    var floats = std.AutoHashMap(u64, void).init(allocator);
    defer floats.deinit();

    var has_catch_all = false;
    var has_true = false;
    var has_false = false;
    var has_null = false;
    const integer_domain = MatchInterval{ .start = std.math.minInt(i64), .end = std.math.maxInt(i64) };

    for (match_expr.arms, 0..) |arm, index| {
        const domain_complete = has_catch_all or
            (match_type == .bool and has_true and has_false) or
            (match_type == .int and intervalCovered(integer_domain, intervals.items));
        if (domain_complete) {
            std.debug.print("Type error: Match arm {d} is unreachable because earlier patterns are exhaustive\n", .{index + 1});
            return error.TypeError;
        }

        switch (arm.pattern) {
            .wildcard, .variable => has_catch_all = true,
            .range => {
                const interval = patternInterval(arm.pattern) orelse {
                    std.debug.print("Type error: Match arm {d} has an empty integer range\n", .{index + 1});
                    return error.TypeError;
                };
                if (intervalCovered(interval, intervals.items)) {
                    std.debug.print("Type error: Match arm {d} is already covered by earlier integer patterns\n", .{index + 1});
                    return error.TypeError;
                }
                try addCoveredInterval(&intervals, allocator, interval);
            },
            .literal => |literal| switch (literal) {
                .int => {
                    const interval = patternInterval(arm.pattern).?;
                    if (intervalCovered(interval, intervals.items)) {
                        std.debug.print("Type error: Match arm {d} duplicates an earlier integer pattern\n", .{index + 1});
                        return error.TypeError;
                    }
                    try addCoveredInterval(&intervals, allocator, interval);
                },
                .bool => |value| {
                    const seen = if (value) has_true else has_false;
                    if (seen) {
                        std.debug.print("Type error: Match arm {d} duplicates an earlier boolean pattern\n", .{index + 1});
                        return error.TypeError;
                    }
                    if (value) has_true = true else has_false = true;
                },
                .null_value => {
                    if (has_null) {
                        std.debug.print("Type error: Match arm {d} duplicates an earlier null pattern\n", .{index + 1});
                        return error.TypeError;
                    }
                    has_null = true;
                },
                .string => |value| {
                    if (strings.contains(value)) {
                        std.debug.print("Type error: Match arm {d} duplicates an earlier string pattern\n", .{index + 1});
                        return error.TypeError;
                    }
                    try strings.put(value, {});
                },
                .float => |value| {
                    const bits: u64 = if (value == 0.0) 0 else @bitCast(value);
                    if (floats.contains(bits)) {
                        std.debug.print("Type error: Match arm {d} duplicates an earlier float pattern\n", .{index + 1});
                        return error.TypeError;
                    }
                    try floats.put(bits, {});
                },
                .unit, .struct_instance, .array => {},
            },
        }
    }

    const exhaustive = has_catch_all or
        (match_type == .bool and has_true and has_false) or
        (match_type == .int and intervalCovered(integer_domain, intervals.items));
    if (!exhaustive) {
        std.debug.print("Type error: Match expression is not exhaustive; add a wildcard or variable arm\n", .{});
        return error.TypeError;
    }
}

pub fn inferExpr(expr: *const Expr, env: *TypeEnvironment) error{ TypeError, UndefinedVariable, OutOfMemory }!Type {
    switch (expr.*) {
        .int_literal => return .int,
        .float_literal => return .float,
        .string_literal => return .string,
        .bool_literal => return .bool,
        .null_literal => {
            // Null has no standalone payload type; expected-type positions
            // restrict this internal marker to optionals.
            return .unknown;
        },
        .variable => |name| {
            if (env.getType(name)) |typ| {
                return typ;
            }
            std.debug.print("Type error: Undefined variable '{s}'\n", .{name});
            return error.UndefinedVariable;
        },
        .unary => |un| {
            const operand_type = try inferExpr(un.operand, env);

            switch (un.op) {
                .logical_not => {
                    if (operand_type != .bool) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Logical NOT requires bool operand, got '{s}'\n", .{typeToString(operand_type, &buf)});
                        return error.TypeError;
                    }
                    return .bool;
                },
                .negate => {
                    if (!operand_type.isNumeric()) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Negation requires numeric operand, got '{s}'\n", .{typeToString(operand_type, &buf)});
                        return error.TypeError;
                    }
                    return operand_type;
                },
            }
        },
        .optional_unwrap => |optional_expr| {
            const optional_type = try inferExpr(optional_expr, env);
            return switch (optional_type) {
                .optional => |inner| inner.*,
                else => {
                    var buf: [256]u8 = undefined;
                    std.debug.print("Type error: Postfix '!' requires an optional value, got '{s}'\n", .{typeToString(optional_type, &buf)});
                    return error.TypeError;
                },
            };
        },
        .optional_coalesce => |coalesce| {
            const optional_type = try inferExpr(coalesce.optional, env);
            const fallback_type = try inferExpr(coalesce.fallback, env);
            if (optional_type == .unknown) return fallback_type;
            const inner_type = switch (optional_type) {
                .optional => |inner| inner.*,
                else => {
                    var buf: [256]u8 = undefined;
                    std.debug.print("Type error: Left operand of '??' must be optional, got '{s}'\n", .{typeToString(optional_type, &buf)});
                    return error.TypeError;
                },
            };
            if (!isTypeCompatible(fallback_type, inner_type)) {
                var expected_buf: [256]u8 = undefined;
                var actual_buf: [256]u8 = undefined;
                std.debug.print(
                    "Type error: Fallback for '??' expects '{s}' but got '{s}'\n",
                    .{ typeToString(inner_type, &expected_buf), typeToString(fallback_type, &actual_buf) },
                );
                return error.TypeError;
            }
            return inner_type;
        },
        .binary => |bin| {
            const left_type = try inferExpr(bin.left, env);
            const right_type = try inferExpr(bin.right, env);

            // Check if operation is valid for these types
            switch (bin.op) {
                .add => {
                    // String concatenation
                    if (left_type == .string and right_type == .string) {
                        return .string;
                    }
                    // Numeric addition
                    if (!left_type.isNumeric()) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Cannot perform arithmetic on type '{s}'\n", .{typeToString(left_type, &buf)});
                        return error.TypeError;
                    }
                    if (!right_type.isNumeric()) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Cannot perform arithmetic on type '{s}'\n", .{typeToString(right_type, &buf)});
                        return error.TypeError;
                    }
                    // Implicit conversion: int + float -> float
                    if (left_type == .float or right_type == .float) {
                        return .float;
                    }
                    return .int;
                },
                .sub, .mul, .div, .mod, .pow => {
                    // Arithmetic operations require numeric types
                    if (!left_type.isNumeric()) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Cannot perform arithmetic on type '{s}'\n", .{typeToString(left_type, &buf)});
                        return error.TypeError;
                    }
                    if (!right_type.isNumeric()) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Cannot perform arithmetic on type '{s}'\n", .{typeToString(right_type, &buf)});
                        return error.TypeError;
                    }

                    // Implicit conversion: int + float -> float
                    if (left_type == .float or right_type == .float) {
                        return .float;
                    }

                    return .int;
                },
                .equal, .not_equal => {
                    // Allow null comparison with optional types
                    if (left_type == .unknown or right_type == .unknown) {
                        // One side is null, the other should be optional or also null
                        if (left_type == .unknown and right_type == .unknown) {
                            return .bool; // null == null
                        }
                        const non_null_type = if (left_type == .unknown) right_type else left_type;
                        // Check if non-null type is optional or we're comparing with a variable that could be optional
                        switch (non_null_type) {
                            .optional => return .bool,
                            else => {
                                var buf: [256]u8 = undefined;
                                std.debug.print("Type error: Cannot compare null with non-optional type '{s}'\n", .{typeToString(non_null_type, &buf)});
                                return error.TypeError;
                            },
                        }
                    }
                    // Equality works on same types
                    if (!left_type.eql(right_type)) {
                        var buf1: [256]u8 = undefined;
                        var buf2: [256]u8 = undefined;
                        std.debug.print("Type error: Cannot compare different types '{s}' and '{s}'\n", .{ typeToString(left_type, &buf1), typeToString(right_type, &buf2) });
                        return error.TypeError;
                    }
                    return .bool;
                },
                .less, .less_equal, .greater, .greater_equal => {
                    // Comparison requires numeric types
                    if (!left_type.isNumeric()) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Cannot compare non-numeric type '{s}'\n", .{typeToString(left_type, &buf)});
                        return error.TypeError;
                    }
                    if (!right_type.isNumeric()) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Cannot compare non-numeric type '{s}'\n", .{typeToString(right_type, &buf)});
                        return error.TypeError;
                    }
                    return .bool;
                },
                .logical_and, .logical_or => {
                    // Logical operations require bool types
                    if (left_type != .bool) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Logical operation requires bool, got '{s}'\n", .{typeToString(left_type, &buf)});
                        return error.TypeError;
                    }
                    if (right_type != .bool) {
                        var buf: [256]u8 = undefined;
                        std.debug.print("Type error: Logical operation requires bool, got '{s}'\n", .{typeToString(right_type, &buf)});
                        return error.TypeError;
                    }
                    return .bool;
                },
            }
        },
        .block => |blk| {
            var scoped_env = TypeEnvironment.initScoped(env.allocator, env);
            defer scoped_env.deinit();

            for (blk.statements) |stmt| {
                try checkStmt(&stmt, &scoped_env);
            }

            if (blk.return_expr) |ret_expr| {
                return try inferExpr(ret_expr, &scoped_env);
            } else {
                return .unit;
            }
        },
        .if_expr => |if_expr| {
            const cond_type = try inferExpr(if_expr.condition, env);
            if (cond_type != .bool) {
                var buf: [256]u8 = undefined;
                std.debug.print("Type error: If condition must be bool, got '{s}'\n", .{typeToString(cond_type, &buf)});
                return error.TypeError;
            }

            const then_type = try inferExpr(if_expr.then_block, env);

            if (if_expr.else_block) |else_block| {
                const else_type = try inferExpr(else_block, env);
                if (!then_type.eql(else_type)) {
                    var buf1: [256]u8 = undefined;
                    var buf2: [256]u8 = undefined;
                    std.debug.print("Type error: If branches must have same type, got '{s}' and '{s}'\n", .{ typeToString(then_type, &buf1), typeToString(else_type, &buf2) });
                    return error.TypeError;
                }
                return then_type;
            } else {
                if (then_type == .unit) {
                    return .unit;
                } else {
                    var buf: [256]u8 = undefined;
                    std.debug.print("Type error: If without else must have unit type in then branch, got '{s}'\n", .{typeToString(then_type, &buf)});
                    return error.TypeError;
                }
            }
        },
        .while_expr => |while_expr| {
            const cond_type = try inferExpr(while_expr.condition, env);
            if (cond_type != .bool) {
                var buf: [256]u8 = undefined;
                std.debug.print("Type error: While condition must be bool, got '{s}'\n", .{typeToString(cond_type, &buf)});
                return error.TypeError;
            }

            var loop_env = TypeEnvironment.initScoped(env.allocator, env);
            defer loop_env.deinit();
            loop_env.loop_depth = env.loop_depth + 1;
            _ = try inferExpr(while_expr.body, &loop_env);
            return .unit;
        },
        .assignment => |assign| {
            // Check if variable exists
            const var_info = env.get(assign.name) orelse {
                std.debug.print("Type error: Cannot assign to undefined variable '{s}'\n", .{assign.name});
                return error.UndefinedVariable;
            };

            // Check if variable is mutable
            if (!var_info.mutable) {
                std.debug.print("Type error: Cannot assign to const variable '{s}'\n", .{assign.name});
                return error.TypeError;
            }

            // Check if value type matches variable type
            const value_type = try inferExprWithExpected(assign.value, var_info.typ, env);

            // Allow null assignment to optional types
            if (value_type == .unknown and var_info.typ == .optional) {
                return .unit;
            }
            // Allow assigning non-optional value to optional type
            if (var_info.typ == .optional) {
                const inner_type = var_info.typ.optional.*;
                if (inner_type.eql(value_type)) {
                    return .unit;
                }
            }

            // Check union type compatibility
            if (isTypeCompatible(value_type, var_info.typ)) {
                return .unit;
            }

            if (!var_info.typ.eql(value_type)) {
                var buf1: [256]u8 = undefined;
                var buf2: [256]u8 = undefined;
                std.debug.print("Type error: Cannot assign '{s}' to variable '{s}' of type '{s}'\n", .{ typeToString(value_type, &buf1), assign.name, typeToString(var_info.typ, &buf2) });
                return error.TypeError;
            }

            // Assignment expressions return unit type
            return .unit;
        },
        .fn_call => |call| {
            // Native backends preserve scalar call types in IR, so printing is
            // intentionally limited to the scalar values every backend can
            // render consistently.
            if (std.mem.eql(u8, call.name, "print") or std.mem.eql(u8, call.name, "println")) {
                if (call.arguments.len != 1) {
                    std.debug.print("Type error: Function '{s}' expects 1 argument but got {d}\n", .{ call.name, call.arguments.len });
                    return error.TypeError;
                }
                const argument_type = try inferExpr(call.arguments[0], env);
                if (argument_type != .int and argument_type != .float and
                    argument_type != .string and argument_type != .bool)
                {
                    var actual_buf: [256]u8 = undefined;
                    std.debug.print(
                        "Type error: Function '{s}' can print only int, float, str, or bool values, got '{s}'\n",
                        .{ call.name, typeToString(argument_type, &actual_buf) },
                    );
                    return error.TypeError;
                }
                return .unit;
            }

            // Numeric helpers are overloaded, but only over a single concrete
            // numeric type. Mixed min/max arguments would otherwise reach the
            // runtime with ambiguous representations.
            if (std.mem.eql(u8, call.name, "abs") or
                std.mem.eql(u8, call.name, "min") or
                std.mem.eql(u8, call.name, "max"))
            {
                const expected_count: usize = if (std.mem.eql(u8, call.name, "abs")) 1 else 2;
                if (call.arguments.len != expected_count) {
                    std.debug.print(
                        "Type error: Function '{s}' expects {d} arguments but got {d}\n",
                        .{ call.name, expected_count, call.arguments.len },
                    );
                    return error.TypeError;
                }

                const first_type = try inferExpr(call.arguments[0], env);
                if (!first_type.isNumeric()) {
                    var actual_buf: [256]u8 = undefined;
                    std.debug.print(
                        "Type error: Function '{s}' expects numeric arguments, got '{s}'\n",
                        .{ call.name, typeToString(first_type, &actual_buf) },
                    );
                    return error.TypeError;
                }

                if (expected_count == 2) {
                    const second_type = try inferExpr(call.arguments[1], env);
                    if (!first_type.eql(second_type)) {
                        var first_buf: [256]u8 = undefined;
                        var second_buf: [256]u8 = undefined;
                        std.debug.print(
                            "Type error: Function '{s}' expects matching numeric types, got '{s}' and '{s}'\n",
                            .{ call.name, typeToString(first_type, &first_buf), typeToString(second_type, &second_buf) },
                        );
                        return error.TypeError;
                    }
                }
                return first_type;
            }

            // Array helpers have dependent types that cannot be represented by
            // the simple builtin signature table. Preserve the input array type
            // and validate its element/index arguments here.
            if (std.mem.eql(u8, call.name, "array_len") or
                std.mem.eql(u8, call.name, "array_push") or
                std.mem.eql(u8, call.name, "array_pop") or
                std.mem.eql(u8, call.name, "array_slice"))
            {
                const expected_count: usize = if (std.mem.eql(u8, call.name, "array_push"))
                    2
                else if (std.mem.eql(u8, call.name, "array_slice"))
                    3
                else
                    1;
                if (call.arguments.len != expected_count) {
                    std.debug.print(
                        "Type error: Function '{s}' expects {d} arguments but got {d}\n",
                        .{ call.name, expected_count, call.arguments.len },
                    );
                    return error.TypeError;
                }

                const array_type = try inferExpr(call.arguments[0], env);
                if (array_type != .array) {
                    std.debug.print("Type error: Function '{s}' expects an array as its first argument\n", .{call.name});
                    return error.TypeError;
                }

                if (std.mem.eql(u8, call.name, "array_len")) return .int;

                if (std.mem.eql(u8, call.name, "array_push")) {
                    const value_type = try inferExprWithExpected(call.arguments[1], array_type.array.*, env);
                    if (!isTypeCompatible(value_type, array_type.array.*)) {
                        var expected_buf: [256]u8 = undefined;
                        var actual_buf: [256]u8 = undefined;
                        std.debug.print(
                            "Type error: array_push expects element type '{s}' but got '{s}'\n",
                            .{ typeToString(array_type.array.*, &expected_buf), typeToString(value_type, &actual_buf) },
                        );
                        return error.TypeError;
                    }
                    return array_type;
                }

                if (std.mem.eql(u8, call.name, "array_slice")) {
                    const start_type = try inferExpr(call.arguments[1], env);
                    const end_type = try inferExpr(call.arguments[2], env);
                    if (start_type != .int or end_type != .int) {
                        std.debug.print("Type error: array_slice bounds must be int values\n", .{});
                        return error.TypeError;
                    }
                }
                return array_type;
            }

            // Check if it's a generic function call with type arguments
            if (call.type_args.len > 0) {
                // Look up generic template
                const template = env.getGenericFn(call.name) orelse {
                    std.debug.print("Type error: Undefined generic function '{s}'\n", .{call.name});
                    return error.UndefinedVariable;
                };

                // Validate type argument count
                if (call.type_args.len != template.type_params.len) {
                    std.debug.print("Type error: Generic function '{s}' expects {d} type arguments but got {d}\n", .{ call.name, template.type_params.len, call.type_args.len });
                    return error.TypeError;
                }

                // Substitute type parameters with type arguments
                var param_types = try env.allocator.alloc(Type, template.parameters.len);
                for (template.parameters, 0..) |param, i| {
                    param_types[i] = try substituteTypeAlloc(env.allocator, param.typ, template.type_params, call.type_args, env);
                }

                const return_type = try substituteTypeAlloc(env.allocator, template.return_type, template.type_params, call.type_args, env);

                // Check argument count and types
                if (call.arguments.len != param_types.len) {
                    std.debug.print("Type error: Function '{s}' expects {d} arguments but got {d}\n", .{ call.name, param_types.len, call.arguments.len });
                    env.allocator.free(param_types);
                    return error.TypeError;
                }

                for (call.arguments, 0..) |arg, i| {
                    const arg_type = try inferExprWithExpected(arg, param_types[i], env);
                    // Use isTypeCompatible to allow passing values to union parameters
                    if (!isTypeCompatible(arg_type, param_types[i])) {
                        var buf1: [256]u8 = undefined;
                        var buf2: [256]u8 = undefined;
                        std.debug.print("Type error: Function '{s}' parameter {d} expects '{s}' but got '{s}'\n", .{ call.name, i, typeToString(param_types[i], &buf1), typeToString(arg_type, &buf2) });
                        env.allocator.free(param_types);
                        return error.TypeError;
                    }
                }

                // Track allocation for cleanup
                try env.allocated_slices.append(env.allocator, param_types);
                return return_type;
            }

            // Non-generic function call
            // Look up function signature
            const signature = env.getFn(call.name) orelse {
                std.debug.print("Type error: Undefined function '{s}'\n", .{call.name});
                return error.UndefinedVariable;
            };

            // Check argument count
            if (call.arguments.len != signature.param_types.len) {
                std.debug.print("Type error: Function '{s}' expects {d} arguments but got {d}\n", .{ call.name, signature.param_types.len, call.arguments.len });
                return error.TypeError;
            }

            // Check argument types
            for (call.arguments, 0..) |arg, i| {
                const arg_type = try inferExprWithExpected(arg, signature.param_types[i], env);
                // Use isTypeCompatible to allow passing values to union parameters
                if (!isTypeCompatible(arg_type, signature.param_types[i])) {
                    var buf1: [256]u8 = undefined;
                    var buf2: [256]u8 = undefined;
                    std.debug.print("Type error: Function '{s}' parameter {d} expects '{s}' but got '{s}'\n", .{ call.name, i, typeToString(signature.param_types[i], &buf1), typeToString(arg_type, &buf2) });
                    return error.TypeError;
                }
            }

            return signature.return_type;
        },
        .struct_init => |init| {
            // Check if it's a generic struct instantiation with type arguments
            if (init.type_args.len > 0) {
                // Look up generic template
                const template = env.getGenericStruct(init.type_name) orelse {
                    std.debug.print("Type error: Undefined generic struct '{s}'\n", .{init.type_name});
                    return error.UndefinedVariable;
                };

                // Validate type argument count
                if (init.type_args.len != template.type_params.len) {
                    std.debug.print("Type error: Generic struct '{s}' expects {d} type arguments but got {d}\n", .{ init.type_name, template.type_params.len, init.type_args.len });
                    return error.TypeError;
                }

                // Substitute type parameters in fields
                for (init.fields) |field_init| {
                    // Find field in template
                    var found = false;
                    var expected_type: Type = .unknown;
                    for (template.fields) |field_decl| {
                        if (std.mem.eql(u8, field_decl.name, field_init.name)) {
                            expected_type = try substituteTypeAlloc(env.allocator, field_decl.typ, template.type_params, init.type_args, env);
                            found = true;
                            break;
                        }
                    }

                    if (!found) {
                        std.debug.print("Type error: Struct '{s}' has no field '{s}'\n", .{ init.type_name, field_init.name });
                        return error.TypeError;
                    }

                    const actual_type = try inferExprWithExpected(field_init.value, expected_type, env);

                    // Allow null assignment to optional fields
                    if (actual_type == .unknown and expected_type == .optional) {
                        continue;
                    }
                    // Allow assigning non-optional value to optional field
                    if (expected_type == .optional) {
                        const inner_type = expected_type.optional.*;
                        if (inner_type.eql(actual_type)) {
                            continue;
                        }
                    }

                    if (!actual_type.eql(expected_type)) {
                        var buf1: [256]u8 = undefined;
                        var buf2: [256]u8 = undefined;
                        std.debug.print("Type error: Field '{s}' of struct '{s}' expects '{s}' but got '{s}'\n", .{ field_init.name, init.type_name, typeToString(expected_type, &buf1), typeToString(actual_type, &buf2) });
                        return error.TypeError;
                    }
                }

                // Return generic instance type
                return Type{ .generic_instance = .{
                    .base_type = init.type_name,
                    .type_args = init.type_args,
                } };
            }

            // Non-generic struct
            // Look up struct definition
            const struct_def = env.getStruct(init.type_name) orelse {
                std.debug.print("Type error: Undefined struct '{s}'\n", .{init.type_name});
                return error.UndefinedVariable;
            };

            // Check that all fields are provided and have correct types
            for (init.fields) |field_init| {
                const expected_type = struct_def.fields.get(field_init.name) orelse {
                    std.debug.print("Type error: Struct '{s}' has no field '{s}'\n", .{ init.type_name, field_init.name });
                    return error.TypeError;
                };

                const actual_type = try inferExprWithExpected(field_init.value, expected_type, env);

                // Allow null assignment to optional fields
                if (actual_type == .unknown and expected_type == .optional) {
                    continue;
                }
                // Allow assigning non-optional value to optional field
                if (expected_type == .optional) {
                    const inner_type = expected_type.optional.*;
                    if (inner_type.eql(actual_type)) {
                        continue;
                    }
                }
                // Check union type compatibility
                if (isTypeCompatible(actual_type, expected_type)) {
                    continue;
                }

                if (!actual_type.eql(expected_type)) {
                    var buf1: [256]u8 = undefined;
                    var buf2: [256]u8 = undefined;
                    std.debug.print("Type error: Field '{s}' of struct '{s}' expects '{s}' but got '{s}'\n", .{ field_init.name, init.type_name, typeToString(expected_type, &buf1), typeToString(actual_type, &buf2) });
                    return error.TypeError;
                }
            }

            return Type{ .user_type = init.type_name };
        },
        .field_access => |access| {
            const object_type = try inferExpr(access.object, env);

            // Check if the object is a struct type
            switch (object_type) {
                .user_type => |struct_name| {
                    // Look up the struct definition
                    const struct_def = env.getStruct(struct_name) orelse {
                        std.debug.print("Type error: Undefined struct '{s}'\n", .{struct_name});
                        return error.UndefinedVariable;
                    };

                    // Look up the field type
                    const field_type = struct_def.fields.get(access.field_name) orelse {
                        std.debug.print("Type error: Struct '{s}' has no field '{s}'\n", .{ struct_name, access.field_name });
                        return error.TypeError;
                    };

                    return field_type;
                },
                .generic_instance => |inst| {
                    // Look up the generic struct template
                    const template = env.getGenericStruct(inst.base_type) orelse {
                        std.debug.print("Type error: Undefined generic struct '{s}'\n", .{inst.base_type});
                        return error.UndefinedVariable;
                    };

                    // Find the field in the template
                    var field_type: ?Type = null;
                    for (template.fields) |field| {
                        if (std.mem.eql(u8, field.name, access.field_name)) {
                            field_type = field.typ;
                            break;
                        }
                    }

                    const ft = field_type orelse {
                        std.debug.print("Type error: Struct '{s}' has no field '{s}'\n", .{ inst.base_type, access.field_name });
                        return error.TypeError;
                    };

                    // Substitute type parameters (use allocator-aware version for complex types)
                    return try substituteTypeAlloc(env.allocator, ft, template.type_params, inst.type_args, env);
                },
                else => {
                    var buf: [256]u8 = undefined;
                    std.debug.print("Type error: Cannot access field on non-struct type '{s}'\n", .{typeToString(object_type, &buf)});
                    return error.TypeError;
                },
            }
        },
        .method_call => |call| {
            // Get the receiver type
            const receiver_type = try inferExpr(call.receiver, env);

            // Check if the receiver is a struct type (including generic instances)
            switch (receiver_type) {
                .user_type => |struct_name| {
                    // Look up the struct definition
                    const struct_def = env.getStruct(struct_name) orelse {
                        std.debug.print("Type error: Undefined struct '{s}'\n", .{struct_name});
                        return error.UndefinedVariable;
                    };

                    // Look up the method
                    const method = struct_def.methods.get(call.method_name) orelse {
                        std.debug.print("Type error: Struct '{s}' has no method '{s}'\n", .{ struct_name, call.method_name });
                        return error.TypeError;
                    };

                    // Check argument count (excluding 'self' which is implicit)
                    const expected_args = method.param_types.len - 1; // -1 for self
                    if (call.arguments.len != expected_args) {
                        std.debug.print("Type error: Method '{s}' expects {d} arguments but got {d}\n", .{ call.method_name, expected_args, call.arguments.len });
                        return error.TypeError;
                    }

                    // Check argument types (skip index 0 which is 'self')
                    for (call.arguments, 0..) |arg, i| {
                        const expected_type = method.param_types[i + 1]; // +1 to skip 'self'
                        const arg_type = try inferExprWithExpected(arg, expected_type, env);
                        // Use isTypeCompatible to allow passing values to union parameters
                        if (!isTypeCompatible(arg_type, expected_type)) {
                            var buf1: [256]u8 = undefined;
                            var buf2: [256]u8 = undefined;
                            std.debug.print("Type error: Method '{s}' parameter {d} expects '{s}' but got '{s}'\n", .{ call.method_name, i, typeToString(expected_type, &buf1), typeToString(arg_type, &buf2) });
                            return error.TypeError;
                        }
                    }

                    return method.return_type;
                },
                .generic_instance => |instance| {
                    // Handle generic struct instances like Counter<str>
                    // Look up the generic struct template
                    const template = env.getGenericStruct(instance.base_type) orelse {
                        std.debug.print("Type error: Undefined generic struct '{s}'\n", .{instance.base_type});
                        return error.UndefinedVariable;
                    };

                    // Look up the method in the template (iterate through methods array)
                    var found_method: ?*const Stmt.MethodDecl = null;
                    for (template.methods) |*method| {
                        if (std.mem.eql(u8, method.name, call.method_name)) {
                            found_method = method;
                            break;
                        }
                    }

                    const method = found_method orelse {
                        std.debug.print("Type error: Struct '{s}' has no method '{s}'\n", .{ instance.base_type, call.method_name });
                        return error.TypeError;
                    };

                    // Check argument count (excluding 'self' which is implicit)
                    const expected_args = method.parameters.len - 1; // -1 for self
                    if (call.arguments.len != expected_args) {
                        std.debug.print("Type error: Method '{s}' expects {d} arguments but got {d}\n", .{ call.method_name, expected_args, call.arguments.len });
                        return error.TypeError;
                    }

                    // Check argument types (skip index 0 which is 'self')
                    for (call.arguments, 0..) |arg, i| {
                        // Substitute type parameters in the expected parameter type
                        const expected_type = try substituteTypeAlloc(env.allocator, method.parameters[i + 1].typ, template.type_params, instance.type_args, env); // +1 to skip 'self'
                        const arg_type = try inferExprWithExpected(arg, expected_type, env);
                        // Use isTypeCompatible to allow passing values to union parameters
                        if (!isTypeCompatible(arg_type, expected_type)) {
                            var buf1: [256]u8 = undefined;
                            var buf2: [256]u8 = undefined;
                            std.debug.print("Type error: Method '{s}' parameter {d} expects '{s}' but got '{s}'\n", .{ call.method_name, i, typeToString(expected_type, &buf1), typeToString(arg_type, &buf2) });
                            return error.TypeError;
                        }
                    }

                    // Substitute type parameters in the return type using the instance's type args
                    return try substituteTypeAlloc(env.allocator, method.return_type, template.type_params, instance.type_args, env);
                },
                else => {
                    var buf: [256]u8 = undefined;
                    std.debug.print("Type error: Cannot call method on non-struct type '{s}'\n", .{typeToString(receiver_type, &buf)});
                    return error.TypeError;
                },
            }
        },
        .array_literal => |literal| {
            // Array literals: [1, 2, 3]
            if (literal.elements.len == 0) {
                std.debug.print("Type error: Empty array literal requires an expected array type\n", .{});
                return error.TypeError;
            }

            // Infer type from first element
            const first_type = try inferExpr(literal.elements[0], env);
            literal.resolved_element_type.* = first_type;

            // Check that all elements have the same type
            for (literal.elements[1..], 1..) |elem, i| {
                const elem_type = try inferExpr(elem, env);
                if (!elem_type.eql(first_type)) {
                    var buf1: [256]u8 = undefined;
                    var buf2: [256]u8 = undefined;
                    std.debug.print("Type error: Array elements must have same type. Expected '{s}' but element {d} is '{s}'\n", .{ typeToString(first_type, &buf1), i, typeToString(elem_type, &buf2) });
                    return error.TypeError;
                }
            }

            // Allocate array type on heap
            const elem_type_ptr = try env.allocator.create(Type);
            elem_type_ptr.* = first_type;
            try env.allocated_types.append(env.allocator, elem_type_ptr);

            const array_type = Type{ .array = elem_type_ptr };
            literal.resolved_array_type.* = array_type;
            return array_type;
        },
        .array_access => |access| {
            // Array indexing: arr[0]
            const array_type = try inferExpr(access.array, env);
            const index_type = try inferExpr(access.index, env);

            // Check that index is an integer
            if (index_type != .int) {
                var buf: [256]u8 = undefined;
                std.debug.print("Type error: Array index must be int, got '{s}'\n", .{typeToString(index_type, &buf)});
                return error.TypeError;
            }

            // Check that we're indexing an array
            switch (array_type) {
                .array => |elem_type| {
                    return elem_type.*;
                },
                else => {
                    var buf: [256]u8 = undefined;
                    std.debug.print("Type error: Cannot index non-array type '{s}'\n", .{typeToString(array_type, &buf)});
                    return error.TypeError;
                },
            }
        },
        .is_check => |check| {
            // Type checking expression: x is int, x is not str
            // First, infer the type of the expression being checked
            const expr_type = resolveTypeAlias(try inferExpr(check.expr, env), env);
            const checked_type = resolveTypeAlias(check.check_type, env);
            check.resolved_type.* = checked_type;
            check.resolved_source_type.* = expr_type;

            // Ordinary statically typed values have an exact answer. Tagged
            // optional/union values keep their payload check dynamic.
            check.static_result.* = if (containsGenericType(expr_type) or containsGenericType(checked_type))
                null
            else switch (expr_type) {
                .optional, .union_type, .unknown => null,
                else => expr_type.eql(checked_type),
            };

            return .bool;
        },
        .for_expr => |for_expr| {
            // Infer the type of the iterable
            const iterable_type = try inferExpr(for_expr.iterable, env);

            // Create scoped environment for loop variable
            var scoped_env = TypeEnvironment.initScoped(env.allocator, env);
            defer scoped_env.deinit();
            scoped_env.loop_depth = env.loop_depth + 1;

            if (for_expr.is_range) {
                // Range-based for loop expects integer start and end bounds
                const end_expr = for_expr.range_end orelse {
                    std.debug.print("Type error: Range for loop is missing an end bound\n", .{});
                    return error.TypeError;
                };
                const end_type = try inferExpr(end_expr, env);

                if (iterable_type != .int or end_type != .int) {
                    std.debug.print("Type error: Range for loop requires int bounds\n", .{});
                    return error.TypeError;
                }

                // Iterator variable is int
                try scoped_env.set(for_expr.iterator, .{ .typ = .int, .mutable = false });
            } else {
                // Array-based for loop expects array type
                if (iterable_type != .array) {
                    std.debug.print("Type error: For loop requires array type\n", .{});
                    return error.TypeError;
                }
                // Iterator variable has element type
                const elem_type = iterable_type.array.*;
                try scoped_env.set(for_expr.iterator, .{ .typ = elem_type, .mutable = false });
            }

            // Check body
            _ = try inferExpr(for_expr.body, &scoped_env);

            // For loops return unit
            return .unit;
        },
        .match_expr => |match_expr| {
            // Infer type of expression being matched
            const match_type = try inferExpr(match_expr.expr, env);

            // All arms must return the same type
            if (match_expr.arms.len == 0) {
                std.debug.print("Type error: Match expression must have at least one arm\n", .{});
                return error.TypeError;
            }

            // Infer type from first arm
            const first_arm = match_expr.arms[0];
            try checkPatternType(first_arm.pattern, match_type);
            var scoped_env = TypeEnvironment.initScoped(env.allocator, env);
            defer scoped_env.deinit();

            // Bind pattern variable if needed
            if (first_arm.pattern == .variable) {
                try scoped_env.set(first_arm.pattern.variable, .{ .typ = match_type, .mutable = false });
            }

            const expected_type = try inferExpr(first_arm.body, &scoped_env);

            // Check all other arms return compatible type
            for (match_expr.arms[1..]) |arm| {
                try checkPatternType(arm.pattern, match_type);
                var arm_env = TypeEnvironment.initScoped(env.allocator, env);
                defer arm_env.deinit();

                if (arm.pattern == .variable) {
                    try arm_env.set(arm.pattern.variable, .{ .typ = match_type, .mutable = false });
                }

                const arm_type = try inferExpr(arm.body, &arm_env);
                if (!isTypeCompatible(arm_type, expected_type)) {
                    var buf1: [256]u8 = undefined;
                    var buf2: [256]u8 = undefined;
                    std.debug.print("Type error: Match arms must return same type, got '{s}' and '{s}'\n", .{ typeToString(expected_type, &buf1), typeToString(arm_type, &buf2) });
                    return error.TypeError;
                }
            }

            try checkMatchExhaustiveness(match_expr, match_type, env.allocator);

            return expected_type;
        },
        .field_assignment => |assign| {
            try requireMutableTarget(assign.object, env);

            // Check object type
            const object_type = try inferExpr(assign.object, env);
            const expected_type = switch (object_type) {
                .user_type => |struct_name| blk: {
                    const def = env.getStruct(struct_name) orelse {
                        std.debug.print("Type error: Undefined struct '{s}'\n", .{struct_name});
                        return error.UndefinedVariable;
                    };
                    break :blk def.fields.get(assign.field_name) orelse {
                        std.debug.print("Type error: Struct '{s}' has no field '{s}'\n", .{ struct_name, assign.field_name });
                        return error.TypeError;
                    };
                },
                .generic_instance => |instance| blk: {
                    const template = env.getGenericStruct(instance.base_type) orelse {
                        std.debug.print("Type error: Undefined generic struct '{s}'\n", .{instance.base_type});
                        return error.UndefinedVariable;
                    };
                    var template_type: ?Type = null;
                    for (template.fields) |field| {
                        if (std.mem.eql(u8, field.name, assign.field_name)) {
                            template_type = field.typ;
                            break;
                        }
                    }
                    const field_type = template_type orelse {
                        std.debug.print("Type error: Struct '{s}' has no field '{s}'\n", .{ instance.base_type, assign.field_name });
                        return error.TypeError;
                    };
                    break :blk try substituteTypeAlloc(env.allocator, field_type, template.type_params, instance.type_args, env);
                },
                else => {
                    std.debug.print("Type error: Cannot access field on non-struct type\n", .{});
                    return error.TypeError;
                },
            };

            const value_type = try inferExprWithExpected(assign.value, expected_type, env);
            if (!isTypeCompatible(value_type, expected_type)) {
                var expected_buf: [256]u8 = undefined;
                var actual_buf: [256]u8 = undefined;
                std.debug.print("Type error: Field '{s}' expects '{s}' but got '{s}'\n", .{ assign.field_name, typeToString(expected_type, &expected_buf), typeToString(value_type, &actual_buf) });
                return error.TypeError;
            }

            // Field assignment returns unit
            return .unit;
        },
        .array_assignment => |assign| {
            try requireMutableTarget(assign.array, env);

            // Check array type
            const array_type = try inferExpr(assign.array, env);
            if (array_type != .array) {
                std.debug.print("Type error: Cannot index non-array type\n", .{});
                return error.TypeError;
            }

            // Check index is int
            const index_type = try inferExpr(assign.index, env);
            if (index_type != .int) {
                std.debug.print("Type error: Array index must be int\n", .{});
                return error.TypeError;
            }

            // Check value type matches element type
            const elem_type = array_type.array.*;
            const value_type = try inferExprWithExpected(assign.value, elem_type, env);
            if (!isTypeCompatible(value_type, elem_type)) {
                var buf1: [256]u8 = undefined;
                var buf2: [256]u8 = undefined;
                std.debug.print("Type error: Array element expects '{s}' but got '{s}'\n", .{ typeToString(elem_type, &buf1), typeToString(value_type, &buf2) });
                return error.TypeError;
            }

            // Array assignment returns unit
            return .unit;
        },
    }
}

// Register builtin function signatures for type checking
pub fn registerBuiltins(env: *TypeEnvironment) !void {
    const allocator = env.allocator;

    // print(x: any) -> unit
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .unknown; // Accept any type
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("print", .{ .param_types = param_types, .return_type = .unit });
    }

    // println(x: any) -> unit
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .unknown; // Accept any type
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("println", .{ .param_types = param_types, .return_type = .unit });
    }

    // str_len(s: str) -> int
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .string;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("str_len", .{ .param_types = param_types, .return_type = .int });
    }

    // str_concat(s1: str, s2: str) -> str
    {
        var param_types = try allocator.alloc(Type, 2);
        param_types[0] = .string;
        param_types[1] = .string;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("str_concat", .{ .param_types = param_types, .return_type = .string });
    }

    // str_substring(s: str, start: int, end: int) -> str
    {
        var param_types = try allocator.alloc(Type, 3);
        param_types[0] = .string;
        param_types[1] = .int;
        param_types[2] = .int;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("str_substring", .{ .param_types = param_types, .return_type = .string });
    }

    // abs(x: int | float) -> int | float (we'll use unknown for simplicity)
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .unknown;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("abs", .{ .param_types = param_types, .return_type = .unknown });
    }

    // min(a: int, b: int) -> int OR min(a: float, b: float) -> float
    // For simplicity, we'll accept unknown
    {
        var param_types = try allocator.alloc(Type, 2);
        param_types[0] = .unknown;
        param_types[1] = .unknown;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("min", .{ .param_types = param_types, .return_type = .unknown });
    }

    // max(a: int, b: int) -> int OR max(a: float, b: float) -> float
    {
        var param_types = try allocator.alloc(Type, 2);
        param_types[0] = .unknown;
        param_types[1] = .unknown;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("max", .{ .param_types = param_types, .return_type = .unknown });
    }

    // sqrt(x: float) -> float
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .float;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("sqrt", .{ .param_types = param_types, .return_type = .float });
    }

    // floor(x: float) -> float
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .float;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("floor", .{ .param_types = param_types, .return_type = .float });
    }

    // ceil(x: float) -> float
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .float;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("ceil", .{ .param_types = param_types, .return_type = .float });
    }

    // int_to_str(x: int) -> str
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .int;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("int_to_str", .{ .param_types = param_types, .return_type = .string });
    }

    // float_to_str(x: float) -> str
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .float;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("float_to_str", .{ .param_types = param_types, .return_type = .string });
    }

    // array_len(arr: []T) -> int
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .unknown; // Accept any array type
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("array_len", .{ .param_types = param_types, .return_type = .int });
    }

    // array_push(arr: []T, elem: T) -> []T
    {
        var param_types = try allocator.alloc(Type, 2);
        param_types[0] = .unknown;
        param_types[1] = .unknown;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("array_push", .{ .param_types = param_types, .return_type = .unknown });
    }

    // array_pop(arr: []T) -> []T
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .unknown;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("array_pop", .{ .param_types = param_types, .return_type = .unknown });
    }

    // array_slice(arr: []T, start: int, end: int) -> []T
    {
        var param_types = try allocator.alloc(Type, 3);
        param_types[0] = .unknown;
        param_types[1] = .int;
        param_types[2] = .int;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("array_slice", .{ .param_types = param_types, .return_type = .unknown });
    }

    // str_split(s: str, delimiter: str) -> []str
    {
        var param_types = try allocator.alloc(Type, 2);
        param_types[0] = .string;
        param_types[1] = .string;
        try env.allocated_slices.append(allocator, param_types);
        const elem_type_ptr = try allocator.create(Type);
        elem_type_ptr.* = .string;
        try env.allocated_types.append(allocator, elem_type_ptr);
        try env.setFn("str_split", .{ .param_types = param_types, .return_type = Type{ .array = elem_type_ptr } });
    }

    // str_trim(s: str) -> str
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .string;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("str_trim", .{ .param_types = param_types, .return_type = .string });
    }

    // str_contains(s: str, substring: str) -> bool
    {
        var param_types = try allocator.alloc(Type, 2);
        param_types[0] = .string;
        param_types[1] = .string;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("str_contains", .{ .param_types = param_types, .return_type = .bool });
    }

    // str_to_int(s: str) -> int
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .string;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("str_to_int", .{ .param_types = param_types, .return_type = .int });
    }

    // str_to_float(s: str) -> float
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .string;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("str_to_float", .{ .param_types = param_types, .return_type = .float });
    }

    // bool_to_str(b: bool) -> str
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .bool;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("bool_to_str", .{ .param_types = param_types, .return_type = .string });
    }

    // int_to_float(x: int) -> float
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .int;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("int_to_float", .{ .param_types = param_types, .return_type = .float });
    }

    // float_to_int(x: float) -> int
    {
        var param_types = try allocator.alloc(Type, 1);
        param_types[0] = .float;
        try env.allocated_slices.append(allocator, param_types);
        try env.setFn("float_to_int", .{ .param_types = param_types, .return_type = .int });
    }
}
