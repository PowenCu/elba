const std = @import("std");
const Expr = @import("../frontend/ast.zig").Expr;
const Stmt = @import("../frontend/ast.zig").Stmt;
const Value = @import("../frontend/ast.zig").Value;

// Thread-local return value for early function returns
threadlocal var return_value: ?Value = null;

// Builtin function signature
pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []Value) error{ UndefinedVariable, OutOfMemory, EarlyReturn, TypeError, IndexOutOfBounds, InvalidArguments }!Value;

pub const FnValue = struct {
    parameters: []Stmt.Parameter,
    body: *Expr,
};

pub const GenericFnTemplate = struct {
    type_params: [][]const u8,
    parameters: []Stmt.Parameter,
    body: *Expr,
};

pub const MethodValue = struct {
    parameters: []Stmt.Parameter, // Includes 'self' as first parameter
    body: *Expr,
};

pub const StructMethods = struct {
    methods: std.StringHashMap(MethodValue),
};

pub const GenericStructTemplate = struct {
    type_params: [][]const u8,
    fields: []Stmt.FieldDecl,
    methods: []Stmt.MethodDecl,
};

pub const Environment = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(Value),
    binding_order: std.ArrayList([]const u8), // Track insertion order
    functions: std.StringHashMap(FnValue),
    builtins: std.StringHashMap(BuiltinFn),
    generic_functions: std.StringHashMap(GenericFnTemplate),
    struct_methods: std.StringHashMap(StructMethods), // Indexed by struct name
    generic_structs: std.StringHashMap(GenericStructTemplate),
    parent: ?*Environment,

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(Value).init(allocator),
            .binding_order = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .functions = std.StringHashMap(FnValue).init(allocator),
            .builtins = std.StringHashMap(BuiltinFn).init(allocator),
            .generic_functions = std.StringHashMap(GenericFnTemplate).init(allocator),
            .struct_methods = std.StringHashMap(StructMethods).init(allocator),
            .generic_structs = std.StringHashMap(GenericStructTemplate).init(allocator),
            .parent = null,
        };
    }

    pub fn initScoped(allocator: std.mem.Allocator, parent: *Environment) Environment {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(Value).init(allocator),
            .binding_order = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .functions = std.StringHashMap(FnValue).init(allocator),
            .builtins = std.StringHashMap(BuiltinFn).init(allocator),
            .generic_functions = std.StringHashMap(GenericFnTemplate).init(allocator),
            .struct_methods = std.StringHashMap(StructMethods).init(allocator),
            .generic_structs = std.StringHashMap(GenericStructTemplate).init(allocator),
            .parent = parent,
        };
    }

    pub fn deinit(self: *Environment) void {
        self.bindings.deinit();
        self.binding_order.deinit(self.allocator);
        self.functions.deinit();
        self.builtins.deinit();
        self.generic_functions.deinit();
        // Deinit all struct method maps
        var iter = self.struct_methods.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.methods.deinit();
        }
        self.struct_methods.deinit();
        self.generic_structs.deinit();
    }

    pub fn set(self: *Environment, name: []const u8, value: Value) !void {
        // Check if variable exists in current scope
        if (self.bindings.contains(name)) {
            try self.bindings.put(name, value);
            return;
        }
        // Check parent scopes
        if (self.parent) |parent| {
            try parent.set(name, value);
        } else {
            // Variable not found, create new binding and track order
            const is_new = !self.bindings.contains(name);
            try self.bindings.put(name, value);
            if (is_new) {
                try self.binding_order.append(self.allocator, name);
            }
        }
    }

    pub fn setLocal(self: *Environment, name: []const u8, value: Value) !void {
        // Always set in the current scope, never delegate to parent
        const is_new = !self.bindings.contains(name);
        try self.bindings.put(name, value);
        if (is_new) {
            try self.binding_order.append(self.allocator, name);
        }
    }

    pub fn get(self: *Environment, name: []const u8) ?Value {
        if (self.bindings.get(name)) |val| {
            return val;
        }
        if (self.parent) |parent| {
            return parent.get(name);
        }
        return null;
    }

    pub fn setFn(self: *Environment, name: []const u8, fn_value: FnValue) !void {
        try self.functions.put(name, fn_value);
    }

    pub fn getFn(self: *Environment, name: []const u8) ?FnValue {
        if (self.functions.get(name)) |fn_val| {
            return fn_val;
        }
        if (self.parent) |parent| {
            return parent.getFn(name);
        }
        return null;
    }

    pub fn setBuiltin(self: *Environment, name: []const u8, builtin: BuiltinFn) !void {
        try self.builtins.put(name, builtin);
    }

    pub fn getBuiltin(self: *Environment, name: []const u8) ?BuiltinFn {
        if (self.builtins.get(name)) |builtin| {
            return builtin;
        }
        if (self.parent) |parent| {
            return parent.getBuiltin(name);
        }
        return null;
    }

    pub fn getMethod(self: *Environment, struct_name: []const u8, method_name: []const u8) ?MethodValue {
        // First check regular struct methods
        if (self.struct_methods.get(struct_name)) |struct_methods| {
            if (struct_methods.methods.get(method_name)) |method| {
                return method;
            }
        }

        // Then check generic struct methods
        if (self.generic_structs.get(struct_name)) |generic_struct| {
            for (generic_struct.methods) |method| {
                if (std.mem.eql(u8, method.name, method_name)) {
                    return MethodValue{
                        .parameters = method.parameters,
                        .body = method.body,
                    };
                }
            }
        }

        if (self.parent) |parent| {
            return parent.getMethod(struct_name, method_name);
        }
        return null;
    }
};

