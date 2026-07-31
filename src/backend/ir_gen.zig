const std = @import("std");
const ir = @import("ir.zig");
const ast = @import("../frontend/ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Type = ast.Type;

/// Generates IR from AST
pub const IrGenerator = struct {
    const LoopScope = struct {
        break_base: usize,
        continue_base: usize,
    };

    allocator: std.mem.Allocator,
    builder: ir.Builder,
    functions: std.ArrayList(ir.Function),
    current_function: ?[]const u8,
    break_stack: std.ArrayList(usize),
    continue_stack: std.ArrayList(usize),
    modules: std.ArrayList(ir.Program.Module),
    imported_symbols: std.StringHashMap([]const u8), // symbol -> module name
    type_aliases: std.StringHashMap(Type), // compile-time alias name -> target type
    struct_types: std.StringHashMap([]const []const u8), // struct_name -> field_names
    struct_field_types: std.StringHashMap([]const Type), // struct_name -> field types in declaration order
    struct_type_params: std.StringHashMap([]const []const u8), // struct_name -> generic parameter names
    variable_struct_types: std.StringHashMap([]const u8), // variable -> struct name
    variable_declared_types: std.StringHashMap(Type), // variable -> declared/inferred aggregate type
    function_struct_returns: std.StringHashMap([]const u8), // function -> struct name
    variable_value_types: std.StringHashMap(ir.ValueType), // variable -> primitive/runtime representation
    function_value_returns: std.StringHashMap(ir.ValueType), // function -> primitive/runtime representation
    function_return_types: std.StringHashMap(Type), // function -> declared return type template
    function_parameter_types: std.StringHashMap([]const Type), // function -> declared parameter types
    function_type_params: std.StringHashMap([]const []const u8), // function -> generic parameter names
    variable_array_element_types: std.StringHashMap(ir.ValueType), // array variable -> element representation
    function_array_returns: std.StringHashMap(ir.ValueType), // array-returning function -> element representation
    temp_counter: usize,
    expected_value_type: ?Type,
    current_return_type: ?Type,

    pub fn init(allocator: std.mem.Allocator) IrGenerator {
        return .{
            .allocator = allocator,
            .builder = ir.Builder.init(allocator),
            .functions = std.ArrayList(ir.Function).initCapacity(allocator, 0) catch unreachable,
            .current_function = null,
            .break_stack = std.ArrayList(usize).initCapacity(allocator, 0) catch unreachable,
            .continue_stack = std.ArrayList(usize).initCapacity(allocator, 0) catch unreachable,
            .modules = std.ArrayList(ir.Program.Module).initCapacity(allocator, 0) catch unreachable,
            .imported_symbols = std.StringHashMap([]const u8).init(allocator),
            .type_aliases = std.StringHashMap(Type).init(allocator),
            .struct_types = std.StringHashMap([]const []const u8).init(allocator),
            .struct_field_types = std.StringHashMap([]const Type).init(allocator),
            .struct_type_params = std.StringHashMap([]const []const u8).init(allocator),
            .variable_struct_types = std.StringHashMap([]const u8).init(allocator),
            .variable_declared_types = std.StringHashMap(Type).init(allocator),
            .function_struct_returns = std.StringHashMap([]const u8).init(allocator),
            .variable_value_types = std.StringHashMap(ir.ValueType).init(allocator),
            .function_value_returns = std.StringHashMap(ir.ValueType).init(allocator),
            .function_return_types = std.StringHashMap(Type).init(allocator),
            .function_parameter_types = std.StringHashMap([]const Type).init(allocator),
            .function_type_params = std.StringHashMap([]const []const u8).init(allocator),
            .variable_array_element_types = std.StringHashMap(ir.ValueType).init(allocator),
            .function_array_returns = std.StringHashMap(ir.ValueType).init(allocator),
            .temp_counter = 0,
            .expected_value_type = null,
            .current_return_type = null,
        };
    }

    pub fn deinit(self: *IrGenerator) void {
        self.builder.deinit();
        self.functions.deinit(self.allocator);
        self.break_stack.deinit(self.allocator);
        self.continue_stack.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.imported_symbols.deinit();
        self.type_aliases.deinit();
        self.struct_type_params.deinit();
        self.variable_struct_types.deinit();
        self.variable_declared_types.deinit();
        self.function_struct_returns.deinit();
        self.variable_value_types.deinit();
        self.function_value_returns.deinit();
        self.function_return_types.deinit();
        var parameter_type_iter = self.function_parameter_types.iterator();
        while (parameter_type_iter.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.function_parameter_types.deinit();
        self.function_type_params.deinit();
        self.variable_array_element_types.deinit();
        self.function_array_returns.deinit();

        // Clean up struct_types
        var iter = self.struct_types.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.struct_types.deinit();

        var field_type_iter = self.struct_field_types.iterator();
        while (field_type_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.struct_field_types.deinit();
    }

    fn structNameFromType(typ: Type) ?[]const u8 {
        return switch (typ) {
            .user_type => |name| name,
            .generic_instance => |instance| instance.base_type,
            else => null,
        };
    }

    fn resolveAlias(self: *IrGenerator, typ: Type) Type {
        var resolved = typ;
        var depth: usize = 0;
        while (resolved == .user_type and depth < 64) : (depth += 1) {
            resolved = self.type_aliases.get(resolved.user_type) orelse break;
        }
        return resolved;
    }

    fn structNameForType(self: *IrGenerator, typ: Type) ?[]const u8 {
        return structNameFromType(self.resolveAlias(typ));
    }

    fn valueTypeForType(self: *IrGenerator, typ: Type) ir.ValueType {
        return valueTypeFromType(self.resolveAlias(typ));
    }

    fn arrayElementValueTypeForType(self: *IrGenerator, typ: Type) ?ir.ValueType {
        const resolved = self.resolveAlias(typ);
        if (resolved != .array) return null;
        const element_type = self.valueTypeForType(resolved.array.*);
        return if (element_type == .void) null else element_type;
    }

    fn valueTypeFromType(typ: Type) ir.ValueType {
        return switch (typ) {
            .int => .int,
            .float => .float,
            .string => .string,
            .bool => .bool,
            .unit => .void,
            .array => .array,
            .optional => .optional,
            .user_type, .generic_instance => .struct_type,
            .union_type => .union_type,
            .generic_param, .unknown => .void,
        };
    }

    fn arrayElementValueTypeFromType(typ: Type) ?ir.ValueType {
        if (typ != .array) return null;
        const element_type = valueTypeFromType(typ.array.*);
        return if (element_type == .void) null else element_type;
    }

    const StructInstanceInfo = struct {
        name: []const u8,
        type_args: []const Type,
    };

    fn structInstanceFromType(typ: Type) ?StructInstanceInfo {
        return switch (typ) {
            .user_type => |name| .{ .name = name, .type_args = &.{} },
            .generic_instance => |instance| .{ .name = instance.base_type, .type_args = instance.type_args },
            else => null,
        };
    }

    fn typeArgumentFor(
        params: []const []const u8,
        args: []const Type,
        parameter_name: []const u8,
    ) ?Type {
        for (params, 0..) |param, index| {
            if (std.mem.eql(u8, param, parameter_name) and index < args.len) return args[index];
        }
        return null;
    }

    fn resolvedValueType(typ: Type, params: []const []const u8, args: []const Type) ir.ValueType {
        return switch (typ) {
            .generic_param => |name| if (typeArgumentFor(params, args, name)) |arg|
                valueTypeFromType(arg)
            else
                .void,
            .user_type => |name| if (typeArgumentFor(params, args, name)) |arg|
                valueTypeFromType(arg)
            else
                .struct_type,
            else => valueTypeFromType(typ),
        };
    }

    fn resolvedTopLevelType(typ: Type, params: []const []const u8, args: []const Type) Type {
        return switch (typ) {
            .generic_param => |name| typeArgumentFor(params, args, name) orelse typ,
            .user_type => |name| typeArgumentFor(params, args, name) orelse typ,
            else => typ,
        };
    }

    fn appendTypeDescriptor(self: *IrGenerator, list: *std.ArrayList(u8), typ: Type) !void {
        switch (self.resolveAlias(typ)) {
            .int => try list.appendSlice(self.allocator, "int"),
            .float => try list.appendSlice(self.allocator, "float"),
            .string => try list.appendSlice(self.allocator, "str"),
            .bool => try list.appendSlice(self.allocator, "bool"),
            .unit => try list.appendSlice(self.allocator, "unit"),
            .user_type => |name| try list.appendSlice(self.allocator, name),
            .generic_param => |name| {
                try list.append(self.allocator, '$');
                try list.appendSlice(self.allocator, name);
            },
            .generic_instance => |instance| {
                try list.appendSlice(self.allocator, instance.base_type);
                try list.append(self.allocator, '<');
                for (instance.type_args, 0..) |arg, index| {
                    if (index != 0) try list.append(self.allocator, ',');
                    try self.appendTypeDescriptor(list, arg);
                }
                try list.append(self.allocator, '>');
            },
            .array => |element| {
                try list.appendSlice(self.allocator, "array<");
                try self.appendTypeDescriptor(list, element.*);
                try list.append(self.allocator, '>');
            },
            .optional => |inner| {
                try list.appendSlice(self.allocator, "optional<");
                try self.appendTypeDescriptor(list, inner.*);
                try list.append(self.allocator, '>');
            },
            .union_type => |members| {
                try list.appendSlice(self.allocator, "union<");
                for (members, 0..) |member, index| {
                    if (index != 0) try list.append(self.allocator, '|');
                    try self.appendTypeDescriptor(list, member);
                }
                try list.append(self.allocator, '>');
            },
            .unknown => try list.appendSlice(self.allocator, "unknown"),
        }
    }

    fn typeDescriptor(self: *IrGenerator, typ: Type) ![]const u8 {
        var descriptor = try std.ArrayList(u8).initCapacity(self.allocator, 32);
        defer descriptor.deinit(self.allocator);
        try self.appendTypeDescriptor(&descriptor, typ);
        const index = try self.builder.internString(descriptor.items);
        return self.builder.string_list.items[index];
    }

    fn uniqueUnionPayloadForValueType(self: *IrGenerator, target_type: Type, value_type: ?ir.ValueType) ?Type {
        const resolved = self.resolveAlias(target_type);
        if (resolved != .union_type or value_type == null) return null;
        var candidate: ?Type = null;
        for (resolved.union_type) |member| {
            const resolved_member = self.resolveAlias(member);
            if (self.valueTypeForType(resolved_member) == value_type.?) {
                if (candidate != null) return null;
                candidate = resolved_member;
            }
        }
        return candidate;
    }

    fn emitTaggedWrap(
        self: *IrGenerator,
        target_type: Type,
        source_declared_type: ?Type,
        source_value_type: ?ir.ValueType,
    ) error{OutOfMemory}!void {
        switch (self.resolveAlias(target_type)) {
            .optional => |inner| {
                if (source_value_type == .optional or source_value_type == .null_type) return;
                const payload_type = source_value_type orelse self.valueTypeForType(inner.*);
                const descriptor = try self.typeDescriptor(source_declared_type orelse inner.*);
                try self.builder.emitFullWithString(.optional_wrap, descriptor, 0, 0, ir.encodeValueType(payload_type));
            },
            .union_type => {
                if (source_value_type == .union_type) return;
                const payload_type = source_declared_type orelse
                    self.uniqueUnionPayloadForValueType(target_type, source_value_type) orelse .unknown;
                const descriptor = try self.typeDescriptor(payload_type);
                try self.builder.emitFullWithString(.optional_wrap, descriptor, 1, 0, ir.encodeValueType(source_value_type));
            },
            else => {},
        }
    }

    fn copyParameterTypes(self: *IrGenerator, parameters: []Stmt.Parameter) ![]Type {
        const types = try self.allocator.alloc(Type, parameters.len);
        for (parameters, 0..) |parameter, index| types[index] = parameter.typ;
        return types;
    }

    fn registerParameterTypes(self: *IrGenerator, name: []const u8, parameters: []Stmt.Parameter) !void {
        if (self.function_parameter_types.contains(name)) return;
        try self.function_parameter_types.put(name, try self.copyParameterTypes(parameters));
    }

    fn resolvedArrayElementValueType(typ: Type, params: []const []const u8, args: []const Type) ?ir.ValueType {
        if (typ != .array) return null;
        const element_type = resolvedValueType(typ.array.*, params, args);
        return if (element_type == .void) null else element_type;
    }

    fn structInstanceFromExpr(self: *IrGenerator, expr: *const Expr) ?StructInstanceInfo {
        return switch (expr.*) {
            .struct_init => |struct_init| .{ .name = struct_init.type_name, .type_args = struct_init.type_args },
            .variable => |name| if (self.variable_declared_types.get(name)) |typ|
                structInstanceFromType(typ)
            else if (self.variable_struct_types.get(name)) |struct_name|
                .{ .name = struct_name, .type_args = &.{} }
            else
                null,
            .optional_unwrap => |optional_expr| if (self.exprDeclaredType(optional_expr)) |typ| blk: {
                const resolved = self.resolveAlias(typ);
                break :blk if (resolved == .optional) structInstanceFromType(self.resolveAlias(resolved.optional.*)) else null;
            } else null,
            .optional_coalesce => |coalesce| self.structInstanceFromExpr(coalesce.fallback),
            else => null,
        };
    }

    fn fieldTypeContext(
        self: *IrGenerator,
        object: *const Expr,
        field_name: []const u8,
    ) ?struct { typ: Type, params: []const []const u8, args: []const Type } {
        const instance = self.structInstanceFromExpr(object) orelse return null;
        const field_names = self.struct_types.get(instance.name) orelse return null;
        const field_types = self.struct_field_types.get(instance.name) orelse return null;
        const params = self.struct_type_params.get(instance.name) orelse &.{};
        for (field_names, 0..) |name, index| {
            if (std.mem.eql(u8, name, field_name)) {
                return .{ .typ = field_types[index], .params = params, .args = instance.type_args };
            }
        }
        return null;
    }

    fn fieldTypeFromExpr(self: *IrGenerator, object: *const Expr, field_name: []const u8) ?Type {
        const context = self.fieldTypeContext(object, field_name) orelse return null;
        return context.typ;
    }

    fn arrayElementValueType(self: *IrGenerator, expr: *const Expr) ?ir.ValueType {
        return switch (expr.*) {
            .variable => |name| self.variable_array_element_types.get(name),
            .array_literal => |array| if (array.elements.len > 0) self.exprValueType(array.elements[0]) else null,
            .field_access => |access| if (self.fieldTypeFromExpr(access.object, access.field_name)) |field_type|
                if (self.fieldTypeContext(access.object, access.field_name)) |context|
                    resolvedArrayElementValueType(field_type, context.params, context.args)
                else
                    null
            else
                null,
            .fn_call => |call| blk: {
                if (std.mem.eql(u8, call.name, "str_split")) break :blk .string;
                if ((std.mem.eql(u8, call.name, "array_push") or
                    std.mem.eql(u8, call.name, "array_pop") or
                    std.mem.eql(u8, call.name, "array_slice")) and call.arguments.len > 0)
                {
                    break :blk self.arrayElementValueType(call.arguments[0]);
                }
                if (self.exprDeclaredType(expr)) |return_type| {
                    const resolved = self.resolveAlias(return_type);
                    if (resolved == .array) break :blk self.valueTypeForType(resolved.array.*);
                }
                break :blk self.function_array_returns.get(call.name);
            },
            .if_expr => |if_expr| self.arrayElementValueType(if_expr.then_block),
            .optional_unwrap => |optional_expr| if (self.exprDeclaredType(optional_expr)) |typ| blk: {
                const resolved = self.resolveAlias(typ);
                break :blk if (resolved == .optional) arrayElementValueTypeFromType(resolved.optional.*) else null;
            } else null,
            .optional_coalesce => |coalesce| self.arrayElementValueType(coalesce.fallback),
            .block => |block| if (block.return_expr) |return_expr| self.arrayElementValueType(return_expr) else null,
            .match_expr => |match_expr| if (match_expr.arms.len > 0) self.arrayElementValueType(match_expr.arms[0].body) else null,
            else => null,
        };
    }

    fn arrayElementDeclaredType(self: *IrGenerator, expr: *const Expr) ?Type {
        return switch (expr.*) {
            .variable => |name| if (self.variable_declared_types.get(name)) |typ|
                if (typ == .array) typ.array.* else null
            else
                null,
            .field_access => |access| if (self.fieldTypeContext(access.object, access.field_name)) |context| blk: {
                if (context.typ != .array) break :blk null;
                break :blk resolvedTopLevelType(context.typ.array.*, context.params, context.args);
            } else null,
            .fn_call => |call| if (self.function_return_types.get(call.name)) |typ|
                blk: {
                    const resolved = resolvedTopLevelType(
                        typ,
                        self.function_type_params.get(call.name) orelse &.{},
                        call.type_args,
                    );
                    break :blk if (resolved == .array) resolved.array.* else null;
                }
            else
                null,
            else => null,
        };
    }

    fn builtinReturnType(self: *IrGenerator, name: []const u8, arguments: []*Expr) ?ir.ValueType {
        if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "println")) return .void;
        if (std.mem.eql(u8, name, "str_len") or std.mem.eql(u8, name, "str_to_int") or
            std.mem.eql(u8, name, "float_to_int") or std.mem.eql(u8, name, "array_len")) return .int;
        if (std.mem.eql(u8, name, "str_concat") or std.mem.eql(u8, name, "str_substring") or
            std.mem.eql(u8, name, "str_trim") or std.mem.eql(u8, name, "int_to_str") or
            std.mem.eql(u8, name, "float_to_str") or std.mem.eql(u8, name, "bool_to_str")) return .string;
        if (std.mem.eql(u8, name, "str_contains")) return .bool;
        if (std.mem.eql(u8, name, "str_to_float") or std.mem.eql(u8, name, "int_to_float") or
            std.mem.eql(u8, name, "sqrt") or std.mem.eql(u8, name, "floor") or
            std.mem.eql(u8, name, "ceil")) return .float;
        if (std.mem.eql(u8, name, "str_split") or std.mem.eql(u8, name, "array_push") or
            std.mem.eql(u8, name, "array_pop") or std.mem.eql(u8, name, "array_slice")) return .array;
        if ((std.mem.eql(u8, name, "abs") or std.mem.eql(u8, name, "min") or
            std.mem.eql(u8, name, "max")) and arguments.len > 0) return self.exprValueType(arguments[0]);
        return null;
    }

    /// Recover the runtime representation required by typed IR operations.
    /// The frontend has already type-checked the AST; this lightweight pass
    /// preserves only the information the type-erased backends need.
    fn exprValueType(self: *IrGenerator, expr: *const Expr) ?ir.ValueType {
        return switch (expr.*) {
            .int_literal => .int,
            .float_literal => .float,
            .string_literal => .string,
            .bool_literal => .bool,
            .null_literal => .null_type,
            .variable => |name| self.variable_value_types.get(name),
            .binary => |binary| switch (binary.op) {
                .equal,
                .not_equal,
                .less,
                .less_equal,
                .greater,
                .greater_equal,
                .logical_and,
                .logical_or,
                => .bool,
                .add, .sub, .mul, .div, .mod, .pow => blk: {
                    const left = self.exprValueType(binary.left);
                    const right = self.exprValueType(binary.right);
                    if (left == .string and right == .string and binary.op == .add) break :blk .string;
                    if (left == .float or right == .float) break :blk .float;
                    if (left == .int and right == .int) break :blk .int;
                    break :blk null;
                },
            },
            .unary => |unary| if (unary.op == .logical_not) .bool else self.exprValueType(unary.operand),
            .optional_unwrap => |optional_expr| if (self.exprDeclaredType(optional_expr)) |typ| blk: {
                const resolved = self.resolveAlias(typ);
                break :blk if (resolved == .optional) self.valueTypeForType(resolved.optional.*) else null;
            } else null,
            .optional_coalesce => |coalesce| self.exprValueType(coalesce.fallback),
            .block => |block| if (block.return_expr) |return_expr| self.exprValueType(return_expr) else .void,
            .if_expr => |if_expr| self.exprValueType(if_expr.then_block),
            .while_expr, .for_expr, .assignment, .field_assignment, .array_assignment => .void,
            .match_expr => |match_expr| if (match_expr.arms.len > 0) self.exprValueType(match_expr.arms[0].body) else null,
            .fn_call => |call| self.builtinReturnType(call.name, call.arguments) orelse blk: {
                const declared_type = self.exprDeclaredType(expr) orelse
                    break :blk self.function_value_returns.get(call.name);
                const value_type = self.valueTypeForType(declared_type);
                break :blk if (value_type == .void) null else value_type;
            },
            .struct_init => .struct_type,
            .field_access => |access| if (self.fieldTypeFromExpr(access.object, access.field_name)) |field_type| blk: {
                const context = self.fieldTypeContext(access.object, access.field_name) orelse break :blk null;
                const value_type = resolvedValueType(field_type, context.params, context.args);
                break :blk if (value_type == .void) null else value_type;
            } else null,
            .method_call => |call| blk: {
                const instance = self.structInstanceFromExpr(call.receiver) orelse break :blk null;
                const function_name = self.qualifiedMethodName(instance.name, call.method_name) catch break :blk null;
                const return_type = self.function_return_types.get(function_name) orelse
                    break :blk self.function_value_returns.get(function_name);
                const params = self.struct_type_params.get(instance.name) orelse &.{};
                const value_type = resolvedValueType(return_type, params, instance.type_args);
                break :blk if (value_type == .void) null else value_type;
            },
            .array_literal => .array,
            .array_access => |access| self.arrayElementValueType(access.array),
            .is_check => .bool,
        };
    }

    fn exprDeclaredType(self: *IrGenerator, expr: *const Expr) ?Type {
        return switch (expr.*) {
            .int_literal => .int,
            .float_literal => .float,
            .string_literal => .string,
            .bool_literal => .bool,
            .null_literal => .unknown,
            .variable => |name| self.variable_declared_types.get(name),
            .fn_call => |call| if (self.function_return_types.get(call.name)) |return_type|
                resolvedTopLevelType(
                    return_type,
                    self.function_type_params.get(call.name) orelse &.{},
                    call.type_args,
                )
            else
                null,
            .method_call => |call| blk: {
                const instance = self.structInstanceFromExpr(call.receiver) orelse break :blk null;
                const function_name = self.qualifiedMethodName(instance.name, call.method_name) catch break :blk null;
                const return_type = self.function_return_types.get(function_name) orelse break :blk null;
                break :blk resolvedTopLevelType(
                    return_type,
                    self.function_type_params.get(function_name) orelse &.{},
                    instance.type_args,
                );
            },
            .struct_init => |struct_init| if (struct_init.type_args.len > 0)
                .{ .generic_instance = .{ .base_type = struct_init.type_name, .type_args = struct_init.type_args } }
            else
                .{ .user_type = struct_init.type_name },
            .field_access => |access| if (self.fieldTypeContext(access.object, access.field_name)) |context|
                resolvedTopLevelType(context.typ, context.params, context.args)
            else
                null,
            .array_access => |access| self.arrayElementDeclaredType(access.array),
            .binary => |binary| switch (binary.op) {
                .equal, .not_equal, .less, .less_equal, .greater, .greater_equal, .logical_and, .logical_or => .bool,
                .add, .sub, .mul, .div, .mod, .pow => if (self.exprValueType(expr) == .float) .float else .int,
            },
            .unary => |unary| if (unary.op == .logical_not) .bool else self.exprDeclaredType(unary.operand),
            .optional_unwrap => |optional_expr| if (self.exprDeclaredType(optional_expr)) |typ| blk: {
                const resolved = self.resolveAlias(typ);
                break :blk if (resolved == .optional) self.resolveAlias(resolved.optional.*) else null;
            } else null,
            .optional_coalesce => |coalesce| self.exprDeclaredType(coalesce.fallback),
            .block => |block| if (block.return_expr) |return_expr| self.exprDeclaredType(return_expr) else .unit,
            .if_expr => |if_expr| self.exprDeclaredType(if_expr.then_block),
            .match_expr => |match_expr| if (match_expr.arms.len > 0) self.exprDeclaredType(match_expr.arms[0].body) else null,
            .is_check => .bool,
            .while_expr, .for_expr, .assignment, .field_assignment, .array_assignment => .unit,
            .array_literal => |literal| literal.resolved_array_type.*,
        };
    }

    fn structNameFromExpr(self: *IrGenerator, expr: *const Expr) ?[]const u8 {
        return switch (expr.*) {
            .struct_init => |struct_init| struct_init.type_name,
            .variable => |name| self.variable_struct_types.get(name),
            .fn_call => |call| self.function_struct_returns.get(call.name),
            else => null,
        };
    }

    fn trackVariableStructType(self: *IrGenerator, decl: Stmt.VarDecl) !void {
        var struct_name = self.structNameFromExpr(decl.value);
        if (decl.type_annotation) |annotation| {
            if (self.structNameForType(annotation)) |annotated_name| {
                if (self.struct_types.contains(annotated_name)) {
                    struct_name = annotated_name;
                }
            }
        }

        if (struct_name) |name| {
            try self.variable_struct_types.put(decl.name, name);
        }
    }

    fn trackVariableValueType(self: *IrGenerator, decl: Stmt.VarDecl) !void {
        const value_type = if (decl.type_annotation) |annotation|
            self.valueTypeForType(annotation)
        else
            self.exprValueType(decl.value) orelse return;
        try self.variable_value_types.put(decl.name, value_type);
    }

    fn trackVariableDeclaredType(self: *IrGenerator, decl: Stmt.VarDecl) !void {
        if (decl.type_annotation) |annotation| {
            try self.variable_declared_types.put(decl.name, self.resolveAlias(annotation));
            return;
        }
        if (self.exprDeclaredType(decl.value)) |typ| try self.variable_declared_types.put(decl.name, typ);
    }

    fn trackVariableArrayElementType(self: *IrGenerator, decl: Stmt.VarDecl) !void {
        const element_type = if (decl.type_annotation) |annotation|
            self.arrayElementValueTypeForType(annotation)
        else
            self.arrayElementValueType(decl.value);
        if (element_type) |typ| try self.variable_array_element_types.put(decl.name, typ);
    }

    fn nextTempName(self: *IrGenerator, prefix: []const u8) ![]const u8 {
        const candidate = try std.fmt.allocPrint(self.allocator, "__{s}_{d}__", .{ prefix, self.temp_counter });
        defer self.allocator.free(candidate);
        self.temp_counter += 1;

        const index = try self.builder.internString(candidate);
        return self.builder.string_list.items[index];
    }

    fn isAggregateEqualityType(typ: Type) bool {
        return switch (typ) {
            .array, .user_type, .generic_instance => true,
            .optional => |inner| isAggregateEqualityType(inner.*),
            .union_type => |members| blk: {
                for (members) |member| {
                    if (isAggregateEqualityType(member)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn runtimeTypeCheckId(typ: Type) i64 {
        return switch (typ) {
            .int => 1,
            .float => 2,
            .string => 3,
            .bool => 4,
            .user_type, .generic_instance => 5,
            .array => 6,
            .unit => 7,
            .optional => 8,
            .union_type => 9,
            else => 0,
        };
    }

    fn emitStoredTypeCheck(self: *IrGenerator, value_name: []const u8, typ: Type, actual_type: ir.ValueType) error{OutOfMemory}!void {
        try self.builder.emitWithString(.load_var, value_name, 0, 0);
        const descriptor = try self.typeDescriptor(typ);
        try self.builder.emitFullWithString(
            .type_check,
            descriptor,
            runtimeTypeCheckId(typ),
            0,
            ir.encodeValueType(actual_type),
        );
    }

    fn emitStoredValueEquality(
        self: *IrGenerator,
        typ: Type,
        left_name: []const u8,
        right_name: []const u8,
        type_params: []const []const u8,
        type_args: []const Type,
    ) error{OutOfMemory}!void {
        const resolved = resolvedTopLevelType(typ, type_params, type_args);
        switch (resolved) {
            .array => |element_type| try self.emitStoredArrayEquality(element_type.*, left_name, right_name, type_params, type_args),
            .user_type, .generic_instance => try self.emitStoredStructEquality(resolved, left_name, right_name),
            .optional => |inner| if (isAggregateEqualityType(inner.*))
                try self.emitStoredOptionalEquality(inner.*, left_name, right_name, type_params, type_args)
            else {
                try self.builder.emitWithString(.load_var, left_name, 0, 0);
                try self.builder.emitWithString(.load_var, right_name, 0, 0);
                try self.builder.emit(.eq, 0, 0, ir.encodeBinaryTypes(.optional, .optional));
            },
            .union_type => |members| try self.emitStoredUnionEquality(members, left_name, right_name, type_params, type_args),
            else => {
                try self.builder.emitWithString(.load_var, left_name, 0, 0);
                try self.builder.emitWithString(.load_var, right_name, 0, 0);
                const value_type = self.valueTypeForType(resolved);
                try self.builder.emit(.eq, 0, 0, ir.encodeBinaryTypes(value_type, value_type));
            },
        }
    }

    fn emitStoredOptionalEquality(
        self: *IrGenerator,
        inner_type: Type,
        left_name: []const u8,
        right_name: []const u8,
        type_params: []const []const u8,
        type_args: []const Type,
    ) error{OutOfMemory}!void {
        const left_is_null = try self.nextTempName("eq_left_null");
        const right_is_null = try self.nextTempName("eq_right_null");
        try self.builder.emitWithString(.load_var, left_name, 0, 0);
        try self.builder.emit(.optional_is_null, 0, 0, 0);
        try self.builder.emitWithString(.store_var, left_is_null, 0, 0);
        try self.builder.emitWithString(.load_var, right_name, 0, 0);
        try self.builder.emit(.optional_is_null, 0, 0, 0);
        try self.builder.emitWithString(.store_var, right_is_null, 0, 0);

        try self.builder.emitWithString(.load_var, left_is_null, 0, 0);
        try self.builder.emitWithString(.load_var, right_is_null, 0, 0);
        try self.builder.emit(.neq, 0, 0, ir.encodeBinaryTypes(.bool, .bool));
        const nullability_differs = self.builder.position();
        try self.builder.emit(.jump_if_true, 0, 0, 0);
        try self.builder.emitWithString(.load_var, left_is_null, 0, 0);
        const both_null = self.builder.position();
        try self.builder.emit(.jump_if_true, 0, 0, 0);

        const left_payload = try self.nextTempName("eq_left_payload");
        const right_payload = try self.nextTempName("eq_right_payload");
        try self.builder.emitWithString(.load_var, left_name, 0, 0);
        try self.builder.emit(.optional_unwrap, 0, 0, 0);
        try self.builder.emitWithString(.store_var, left_payload, 0, 0);
        try self.builder.emitWithString(.load_var, right_name, 0, 0);
        try self.builder.emit(.optional_unwrap, 0, 0, 0);
        try self.builder.emitWithString(.store_var, right_payload, 0, 0);
        try self.emitStoredValueEquality(inner_type, left_payload, right_payload, type_params, type_args);
        const payloads_differ = self.builder.position();
        try self.builder.emit(.jump_if_false, 0, 0, 0);

        const equal_target = self.builder.position();
        self.builder.patchJump(both_null, equal_target);
        try self.builder.emit(.load_const_bool, 1, 0, 0);
        const equality_done = self.builder.position();
        try self.builder.emit(.jump, 0, 0, 0);
        const unequal_target = self.builder.position();
        self.builder.patchJump(nullability_differs, unequal_target);
        self.builder.patchJump(payloads_differ, unequal_target);
        try self.builder.emit(.load_const_bool, 0, 0, 0);
        self.builder.patchJump(equality_done, self.builder.position());
    }

    fn emitStoredUnionEquality(
        self: *IrGenerator,
        members: []const Type,
        left_name: []const u8,
        right_name: []const u8,
        type_params: []const []const u8,
        type_args: []const Type,
    ) error{OutOfMemory}!void {
        var unequal_jumps = try std.ArrayList(usize).initCapacity(self.allocator, members.len * 2);
        defer unequal_jumps.deinit(self.allocator);
        var equal_jumps = try std.ArrayList(usize).initCapacity(self.allocator, members.len);
        defer equal_jumps.deinit(self.allocator);

        for (members) |member| {
            try self.emitStoredTypeCheck(left_name, member, .union_type);
            const next_member = self.builder.position();
            try self.builder.emit(.jump_if_false, 0, 0, 0);
            try self.emitStoredTypeCheck(right_name, member, .union_type);
            try unequal_jumps.append(self.allocator, self.builder.position());
            try self.builder.emit(.jump_if_false, 0, 0, 0);

            const left_payload = try self.nextTempName("eq_union_left");
            const right_payload = try self.nextTempName("eq_union_right");
            try self.builder.emitWithString(.load_var, left_name, 0, 0);
            try self.builder.emit(.optional_unwrap, 0, 0, 0);
            try self.builder.emitWithString(.store_var, left_payload, 0, 0);
            try self.builder.emitWithString(.load_var, right_name, 0, 0);
            try self.builder.emit(.optional_unwrap, 0, 0, 0);
            try self.builder.emitWithString(.store_var, right_payload, 0, 0);
            try self.emitStoredValueEquality(member, left_payload, right_payload, type_params, type_args);
            try unequal_jumps.append(self.allocator, self.builder.position());
            try self.builder.emit(.jump_if_false, 0, 0, 0);
            try self.builder.emit(.load_const_bool, 1, 0, 0);
            try equal_jumps.append(self.allocator, self.builder.position());
            try self.builder.emit(.jump, 0, 0, 0);
            self.builder.patchJump(next_member, self.builder.position());
        }

        const unequal_target = self.builder.position();
        for (unequal_jumps.items) |jump| self.builder.patchJump(jump, unequal_target);
        try self.builder.emit(.load_const_bool, 0, 0, 0);
        const done = self.builder.position();
        for (equal_jumps.items) |jump| self.builder.patchJump(jump, done);
    }

    fn emitStoredStructEquality(self: *IrGenerator, typ: Type, left_name: []const u8, right_name: []const u8) error{OutOfMemory}!void {
        const instance = structInstanceFromType(typ) orelse {
            try self.builder.emit(.load_const_bool, 0, 0, 0);
            return;
        };
        const field_types = self.struct_field_types.get(instance.name) orelse &.{};
        const params = self.struct_type_params.get(instance.name) orelse &.{};

        var unequal_jumps = try std.ArrayList(usize).initCapacity(self.allocator, field_types.len);
        defer unequal_jumps.deinit(self.allocator);
        for (field_types, 0..) |field_type, index| {
            const left_field = try self.nextTempName("eq_left_field");
            const right_field = try self.nextTempName("eq_right_field");

            try self.builder.emitWithString(.load_var, left_name, 0, 0);
            try self.builder.emit(.field_get, @intCast(index), 0, 0);
            try self.builder.emitWithString(.store_var, left_field, 0, 0);
            try self.builder.emitWithString(.load_var, right_name, 0, 0);
            try self.builder.emit(.field_get, @intCast(index), 0, 0);
            try self.builder.emitWithString(.store_var, right_field, 0, 0);

            try self.emitStoredValueEquality(field_type, left_field, right_field, params, instance.type_args);
            try unequal_jumps.append(self.allocator, self.builder.position());
            try self.builder.emit(.jump_if_false, 0, 0, 0);
        }

        try self.builder.emit(.load_const_bool, 1, 0, 0);
        const equality_done = self.builder.position();
        try self.builder.emit(.jump, 0, 0, 0);
        const unequal_target = self.builder.position();
        for (unequal_jumps.items) |jump| self.builder.patchJump(jump, unequal_target);
        try self.builder.emit(.load_const_bool, 0, 0, 0);
        self.builder.patchJump(equality_done, self.builder.position());
    }

    fn emitStoredArrayEquality(
        self: *IrGenerator,
        element_type: Type,
        left_name: []const u8,
        right_name: []const u8,
        type_params: []const []const u8,
        type_args: []const Type,
    ) error{OutOfMemory}!void {
        const index_name = try self.nextTempName("eq_index");
        const left_element = try self.nextTempName("eq_left_element");
        const right_element = try self.nextTempName("eq_right_element");

        try self.builder.emitWithString(.load_var, left_name, 0, 0);
        try self.builder.emit(.array_len, 0, 0, 0);
        try self.builder.emitWithString(.load_var, right_name, 0, 0);
        try self.builder.emit(.array_len, 0, 0, 0);
        try self.builder.emit(.eq, 0, 0, ir.encodeBinaryTypes(.int, .int));
        const lengths_differ = self.builder.position();
        try self.builder.emit(.jump_if_false, 0, 0, 0);

        try self.builder.emit(.load_const_int, 0, 0, 0);
        try self.builder.emitWithString(.store_var, index_name, 0, 0);
        const loop_start = self.builder.position();
        try self.builder.emitWithString(.load_var, index_name, 0, 0);
        try self.builder.emitWithString(.load_var, left_name, 0, 0);
        try self.builder.emit(.array_len, 0, 0, 0);
        try self.builder.emit(.lt, 0, 0, ir.encodeBinaryTypes(.int, .int));
        const loop_done = self.builder.position();
        try self.builder.emit(.jump_if_false, 0, 0, 0);

        try self.builder.emitWithString(.load_var, left_name, 0, 0);
        try self.builder.emitWithString(.load_var, index_name, 0, 0);
        try self.builder.emit(.array_get, 0, 0, 0);
        try self.builder.emitWithString(.store_var, left_element, 0, 0);
        try self.builder.emitWithString(.load_var, right_name, 0, 0);
        try self.builder.emitWithString(.load_var, index_name, 0, 0);
        try self.builder.emit(.array_get, 0, 0, 0);
        try self.builder.emitWithString(.store_var, right_element, 0, 0);
        try self.emitStoredValueEquality(element_type, left_element, right_element, type_params, type_args);
        const elements_differ = self.builder.position();
        try self.builder.emit(.jump_if_false, 0, 0, 0);

        try self.builder.emitWithString(.load_var, index_name, 0, 0);
        try self.builder.emit(.load_const_int, 1, 0, 0);
        try self.builder.emit(.add, 0, 0, ir.encodeBinaryTypes(.int, .int));
        try self.builder.emitWithString(.store_var, index_name, 0, 0);
        try self.builder.emit(.jump, @intCast(loop_start), 0, 0);

        const equal_target = self.builder.position();
        self.builder.patchJump(loop_done, equal_target);
        try self.builder.emit(.load_const_bool, 1, 0, 0);
        const equality_done = self.builder.position();
        try self.builder.emit(.jump, 0, 0, 0);

        const unequal_target = self.builder.position();
        self.builder.patchJump(lengths_differ, unequal_target);
        self.builder.patchJump(elements_differ, unequal_target);
        try self.builder.emit(.load_const_bool, 0, 0, 0);
        self.builder.patchJump(equality_done, self.builder.position());
    }

    fn emitAggregateEquality(self: *IrGenerator, left: *const Expr, right: *const Expr, typ: Type, negate: bool) error{OutOfMemory}!void {
        const left_name = try self.nextTempName("eq_left");
        const right_name = try self.nextTempName("eq_right");
        try self.genExpr(left);
        try self.builder.emitWithString(.store_var, left_name, 0, 0);
        try self.genExpr(right);
        try self.builder.emitWithString(.store_var, right_name, 0, 0);
        try self.emitStoredValueEquality(typ, left_name, right_name, &.{}, &.{});
        if (negate) try self.builder.emit(.not_op, 0, 0, 0);
    }

    fn beginLoop(self: *IrGenerator) !LoopScope {
        const scope = LoopScope{
            .break_base = self.break_stack.items.len,
            .continue_base = self.continue_stack.items.len,
        };
        const marker = std.math.maxInt(usize);
        try self.break_stack.append(self.allocator, marker);
        errdefer self.break_stack.items.len = scope.break_base;
        try self.continue_stack.append(self.allocator, marker);
        return scope;
    }

    fn abandonLoop(self: *IrGenerator, scope: LoopScope) void {
        self.break_stack.items.len = scope.break_base;
        self.continue_stack.items.len = scope.continue_base;
    }

    fn finishLoop(self: *IrGenerator, scope: LoopScope, continue_target: usize, break_target: usize) void {
        for (self.continue_stack.items[scope.continue_base + 1 ..]) |jump_pos| {
            self.builder.patchJump(jump_pos, continue_target);
        }
        for (self.break_stack.items[scope.break_base + 1 ..]) |jump_pos| {
            self.builder.patchJump(jump_pos, break_target);
        }
        self.abandonLoop(scope);
    }

    fn stashInstructions(self: *IrGenerator) ![]ir.Instruction {
        return try self.builder.instructions.toOwnedSlice(self.allocator);
    }

    fn restoreInstructions(self: *IrGenerator, saved: []ir.Instruction) !void {
        errdefer self.allocator.free(saved);

        var restored = std.ArrayList(ir.Instruction).initCapacity(self.allocator, saved.len) catch unreachable;
        errdefer restored.deinit(self.allocator);

        try restored.appendSlice(self.allocator, saved);

        self.builder.instructions = restored;
        self.allocator.free(saved);
    }

    fn copyParamNames(self: *IrGenerator, params: []Stmt.Parameter) ![][]const u8 {
        var param_names = try self.allocator.alloc([]const u8, params.len);
        for (params, 0..) |param, i| {
            param_names[i] = param.name;
        }
        return param_names;
    }

    fn qualifiedMethodName(self: *IrGenerator, struct_name: []const u8, method_name: []const u8) ![]const u8 {
        const candidate = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ struct_name, method_name });
        defer self.allocator.free(candidate);

        const index = try self.builder.internString(candidate);
        return self.builder.string_list.items[index];
    }

    fn generateFunction(
        self: *IrGenerator,
        name: []const u8,
        type_params: [][]const u8,
        parameters: []Stmt.Parameter,
        return_type: Type,
        body: *const Expr,
    ) !void {
        const saved_instructions = try self.stashInstructions();
        var restored_instructions = false;
        defer if (!restored_instructions) {
            self.restoreInstructions(saved_instructions) catch |err| {
                std.debug.print("Warning: Failed to restore IR builder state: {}\n", .{err});
            };
        };

        const saved_variable_types = self.variable_struct_types;
        self.variable_struct_types = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            self.variable_struct_types.deinit();
            self.variable_struct_types = saved_variable_types;
        }

        const saved_declared_types = self.variable_declared_types;
        self.variable_declared_types = std.StringHashMap(Type).init(self.allocator);
        defer {
            self.variable_declared_types.deinit();
            self.variable_declared_types = saved_declared_types;
        }

        const saved_value_types = self.variable_value_types;
        self.variable_value_types = std.StringHashMap(ir.ValueType).init(self.allocator);
        defer {
            self.variable_value_types.deinit();
            self.variable_value_types = saved_value_types;
        }

        const saved_array_element_types = self.variable_array_element_types;
        self.variable_array_element_types = std.StringHashMap(ir.ValueType).init(self.allocator);
        defer {
            self.variable_array_element_types.deinit();
            self.variable_array_element_types = saved_array_element_types;
        }

        for (parameters) |param| {
            try self.variable_declared_types.put(param.name, self.resolveAlias(param.typ));
            if (self.structNameForType(param.typ)) |struct_name| {
                try self.variable_struct_types.put(param.name, struct_name);
            }
            try self.variable_value_types.put(param.name, self.valueTypeForType(param.typ));
            if (self.arrayElementValueTypeForType(param.typ)) |element_type| {
                try self.variable_array_element_types.put(param.name, element_type);
            }
        }

        self.current_function = name;
        defer self.current_function = null;

        const saved_return_type = self.current_return_type;
        self.current_return_type = return_type;
        defer self.current_return_type = saved_return_type;

        const saved_expected_type = self.expected_value_type;
        self.expected_value_type = return_type;
        try self.genExpr(body);
        self.expected_value_type = saved_expected_type;
        if (body.* == .block and body.block.return_expr != null) {
            try self.emitTaggedWrap(return_type, self.exprDeclaredType(body), self.exprValueType(body));
        }
        try self.builder.emit(.ret, 0, 0, 0);

        const func_instructions = try self.builder.instructions.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(func_instructions);

        const param_names = try self.copyParamNames(parameters);
        errdefer self.allocator.free(param_names);

        try self.functions.append(self.allocator, .{
            .name = name,
            .param_count = parameters.len,
            .param_names = param_names,
            .local_count = countLocalVariables(func_instructions, param_names),
            .instructions = func_instructions,
            .type_params = type_params,
            .is_generic = type_params.len > 0,
            .return_type = self.valueTypeForType(return_type),
        });
        try self.restoreInstructions(saved_instructions);
        restored_instructions = true;
    }

    /// Count unique local variables in function body by analyzing store_var instructions
    fn countLocalVariables(instructions: []const ir.Instruction, param_names: []const []const u8) usize {
        var locals = std.StringHashMap(void).init(std.heap.page_allocator);
        defer locals.deinit();

        for (instructions) |inst| {
            if (inst.op == .store_var) {
                if (inst.string_data) |var_name| {
                    // Check if it's not a parameter
                    var is_param = false;
                    for (param_names) |param_name| {
                        if (std.mem.eql(u8, var_name, param_name)) {
                            is_param = true;
                            break;
                        }
                    }
                    if (!is_param) {
                        locals.put(var_name, {}) catch {};
                    }
                }
            }
        }

        return locals.count();
    }

    fn genLiteralValue(self: *IrGenerator, value: ast.Value) !void {
        switch (value) {
            .int => |int_value| try self.builder.emit(.load_const_int, int_value, 0, 0),
            .float => |float_value| {
                const bits: u64 = @bitCast(float_value);
                try self.builder.emit(.load_const_float, @bitCast(bits), 0, 0);
            },
            .string => |string_value| try self.builder.emitWithString(.load_const_str, string_value, 0, 0),
            .bool => |bool_value| try self.builder.emit(.load_const_bool, if (bool_value) 1 else 0, 0, 0),
            .unit, .null_value => try self.builder.emit(.load_null, 0, 0, 0),
            .struct_instance, .array => unreachable,
        }
    }

    fn valueTypeFromValue(value: ast.Value) ir.ValueType {
        return switch (value) {
            .int => .int,
            .float => .float,
            .string => .string,
            .bool => .bool,
            .unit => .void,
            .null_value => .null_type,
            .struct_instance => .struct_type,
            .array => .array,
        };
    }

    /// Generate IR for a statement
    pub fn genStmt(self: *IrGenerator, stmt: *const Stmt) !void {
        switch (stmt.*) {
            .const_decl, .let_decl => |decl| {
                // Evaluate the value
                const saved_expected_type = self.expected_value_type;
                self.expected_value_type = decl.type_annotation;
                try self.genExpr(decl.value);
                self.expected_value_type = saved_expected_type;
                if (decl.type_annotation) |annotation| {
                    try self.emitTaggedWrap(annotation, self.exprDeclaredType(decl.value), self.exprValueType(decl.value));
                }
                // Store to variable
                try self.builder.emitWithString(.store_var, decl.name, 0, 0);
                try self.trackVariableDeclaredType(decl);
                try self.trackVariableStructType(decl);
                try self.trackVariableValueType(decl);
                try self.trackVariableArrayElementType(decl);
            },
            .expr_stmt => |expr| {
                try self.genExpr(expr);
                // Pop the result since it's not used
                try self.builder.emit(.pop, 0, 0, 0);
            },
            .fn_decl => |decl| {
                try self.function_return_types.put(decl.name, decl.return_type);
                try self.registerParameterTypes(decl.name, decl.parameters);
                try self.function_type_params.put(decl.name, decl.type_params);
                if (self.structNameForType(decl.return_type)) |struct_name| {
                    try self.function_struct_returns.put(decl.name, struct_name);
                }
                try self.function_value_returns.put(decl.name, self.valueTypeForType(decl.return_type));
                if (self.arrayElementValueTypeForType(decl.return_type)) |element_type| {
                    try self.function_array_returns.put(decl.name, element_type);
                }
                try self.generateFunction(decl.name, decl.type_params, decl.parameters, decl.return_type, decl.body);
            },
            .return_stmt => |maybe_expr| {
                if (maybe_expr) |expr| {
                    try self.genExpr(expr);
                    if (self.current_return_type) |return_type| {
                        try self.emitTaggedWrap(return_type, self.exprDeclaredType(expr), self.exprValueType(expr));
                    }
                } else {
                    try self.builder.emit(.load_null, 0, 0, 0);
                }
                try self.builder.emit(.ret, 0, 0, 0);
            },
            .break_stmt => {
                std.debug.assert(self.break_stack.items.len > 0);
                const jump_pos = self.builder.position();
                try self.builder.emit(.jump, 0, 0, 0);
                try self.break_stack.append(self.allocator, jump_pos);
            },
            .continue_stmt => {
                std.debug.assert(self.continue_stack.items.len > 0);
                const jump_pos = self.builder.position();
                try self.builder.emit(.jump, 0, 0, 0);
                try self.continue_stack.append(self.allocator, jump_pos);
            },
            .struct_decl => |decl| {
                // Register struct type with field names for proper field index mapping
                var field_names = try self.allocator.alloc([]const u8, decl.fields.len);
                for (decl.fields, 0..) |field, i| {
                    field_names[i] = field.name;
                }
                try self.struct_types.put(decl.name, field_names);

                const field_types = try self.allocator.alloc(Type, decl.fields.len);
                for (decl.fields, 0..) |field, i| {
                    field_types[i] = field.typ;
                }
                try self.struct_field_types.put(decl.name, field_types);
                try self.struct_type_params.put(decl.name, decl.type_params);

                // Register in builder for IR generation
                try self.builder.registerStructType(decl.name, field_names);

                // Lower methods as ordinary functions with an explicit `self`
                // parameter. The qualified name prevents collisions between
                // methods belonging to different struct types.
                for (decl.methods) |method| {
                    const qualified_name = try self.qualifiedMethodName(decl.name, method.name);
                    try self.function_return_types.put(qualified_name, method.return_type);
                    try self.registerParameterTypes(qualified_name, method.parameters);
                    try self.function_type_params.put(qualified_name, decl.type_params);
                    if (self.structNameForType(method.return_type)) |struct_name| {
                        try self.function_struct_returns.put(qualified_name, struct_name);
                    }
                    try self.function_value_returns.put(qualified_name, self.valueTypeForType(method.return_type));
                    if (self.arrayElementValueTypeForType(method.return_type)) |element_type| {
                        try self.function_array_returns.put(qualified_name, element_type);
                    }
                    try self.generateFunction(
                        qualified_name,
                        decl.type_params,
                        method.parameters,
                        method.return_type,
                        method.body,
                    );
                }
            },
            .type_alias => |alias| try self.type_aliases.put(alias.name, alias.target_type),
            .import_stmt => |import| {
                // Track imports for module system
                const module_name = std.fs.path.basename(import.module_path);

                // Create module entry
                const module = ir.Program.Module{
                    .name = try self.allocator.dupe(u8, module_name),
                    .path = try self.allocator.dupe(u8, import.module_path),
                    .exports = &[_][]const u8{}, // Will be populated during linking
                };

                try self.modules.append(self.allocator, module);

                // Track imported symbols
                if (import.imports) |imports| {
                    // Selective imports
                    for (imports) |symbol| {
                        try self.imported_symbols.put(try self.allocator.dupe(u8, symbol), try self.allocator.dupe(u8, module_name));
                    }
                } else {
                    // Full imports have already been expanded by the module
                    // loader before IR generation; retain only module metadata.
                }
            },
        }
    }

    /// Generate IR for an expression
    pub fn genExpr(self: *IrGenerator, expr: *const Expr) error{OutOfMemory}!void {
        switch (expr.*) {
            .int_literal => |val| {
                try self.builder.emit(.load_const_int, val, 0, 0);
            },
            .float_literal => |val| {
                const bits: u64 = @bitCast(val);
                try self.builder.emit(.load_const_float, @bitCast(bits), 0, 0);
            },
            .string_literal => |val| {
                try self.builder.emitWithString(.load_const_str, val, 0, 0);
            },
            .bool_literal => |val| {
                try self.builder.emit(.load_const_bool, if (val) 1 else 0, 0, 0);
            },
            .null_literal => {
                try self.builder.emit(.load_null, 0, 0, 0);
            },
            .variable => |name| {
                try self.builder.emitWithString(.load_var, name, 0, 0);
            },
            .binary => |binop| {
                const declared_left_type = self.exprDeclaredType(binop.left);
                if ((binop.op == .equal or binop.op == .not_equal) and
                    declared_left_type != null and isAggregateEqualityType(declared_left_type.?))
                {
                    try self.emitAggregateEquality(binop.left, binop.right, declared_left_type.?, binop.op == .not_equal);
                    return;
                }
                const operand_types = ir.encodeBinaryTypes(
                    self.exprValueType(binop.left),
                    self.exprValueType(binop.right),
                );
                // Generate left and right operands
                try self.genExpr(binop.left);
                try self.genExpr(binop.right);

                // Generate operation
                const op: ir.Opcode = switch (binop.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod,
                    .pow => .pow,
                    .equal => .eq,
                    .not_equal => .neq,
                    .less => .lt,
                    .less_equal => .lte,
                    .greater => .gt,
                    .greater_equal => .gte,
                    .logical_and => .and_op,
                    .logical_or => .or_op,
                };
                try self.builder.emit(op, 0, 0, operand_types);
            },
            .unary => |unop| {
                const operand_type = ir.encodeValueType(self.exprValueType(unop.operand));
                try self.genExpr(unop.operand);

                const op: ir.Opcode = switch (unop.op) {
                    .negate => .neg,
                    .logical_not => .not_op,
                };
                try self.builder.emit(op, 0, 0, operand_type);
            },
            .optional_unwrap => |optional_expr| {
                try self.genExpr(optional_expr);
                try self.builder.emit(.optional_unwrap, 0, 0, 0);
            },
            .optional_coalesce => |coalesce| {
                const optional_name = try self.nextTempName("coalesce_optional");
                const result_name = try self.nextTempName("coalesce_result");
                try self.genExpr(coalesce.optional);
                try self.builder.emitWithString(.store_var, optional_name, 0, 0);
                try self.builder.emitWithString(.load_var, optional_name, 0, 0);
                try self.builder.emit(.optional_is_null, 0, 0, 0);
                const use_optional = self.builder.position();
                try self.builder.emit(.jump_if_false, 0, 0, 0);

                try self.genExpr(coalesce.fallback);
                try self.builder.emitWithString(.store_var, result_name, 0, 0);
                const coalesce_done = self.builder.position();
                try self.builder.emit(.jump, 0, 0, 0);

                const optional_target = self.builder.position();
                self.builder.patchJump(use_optional, optional_target);
                try self.builder.emit(.stack_reset, 0, 0, 0);
                try self.builder.emitWithString(.load_var, optional_name, 0, 0);
                try self.builder.emit(.optional_unwrap, 0, 0, 0);
                try self.builder.emitWithString(.store_var, result_name, 0, 0);
                self.builder.patchJump(coalesce_done, self.builder.position());
                try self.builder.emit(.stack_reset, 0, 0, 0);
                try self.builder.emitWithString(.load_var, result_name, 0, 0);
            },
            .fn_call => |call| {
                const argument_type = if (call.arguments.len > 0)
                    ir.encodeValueType(self.exprValueType(call.arguments[0]))
                else
                    0;
                const parameter_types = self.function_parameter_types.get(call.name);
                const type_params = self.function_type_params.get(call.name) orelse &.{};
                // Generate arguments
                for (call.arguments, 0..) |arg, index| {
                    const target_type = if (parameter_types) |types|
                        if (index < types.len) resolvedTopLevelType(types[index], type_params, call.type_args) else null
                    else
                        null;
                    const saved_expected_type = self.expected_value_type;
                    self.expected_value_type = target_type;
                    try self.genExpr(arg);
                    self.expected_value_type = saved_expected_type;
                    if (target_type) |typ| try self.emitTaggedWrap(typ, self.exprDeclaredType(arg), self.exprValueType(arg));
                }

                // Call function
                try self.builder.emitWithString(.call, call.name, @intCast(call.arguments.len), argument_type);
            },
            .assignment => |assign| {
                const target_type = self.variable_declared_types.get(assign.name);
                const saved_expected_type = self.expected_value_type;
                self.expected_value_type = target_type;
                try self.genExpr(assign.value);
                self.expected_value_type = saved_expected_type;
                if (target_type) |typ| try self.emitTaggedWrap(typ, self.exprDeclaredType(assign.value), self.exprValueType(assign.value));
                try self.builder.emit(.dup, 0, 0, 0); // Duplicate for result
                try self.builder.emitWithString(.store_var, assign.name, 0, 0);
            },
            .block => |block| {
                for (block.statements, 0..) |*stmt, i| {
                    try self.genStmt(stmt);

                    // If there's an expression at the end, leave it on the stack
                    if (i == block.statements.len - 1) {
                        if (stmt.* == .expr_stmt) {
                            // Don't pop the last expression
                            continue;
                        }
                    }
                }

                // If there's a return expression, generate it
                if (block.return_expr) |return_expr| {
                    try self.genExpr(return_expr);
                } else {
                    // A block without a trailing value expression evaluates to unit.
                    try self.builder.emit(.load_null, 0, 0, 0);
                }
            },
            .if_expr => |if_expr| {
                // Generate condition
                try self.genExpr(if_expr.condition);

                // Jump to else if condition is false
                const jump_to_else = self.builder.position();
                try self.builder.emit(.jump_if_false, 0, 0, 0);

                // Generate then branch
                try self.genExpr(if_expr.then_block);

                // Jump over else
                const jump_over_else = self.builder.position();
                try self.builder.emit(.jump, 0, 0, 0);

                // Patch jump to else
                const else_pos = self.builder.position();
                self.builder.patchJump(jump_to_else, else_pos);

                // Generate else branch
                if (if_expr.else_block) |else_block| {
                    try self.genExpr(else_block);
                } else {
                    // No else branch, push null
                    try self.builder.emit(.load_null, 0, 0, 0);
                }

                // Patch jump over else
                const after_else = self.builder.position();
                self.builder.patchJump(jump_over_else, after_else);
            },
            .while_expr => |while_expr| {
                const loop_start = self.builder.position();

                // Generate condition
                try self.genExpr(while_expr.condition);

                // Jump out of loop if false
                const jump_out = self.builder.position();
                try self.builder.emit(.jump_if_false, 0, 0, 0);

                // Generate body
                const loop_scope = try self.beginLoop();
                var loop_finished = false;
                defer if (!loop_finished) self.abandonLoop(loop_scope);
                try self.genExpr(while_expr.body);
                try self.builder.emit(.pop, 0, 0, 0);

                // Jump back to start
                try self.builder.emit(.jump, @intCast(loop_start), 0, 0);

                // Patch exit jump
                const after_loop = self.builder.position();
                self.builder.patchJump(jump_out, after_loop);
                self.finishLoop(loop_scope, loop_start, after_loop);
                loop_finished = true;

                // Push null as result of while expression
                try self.builder.emit(.load_null, 0, 0, 0);
            },
            .struct_init => |struct_init| {
                // Push field count
                try self.builder.emit(.struct_new, @intCast(struct_init.fields.len), 0, 0);

                // Generate each field value with type-specific field indices
                for (struct_init.fields) |field| {
                    // Get field index based on struct type
                    const field_idx = try self.builder.getFieldIndex(struct_init.type_name, field.name);
                    const field_names = self.struct_types.get(struct_init.type_name) orelse &.{};
                    const field_types = self.struct_field_types.get(struct_init.type_name) orelse &.{};
                    const type_params = self.struct_type_params.get(struct_init.type_name) orelse &.{};
                    var target_type: ?Type = null;
                    for (field_names, 0..) |field_name, index| {
                        if (std.mem.eql(u8, field_name, field.name)) {
                            target_type = resolvedTopLevelType(field_types[index], type_params, struct_init.type_args);
                            break;
                        }
                    }
                    const saved_expected_type = self.expected_value_type;
                    self.expected_value_type = target_type;
                    try self.genExpr(field.value);
                    self.expected_value_type = saved_expected_type;
                    if (target_type) |typ| try self.emitTaggedWrap(typ, self.exprDeclaredType(field.value), self.exprValueType(field.value));
                    try self.builder.emit(.field_set, @intCast(field_idx), 0, 0);
                }
            },
            .field_access => |access| {
                // Generate the object
                try self.genExpr(access.object);

                // Resolve the field against the statically known receiver type.
                // Falling back to string interning keeps malformed IR diagnosable,
                // but valid typed programs should always take the first branch.
                const field_idx = if (self.structNameFromExpr(access.object)) |struct_name|
                    try self.builder.getFieldIndex(struct_name, access.field_name)
                else
                    try self.builder.getFieldIndexByName(access.field_name);
                try self.builder.emit(.field_get, @intCast(field_idx), 0, 0);
            },
            .method_call => |call| {
                const receiver_type = ir.encodeValueType(self.exprValueType(call.receiver));
                // Generate receiver (self)
                try self.genExpr(call.receiver);

                // Call the qualified method (receiver is the explicit first argument).
                const function_name = if (self.structNameFromExpr(call.receiver)) |struct_name|
                    try self.qualifiedMethodName(struct_name, call.method_name)
                else
                    call.method_name;
                const parameter_types = self.function_parameter_types.get(function_name);
                const instance = self.structInstanceFromExpr(call.receiver);
                const type_params = self.function_type_params.get(function_name) orelse &.{};
                // Generate arguments (parameter zero is the explicit receiver).
                for (call.arguments, 0..) |arg, index| {
                    const parameter_index = index + 1;
                    const target_type = if (parameter_types) |types|
                        if (parameter_index < types.len)
                            resolvedTopLevelType(
                                types[parameter_index],
                                type_params,
                                if (instance) |info| info.type_args else &.{},
                            )
                        else
                            null
                    else
                        null;
                    const saved_expected_type = self.expected_value_type;
                    self.expected_value_type = target_type;
                    try self.genExpr(arg);
                    self.expected_value_type = saved_expected_type;
                    if (target_type) |typ| try self.emitTaggedWrap(typ, self.exprDeclaredType(arg), self.exprValueType(arg));
                }
                try self.builder.emitWithString(.call, function_name, @intCast(call.arguments.len + 1), receiver_type);
            },
            .array_literal => |array| {
                // Push array size
                try self.builder.emit(.array_new, @intCast(array.elements.len), 0, 0);

                // Generate each element
                const element_target = if (self.expected_value_type) |expected|
                    if (expected == .array) expected.array.* else null
                else
                    null;
                for (array.elements, 0..) |elem, i| {
                    try self.builder.emit(.dup, 0, 0, 0); // Duplicate array reference
                    try self.builder.emit(.load_const_int, @intCast(i), 0, 0); // Index
                    const saved_expected_type = self.expected_value_type;
                    self.expected_value_type = element_target;
                    try self.genExpr(elem); // Value
                    self.expected_value_type = saved_expected_type;
                    if (element_target) |typ| try self.emitTaggedWrap(typ, self.exprDeclaredType(elem), self.exprValueType(elem));
                    try self.builder.emit(.array_set, 0, 0, 0);
                }
            },
            .array_access => |access| {
                // Generate array and index
                try self.genExpr(access.array);
                try self.genExpr(access.index);
                try self.builder.emit(.array_get, 0, 0, 0);
            },
            .is_check => |check| {
                const check_type = check.resolved_type.* orelse check.check_type;
                const checked_type = ir.encodeValueType(self.exprValueType(check.expr));
                // Generate the expression to check
                try self.genExpr(check.expr);

                // Encode the checked runtime type in operand1.
                const type_id: i64 = switch (check_type) {
                    .int => 1,
                    .float => 2,
                    .string => 3,
                    .bool => 4,
                    .user_type, .generic_instance => 5,
                    .array => 6,
                    .unit => 7,
                    .optional => 8,
                    .union_type => 9,
                    else => 0,
                };

                const target_descriptor = try self.typeDescriptor(check_type);
                const actual_declared_type = self.exprDeclaredType(check.expr);
                const encoded_type_id = if (check.static_result.*) |matches|
                    if (matches) @as(i64, 10) else @as(i64, 11)
                else if (checked_type != ir.encodeValueType(.optional) and
                    checked_type != ir.encodeValueType(.union_type) and type_id == 5)
                    if (actual_declared_type != null and actual_declared_type.?.eql(check_type)) @as(i64, 10) else @as(i64, 11)
                else
                    type_id;
                try self.builder.emitFullWithString(.type_check, target_descriptor, encoded_type_id, if (check.is_not) 1 else 0, checked_type);
            },
            .for_expr => |for_expr| {
                // Lower for loops to the core jump/array operations.

                if (for_expr.is_range) {
                    // Lower range loops directly: start..end or start..=end
                    try self.genExpr(for_expr.iterable);

                    const index_var = try self.nextTempName("for_range_index");
                    try self.builder.emitWithString(.store_var, index_var, 0, 0);

                    const range_end = for_expr.range_end orelse unreachable;
                    try self.genExpr(range_end);
                    const end_var = try self.nextTempName("for_range_end");
                    try self.builder.emitWithString(.store_var, end_var, 0, 0);

                    // Choose a direction once so both ascending and descending
                    // ranges share the same loop. The AST interpreter already
                    // supports both directions; keeping the step in IR preserves
                    // that behavior in C and LLVM as well.
                    const step_var = try self.nextTempName("for_range_step");
                    try self.builder.emitWithString(.load_var, index_var, 0, 0);
                    try self.builder.emitWithString(.load_var, end_var, 0, 0);
                    try self.builder.emit(.lte, 0, 0, 0);
                    const jump_to_descending = self.builder.position();
                    try self.builder.emit(.jump_if_false, 0, 0, 0);
                    try self.builder.emit(.load_const_int, 1, 0, 0);
                    try self.builder.emitWithString(.store_var, step_var, 0, 0);
                    const jump_after_step = self.builder.position();
                    try self.builder.emit(.jump, 0, 0, 0);
                    const descending_step = self.builder.position();
                    self.builder.patchJump(jump_to_descending, descending_step);
                    try self.builder.emit(.load_const_int, -1, 0, 0);
                    try self.builder.emitWithString(.store_var, step_var, 0, 0);
                    const after_step = self.builder.position();
                    self.builder.patchJump(jump_after_step, after_step);

                    const loop_start = self.builder.position();

                    // Compare in the selected direction without subtracting the
                    // endpoints. Subtraction can overflow for ranges spanning
                    // the full signed integer domain.
                    try self.builder.emitWithString(.load_var, step_var, 0, 0);
                    try self.builder.emit(.load_const_int, 0, 0, 0);
                    try self.builder.emit(.gt, 0, 0, 0);
                    try self.builder.emitWithString(.load_var, index_var, 0, 0);
                    try self.builder.emitWithString(.load_var, end_var, 0, 0);
                    try self.builder.emit(if (for_expr.range_inclusive) .lte else .lt, 0, 0, 0);
                    try self.builder.emit(.and_op, 0, 0, 0);

                    try self.builder.emitWithString(.load_var, step_var, 0, 0);
                    try self.builder.emit(.load_const_int, 0, 0, 0);
                    try self.builder.emit(.lt, 0, 0, 0);
                    try self.builder.emitWithString(.load_var, index_var, 0, 0);
                    try self.builder.emitWithString(.load_var, end_var, 0, 0);
                    try self.builder.emit(if (for_expr.range_inclusive) .gte else .gt, 0, 0, 0);
                    try self.builder.emit(.and_op, 0, 0, 0);
                    try self.builder.emit(.or_op, 0, 0, 0);

                    // Jump out if done
                    const jump_out = self.builder.position();
                    try self.builder.emit(.jump_if_false, 0, 0, 0);

                    // Set iterator variable from current index
                    try self.builder.emitWithString(.load_var, index_var, 0, 0);
                    try self.builder.emitWithString(.store_var, for_expr.iterator, 0, 0);

                    // Execute body
                    const previous_iterator_type = self.variable_value_types.get(for_expr.iterator);
                    try self.variable_value_types.put(for_expr.iterator, .int);
                    defer {
                        if (previous_iterator_type) |previous| {
                            self.variable_value_types.put(for_expr.iterator, previous) catch unreachable;
                        } else {
                            _ = self.variable_value_types.remove(for_expr.iterator);
                        }
                    }
                    const loop_scope = try self.beginLoop();
                    var loop_finished = false;
                    defer if (!loop_finished) self.abandonLoop(loop_scope);
                    try self.genExpr(for_expr.body);
                    try self.builder.emit(.pop, 0, 0, 0);

                    // Increment index
                    const continue_target = self.builder.position();
                    const jump_at_inclusive_end = if (for_expr.range_inclusive) blk: {
                        try self.builder.emitWithString(.load_var, index_var, 0, 0);
                        try self.builder.emitWithString(.load_var, end_var, 0, 0);
                        try self.builder.emit(.eq, 0, 0, 0);
                        const jump_pos = self.builder.position();
                        try self.builder.emit(.jump_if_true, 0, 0, 0);
                        break :blk @as(?usize, jump_pos);
                    } else null;
                    try self.builder.emitWithString(.load_var, index_var, 0, 0);
                    try self.builder.emitWithString(.load_var, step_var, 0, 0);
                    try self.builder.emit(.add, 0, 0, 0);
                    try self.builder.emitWithString(.store_var, index_var, 0, 0);

                    // Jump back to start
                    try self.builder.emit(.jump, @intCast(loop_start), 0, 0);

                    // Patch exit
                    const after_loop = self.builder.position();
                    self.builder.patchJump(jump_out, after_loop);
                    if (jump_at_inclusive_end) |jump_pos| self.builder.patchJump(jump_pos, after_loop);
                    self.finishLoop(loop_scope, continue_target, after_loop);
                    loop_finished = true;

                    // Push unit result
                    try self.builder.emit(.load_null, 0, 0, 0);
                    return;
                }

                // Evaluate iterable
                try self.genExpr(for_expr.iterable);

                // Store in temporary (we'll use a generated temp variable)
                const temp_name = try self.nextTempName("for_iterable");
                try self.builder.emitWithString(.store_var, temp_name, 0, 0);

                // Initialize index to 0
                try self.builder.emit(.load_const_int, 0, 0, 0);
                const index_var = try self.nextTempName("for_index");
                try self.builder.emitWithString(.store_var, index_var, 0, 0);

                // Loop start
                const loop_start = self.builder.position();

                // Check if index < length
                try self.builder.emitWithString(.load_var, index_var, 0, 0);
                try self.builder.emitWithString(.load_var, temp_name, 0, 0);
                try self.builder.emit(.array_len, 0, 0, 0);
                try self.builder.emit(.lt, 0, 0, 0);

                // Jump out if done
                const jump_out = self.builder.position();
                try self.builder.emit(.jump_if_false, 0, 0, 0);

                // Load current element into iterator variable
                try self.builder.emitWithString(.load_var, temp_name, 0, 0);
                try self.builder.emitWithString(.load_var, index_var, 0, 0);
                try self.builder.emit(.array_get, 0, 0, 0);
                try self.builder.emitWithString(.store_var, for_expr.iterator, 0, 0);

                // Execute body
                const previous_iterator_type = self.variable_value_types.get(for_expr.iterator);
                const element_type = self.arrayElementValueType(for_expr.iterable);
                if (element_type) |typ| try self.variable_value_types.put(for_expr.iterator, typ);
                defer {
                    if (previous_iterator_type) |previous| {
                        self.variable_value_types.put(for_expr.iterator, previous) catch unreachable;
                    } else if (element_type != null) {
                        _ = self.variable_value_types.remove(for_expr.iterator);
                    }
                }
                const loop_scope = try self.beginLoop();
                var loop_finished = false;
                defer if (!loop_finished) self.abandonLoop(loop_scope);
                try self.genExpr(for_expr.body);
                try self.builder.emit(.pop, 0, 0, 0); // Pop body result

                // Increment index
                const continue_target = self.builder.position();
                try self.builder.emitWithString(.load_var, index_var, 0, 0);
                try self.builder.emit(.load_const_int, 1, 0, 0);
                try self.builder.emit(.add, 0, 0, 0);
                try self.builder.emitWithString(.store_var, index_var, 0, 0);

                // Jump back to start
                try self.builder.emit(.jump, @intCast(loop_start), 0, 0);

                // Patch exit
                const after_loop = self.builder.position();
                self.builder.patchJump(jump_out, after_loop);
                self.finishLoop(loop_scope, continue_target, after_loop);
                loop_finished = true;

                // Push unit result
                try self.builder.emit(.load_null, 0, 0, 0);
            },
            .match_expr => |match_expr| {
                // Generate match expression value
                try self.genExpr(match_expr.expr);
                const match_value_type = self.exprValueType(match_expr.expr);
                const match_temp = try self.nextTempName("match_value");
                try self.builder.emitWithString(.store_var, match_temp, 0, 0);

                // Generate each arm
                var jump_to_end = std.ArrayList(usize).initCapacity(self.allocator, 4) catch unreachable;
                defer jump_to_end.deinit(self.allocator);

                for (match_expr.arms) |arm| {
                    var next_arm_jump: ?usize = null;
                    switch (arm.pattern) {
                        .wildcard, .variable => {},
                        .literal => |literal| {
                            try self.builder.emitWithString(.load_var, match_temp, 0, 0);
                            try self.genLiteralValue(literal);
                            try self.builder.emit(.eq, 0, 0, ir.encodeBinaryTypes(match_value_type, valueTypeFromValue(literal)));
                            next_arm_jump = self.builder.position();
                            try self.builder.emit(.jump_if_false, 0, 0, 0);
                        },
                        .range => |range| {
                            try self.builder.emitWithString(.load_var, match_temp, 0, 0);
                            try self.builder.emit(.load_const_int, range.start, 0, 0);
                            try self.builder.emit(.gte, 0, 0, ir.encodeBinaryTypes(.int, .int));
                            try self.builder.emitWithString(.load_var, match_temp, 0, 0);
                            try self.builder.emit(.load_const_int, range.end, 0, 0);
                            try self.builder.emit(if (range.inclusive) .lte else .lt, 0, 0, ir.encodeBinaryTypes(.int, .int));
                            try self.builder.emit(.and_op, 0, 0, 0);
                            next_arm_jump = self.builder.position();
                            try self.builder.emit(.jump_if_false, 0, 0, 0);
                        },
                    }

                    // Bind pattern variable if needed
                    if (arm.pattern == .variable) {
                        try self.builder.emitWithString(.load_var, match_temp, 0, 0);
                        try self.builder.emitWithString(.store_var, arm.pattern.variable, 0, 0);
                    }

                    // Generate arm body
                    try self.genExpr(arm.body);

                    // Jump to end
                    try jump_to_end.append(self.allocator, self.builder.position());
                    try self.builder.emit(.jump, 0, 0, 0);

                    // Patch next arm jump
                    if (next_arm_jump) |jump_pos| {
                        const next_pos = self.builder.position();
                        self.builder.patchJump(jump_pos, next_pos);
                    }
                }

                // A non-exhaustive match that reaches the end produces null in
                // IR. The type checker is responsible for rejecting incompatible
                // uses of that value.
                try self.builder.emit(.load_null, 0, 0, 0);

                // Patch all end jumps
                const end_pos = self.builder.position();
                for (jump_to_end.items) |jump_pos| {
                    self.builder.patchJump(jump_pos, end_pos);
                }
            },
            .field_assignment => |assign| {
                // Generate object
                try self.genExpr(assign.object);

                // Generate value
                const target_type = if (self.fieldTypeContext(assign.object, assign.field_name)) |context|
                    resolvedTopLevelType(context.typ, context.params, context.args)
                else
                    null;
                const saved_expected_type = self.expected_value_type;
                self.expected_value_type = target_type;
                try self.genExpr(assign.value);
                self.expected_value_type = saved_expected_type;
                if (target_type) |typ| try self.emitTaggedWrap(typ, self.exprDeclaredType(assign.value), self.exprValueType(assign.value));

                // Get field index
                const field_idx = if (self.structNameFromExpr(assign.object)) |struct_name|
                    try self.builder.getFieldIndex(struct_name, assign.field_name)
                else
                    try self.builder.getFieldIndexByName(assign.field_name);
                try self.builder.emit(.field_set, @intCast(field_idx), 0, 0);
                try self.builder.emit(.pop, 0, 0, 0); // Discard the chaining value.

                // Push unit result
                try self.builder.emit(.load_null, 0, 0, 0);
            },
            .array_assignment => |assign| {
                // Generate array
                try self.genExpr(assign.array);

                // Generate index
                try self.genExpr(assign.index);

                // Generate value
                const target_type = self.arrayElementDeclaredType(assign.array);
                const saved_expected_type = self.expected_value_type;
                self.expected_value_type = target_type;
                try self.genExpr(assign.value);
                self.expected_value_type = saved_expected_type;
                if (target_type) |typ| try self.emitTaggedWrap(typ, self.exprDeclaredType(assign.value), self.exprValueType(assign.value));

                // Set array element
                try self.builder.emit(.array_set, 0, 0, 0);

                // Push unit result
                try self.builder.emit(.load_null, 0, 0, 0);
            },
        }
    }

    /// Generate a complete IR program from a list of statements
    pub fn generate(self: *IrGenerator, statements: []const Stmt) !ir.Program {
        // Aliases affect runtime representation decisions, including aliases
        // used by functions declared before their textual definition.
        for (statements) |stmt| {
            if (stmt == .type_alias) try self.type_aliases.put(stmt.type_alias.name, stmt.type_alias.target_type);
        }

        // Register return representations before lowering bodies so forward
        // calls carry the same type metadata as calls to earlier functions.
        for (statements) |stmt| {
            switch (stmt) {
                .fn_decl => |decl| {
                    try self.function_return_types.put(decl.name, decl.return_type);
                    try self.registerParameterTypes(decl.name, decl.parameters);
                    try self.function_type_params.put(decl.name, decl.type_params);
                    try self.function_value_returns.put(decl.name, self.valueTypeForType(decl.return_type));
                    if (self.arrayElementValueTypeForType(decl.return_type)) |element_type| {
                        try self.function_array_returns.put(decl.name, element_type);
                    }
                    if (self.structNameForType(decl.return_type)) |struct_name| {
                        try self.function_struct_returns.put(decl.name, struct_name);
                    }
                },
                .struct_decl => |decl| {
                    try self.struct_type_params.put(decl.name, decl.type_params);
                    for (decl.methods) |method| {
                        const qualified_name = try self.qualifiedMethodName(decl.name, method.name);
                        try self.function_return_types.put(qualified_name, method.return_type);
                        try self.registerParameterTypes(qualified_name, method.parameters);
                        try self.function_type_params.put(qualified_name, decl.type_params);
                        try self.function_value_returns.put(qualified_name, self.valueTypeForType(method.return_type));
                        if (self.arrayElementValueTypeForType(method.return_type)) |element_type| {
                            try self.function_array_returns.put(qualified_name, element_type);
                        }
                        if (self.structNameForType(method.return_type)) |struct_name| {
                            try self.function_struct_returns.put(qualified_name, struct_name);
                        }
                    }
                },
                else => {},
            }
        }

        // Generate IR for each statement
        for (statements) |*stmt| {
            try self.genStmt(stmt);
        }

        // Add halt instruction
        try self.builder.emit(.halt, 0, 0, 0);

        // Create main function with all the top-level code
        const main_instructions = try self.builder.instructions.toOwnedSlice(self.allocator);
        try self.functions.append(self.allocator, .{
            .name = "main",
            .param_count = 0,
            .local_count = 0,
            .instructions = main_instructions,
        });

        // Create program
        const functions = try self.functions.toOwnedSlice(self.allocator);
        const strings = try self.builder.string_list.toOwnedSlice(self.allocator);
        const modules = try self.modules.toOwnedSlice(self.allocator);

        return ir.Program{
            .functions = functions,
            .string_pool = strings,
            .entry_point = "main",
            .modules = modules,
        };
    }
};
