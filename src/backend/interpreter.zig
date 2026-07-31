const std = @import("std");
const Expr = @import("../frontend/ast.zig").Expr;
const Stmt = @import("../frontend/ast.zig").Stmt;
const Value = @import("../frontend/ast.zig").Value;
const Type = @import("../frontend/ast.zig").Type;
const checked_int = @import("checked_int.zig");

// Builtin function signature
pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []Value) error{ UndefinedVariable, OutOfMemory, EarlyReturn, BreakLoop, ContinueLoop, TypeError, IndexOutOfBounds, InvalidArguments }!Value;

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
    function_scope: bool,
    return_value: ?Value,

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(Value).init(allocator),
            .binding_order = std.ArrayList([]const u8).initCapacity(allocator, 8) catch unreachable,
            .functions = std.StringHashMap(FnValue).init(allocator),
            .builtins = std.StringHashMap(BuiltinFn).init(allocator),
            .generic_functions = std.StringHashMap(GenericFnTemplate).init(allocator),
            .struct_methods = std.StringHashMap(StructMethods).init(allocator),
            .generic_structs = std.StringHashMap(GenericStructTemplate).init(allocator),
            .parent = null,
            .function_scope = false,
            .return_value = null,
        };
    }

    pub fn initScoped(allocator: std.mem.Allocator, parent: *Environment) Environment {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(Value).init(allocator),
            .binding_order = std.ArrayList([]const u8).initCapacity(allocator, 8) catch unreachable,
            .functions = std.StringHashMap(FnValue).init(allocator),
            .builtins = std.StringHashMap(BuiltinFn).init(allocator),
            .generic_functions = std.StringHashMap(GenericFnTemplate).init(allocator),
            .struct_methods = std.StringHashMap(StructMethods).init(allocator),
            .generic_structs = std.StringHashMap(GenericStructTemplate).init(allocator),
            .parent = parent,
            .function_scope = false,
            .return_value = null,
        };
    }

    pub fn initFunctionScoped(allocator: std.mem.Allocator, parent: *Environment) Environment {
        var environment = initScoped(allocator, parent);
        environment.function_scope = true;
        return environment;
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

    pub fn setReturnValue(self: *Environment, value: Value) !void {
        if (self.function_scope) {
            self.return_value = value;
            return;
        }
        if (self.parent) |parent| return parent.setReturnValue(value);
        return error.EarlyReturn;
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

pub fn evalStmt(stmt: *const Stmt, env: *Environment) error{ UndefinedVariable, OutOfMemory, EarlyReturn, BreakLoop, ContinueLoop, TypeError, IndexOutOfBounds, InvalidArguments, IntegerOverflow, DivisionByZero, NegativeExponent }!void {
    switch (stmt.*) {
        .const_decl, .let_decl => |decl| {
            const value = try evalExpr(decl.value, env);
            try env.setLocal(decl.name, value);
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
        .return_stmt => |maybe_expr| {
            // Evaluate the return expression and store it
            const value = if (maybe_expr) |expr|
                try evalExpr(expr, env)
            else
                Value{ .unit = {} };
            try env.setReturnValue(value);
            return error.EarlyReturn;
        },
        .break_stmt => return error.BreakLoop,
        .continue_stmt => return error.ContinueLoop,
        .expr_stmt => |expr| {
            _ = try evalExpr(expr, env);
        },
    }
}

pub fn evalExpr(expr: *const Expr, env: *Environment) error{ UndefinedVariable, OutOfMemory, EarlyReturn, BreakLoop, ContinueLoop, TypeError, IndexOutOfBounds, InvalidArguments, IntegerOverflow, DivisionByZero, NegativeExponent }!Value {
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
                        return Value{ .int = try checked_int.neg(operand.int) };
                    } else {
                        return Value{ .float = -operand.float };
                    }
                },
            }
        },
        .optional_unwrap => |optional_expr| {
            const value = try evalExpr(optional_expr, env);
            if (value == .null_value) {
                std.debug.print("Runtime error: Cannot unwrap null\n", .{});
                return error.TypeError;
            }
            return value;
        },
        .optional_coalesce => |coalesce| {
            const value = try evalExpr(coalesce.optional, env);
            if (value != .null_value) return value;
            return try evalExpr(coalesce.fallback, env);
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
                        return Value{ .int = try checked_int.add(left.int, right.int) };
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
                            .sub => try checked_int.sub(left.int, right.int),
                            .mul => try checked_int.mul(left.int, right.int),
                            .div => try checked_int.div(left.int, right.int),
                            .mod => try checked_int.mod(left.int, right.int),
                            .pow => try checked_int.pow(left.int, right.int),
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
                    return Value{ .bool = valuesEqual(left, right) };
                },
                .not_equal => {
                    return Value{ .bool = !valuesEqual(left, right) };
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
                _ = evalExpr(while_expr.body, env) catch |err| switch (err) {
                    error.BreakLoop => break,
                    error.ContinueLoop => continue,
                    else => return err,
                };
            }
            return Value{ .unit = {} };
        },
        .for_expr => |for_expr| {
            // Evaluate the iterable
            const iterable_value = try evalExpr(for_expr.iterable, env);

            // Create scoped environment for loop
            var scoped_env = Environment.initScoped(env.allocator, env);
            defer scoped_env.deinit();

            if (for_expr.is_range) {
                // Range-based for loop (start..end or start..=end)
                if (iterable_value != .int) {
                    std.debug.print("Runtime error: Range for loop start must be int\n", .{});
                    return error.TypeError;
                }

                const end_expr = for_expr.range_end orelse {
                    std.debug.print("Runtime error: Range for loop missing end expression\n", .{});
                    return error.TypeError;
                };

                const end_value = try evalExpr(end_expr, env);
                if (end_value != .int) {
                    std.debug.print("Runtime error: Range for loop end must be int\n", .{});
                    return error.TypeError;
                }

                const start = iterable_value.int;
                const end = end_value.int;
                var i = start;

                if (start <= end) {
                    if (for_expr.range_inclusive) {
                        while (i <= end) {
                            try scoped_env.setLocal(for_expr.iterator, Value{ .int = i });
                            var break_loop = false;
                            _ = evalExpr(for_expr.body, &scoped_env) catch |err| switch (err) {
                                error.BreakLoop => blk: {
                                    break_loop = true;
                                    break :blk Value{ .unit = {} };
                                },
                                error.ContinueLoop => Value{ .unit = {} },
                                else => return err,
                            };
                            if (break_loop or i == end) break;
                            i = try checked_int.add(i, 1);
                        }
                    } else {
                        while (i < end) {
                            try scoped_env.setLocal(for_expr.iterator, Value{ .int = i });
                            _ = evalExpr(for_expr.body, &scoped_env) catch |err| switch (err) {
                                error.BreakLoop => break,
                                error.ContinueLoop => Value{ .unit = {} },
                                else => return err,
                            };
                            i = try checked_int.add(i, 1);
                        }
                    }
                } else {
                    if (for_expr.range_inclusive) {
                        while (i >= end) {
                            try scoped_env.setLocal(for_expr.iterator, Value{ .int = i });
                            var break_loop = false;
                            _ = evalExpr(for_expr.body, &scoped_env) catch |err| switch (err) {
                                error.BreakLoop => blk: {
                                    break_loop = true;
                                    break :blk Value{ .unit = {} };
                                },
                                error.ContinueLoop => Value{ .unit = {} },
                                else => return err,
                            };
                            if (break_loop or i == end) break;
                            i = try checked_int.sub(i, 1);
                        }
                    } else {
                        while (i > end) {
                            try scoped_env.setLocal(for_expr.iterator, Value{ .int = i });
                            _ = evalExpr(for_expr.body, &scoped_env) catch |err| switch (err) {
                                error.BreakLoop => break,
                                error.ContinueLoop => Value{ .unit = {} },
                                else => return err,
                            };
                            i = try checked_int.sub(i, 1);
                        }
                    }
                }
            } else {
                // Array-based for loop
                if (iterable_value != .array) return error.TypeError;
                const array = iterable_value.array.elements;

                for (array) |item| {
                    try scoped_env.setLocal(for_expr.iterator, item);
                    _ = evalExpr(for_expr.body, &scoped_env) catch |err| switch (err) {
                        error.BreakLoop => break,
                        error.ContinueLoop => continue,
                        else => return err,
                    };
                }
            }

            return Value{ .unit = {} };
        },
        .match_expr => |match_expr| {
            const match_value = try evalExpr(match_expr.expr, env);

            // Try each arm until one matches
            for (match_expr.arms) |arm| {
                const matches = try matchPattern(arm.pattern, match_value);
                if (matches) {
                    // Create scoped environment for pattern variables
                    var scoped_env = Environment.initScoped(env.allocator, env);
                    defer scoped_env.deinit();

                    // Bind pattern variables if needed
                    if (arm.pattern == .variable) {
                        try scoped_env.setLocal(arm.pattern.variable, match_value);
                    }

                    return try evalExpr(arm.body, &scoped_env);
                }
            }

            // No pattern matched - this should be caught by type checker
            std.debug.print("No pattern matched in match expression\n", .{});
            return error.TypeError;
        },
        .assignment => |assign| {
            const value = try evalExpr(assign.value, env);
            try env.set(assign.name, value);
            return Value{ .unit = {} };
        },
        .field_assignment => |assign| {
            const object_value = try evalExpr(assign.object, env);
            const new_value = try evalExpr(assign.value, env);

            if (object_value != .struct_instance) {
                std.debug.print("Cannot assign field on non-struct value\n", .{});
                return error.TypeError;
            }

            // Note: This modifies the struct in place, which works because
            // struct_instance contains a HashMap that we can mutate
            var fields = object_value.struct_instance.fields;
            try fields.put(assign.field_name, new_value);
            return Value{ .unit = {} };
        },
        .array_assignment => |assign| {
            const array_value = try evalExpr(assign.array, env);
            const index_value = try evalExpr(assign.index, env);
            const new_value = try evalExpr(assign.value, env);

            if (array_value != .array) {
                std.debug.print("Cannot index non-array value\n", .{});
                return error.TypeError;
            }

            if (index_value != .int) {
                std.debug.print("Array index must be an integer\n", .{});
                return error.TypeError;
            }

            if (index_value.int < 0 or index_value.int >= array_value.array.elements.len) {
                return error.IndexOutOfBounds;
            }

            // Modify the array element
            const index: usize = @intCast(index_value.int);
            array_value.array.elements[index] = new_value;
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
            var fn_env = Environment.initFunctionScoped(env.allocator, env);
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
                    return fn_env.return_value orelse Value{ .unit = {} };
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
                .type_args = init.type_args,
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
            var method_env = Environment.initFunctionScoped(env.allocator, env);
            defer method_env.deinit();

            // Bind 'self' parameter to the receiver value
            try method_env.setLocal(method.parameters[0].name, receiver_value);

            // Evaluate and bind remaining arguments
            for (call.arguments, 0..) |arg, i| {
                const arg_value = try evalExpr(arg, env);
                try method_env.setLocal(method.parameters[i + 1].name, arg_value); // +1 to skip 'self'
            }

            // Execute method body
            const result = evalExpr(method.body, &method_env) catch |err| {
                if (err == error.EarlyReturn) {
                    return method_env.return_value orelse Value{ .unit = {} };
                }
                return err;
            };
            return result;
        },
        .array_literal => |literal| {
            // Evaluate each element
            var elements = try env.allocator.alloc(Value, literal.elements.len);

            for (literal.elements, 0..) |elem_expr, i| {
                elements[i] = try evalExpr(elem_expr, env);
            }

            return Value{ .array = .{
                .elements = elements,
                .element_type = literal.resolved_element_type.*,
            } };
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
            const array = array_value.array.elements;

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
            const matches = check.static_result.* orelse switch (check.resolved_type.* orelse check.check_type) {
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
                .generic_instance => |expected| blk: {
                    if (value != .struct_instance or
                        !std.mem.eql(u8, value.struct_instance.type_name, expected.base_type) or
                        value.struct_instance.type_args.len != expected.type_args.len)
                    {
                        break :blk false;
                    }
                    for (value.struct_instance.type_args, expected.type_args) |actual_arg, expected_arg| {
                        if (!actual_arg.eql(expected_arg)) break :blk false;
                    }
                    break :blk true;
                },
                .array => |expected_element| blk: {
                    if (value != .array) break :blk false;
                    if (value.array.element_type) |actual_element| {
                        break :blk actual_element.eql(expected_element.*);
                    }
                    const source_type = check.resolved_source_type.* orelse break :blk false;
                    break :blk sourceMatchesArrayType(source_type, expected_element.*);
                },
                else => false,
            };

            // Apply "is not" if needed
            const result = if (check.is_not) !matches else matches;
            return Value{ .bool = result };
        },
    }
}