pub fn evalStmt(stmt: *const Stmt, env: *Environment) error{ UndefinedVariable, OutOfMemory, EarlyReturn, TypeError, IndexOutOfBounds, InvalidArguments }!void {
    switch (stmt.*) {
        .const_decl, .let_decl => |decl| {
            const value = try evalExpr(decl.value, env);
            try env.set(decl.name, value);
        },
        .type_alias => {
            // Type aliases are handled at compile time, no runtime action needed
        },
        .import_stmt => {
            // Module imports are handled at a higher level (in main.zig)
            // The actual module statements will be executed individually
        },
        .fn_decl => |decl| {
            // Check if generic
            if (decl.type_params.len > 0) {
                try env.generic_functions.put(decl.name, .{
                    .type_params = decl.type_params,
                    .parameters = decl.parameters,
                    .body = decl.body,
                });
            } else {
                try env.setFn(decl.name, .{
                    .parameters = decl.parameters,
                    .body = decl.body,
                });
            }
        },
        .struct_decl => |decl| {
            // Check if generic
            if (decl.type_params.len > 0) {
                try env.generic_structs.put(decl.name, .{
                    .type_params = decl.type_params,
                    .fields = decl.fields,
                    .methods = decl.methods,
                });
            } else {
                // Store methods for this struct
                var methods = std.StringHashMap(MethodValue).init(env.allocator);
                for (decl.methods) |method| {
                    try methods.put(method.name, .{
                        .parameters = method.parameters,
                        .body = method.body,
                    });
                }
                try env.struct_methods.put(decl.name, .{ .methods = methods });
            }
        },
        .return_stmt => |expr| {
            // Evaluate the return expression and store it
            const value = try evalExpr(expr, env);
            return_value = value;
            return error.EarlyReturn;
        },
        .expr_stmt => |expr| {
            _ = try evalExpr(expr, env);
        },
    }
}

