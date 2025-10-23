const std = @import("std");
const ir = @import("ir.zig");
const Instruction = ir.Instruction;
const Program = ir.Program;
const Opcode = ir.Opcode;

/// Value types in the IR interpreter
pub const Value = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    null_value,
    array: []Value,
    struct_val: []i64, // Struct as array of i64 values

    pub fn format(self: Value, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .bool => |v| try writer.print("{}", .{v}),
            .string => |v| try writer.print("{s}", .{v}),
            .null_value => try writer.print("null", .{}),
            .array => |arr| {
                try writer.print("[", .{});
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try item.format("", .{}, writer);
                }
                try writer.print("]", .{});
            },
            .struct_val => |fields| {
                try writer.print("struct{{{d} fields}}", .{fields.len});
            },
        }
    }
};

/// IR Interpreter - executes IR code directly
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    program: Program,
    stack: std.ArrayList(Value),
    variables: std.StringHashMap(Value),
    call_stack: std.ArrayList(CallFrame),
    verbose: bool,

    const CallFrame = struct {
        function_name: []const u8,
        return_address: usize,
        base_pointer: usize,
    };

    pub fn init(allocator: std.mem.Allocator, program: Program, verbose: bool) !Interpreter {
        return .{
            .allocator = allocator,
            .program = program,
            .stack = try std.ArrayList(Value).initCapacity(allocator, 256),
            .variables = std.StringHashMap(Value).init(allocator),
            .call_stack = try std.ArrayList(CallFrame).initCapacity(allocator, 64),
            .verbose = verbose,
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.stack.deinit(self.allocator);
        self.variables.deinit();
        self.call_stack.deinit(self.allocator);
    }

    /// Execute the program starting from entry point
    pub fn execute(self: *Interpreter) !void {
        // Find entry point function
        const entry_func = for (self.program.functions) |func| {
            if (std.mem.eql(u8, func.name, self.program.entry_point)) {
                break func;
            }
        } else {
            std.debug.print("Error: Entry point '{s}' not found\n", .{self.program.entry_point});
            return error.EntryPointNotFound;
        };

        if (self.verbose) {
            std.debug.print("=== Executing IR Program ===\n", .{});
            std.debug.print("Entry point: {s}\n\n", .{self.program.entry_point});
        }

        // Execute entry function
        try self.executeFunction(entry_func);

        if (self.verbose) {
            std.debug.print("\n=== Execution Complete ===\n", .{});
        }
    }

    /// Execute a single function
    fn executeFunction(self: *Interpreter, func: ir.Function) !void {
        if (self.verbose) {
            std.debug.print("Executing function: {s}\n", .{func.name});
        }

        var ip: usize = 0; // Instruction pointer

        while (ip < func.instructions.len) {
            const inst = func.instructions[ip];

            if (self.verbose) {
                std.debug.print("  [{d}] {s}", .{ ip, @tagName(inst.op) });
            }

            switch (inst.op) {
                .load_const_int => {
                    try self.stack.append(self.allocator, Value{ .int = inst.operand1 });
                    if (self.verbose) std.debug.print(" {d}\n", .{inst.operand1});
                },
                .load_const_float => {
                    const f: f64 = @bitCast(@as(u64, @intCast(inst.operand1)));
                    try self.stack.append(self.allocator, Value{ .float = f });
                    if (self.verbose) std.debug.print(" {d}\n", .{f});
                },
                .load_const_bool => {
                    try self.stack.append(self.allocator, Value{ .bool = inst.operand1 != 0 });
                    if (self.verbose) std.debug.print(" {}\n", .{inst.operand1 != 0});
                },
                .load_const_str => {
                    if (inst.string_data) |str| {
                        try self.stack.append(self.allocator, Value{ .string = str });
                        if (self.verbose) std.debug.print(" \"{s}\"\n", .{str});
                    }
                },
                .load_null => {
                    try self.stack.append(self.allocator, Value.null_value);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .load_var => {
                    if (inst.string_data) |var_name| {
                        if (self.variables.get(var_name)) |value| {
                            try self.stack.append(self.allocator, value);
                            if (self.verbose) std.debug.print(" {s}\n", .{var_name});
                        } else {
                            std.debug.print("\nError: Variable '{s}' not found\n", .{var_name});
                            return error.UndefinedVariable;
                        }
                    }
                },
                .store_var => {
                    if (inst.string_data) |var_name| {
                        const value = self.stack.pop() orelse return error.StackUnderflow;
                        try self.variables.put(var_name, value);
                        if (self.verbose) std.debug.print(" {s}\n", .{var_name});
                    }
                },
                .add => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = try self.binaryOp(a, b, .add);
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .sub => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = try self.binaryOp(a, b, .sub);
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .mul => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = try self.binaryOp(a, b, .mul);
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .div => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = try self.binaryOp(a, b, .div);
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .mod => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = try self.binaryOp(a, b, .mod);
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .neg => {
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = switch (a) {
                        .int => |v| Value{ .int = -v },
                        .float => |v| Value{ .float = -v },
                        else => return error.TypeError,
                    };
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .not_op => {
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = switch (a) {
                        .bool => |v| Value{ .bool = !v },
                        else => return error.TypeError,
                    };
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .eq, .neq, .lt, .lte, .gt, .gte => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = try self.compareOp(a, b, inst.op);
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .and_op => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = Value{ .bool = a.bool and b.bool };
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .or_op => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = Value{ .bool = a.bool or b.bool };
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .jump => {
                    ip = @intCast(inst.operand1);
                    if (self.verbose) std.debug.print(" -> {d}\n", .{ip});
                    continue;
                },
                .jump_if_false => {
                    const cond = self.stack.pop() orelse return error.StackUnderflow;
                    if (!cond.bool) {
                        ip = @intCast(inst.operand1);
                        if (self.verbose) std.debug.print(" -> {d}\n", .{ip});
                        continue;
                    }
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .jump_if_true => {
                    const cond = self.stack.pop() orelse return error.StackUnderflow;
                    if (cond.bool) {
                        ip = @intCast(inst.operand1);
                        if (self.verbose) std.debug.print(" -> {d}\n", .{ip});
                        continue;
                    }
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .call => {
                    if (inst.string_data) |func_name| {
                        // Handle built-in functions
                        if (std.mem.eql(u8, func_name, "println")) {
                            const arg = self.stack.pop() orelse return error.StackUnderflow;
                            switch (arg) {
                                .int => |v| std.debug.print("{d}\n", .{v}),
                                .float => |v| std.debug.print("{d}\n", .{v}),
                                .bool => |v| std.debug.print("{}\n", .{v}),
                                .string => |v| std.debug.print("{s}\n", .{v}),
                                .null_value => std.debug.print("null\n", .{}),
                                .array => std.debug.print("[array]\n", .{}),
                                .struct_val => |fields| std.debug.print("[struct with {d} fields]\n", .{fields.len}),
                            }
                        } else if (std.mem.eql(u8, func_name, "print")) {
                            const arg = self.stack.pop() orelse return error.StackUnderflow;
                            switch (arg) {
                                .int => |v| std.debug.print("{d}", .{v}),
                                .float => |v| std.debug.print("{d}", .{v}),
                                .bool => |v| std.debug.print("{}", .{v}),
                                .string => |v| std.debug.print("{s}", .{v}),
                                .null_value => std.debug.print("null", .{}),
                                .array => std.debug.print("[array]", .{}),
                                .struct_val => |fields| std.debug.print("[struct with {d} fields]", .{fields.len}),
                            }
                        } else if (std.mem.eql(u8, func_name, "int_to_str")) {
                            const arg = self.stack.pop() orelse return error.StackUnderflow;
                            switch (arg) {
                                .int => |v| {
                                    // Convert int to string
                                    const str = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                                    try self.stack.append(self.allocator, .{ .string = str });
                                    if (self.verbose) std.debug.print(" -> \"{s}\"\n", .{str});
                                },
                                else => {
                                    std.debug.print("\nError: int_to_str expects int argument\n", .{});
                                    return error.TypeError;
                                },
                            }
                        } else if (std.mem.eql(u8, func_name, "str_concat")) {
                            const b = self.stack.pop() orelse return error.StackUnderflow;
                            const a = self.stack.pop() orelse return error.StackUnderflow;
                            
                            const str_a = switch (a) {
                                .string => |s| s,
                                else => {
                                    std.debug.print("\nError: str_concat expects string arguments\n", .{});
                                    return error.TypeError;
                                },
                            };
                            const str_b = switch (b) {
                                .string => |s| s,
                                else => {
                                    std.debug.print("\nError: str_concat expects string arguments\n", .{});
                                    return error.TypeError;
                                },
                            };
                            
                            // Concatenate strings
                            const result = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ str_a, str_b });
                            try self.stack.append(self.allocator, .{ .string = result });
                            if (self.verbose) std.debug.print(" -> \"{s}\"\n", .{result});
                        } else if (std.mem.eql(u8, func_name, "str_len")) {
                            const arg = self.stack.pop() orelse return error.StackUnderflow;
                            switch (arg) {
                                .string => |s| {
                                    const len: i64 = @intCast(s.len);
                                    try self.stack.append(self.allocator, .{ .int = len });
                                    if (self.verbose) std.debug.print(" -> {d}\n", .{len});
                                },
                                else => {
                                    std.debug.print("\nError: str_len expects string argument\n", .{});
                                    return error.TypeError;
                                },
                            }
                        } else {
                            // User-defined function call
                            std.debug.print("\nError: Function '{s}' not implemented\n", .{func_name});
                            return error.NotImplemented;
                        }
                        // Don't push null for builtin functions that return values
                        if (!std.mem.eql(u8, func_name, "println") and !std.mem.eql(u8, func_name, "print")) {
                            // Built-in functions that return values already pushed their result
                            // No need to push null
                        } else {
                            // println and print don't return anything
                            try self.stack.append(self.allocator, Value.null_value);
                        }
                        if (self.verbose) std.debug.print(" {s}\n", .{func_name});
                    }
                },
                .ret => {
                    if (self.verbose) std.debug.print("\n", .{});
                    return; // Return from function
                },
                .pop => {
                    _ = self.stack.pop() orelse return error.StackUnderflow;
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .dup => {
                    const value = self.stack.items[self.stack.items.len - 1];
                    try self.stack.append(self.allocator, value);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .halt => {
                    if (self.verbose) std.debug.print("\n", .{});
                    return; // Stop execution
                },
                .struct_new => {
                    const field_count: usize = @intCast(inst.operand1);
                    const fields = try self.allocator.alloc(i64, field_count);
                    // Initialize to zero
                    for (fields) |*field| {
                        field.* = 0;
                    }
                    try self.stack.append(self.allocator, .{ .struct_val = fields });
                    if (self.verbose) std.debug.print(" -> struct{{{d}}}\n", .{field_count});
                },
                .field_get => {
                    const struct_val = self.stack.pop() orelse return error.StackUnderflow;
                    const field_idx: usize = @intCast(inst.operand1);

                    switch (struct_val) {
                        .struct_val => |fields| {
                            if (field_idx >= fields.len) {
                                std.debug.print("\nError: Field index {d} out of bounds (struct has {d} fields)\n", .{ field_idx, fields.len });
                                return error.FieldOutOfBounds;
                            }
                            const value = fields[field_idx];
                            try self.stack.append(self.allocator, .{ .int = value });
                            if (self.verbose) std.debug.print(" -> field[{d}]={d}\n", .{ field_idx, value });
                        },
                        else => {
                            std.debug.print("\nError: field_get on non-struct value\n", .{});
                            return error.TypeError;
                        },
                    }
                },
                .field_set => {
                    const value = self.stack.pop() orelse return error.StackUnderflow;
                    const struct_val = self.stack.pop() orelse return error.StackUnderflow;
                    const field_idx: usize = @intCast(inst.operand1);

                    switch (struct_val) {
                        .struct_val => |fields| {
                            if (field_idx >= fields.len) {
                                std.debug.print("\nError: Field index {d} out of bounds (struct has {d} fields)\n", .{ field_idx, fields.len });
                                return error.FieldOutOfBounds;
                            }
                            switch (value) {
                                .int => |v| {
                                    fields[field_idx] = v;
                                    if (self.verbose) std.debug.print(" -> field[{d}]={d}\n", .{ field_idx, v });
                                },
                                else => {
                                    std.debug.print("\nError: Can only store int values in struct fields\n", .{});
                                    return error.TypeError;
                                },
                            }
                            // Push struct back for chaining
                            try self.stack.append(self.allocator, struct_val);
                        },
                        else => {
                            std.debug.print("\nError: field_set on non-struct value\n", .{});
                            return error.TypeError;
                        },
                    }
                },
                else => {
                    std.debug.print("\nError: Opcode {s} not implemented\n", .{@tagName(inst.op)});
                    return error.NotImplemented;
                },
            }

            ip += 1;
        }
    }

    /// Perform binary operation
    fn binaryOp(self: *Interpreter, a: Value, b: Value, op: Opcode) !Value {
        _ = self;
        return switch (a) {
            .int => |a_val| switch (b) {
                .int => |b_val| switch (op) {
                    .add => Value{ .int = a_val + b_val },
                    .sub => Value{ .int = a_val - b_val },
                    .mul => Value{ .int = a_val * b_val },
                    .div => Value{ .int = @divTrunc(a_val, b_val) },
                    .mod => Value{ .int = @mod(a_val, b_val) },
                    else => error.InvalidOperation,
                },
                else => error.TypeError,
            },
            .float => |a_val| switch (b) {
                .float => |b_val| switch (op) {
                    .add => Value{ .float = a_val + b_val },
                    .sub => Value{ .float = a_val - b_val },
                    .mul => Value{ .float = a_val * b_val },
                    .div => Value{ .float = a_val / b_val },
                    else => error.InvalidOperation,
                },
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    /// Perform comparison operation
    fn compareOp(self: *Interpreter, a: Value, b: Value, op: Opcode) !Value {
        _ = self;
        return switch (a) {
            .int => |a_val| switch (b) {
                .int => |b_val| switch (op) {
                    .eq => Value{ .bool = a_val == b_val },
                    .neq => Value{ .bool = a_val != b_val },
                    .lt => Value{ .bool = a_val < b_val },
                    .lte => Value{ .bool = a_val <= b_val },
                    .gt => Value{ .bool = a_val > b_val },
                    .gte => Value{ .bool = a_val >= b_val },
                    else => error.InvalidOperation,
                },
                else => error.TypeError,
            },
            .bool => |a_val| switch (b) {
                .bool => |b_val| switch (op) {
                    .eq => Value{ .bool = a_val == b_val },
                    .neq => Value{ .bool = a_val != b_val },
                    else => error.InvalidOperation,
                },
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }
};