fn sourceMatchesArrayType(source_type: Type, expected_element: Type) bool {
    return switch (source_type) {
        .array => |actual_element| actual_element.eql(expected_element),
        .optional => |inner| sourceMatchesArrayType(inner.*, expected_element),
        .union_type => |members| blk: {
            var array_count: usize = 0;
            var matches = false;
            for (members) |member| {
                if (member == .array) {
                    array_count += 1;
                    if (member.array.eql(expected_element)) matches = true;
                }
            }
            break :blk array_count == 1 and matches;
        },
        else => false,
    };
}

fn valuesEqual(left: Value, right: Value) bool {
    return switch (left) {
        .int => |value| right == .int and value == right.int,
        .float => |value| right == .float and value == right.float,
        .string => |value| right == .string and std.mem.eql(u8, value, right.string),
        .bool => |value| right == .bool and value == right.bool,
        .unit => right == .unit,
        .null_value => right == .null_value,
        .array => |array_value| blk: {
            if (right != .array or array_value.elements.len != right.array.elements.len) break :blk false;
            for (array_value.elements, right.array.elements) |left_item, right_item| {
                if (!valuesEqual(left_item, right_item)) break :blk false;
            }
            break :blk true;
        },
        .struct_instance => |instance| blk: {
            if (right != .struct_instance or
                !std.mem.eql(u8, instance.type_name, right.struct_instance.type_name) or
                instance.type_args.len != right.struct_instance.type_args.len or
                instance.fields.count() != right.struct_instance.fields.count())
            {
                break :blk false;
            }
            for (instance.type_args, right.struct_instance.type_args) |left_arg, right_arg| {
                if (!left_arg.eql(right_arg)) break :blk false;
            }
            var fields = instance.fields.iterator();
            while (fields.next()) |entry| {
                const right_value = right.struct_instance.fields.get(entry.key_ptr.*) orelse break :blk false;
                if (!valuesEqual(entry.value_ptr.*, right_value)) break :blk false;
            }
            break :blk true;
        },
    };
}

