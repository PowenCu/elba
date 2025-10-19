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
        .generic_instance => |inst| {
            // Recursively substitute type arguments
            var new_args = std.ArrayList(Type).initCapacity(std.heap.page_allocator, inst.type_args.len) catch return typ;

            for (inst.type_args) |arg| {
                new_args.append(std.heap.page_allocator, substituteType(arg, type_params, type_args)) catch return typ;
            }

            return Type{ .generic_instance = .{
                .base_type = inst.base_type,
                .type_args = new_args.toOwnedSlice(std.heap.page_allocator) catch return typ,
            } };
        },
        .array => |elem_type_ptr| {
            // Recursively substitute the element type
            const substituted_elem = substituteType(elem_type_ptr.*, type_params, type_args);
            const new_elem_ptr = std.heap.page_allocator.create(Type) catch return typ;
            new_elem_ptr.* = substituted_elem;
            return Type{ .array = new_elem_ptr };
        },
        .optional => |inner_type_ptr| {
            // Recursively substitute the inner type
            const substituted_inner = substituteType(inner_type_ptr.*, type_params, type_args);
            const new_inner_ptr = std.heap.page_allocator.create(Type) catch return typ;
            new_inner_ptr.* = substituted_inner;
            return Type{ .optional = new_inner_ptr };
        },
        .union_type => |types| {
            // Recursively substitute each type in the union
            var new_types = std.ArrayList(Type).initCapacity(std.heap.page_allocator, types.len) catch return typ;
            for (types) |t| {
                new_types.append(std.heap.page_allocator, substituteType(t, type_params, type_args)) catch return typ;
            }
            return Type{ .union_type = new_types.toOwnedSlice(std.heap.page_allocator) catch return typ };
        },
        else => return typ,
    }
}