pub fn evalExpr(expr: *const Expr, env: *Environment) error{ UndefinedVariable, OutOfMemory, EarlyReturn, TypeError, IndexOutOfBounds, InvalidArguments }!Value {
    switch (expr.*) {
        .int_literal => |val| return Value{ .int = val },
        .float_literal => |val| return Value{ .float = val },
        .string_literal => |val| return Value{ .string = val },
        .bool_literal => |val| return Value{ .bool = val },
        .null_literal => return Value{ .null_value = {} },
        .variable => |name| {
            if (env.get(name)) |val| {
                return val;
            }
            std.debug.print("Undefined variable: {s}\n", .{name});
            return error.UndefinedVariable;
        },
        .unary => |un| {
            const operand = try evalExpr(un.operand, env);

            switch (un.op) {
                .logical_not => {
                    return Value{ .bool = !operand.bool };
                },
                .negate => {
                    if (operand == .int) {
                        return Value{ .int = -operand.int };
                    } else {
                        return Value{ .float = -operand.float };
                    }
                },
            }
        },
        .binary => |bin| {
            const left = try evalExpr(bin.left, env);
            const right = try evalExpr(bin.right, env);

            switch (bin.op) {
                .add => {
                    // String concatenation
                    if (left == .string and right == .string) {
                        const result = try std.mem.concat(env.allocator, u8, &[_][]const u8{ left.string, right.string });
                        return Value{ .string = result };
                    }

                    // Handle int operations
                    if (left == .int and right == .int) {
                        return Value{ .int = left.int + right.int };
                    }

                    // Handle float operations (coerce int to float)
                    const left_f = if (left == .float) left.float else @as(f64, @floatFromInt(left.int));
                    const right_f = if (right == .float) right.float else @as(f64, @floatFromInt(right.int));
                    return Value{ .float = left_f + right_f };
                },
                .sub, .mul, .div, .mod, .pow => {
                    // Handle int operations
                    if (left == .int and right == .int) {
                        const result = switch (bin.op) {
                            .sub => left.int - right.int,
                            .mul => left.int * right.int,
                            .div => @divTrunc(left.int, right.int),
                            .mod => @mod(left.int, right.int),
                            .pow => std.math.pow(i64, left.int, @intCast(right.int)),
                            else => unreachable,
                        };
                        return Value{ .int = result };
                    }

                    // Handle float operations (coerce int to float)
                    const left_f = if (left == .float) left.float else @as(f64, @floatFromInt(left.int));
                    const right_f = if (right == .float) right.float else @as(f64, @floatFromInt(right.int));

                    const result = switch (bin.op) {
                        .sub => left_f - right_f,
                        .mul => left_f * right_f,
                        .div => left_f / right_f,
                        .mod => @mod(left_f, right_f),
                        .pow => std.math.pow(f64, left_f, right_f),
                        else => unreachable,
                    };
                    return Value{ .float = result };
                },
                .equal => {
                    // Handle null comparisons first
                    if (left == .null_value or right == .null_value) {
                        return Value{ .bool = (left == .null_value and right == .null_value) };
                    }
                    const result = switch (left) {
                        .int => |l| right == .int and l == right.int,
                        .float => |l| right == .float and l == right.float,
                        .string => |l| right == .string and std.mem.eql(u8, l, right.string),
                        .bool => |l| right == .bool and l == right.bool,
                        .unit => right == .unit,
                        .null_value => unreachable, // Already handled
                        .struct_instance => false, // Struct equality not implemented
                        .array => false, // Array equality not implemented
                    };
                    return Value{ .bool = result };
                },
                .not_equal => {
                    // Handle null comparisons first
                    if (left == .null_value or right == .null_value) {
                        return Value{ .bool = !(left == .null_value and right == .null_value) };
                    }
                    const result = switch (left) {
                        .int => |l| right != .int or l != right.int,
                        .float => |l| right != .float or l != right.float,
                        .string => |l| right != .string or !std.mem.eql(u8, l, right.string),
                        .bool => |l| right != .bool or l != right.bool,
                        .unit => right != .unit,
                        .null_value => unreachable, // Already handled
                        .struct_instance => true, // Struct equality not implemented
                        .array => true, // Array equality not implemented
                    };
                    return Value{ .bool = result };
                },
                .less => {
                    if (left == .int and right == .int) {
                        return Value{ .bool = left.int < right.int };
                    }
                    const left_f = if (left == .float) left.float else @as(f64, @floatFromInt(left.int));
                    const right_f = if (right == .float) right.float else @as(f64, @floatFromInt(right.int));
                    return Value{ .bool = left_f < right_f };
                },
                .less_equal => {
                    if (left == .int and right == .int) {
                        return Value{ .bool = left.int <= right.int };
                    }
                    const left_f = if (left == .float) left.float else @as(f64, @floatFromInt(left.int));
                    const right_f = if (right == .float) right.float else @as(f64, @floatFromInt(right.int));
                    return Value{ .bool = left_f <= right_f };
                },
                .greater => {
                    if (left == .int and right == .int) {
                        return Value{ .bool = left.int > right.int };
                    }
                    const left_f = if (left == .float) left.float else @as(f64, @floatFromInt(left.int));
                    const right_f = if (right == .float) right.float else @as(f64, @floatFromInt(right.int));
                    return Value{ .bool = left_f > right_f };
                },
                .greater_equal => {
                    if (left == .int and right == .int) {
                        return Value{ .bool = left.int >= right.int };
                    }
                    const left_f = if (left == .float) left.float else @as(f64, @floatFromInt(left.int));
                    const right_f = if (right == .float) right.float else @as(f64, @floatFromInt(right.int));
                    return Value{ .bool = left_f >= right_f };
                },
                .logical_and => {
                    return Value{ .bool = left.bool and right.bool };
                },
                .logical_or => {
                    return Value{ .bool = left.bool or right.bool };
                },
            }
        },
        .block => |blk| {
            var scoped_env = Environment.initScoped(env.allocator, env);
            defer scoped_env.deinit();

            for (blk.statements) |stmt| {
                try evalStmt(&stmt, &scoped_env);
            }

            if (blk.return_expr) |ret_expr| {
                return try evalExpr(ret_expr, &scoped_env);
            } else {
                return Value{ .unit = {} };
            }
        },
        .if_expr => |if_expr| {
            const condition = try evalExpr(if_expr.condition, env);

            if (condition.bool) {
                return try evalExpr(if_expr.then_block, env);
            } else if (if_expr.else_block) |else_block| {
                return try evalExpr(else_block, env);
            } else {
                return Value{ .unit = {} };
            }
        },
        .while_expr => |while_expr| {
            while (true) {
                const condition = try evalExpr(while_expr.condition, env);
                if (!condition.bool) {
                    break;
                }
                _ = try evalExpr(while_expr.body, env);
            }
            return Value{ .unit = {} };
        },
        .assignment => |assign| {
            const value = try evalExpr(assign.value, env);
            try env.set(assign.name, value);
            return Value{ .unit = {} };
        },
        .fn_call => |call| {
            // Check for builtin functions first
            if (env.getBuiltin(call.name)) |builtin| {
                // Evaluate arguments
                var args = try std.ArrayList(Value).initCapacity(env.allocator, call.arguments.len);
                defer args.deinit(env.allocator);
                for (call.arguments) |arg_expr| {
                    const arg_value = try evalExpr(arg_expr, env);
                    try args.append(env.allocator, arg_value);
                }
                // Call builtin
                return try builtin(env.allocator, args.items);
            }

            // Generic functions: Type checking already validated types,
            // so we can execute generic functions just like regular ones
            // by looking them up in either functions or generic_functions

            // Try regular function first
            var fn_value_opt = env.getFn(call.name);
            var is_generic = false;

            // If not found, try generic function template
            if (fn_value_opt == null and call.type_args.len > 0) {
                if (env.generic_functions.get(call.name)) |template| {
                    // For execution, we treat generic functions as regular functions
                    // Type substitution was already done at type-check time
                    fn_value_opt = FnValue{
                        .parameters = template.parameters,
                        .body = template.body,
                    };
                    is_generic = true;
                }
            }

            const fn_value = fn_value_opt orelse {
                std.debug.print("Runtime error: Undefined function '{s}'\n", .{call.name});
                return error.UndefinedVariable;
            };

            // Create new environment for function execution
            var fn_env = Environment.initScoped(env.allocator, env);
            defer fn_env.deinit();

            // Bind parameters to arguments
            for (fn_value.parameters, 0..) |param, i| {
                const arg_value = try evalExpr(call.arguments[i], env);
                try fn_env.setLocal(param.name, arg_value);
            }

            // Execute function body - catch early return
            if (evalExpr(fn_value.body, &fn_env)) |result| {
                return result;
            } else |err| {
                if (err == error.EarlyReturn) {
                    // Return the stored return value
                    const ret_val = return_value.?;
                    return_value = null; // Clear for next use
                    return ret_val;
                } else {
                    return err;
                }
            }
        },
        .struct_init => |init| {
            // Generic structs: Type checking already validated types and fields,
            // so we can execute generic struct initialization just like regular ones

            // Create a new struct instance
            var fields = std.StringHashMap(Value).init(env.allocator);

            for (init.fields) |field_init| {
                const field_value = try evalExpr(field_init.value, env);
                try fields.put(field_init.name, field_value);
            }

            // For generic instances, we store the full type information
            // but at runtime we just need the type name for method lookup
            return Value{ .struct_instance = .{
                .type_name = init.type_name,
                .fields = fields,
            } };
        },
        .field_access => |access| {
            const object_value = try evalExpr(access.object, env);

            if (object_value != .struct_instance) {
                std.debug.print("Runtime error: Cannot access field on non-struct value\n", .{});
                return error.UndefinedVariable;
            }

            const field_value = object_value.struct_instance.fields.get(access.field_name) orelse {
                std.debug.print("Runtime error: Struct has no field '{s}'\n", .{access.field_name});
                return error.UndefinedVariable;
            };

            return field_value;
        },
        .method_call => |call| {
            // Evaluate the receiver
            const receiver_value = try evalExpr(call.receiver, env);

            if (receiver_value != .struct_instance) {
                std.debug.print("Runtime error: Cannot call method on non-struct value\n", .{});
                return error.UndefinedVariable;
            }

            const struct_name = receiver_value.struct_instance.type_name;

            // Look up the method
            const method = env.getMethod(struct_name, call.method_name) orelse {
                std.debug.print("Runtime error: Struct '{s}' has no method '{s}'\n", .{ struct_name, call.method_name });
                return error.UndefinedVariable;
            };

            // Create a new environment for method execution
            var method_env = Environment.initScoped(env.allocator, env);
            defer method_env.deinit();

            // Bind 'self' parameter to the receiver value
            try method_env.setLocal(method.parameters[0].name, receiver_value);

            // Evaluate and bind remaining arguments
            for (call.arguments, 0..) |arg, i| {
                const arg_value = try evalExpr(arg, env);
                try method_env.setLocal(method.parameters[i + 1].name, arg_value); // +1 to skip 'self'
            }

            // Execute method body
            const saved_return_value = return_value;
            return_value = null;

            const result = evalExpr(method.body, &method_env) catch |err| {
                if (err == error.EarlyReturn) {
                    const ret_val = return_value orelse Value{ .unit = {} };
                    return_value = saved_return_value;
                    return ret_val;
                }
                return err;
            };

            // Restore previous return value context
            return_value = saved_return_value;
            return result;
        },
        .array_literal => |literal| {
            // Evaluate each element
            var elements = try env.allocator.alloc(Value, literal.elements.len);

            for (literal.elements, 0..) |elem_expr, i| {
                elements[i] = try evalExpr(elem_expr, env);
            }

            return Value{ .array = elements };
        },
        .array_access => |access| {
            // Evaluate the array and index
            const array_value = try evalExpr(access.array, env);
            const index_value = try evalExpr(access.index, env);

            if (array_value != .array) {
                std.debug.print("Runtime error: Cannot index non-array value\n", .{});
                return error.TypeError;
            }

            if (index_value != .int) {
                std.debug.print("Runtime error: Array index must be an integer\n", .{});
                return error.TypeError;
            }

            const index = index_value.int;
            const array = array_value.array;

            // Bounds checking
            if (index < 0 or index >= array.len) {
                std.debug.print("Runtime error: Array index {d} out of bounds (array length: {d})\n", .{ index, array.len });
                return error.IndexOutOfBounds;
            }

            return array[@intCast(index)];
        },
        .is_check => |check| {
            // Evaluate the expression
            const value = try evalExpr(check.expr, env);

            // Check the runtime type against the expected type
            const matches = switch (check.check_type) {
                .int => value == .int,
                .float => value == .float,
                .string => value == .string,
                .bool => value == .bool,
                .unit => value == .unit,
                .user_type => |type_name| blk: {
                    if (value == .struct_instance) {
                        break :blk std.mem.eql(u8, value.struct_instance.type_name, type_name);
                    } else {
                        break :blk false;
                    }
                },
                // For complex types, we can't do perfect runtime checking without more info
                // For now, just return false for complex types
                else => false,
            };

            // Apply "is not" if needed
            const result = if (check.is_not) !matches else matches;
            return Value{ .bool = result };
        },
    }
}