// ============================================================================
// Pattern Matching Helper
// ============================================================================

fn matchPattern(pattern: Expr.Pattern, value: Value) !bool {
    switch (pattern) {
        .wildcard => return true, // _ matches everything
        .variable => return true, // Variable binding matches everything
        .literal => |lit| {
            // Check if literal matches value
            return switch (lit) {
                .int => |i| value == .int and value.int == i,
                .float => |f| value == .float and value.float == f,
                .string => |s| value == .string and std.mem.eql(u8, value.string, s),
                .bool => |b| value == .bool and value.bool == b,
                .null_value => value == .null_value,
                .unit => value == .unit,
                else => false,
            };
        },
        .range => |range| {
            if (value != .int) return false;
            const v = value.int;
            if (range.inclusive) {
                return v >= range.start and v <= range.end;
            } else {
                return v >= range.start and v < range.end;
            }
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
                // Aggregate output is outside the typed print API; keep this
                // fallback compact for interpreter diagnostics.
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
        .array => |array_value| {
            std.debug.print("[", .{});
            for (array_value.elements, 0..) |elem, i| {
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
        .int => |val| {
            if (val == std.math.minInt(i64)) return error.InvalidArguments;
            return Value{ .int = if (val < 0) -val else val };
        },
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

// Get array length
fn builtin_array_len(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .array) return error.TypeError;

    const len: i64 = @intCast(args[0].array.elements.len);
    return Value{ .int = len };
}

// Push element to array (returns new array)
fn builtin_array_push(allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 2) return error.InvalidArguments;
    if (args[0] != .array) return error.TypeError;

    const old_array = args[0].array;
    var new_array = try allocator.alloc(Value, old_array.elements.len + 1);
    @memcpy(new_array[0..old_array.elements.len], old_array.elements);
    new_array[old_array.elements.len] = args[1];

    return Value{ .array = .{ .elements = new_array, .element_type = old_array.element_type } };
}

// Remove the final element and return the shortened array.
fn builtin_array_pop(allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .array) return error.TypeError;

    const old_array = args[0].array;
    if (old_array.elements.len == 0) return error.IndexOutOfBounds;

    const new_array = try allocator.alloc(Value, old_array.elements.len - 1);
    @memcpy(new_array, old_array.elements[0 .. old_array.elements.len - 1]);

    return Value{ .array = .{ .elements = new_array, .element_type = old_array.element_type } };
}

// Array slice
fn builtin_array_slice(allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 3) return error.InvalidArguments;
    if (args[0] != .array or args[1] != .int or args[2] != .int) return error.TypeError;

    const arr = args[0].array;
    const start_value = args[1].int;
    const end_value = args[2].int;
    if (start_value < 0 or end_value < start_value or end_value > arr.elements.len) {
        return error.IndexOutOfBounds;
    }
    const start: usize = @intCast(start_value);
    const end: usize = @intCast(end_value);

    const slice = try allocator.alloc(Value, end - start);
    @memcpy(slice, arr.elements[start..end]);

    return Value{ .array = .{ .elements = slice, .element_type = arr.element_type } };
}

// String split
fn builtin_str_split(allocator: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 2) return error.InvalidArguments;
    if (args[0] != .string or args[1] != .string) return error.TypeError;

    const str = args[0].string;
    const delimiter = args[1].string;

    var parts = std.ArrayList(Value).initCapacity(allocator, 4) catch unreachable;
    defer parts.deinit(allocator);

    var it = std.mem.splitSequence(u8, str, delimiter);
    while (it.next()) |part| {
        try parts.append(allocator, Value{ .string = part });
    }

    return Value{ .array = .{
        .elements = try parts.toOwnedSlice(allocator),
        .element_type = .string,
    } };
}