// Check if a value type is compatible with a target type (including union types)
fn isTypeCompatible(value_type: Type, target_type: Type) bool {
    // Unknown type accepts anything (for builtins with generic params)
    if (target_type == .unknown or value_type == .unknown) {
        return true;
    }

    // Direct match
    if (value_type.eql(target_type)) {
        return true;
    }

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

pub fn checkStmt(stmt: *const Stmt, env: *TypeEnvironment) error{ TypeError, UndefinedVariable, OutOfMemory }!void {
    switch (stmt.*) {
        .const_decl => |decl| {
            const value_type = try inferExpr(decl.value, env);

            // If type annotation is provided, check it matches the value type
            if (decl.type_annotation) |annotated_type| {
                // Resolve type alias
                const resolved_type = resolveTypeAlias(annotated_type, env);

                // Allow null assignment to optional types
                if (value_type == .unknown and resolved_type == .optional) {
                    try env.set(decl.name, .{ .typ = resolved_type, .mutable = false });
                    return;
                }
                // Allow assigning non-optional value to optional type
                if (resolved_type == .optional) {
                    const inner_type = resolved_type.optional.*;
                    if (inner_type.eql(value_type)) {
                        try env.set(decl.name, .{ .typ = resolved_type, .mutable = false });
                        return;
                    }
                }
                // Check union type compatibility
                if (isTypeCompatible(value_type, resolved_type)) {
                    try env.set(decl.name, .{ .typ = resolved_type, .mutable = false });
                    return;
                }
                // Allow implicit int->float conversion
                if (resolved_type == .float and value_type == .int) {
                    try env.set(decl.name, .{ .typ = .float, .mutable = false });
                    return;
                }
                var buf1: [256]u8 = undefined;
                var buf2: [256]u8 = undefined;
                std.debug.print("Type error: Variable '{s}' declared as '{s}' but initialized with '{s}'\n", .{ decl.name, typeToString(resolved_type, &buf1), typeToString(value_type, &buf2) });
                return error.TypeError;
            } else {
                // No type annotation, use inferred type
                try env.set(decl.name, .{ .typ = value_type, .mutable = false });
            }
        },
        .let_decl => |decl| {
            const value_type = try inferExpr(decl.value, env);

            // If type annotation is provided, check it matches the value type
            if (decl.type_annotation) |annotated_type| {
                // Resolve type alias
                const resolved_type = resolveTypeAlias(annotated_type, env);

                // Allow null assignment to optional types
                if (value_type == .unknown and resolved_type == .optional) {
                    try env.set(decl.name, .{ .typ = resolved_type, .mutable = true });
                    return;
                }
                // Allow assigning non-optional value to optional type
                if (resolved_type == .optional) {
                    const inner_type = resolved_type.optional.*;
                    if (inner_type.eql(value_type)) {
                        try env.set(decl.name, .{ .typ = resolved_type, .mutable = true });
                        return;
                    }
                }
                // Check union type compatibility
                if (isTypeCompatible(value_type, resolved_type)) {
                    try env.set(decl.name, .{ .typ = resolved_type, .mutable = true });
                    return;
                }
                if (!resolved_type.eql(value_type)) {
                    // Allow implicit int->float conversion
                    if (resolved_type == .float and value_type == .int) {
                        try env.set(decl.name, .{ .typ = .float, .mutable = true });
                        return;
                    }
                    var buf1: [256]u8 = undefined;
                    var buf2: [256]u8 = undefined;
                    std.debug.print("Type error: Variable '{s}' declared as '{s}' but initialized with '{s}'\n", .{ decl.name, typeToString(resolved_type, &buf1), typeToString(value_type, &buf2) });
                    return error.TypeError;
                }
                try env.set(decl.name, .{ .typ = resolved_type, .mutable = true });
            } else {
                // No type annotation, use inferred type
                try env.set(decl.name, .{ .typ = value_type, .mutable = true });
            }
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

            for (decl.parameters, 0..) |param, i| {
                try fn_env.set(param.name, .{ .typ = param_types[i], .mutable = false });
            }

            const body_type = try inferExpr(decl.body, &fn_env);

            // Check return type matches
            // However, if the body is a block with return statements, those handle the return
            const has_return_stmt = blk: {
                if (decl.body.* == .block) {
                    for (decl.body.block.statements) |block_stmt| {
                        if (block_stmt == .return_stmt) {
                            break :blk true;
                        }
                    }
                }
                break :blk false;
            };

            if (!has_return_stmt and !isTypeCompatible(body_type, resolved_return_type)) {
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

                for (method.parameters) |param| {
                    try method_env.set(param.name, .{ .typ = param.typ, .mutable = false });
                }

                const body_type = try inferExpr(method.body, &method_env);

                // Check return type matches
                const has_return_stmt = blk: {
                    if (method.body.* == .block) {
                        for (method.body.block.statements) |block_stmt| {
                            if (block_stmt == .return_stmt) {
                                break :blk true;
                            }
                        }
                    }
                    break :blk false;
                };

                if (!has_return_stmt and !isTypeCompatible(body_type, method.return_type)) {
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
        .return_stmt => |expr| {
            _ = try inferExpr(expr, env);
            // Note: We'll need to track expected return type in a more sophisticated implementation
        },
        .expr_stmt => |expr| {
            _ = try inferExpr(expr, env);
        },
    }
}

pub fn inferExpr(expr: *const Expr, env: *TypeEnvironment) error{ TypeError, UndefinedVariable, OutOfMemory }!Type {
    switch (expr.*) {
        .int_literal => return .int,
        .float_literal => return .float,
        .string_literal => return .string,
        .bool_literal => return .bool,
        .null_literal => {
            // null has unknown type by itself, it needs context to determine its type
            // For now, we'll return unknown and handle it in assignments/comparisons
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
                                // Could be a variable of optional type, allow it for now
                                return .bool;
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

            _ = try inferExpr(while_expr.body, env);
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
            const value_type = try inferExpr(assign.value, env);

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
                    param_types[i] = substituteType(param.typ, template.type_params, call.type_args);
                }

                const return_type = substituteType(template.return_type, template.type_params, call.type_args);

                // Check argument count and types
                if (call.arguments.len != param_types.len) {
                    std.debug.print("Type error: Function '{s}' expects {d} arguments but got {d}\n", .{ call.name, param_types.len, call.arguments.len });
                    env.allocator.free(param_types);
                    return error.TypeError;
                }

                for (call.arguments, 0..) |arg, i| {
                    const arg_type = try inferExpr(arg, env);
                    // Use isTypeCompatible to allow passing values to union parameters
                    if (!isTypeCompatible(arg_type, param_types[i])) {
                        var buf1: [256]u8 = undefined;
                        var buf2: [256]u8 = undefined;
                        std.debug.print("Type error: Function '{s}' parameter {d} expects '{s}' but got '{s}'\n", .{ call.name, i, typeToString(param_types[i], &buf1), typeToString(arg_type, &buf2) });
                        env.allocator.free(param_types);
                        return error.TypeError;
                    }
                }

                env.allocator.free(param_types);
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
                const arg_type = try inferExpr(arg, env);
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
                            expected_type = substituteType(field_decl.typ, template.type_params, init.type_args);
                            found = true;
                            break;
                        }
                    }

                    if (!found) {
                        std.debug.print("Type error: Struct '{s}' has no field '{s}'\n", .{ init.type_name, field_init.name });
                        return error.TypeError;
                    }

                    const actual_type = try inferExpr(field_init.value, env);

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

                const actual_type = try inferExpr(field_init.value, env);

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

                    // Substitute type parameters
                    return substituteType(ft, template.type_params, inst.type_args);
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
                        const arg_type = try inferExpr(arg, env);
                        const expected_type = method.param_types[i + 1]; // +1 to skip 'self'
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
                        const arg_type = try inferExpr(arg, env);
                        const expected_type = method.parameters[i + 1].typ; // +1 to skip 'self'
                        // Use isTypeCompatible to allow passing values to union parameters
                        if (!isTypeCompatible(arg_type, expected_type)) {
                            var buf1: [256]u8 = undefined;
                            var buf2: [256]u8 = undefined;
                            std.debug.print("Type error: Method '{s}' parameter {d} expects '{s}' but got '{s}'\n", .{ call.method_name, i, typeToString(expected_type, &buf1), typeToString(arg_type, &buf2) });
                            return error.TypeError;
                        }
                    }

                    // Substitute type parameters in the return type
                    // If return type is a generic_instance with type params from the template,
                    // replace them with the actual type args from the instance
                    const return_type = method.return_type;
                    switch (return_type) {
                        .generic_instance => |ret_instance| {
                            // Check if the base type matches our struct
                            if (std.mem.eql(u8, ret_instance.base_type, instance.base_type)) {
                                // Return the same generic instance type as the receiver
                                return receiver_type;
                            }
                            return return_type;
                        },
                        else => return return_type,
                    }
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
                // Empty array - we'll infer type from usage later
                // For now, return unknown array type
                std.debug.print("Type error: Empty array literals not yet supported\n", .{});
                return error.TypeError;
            }

            // Infer type from first element
            const first_type = try inferExpr(literal.elements[0], env);

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

            return Type{ .array = elem_type_ptr };
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
            const expr_type = try inferExpr(check.expr, env);

            // The result is always a bool
            // We could validate that the check_type is compatible with expr_type,
            // but for union types, any check is valid
            _ = expr_type; // Suppress unused warning

            return .bool;
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
}