// ============================================================================
// Builtin Functions
// ============================================================================

// Print a value to stdout
fn builtin_print(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;

    switch (args[0]) {
        .int => |val| std.debug.print("{d}", .{val}),
        .float => |val| std.debug.print("{d}", .{val}),
        .string => |val| std.debug.print("{s}", .{val}),
        .bool => |val| std.debug.print("{}", .{val}),
        .unit => std.debug.print("()", .{}),
        .null_value => std.debug.print("null", .{}),
        .struct_instance => |instance| {
            std.debug.print("{s} {{", .{instance.type_name});
            var it = instance.fields.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) std.debug.print(", ", .{});
                first = false;
                std.debug.print("{s}: ", .{entry.key_ptr.*});
                // Recursive print would be better, but this works for now
                switch (entry.value_ptr.*) {
                    .int => |v| std.debug.print("{d}", .{v}),
                    .float => |v| std.debug.print("{d}", .{v}),
                    .string => |v| std.debug.print("\"{s}\"", .{v}),
                    .bool => |v| std.debug.print("{}", .{v}),
                    else => std.debug.print("...", .{}),
                }
            }
            std.debug.print("}}", .{});
        },
        .array => |elements| {
            std.debug.print("[", .{});
            for (elements, 0..) |elem, i| {
                if (i > 0) std.debug.print(", ", .{});
                switch (elem) {
                    .int => |v| std.debug.print("{d}", .{v}),
                    .float => |v| std.debug.print("{d}", .{v}),
                    .string => |v| std.debug.print("\"{s}\"", .{v}),
                    .bool => |v| std.debug.print("{}", .{v}),
                    else => std.debug.print("...", .{}),
                }
            }
            std.debug.print("]", .{});
        },
    }
    return Value{ .unit = {} };
}

