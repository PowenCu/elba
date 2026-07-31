const std = @import("std");
const ir = @import("ir.zig");
const checked_int = @import("checked_int.zig");
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
    struct_val: []Value,
    tagged: *TaggedValue,

    pub const TaggedValue = struct {
        payload: Value,
        type_descriptor: []const u8,
    };

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
            .tagged => |tagged| try tagged.payload.format("", .{}, writer),
        }
    }
};

/// IR Interpreter - executes IR code directly
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    program: Program,
    stack: std.ArrayList(Value),
    variables: std.StringHashMap(Value),
    local_environments: std.ArrayList(std.StringHashMap(Value)),
    call_stack: std.ArrayList(CallFrame),
    verbose: bool,
    allocated_strings: std.ArrayList([]const u8), // Track allocated strings for cleanup
    allocated_arrays: std.ArrayList([]Value),
    allocated_structs: std.ArrayList([]Value),
    allocated_tagged: std.ArrayList(*Value.TaggedValue),

    const CallFrame = struct {
        function_name: []const u8,
        return_address: usize,
        base_pointer: usize,
    };

    const AdditionalBuiltin = enum {
        str_substring,
        str_split,
        str_trim,
        str_contains,
        str_to_int,
        str_to_float,
        abs,
        min,
        max,
        sqrt,
        floor,
        ceil,
        float_to_str,
        bool_to_str,
        int_to_float,
        float_to_int,
        array_len,
        array_push,
        array_pop,
        array_slice,

        fn fromName(name: []const u8) ?AdditionalBuiltin {
            inline for (std.meta.fields(AdditionalBuiltin)) |field| {
                if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
            }
            return null;
        }
    };

    pub fn init(allocator: std.mem.Allocator, program: Program, verbose: bool) !Interpreter {
        return .{
            .allocator = allocator,
            .program = program,
            .stack = try std.ArrayList(Value).initCapacity(allocator, 256),
            .variables = std.StringHashMap(Value).init(allocator),
            .local_environments = try std.ArrayList(std.StringHashMap(Value)).initCapacity(allocator, 16),
            .call_stack = try std.ArrayList(CallFrame).initCapacity(allocator, 64),
            .verbose = verbose,
            .allocated_strings = try std.ArrayList([]const u8).initCapacity(allocator, 32),
            .allocated_arrays = try std.ArrayList([]Value).initCapacity(allocator, 16),
            .allocated_structs = try std.ArrayList([]Value).initCapacity(allocator, 16),
            .allocated_tagged = try std.ArrayList(*Value.TaggedValue).initCapacity(allocator, 16),
        };
    }

    pub fn deinit(self: *Interpreter) void {
        // Free allocated strings from int_to_str and str_concat
        for (self.allocated_strings.items) |str| {
            self.allocator.free(str);
        }
        self.allocated_strings.deinit(self.allocator);

        for (self.allocated_arrays.items) |array| {
            self.allocator.free(array);
        }
        self.allocated_arrays.deinit(self.allocator);

        for (self.allocated_structs.items) |fields| {
            self.allocator.free(fields);
        }
        self.allocated_structs.deinit(self.allocator);

        for (self.allocated_tagged.items) |tagged| self.allocator.destroy(tagged);
        self.allocated_tagged.deinit(self.allocator);

        for (self.local_environments.items) |*environment| {
            environment.deinit();
        }
        self.local_environments.deinit(self.allocator);

        self.stack.deinit(self.allocator);
        self.variables.deinit();
        self.call_stack.deinit(self.allocator);
    }

    fn getVariable(self: *Interpreter, name: []const u8) ?Value {
        if (self.local_environments.items.len > 0) {
            const current = &self.local_environments.items[self.local_environments.items.len - 1];
            if (current.get(name)) |value| return value;
        }
        return self.variables.get(name);
    }

    fn setVariable(self: *Interpreter, name: []const u8, value: Value) !void {
        if (self.local_environments.items.len > 0) {
            const current = &self.local_environments.items[self.local_environments.items.len - 1];
            try current.put(name, value);
            return;
        }
        try self.variables.put(name, value);
    }

    fn findFunction(self: *Interpreter, name: []const u8) ?ir.Function {
        for (self.program.functions) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }

    fn executeUserFunction(self: *Interpreter, name: []const u8, arg_count: usize) anyerror!void {
        const function = self.findFunction(name) orelse {
            std.debug.print("\nError: Undefined function '{s}'\n", .{name});
            return error.UndefinedFunction;
        };
        if (function.param_count != arg_count) {
            std.debug.print(
                "\nError: Function '{s}' expects {d} arguments but received {d}\n",
                .{ name, function.param_count, arg_count },
            );
            return error.InvalidArgumentCount;
        }

        const arguments = try self.allocator.alloc(Value, arg_count);
        defer self.allocator.free(arguments);
        var argument_index = arg_count;
        while (argument_index > 0) {
            argument_index -= 1;
            arguments[argument_index] = self.stack.pop() orelse return error.StackUnderflow;
        }

        const environment = std.StringHashMap(Value).init(self.allocator);
        try self.local_environments.append(self.allocator, environment);
        defer {
            var finished_environment = self.local_environments.pop() orelse unreachable;
            finished_environment.deinit();
        }

        const current = &self.local_environments.items[self.local_environments.items.len - 1];
        for (function.param_names, arguments) |param_name, argument| {
            try current.put(param_name, argument);
        }

        const stack_base = self.stack.items.len;
        try self.executeFunction(function);

        const result = if (self.stack.items.len > stack_base)
            self.stack.pop() orelse unreachable
        else
            Value.null_value;
        self.stack.items.len = stack_base;
        try self.stack.append(self.allocator, result);
    }

    fn popArguments(self: *Interpreter, arg_count: usize) ![]Value {
        const arguments = try self.allocator.alloc(Value, arg_count);
        errdefer self.allocator.free(arguments);

        var argument_index = arg_count;
        while (argument_index > 0) {
            argument_index -= 1;
            arguments[argument_index] = self.stack.pop() orelse return error.StackUnderflow;
        }
        return arguments;
    }

    fn expectArgumentCount(arguments: []const Value, expected: usize) !void {
        if (arguments.len != expected) return error.InvalidArgumentCount;
    }

    fn trackString(self: *Interpreter, string: []const u8) !Value {
        try self.allocated_strings.append(self.allocator, string);
        return .{ .string = string };
    }

    fn trackArray(self: *Interpreter, array: []Value) !Value {
        try self.allocated_arrays.append(self.allocator, array);
        return .{ .array = array };
    }

    fn executeAdditionalBuiltin(self: *Interpreter, name: []const u8, arg_count: usize) !bool {
        const builtin = AdditionalBuiltin.fromName(name) orelse return false;
        const arguments = try self.popArguments(arg_count);
        defer self.allocator.free(arguments);

        const result: Value = switch (builtin) {
            .str_substring => blk: {
                try expectArgumentCount(arguments, 3);
                if (arguments[0] != .string or arguments[1] != .int or arguments[2] != .int) return error.TypeError;
                const start_value = arguments[1].int;
                const end_value = arguments[2].int;
                const string = arguments[0].string;
                if (start_value < 0 or end_value < start_value or end_value > string.len) return error.IndexOutOfBounds;
                break :blk .{ .string = string[@intCast(start_value)..@intCast(end_value)] };
            },
            .str_split => blk: {
                try expectArgumentCount(arguments, 2);
                if (arguments[0] != .string or arguments[1] != .string) return error.TypeError;
                if (arguments[1].string.len == 0) return error.InvalidArguments;
                var parts = try std.ArrayList(Value).initCapacity(self.allocator, 4);
                defer parts.deinit(self.allocator);
                var iterator = std.mem.splitSequence(u8, arguments[0].string, arguments[1].string);
                while (iterator.next()) |part| {
                    try parts.append(self.allocator, .{ .string = part });
                }
                break :blk try self.trackArray(try parts.toOwnedSlice(self.allocator));
            },
            .str_trim => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .string) return error.TypeError;
                break :blk .{ .string = std.mem.trim(u8, arguments[0].string, &std.ascii.whitespace) };
            },
            .str_contains => blk: {
                try expectArgumentCount(arguments, 2);
                if (arguments[0] != .string or arguments[1] != .string) return error.TypeError;
                break :blk .{ .bool = std.mem.indexOf(u8, arguments[0].string, arguments[1].string) != null };
            },
            .str_to_int => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .string) return error.TypeError;
                const value = std.fmt.parseInt(i64, arguments[0].string, 10) catch return error.TypeError;
                break :blk .{ .int = value };
            },
            .str_to_float => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .string) return error.TypeError;
                const value = std.fmt.parseFloat(f64, arguments[0].string) catch return error.TypeError;
                if (!std.math.isFinite(value)) return error.TypeError;
                break :blk .{ .float = value };
            },
            .abs => blk: {
                try expectArgumentCount(arguments, 1);
                break :blk switch (arguments[0]) {
                    .int => |value| if (value == std.math.minInt(i64)) return error.InvalidArguments else .{ .int = if (value < 0) -value else value },
                    .float => |value| .{ .float = @abs(value) },
                    else => return error.TypeError,
                };
            },
            .min, .max => blk: {
                try expectArgumentCount(arguments, 2);
                const use_min = builtin == .min;
                if (arguments[0] == .int and arguments[1] == .int) {
                    break :blk .{ .int = if (use_min) @min(arguments[0].int, arguments[1].int) else @max(arguments[0].int, arguments[1].int) };
                }
                const left: f64 = switch (arguments[0]) {
                    .int => |value| @floatFromInt(value),
                    .float => |value| value,
                    else => return error.TypeError,
                };
                const right: f64 = switch (arguments[1]) {
                    .int => |value| @floatFromInt(value),
                    .float => |value| value,
                    else => return error.TypeError,
                };
                break :blk .{ .float = if (use_min) @min(left, right) else @max(left, right) };
            },
            .sqrt, .floor, .ceil => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .float) return error.TypeError;
                const value = arguments[0].float;
                break :blk .{ .float = switch (builtin) {
                    .sqrt => @sqrt(value),
                    .floor => @floor(value),
                    .ceil => @ceil(value),
                    else => unreachable,
                } };
            },
            .float_to_str => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .float) return error.TypeError;
                break :blk try self.trackString(try std.fmt.allocPrint(self.allocator, "{d}", .{arguments[0].float}));
            },
            .bool_to_str => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .bool) return error.TypeError;
                break :blk .{ .string = if (arguments[0].bool) "true" else "false" };
            },
            .int_to_float => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .int) return error.TypeError;
                break :blk .{ .float = @floatFromInt(arguments[0].int) };
            },
            .float_to_int => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .float) return error.TypeError;
                const lower: f64 = @floatFromInt(std.math.minInt(i64));
                const upper = -lower;
                if (!std.math.isFinite(arguments[0].float) or arguments[0].float < lower or arguments[0].float >= upper) return error.TypeError;
                break :blk .{ .int = @intFromFloat(arguments[0].float) };
            },
            .array_len => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .array) return error.TypeError;
                break :blk .{ .int = @intCast(arguments[0].array.len) };
            },
            .array_push => blk: {
                try expectArgumentCount(arguments, 2);
                if (arguments[0] != .array) return error.TypeError;
                const old_array = arguments[0].array;
                const new_array = try self.allocator.alloc(Value, old_array.len + 1);
                @memcpy(new_array[0..old_array.len], old_array);
                new_array[old_array.len] = arguments[1];
                break :blk try self.trackArray(new_array);
            },
            .array_pop => blk: {
                try expectArgumentCount(arguments, 1);
                if (arguments[0] != .array) return error.TypeError;
                const old_array = arguments[0].array;
                if (old_array.len == 0) return error.IndexOutOfBounds;
                const shortened = try self.allocator.alloc(Value, old_array.len - 1);
                @memcpy(shortened, old_array[0 .. old_array.len - 1]);
                break :blk try self.trackArray(shortened);
            },
            .array_slice => blk: {
                try expectArgumentCount(arguments, 3);
                if (arguments[0] != .array or arguments[1] != .int or arguments[2] != .int) return error.TypeError;
                const start_value = arguments[1].int;
                const end_value = arguments[2].int;
                const old_array = arguments[0].array;
                if (start_value < 0 or end_value < start_value or end_value > old_array.len) return error.IndexOutOfBounds;
                const new_array = try self.allocator.alloc(Value, @intCast(end_value - start_value));
                @memcpy(new_array, old_array[@intCast(start_value)..@intCast(end_value)]);
                break :blk try self.trackArray(new_array);
            },
        };

        try self.stack.append(self.allocator, result);
        return true;
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
    fn executeFunction(self: *Interpreter, func: ir.Function) anyerror!void {
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
                    const f: f64 = @bitCast(inst.operand1);
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
                        if (self.getVariable(var_name)) |value| {
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
                        try self.setVariable(var_name, value);
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
                .pow => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = try switch (a) {
                        .int => |base| switch (b) {
                            .int => |exponent| Value{ .int = try checked_int.pow(base, exponent) },
                            else => error.TypeError,
                        },
                        .float => |base| switch (b) {
                            .float => |exponent| Value{ .float = std.math.pow(f64, base, exponent) },
                            .int => |exponent| Value{ .float = std.math.pow(f64, base, @floatFromInt(exponent)) },
                            else => error.TypeError,
                        },
                        else => error.TypeError,
                    };
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .neg => {
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    const result = switch (a) {
                        .int => |v| Value{ .int = try checked_int.neg(v) },
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
                    if (a != .bool or b != .bool) return error.TypeError;
                    const result = Value{ .bool = a.bool and b.bool };
                    try self.stack.append(self.allocator, result);
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .or_op => {
                    const b = self.stack.pop() orelse return error.StackUnderflow;
                    const a = self.stack.pop() orelse return error.StackUnderflow;
                    if (a != .bool or b != .bool) return error.TypeError;
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
                    if (cond != .bool) return error.TypeError;
                    if (!cond.bool) {
                        ip = @intCast(inst.operand1);
                        if (self.verbose) std.debug.print(" -> {d}\n", .{ip});
                        continue;
                    }
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .jump_if_true => {
                    const cond = self.stack.pop() orelse return error.StackUnderflow;
                    if (cond != .bool) return error.TypeError;
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
                                .tagged => std.debug.print("[tagged]\n", .{}),
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
                                .tagged => std.debug.print("[tagged]", .{}),
                            }
                        } else if (std.mem.eql(u8, func_name, "int_to_str")) {
                            const arg = self.stack.pop() orelse return error.StackUnderflow;
                            switch (arg) {
                                .int => |v| {
                                    // Convert int to string
                                    const str = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                                    try self.allocated_strings.append(self.allocator, str); // Track for cleanup
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
                            try self.allocated_strings.append(self.allocator, result); // Track for cleanup
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
                        } else if (try self.executeAdditionalBuiltin(func_name, @intCast(inst.operand2))) {
                            // The builtin implementation pushed its result.
                        } else {
                            // User-defined function call
                            try self.executeUserFunction(func_name, @intCast(inst.operand2));
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
                .stack_reset => {},
                .halt => {
                    if (self.verbose) std.debug.print("\n", .{});
                    return; // Stop execution
                },
                .struct_new => {
                    const field_count: usize = @intCast(inst.operand1);
                    const fields = try self.allocator.alloc(Value, field_count);
                    for (fields) |*field| {
                        field.* = Value.null_value;
                    }
                    try self.allocated_structs.append(self.allocator, fields);
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
                            try self.stack.append(self.allocator, value);
                            if (self.verbose) std.debug.print(" -> field[{d}]\n", .{field_idx});
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
                            fields[field_idx] = value;
                            if (self.verbose) std.debug.print(" -> field[{d}]\n", .{field_idx});
                            // Push struct back for chaining
                            try self.stack.append(self.allocator, struct_val);
                        },
                        else => {
                            std.debug.print("\nError: field_set on non-struct value\n", .{});
                            return error.TypeError;
                        },
                    }
                },
                .array_new => {
                    const size: usize = @intCast(inst.operand1);
                    const arr = try self.allocator.alloc(Value, size);
                    // Initialize with null values
                    for (arr) |*elem| {
                        elem.* = Value.null_value;
                    }
                    try self.allocated_arrays.append(self.allocator, arr);
                    try self.stack.append(self.allocator, .{ .array = arr });
                    if (self.verbose) std.debug.print(" -> array[{d}]\n", .{size});
                },
                .array_get => {
                    const index = self.stack.pop() orelse return error.StackUnderflow;
                    const array_val = self.stack.pop() orelse return error.StackUnderflow;

                    switch (array_val) {
                        .array => |arr| {
                            const idx: usize = switch (index) {
                                .int => |i| if (i < 0) return error.IndexOutOfBounds else @intCast(i),
                                else => {
                                    std.debug.print("\nError: Array index must be an integer\n", .{});
                                    return error.TypeError;
                                },
                            };
                            if (idx >= arr.len) {
                                std.debug.print("\nError: Array index {d} out of bounds (length: {d})\n", .{ idx, arr.len });
                                return error.IndexOutOfBounds;
                            }
                            try self.stack.append(self.allocator, arr[idx]);
                            if (self.verbose) std.debug.print(" -> array[{d}]\n", .{idx});
                        },
                        else => {
                            std.debug.print("\nError: array_get on non-array value\n", .{});
                            return error.TypeError;
                        },
                    }
                },
                .array_set => {
                    const value = self.stack.pop() orelse return error.StackUnderflow;
                    const index = self.stack.pop() orelse return error.StackUnderflow;
                    const array_val = self.stack.pop() orelse return error.StackUnderflow;

                    switch (array_val) {
                        .array => |arr| {
                            const idx: usize = switch (index) {
                                .int => |i| if (i < 0) return error.IndexOutOfBounds else @intCast(i),
                                else => {
                                    std.debug.print("\nError: Array index must be an integer\n", .{});
                                    return error.TypeError;
                                },
                            };
                            if (idx >= arr.len) {
                                std.debug.print("\nError: Array index {d} out of bounds (length: {d})\n", .{ idx, arr.len });
                                return error.IndexOutOfBounds;
                            }
                            arr[idx] = value;
                            if (self.verbose) std.debug.print(" -> array[{d}] = value\n", .{idx});
                        },
                        else => {
                            std.debug.print("\nError: array_set on non-array value\n", .{});
                            return error.TypeError;
                        },
                    }
                },
                .array_len => {
                    const array_value = self.stack.pop() orelse return error.StackUnderflow;
                    switch (array_value) {
                        .array => |array| try self.stack.append(self.allocator, .{ .int = @intCast(array.len) }),
                        else => return error.TypeError,
                    }
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .optional_wrap => {
                    const payload = self.stack.pop() orelse return error.StackUnderflow;
                    const tagged = try self.allocator.create(Value.TaggedValue);
                    tagged.* = .{
                        .payload = payload,
                        .type_descriptor = inst.string_data orelse "unknown",
                    };
                    try self.allocated_tagged.append(self.allocator, tagged);
                    try self.stack.append(self.allocator, .{ .tagged = tagged });
                    if (self.verbose) std.debug.print(" -> tagged\n", .{});
                },
                .optional_unwrap => {
                    const value = self.stack.pop() orelse return error.StackUnderflow;
                    if (value == .null_value) return error.TypeError;
                    try self.stack.append(self.allocator, if (value == .tagged) value.tagged.payload else value);
                    if (self.verbose) std.debug.print(" -> unwrapped\n", .{});
                },
                .optional_is_null => {
                    const value = self.stack.pop() orelse return error.StackUnderflow;
                    try self.stack.append(self.allocator, .{ .bool = value == .null_value });
                    if (self.verbose) std.debug.print("\n", .{});
                },
                .type_check => {
                    const value = self.stack.pop() orelse return error.StackUnderflow;
                    const payload = if (value == .tagged) value.tagged.payload else value;
                    const tag_matches = switch (inst.operand1) {
                        1 => payload == .int,
                        2 => payload == .float,
                        3 => payload == .string,
                        4 => payload == .bool,
                        5 => payload == .struct_val,
                        6 => payload == .array,
                        7 => payload == .null_value,
                        8, 9 => payload == .tagged,
                        10 => true,
                        else => false,
                    };
                    const descriptor_matches = value != .tagged or inst.string_data == null or
                        std.mem.eql(u8, value.tagged.type_descriptor, inst.string_data.?);
                    const matches = tag_matches and descriptor_matches;
                    const negate = inst.operand2 != 0;
                    try self.stack.append(self.allocator, .{ .bool = if (negate) !matches else matches });
                    if (self.verbose) std.debug.print("\n", .{});
                },
            }

            ip += 1;
        }
    }

    /// Perform binary operation
    fn binaryOp(self: *Interpreter, a: Value, b: Value, op: Opcode) !Value {
        return switch (a) {
            .int => |a_val| switch (b) {
                .int => |b_val| switch (op) {
                    .add => Value{ .int = try checked_int.add(a_val, b_val) },
                    .sub => Value{ .int = try checked_int.sub(a_val, b_val) },
                    .mul => Value{ .int = try checked_int.mul(a_val, b_val) },
                    .div => Value{ .int = try checked_int.div(a_val, b_val) },
                    .mod => Value{ .int = try checked_int.mod(a_val, b_val) },
                    else => error.InvalidOperation,
                },
                .float => |b_val| switch (op) {
                    .add => Value{ .float = @as(f64, @floatFromInt(a_val)) + b_val },
                    .sub => Value{ .float = @as(f64, @floatFromInt(a_val)) - b_val },
                    .mul => Value{ .float = @as(f64, @floatFromInt(a_val)) * b_val },
                    .div => Value{ .float = @as(f64, @floatFromInt(a_val)) / b_val },
                    .mod => Value{ .float = @mod(@as(f64, @floatFromInt(a_val)), b_val) },
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
                    .mod => Value{ .float = @mod(a_val, b_val) },
                    else => error.InvalidOperation,
                },
                .int => |b_val| switch (op) {
                    .add => Value{ .float = a_val + @as(f64, @floatFromInt(b_val)) },
                    .sub => Value{ .float = a_val - @as(f64, @floatFromInt(b_val)) },
                    .mul => Value{ .float = a_val * @as(f64, @floatFromInt(b_val)) },
                    .div => Value{ .float = a_val / @as(f64, @floatFromInt(b_val)) },
                    .mod => Value{ .float = @mod(a_val, @as(f64, @floatFromInt(b_val))) },
                    else => error.InvalidOperation,
                },
                else => error.TypeError,
            },
            .string => |a_val| switch (b) {
                .string => |b_val| if (op == .add) blk: {
                    const result = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ a_val, b_val });
                    try self.allocated_strings.append(self.allocator, result);
                    break :blk Value{ .string = result };
                } else error.InvalidOperation,
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    /// Perform comparison operation
    fn compareOp(self: *Interpreter, a: Value, b: Value, op: Opcode) !Value {
        _ = self;
        if (op == .eq or op == .neq) {
            const equal = valuesEqual(a, b);
            return .{ .bool = if (op == .eq) equal else !equal };
        }
        if (a == .null_value or b == .null_value) {
            return switch (op) {
                .eq => Value{ .bool = a == .null_value and b == .null_value },
                .neq => Value{ .bool = a != .null_value or b != .null_value },
                else => error.InvalidOperation,
            };
        }

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
                .float => |b_val| compareFloats(@floatFromInt(a_val), b_val, op),
                else => error.TypeError,
            },
            .float => |a_val| switch (b) {
                .float => |b_val| compareFloats(a_val, b_val, op),
                .int => |b_val| compareFloats(a_val, @floatFromInt(b_val), op),
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
            .string => |a_val| switch (b) {
                .string => |b_val| switch (op) {
                    .eq => Value{ .bool = std.mem.eql(u8, a_val, b_val) },
                    .neq => Value{ .bool = !std.mem.eql(u8, a_val, b_val) },
                    else => error.InvalidOperation,
                },
                else => error.TypeError,
            },
            else => error.TypeError,
        };
    }

    fn valuesEqual(a: Value, b: Value) bool {
        return switch (a) {
            .int => |left| b == .int and left == b.int,
            .float => |left| b == .float and left == b.float,
            .bool => |left| b == .bool and left == b.bool,
            .string => |left| b == .string and std.mem.eql(u8, left, b.string),
            .null_value => b == .null_value,
            .array => |left| blk: {
                if (b != .array or left.len != b.array.len) break :blk false;
                for (left, b.array) |left_item, right_item| {
                    if (!valuesEqual(left_item, right_item)) break :blk false;
                }
                break :blk true;
            },
            .struct_val => |left| blk: {
                if (b != .struct_val or left.len != b.struct_val.len) break :blk false;
                for (left, b.struct_val) |left_field, right_field| {
                    if (!valuesEqual(left_field, right_field)) break :blk false;
                }
                break :blk true;
            },
            .tagged => |left| b == .tagged and
                std.mem.eql(u8, left.type_descriptor, b.tagged.type_descriptor) and
                valuesEqual(left.payload, b.tagged.payload),
        };
    }

    fn compareFloats(a: f64, b: f64, op: Opcode) !Value {
        return switch (op) {
            .eq => Value{ .bool = a == b },
            .neq => Value{ .bool = a != b },
            .lt => Value{ .bool = a < b },
            .lte => Value{ .bool = a <= b },
            .gt => Value{ .bool = a > b },
            .gte => Value{ .bool = a >= b },
            else => error.InvalidOperation,
        };
    }
};