// String trim
fn builtin_str_trim(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .string) return error.TypeError;

    const trimmed = std.mem.trim(u8, args[0].string, &std.ascii.whitespace);
    return Value{ .string = trimmed };
}

// String contains
fn builtin_str_contains(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 2) return error.InvalidArguments;
    if (args[0] != .string or args[1] != .string) return error.TypeError;

    const contains = std.mem.indexOf(u8, args[0].string, args[1].string) != null;
    return Value{ .bool = contains };
}

// String to int conversion
fn builtin_str_to_int(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .string) return error.TypeError;

    const value = std.fmt.parseInt(i64, args[0].string, 10) catch return error.TypeError;
    return Value{ .int = value };
}

// String to float conversion
fn builtin_str_to_float(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .string) return error.TypeError;

    const value = std.fmt.parseFloat(f64, args[0].string) catch return error.TypeError;
    if (!std.math.isFinite(value)) return error.TypeError;
    return Value{ .float = value };
}

// Bool to string conversion
fn builtin_bool_to_str(_: std.mem.Allocator, args: []Value) !Value {
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .bool) return error.TypeError;

    const result = if (args[0].bool) "true" else "false";
    return Value{ .string = result };
}

// Int to float conversion
fn builtin_int_to_float(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .int) return error.TypeError;

    const value: f64 = @floatFromInt(args[0].int);
    return Value{ .float = value };
}