// Print a value to stdout with newline
fn builtin_println(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = try builtin_print(allocator, args);
    std.debug.print("\n", .{});
    return Value{ .unit = {} };
}

// Get string length
fn builtin_str_len(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .string) return error.TypeError;

    const len: i64 = @intCast(args[0].string.len);
    return Value{ .int = len };
}

// Concatenate two strings
fn builtin_str_concat(allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 2) return error.InvalidArguments;
    if (args[0] != .string or args[1] != .string) return error.TypeError;

    const result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ args[0].string, args[1].string });
    return Value{ .string = result };
}

// Get substring
fn builtin_str_substring(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 3) return error.InvalidArguments;
    if (args[0] != .string or args[1] != .int or args[2] != .int) return error.TypeError;

    const str = args[0].string;
    const start: usize = @intCast(args[1].int);
    const end: usize = @intCast(args[2].int);

    if (start > str.len or end > str.len or start > end) {
        return error.IndexOutOfBounds;
    }

    return Value{ .string = str[start..end] };
}

// Absolute value
fn builtin_abs(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;

    switch (args[0]) {
        .int => |val| return Value{ .int = if (val < 0) -val else val },
        .float => |val| return Value{ .float = if (val < 0) -val else val },
        else => return error.TypeError,
    }
}

// Minimum of two numbers
fn builtin_min(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 2) return error.InvalidArguments;

    if (args[0] == .int and args[1] == .int) {
        return Value{ .int = @min(args[0].int, args[1].int) };
    } else if (args[0] == .float and args[1] == .float) {
        return Value{ .float = @min(args[0].float, args[1].float) };
    } else {
        return error.TypeError;
    }
}

// Maximum of two numbers
fn builtin_max(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 2) return error.InvalidArguments;

    if (args[0] == .int and args[1] == .int) {
        return Value{ .int = @max(args[0].int, args[1].int) };
    } else if (args[0] == .float and args[1] == .float) {
        return Value{ .float = @max(args[0].float, args[1].float) };
    } else {
        return error.TypeError;
    }
}

// Square root
fn builtin_sqrt(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .float) return error.TypeError;

    return Value{ .float = @sqrt(args[0].float) };
}

// Floor function
fn builtin_floor(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .float) return error.TypeError;

    return Value{ .float = @floor(args[0].float) };
}

// Ceiling function
fn builtin_ceil(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .float) return error.TypeError;

    return Value{ .float = @ceil(args[0].float) };
}

// Convert int to string
fn builtin_int_to_str(allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .int) return error.TypeError;

    const result = try std.fmt.allocPrint(allocator, "{d}", .{args[0].int});
    return Value{ .string = result };
}

// Convert float to string
fn builtin_float_to_str(allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .float) return error.TypeError;

    const result = try std.fmt.allocPrint(allocator, "{d}", .{args[0].float});
    return Value{ .string = result };
}

// Register all builtin functions
pub fn registerBuiltins(env: *Environment) !void {
    try env.setBuiltin("print", builtin_print);
    try env.setBuiltin("println", builtin_println);
    try env.setBuiltin("str_len", builtin_str_len);
    try env.setBuiltin("str_concat", builtin_str_concat);
    try env.setBuiltin("str_substring", builtin_str_substring);
    try env.setBuiltin("abs", builtin_abs);
    try env.setBuiltin("min", builtin_min);
    try env.setBuiltin("max", builtin_max);
    try env.setBuiltin("sqrt", builtin_sqrt);
    try env.setBuiltin("floor", builtin_floor);
    try env.setBuiltin("ceil", builtin_ceil);
    try env.setBuiltin("int_to_str", builtin_int_to_str);
    try env.setBuiltin("float_to_str", builtin_float_to_str);
}