// Float to int conversion (truncate)
fn builtin_float_to_int(allocator: std.mem.Allocator, args: []Value) !Value {
    _ = allocator;
    if (args.len != 1) return error.InvalidArguments;
    if (args[0] != .float) return error.TypeError;

    const lower: f64 = @floatFromInt(std.math.minInt(i64));
    const upper = -lower;
    if (!std.math.isFinite(args[0].float) or args[0].float < lower or args[0].float >= upper) return error.TypeError;
    const value: i64 = @intFromFloat(args[0].float);
    return Value{ .int = value };
}

// Register all builtin functions
pub fn registerBuiltins(env: *Environment) !void {
    try env.setBuiltin("print", builtin_print);
    try env.setBuiltin("println", builtin_println);
    try env.setBuiltin("str_len", builtin_str_len);
    try env.setBuiltin("str_concat", builtin_str_concat);
    try env.setBuiltin("str_substring", builtin_str_substring);
    try env.setBuiltin("str_split", builtin_str_split);
    try env.setBuiltin("str_trim", builtin_str_trim);
    try env.setBuiltin("str_contains", builtin_str_contains);
    try env.setBuiltin("str_to_int", builtin_str_to_int);
    try env.setBuiltin("str_to_float", builtin_str_to_float);
    try env.setBuiltin("abs", builtin_abs);
    try env.setBuiltin("min", builtin_min);
    try env.setBuiltin("max", builtin_max);
    try env.setBuiltin("sqrt", builtin_sqrt);
    try env.setBuiltin("floor", builtin_floor);
    try env.setBuiltin("ceil", builtin_ceil);
    try env.setBuiltin("int_to_str", builtin_int_to_str);
    try env.setBuiltin("float_to_str", builtin_float_to_str);
    try env.setBuiltin("bool_to_str", builtin_bool_to_str);
    try env.setBuiltin("int_to_float", builtin_int_to_float);
    try env.setBuiltin("float_to_int", builtin_float_to_int);
    try env.setBuiltin("array_len", builtin_array_len);
    try env.setBuiltin("array_push", builtin_array_push);
    try env.setBuiltin("array_pop", builtin_array_pop);
    try env.setBuiltin("array_slice", builtin_array_slice);
}
