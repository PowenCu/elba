const std = @import("std");
pub const runtime = @import("runtime.zig");

/// Simple Intermediate Representation for Elba
/// This is a stack-based IR with basic operations
///
/// The IR uses a stack-based execution model where:
/// - Values are pushed onto and popped from a stack
/// - Operations consume values from the stack and push results
/// - Variables are stored in a separate environment (hash map)
/// - Functions are stored with their instruction sequences
pub const ValueType = enum {
    int,
    float,
    bool,
    string,
    null_type,
    void,
    array,
    struct_type,
    function,
    optional,
    union_type,

    /// Convert from runtime TypeTag
    pub fn fromRuntimeTag(tag: runtime.TypeTag) ValueType {
        return switch (tag) {
            .null_type => .null_type,
            .int => .int,
            .float => .float,
            .bool => .bool,
            .string => .string,
            .array => .array,
            .struct_type => .struct_type,
            .function => .function,
            .optional => .optional,
            .union_type => .union_type,
        };
    }

    /// Convert to runtime TypeTag
    pub fn toRuntimeTag(self: ValueType) runtime.TypeTag {
        return switch (self) {
            .null_type, .void => .null_type,
            .int => .int,
            .float => .float,
            .bool => .bool,
            .string => .string,
            .array => .array,
            .struct_type => .struct_type,
            .function => .function,
            .optional => .optional,
            .union_type => .union_type,
        };
    }
};

/// Instruction operands use zero for "type unknown" and store concrete value
/// types as their enum tag plus one. Binary instructions pack the left and
/// right operand types into the low two bytes of `operand3`.
pub fn encodeValueType(value_type: ?ValueType) i64 {
    return if (value_type) |typ| @as(i64, @intFromEnum(typ)) + 1 else 0;
}

pub fn decodeValueType(encoded: i64) ?ValueType {
    if (encoded <= 0 or encoded > 0xff) return null;
    return std.meta.intToEnum(ValueType, @as(std.meta.Tag(ValueType), @intCast(encoded - 1))) catch null;
}

pub fn encodeBinaryTypes(left: ?ValueType, right: ?ValueType) i64 {
    return encodeValueType(left) | (encodeValueType(right) << 8);
}

pub fn decodeBinaryLeft(encoded: i64) ?ValueType {
    return decodeValueType(encoded & 0xff);
}

pub fn decodeBinaryRight(encoded: i64) ?ValueType {
    return decodeValueType((encoded >> 8) & 0xff);
}

pub const Register = u32;

pub const Opcode = enum {
    // Load/Store
    load_const_int, // Load integer constant
    load_const_float, // Load float constant
    load_const_bool, // Load boolean constant
    load_const_str, // Load string constant
    load_null, // Load null value
    load_var, // Load variable from environment
    store_var, // Store to variable

    // Arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    pow,

    // Comparison
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,

    // Logical
    and_op,
    or_op,
    not_op,

    // Control Flow
    jump, // Unconditional jump
    jump_if_false, // Conditional jump
    jump_if_true, // Conditional jump
    call, // Function call
    ret, // Return from function

    // Stack operations
    pop, // Pop value from stack
    dup, // Duplicate top of stack
    stack_reset, // Compiler-only synchronization at value-less control-flow joins

    // Array operations
    array_new, // Create new array with capacity
    array_get, // Get array element
    array_set, // Set array element
    array_len, // Get array length

    // Struct operations
    struct_new, // Create new struct
    field_get, // Get struct field by index
    field_set, // Set struct field by index

    // Optional operations
    optional_wrap, // Wrap value in optional (T -> T?)
    optional_unwrap, // Unwrap optional (T? -> T, error if null)
    optional_is_null, // Check if optional is null

    // Type operations
    type_check, // Check type (is)

    // Special
    halt, // Stop execution
};

pub const Instruction = struct {
    op: Opcode,
    operand1: i64 = 0, // Primary operand (constant value, jump target, etc.)
    operand2: i64 = 0, // Secondary operand (arg count, field index, etc.)
    operand3: i64 = 0, // Tertiary operand (type info, flags, etc.)
    string_data: ?[]const u8 = null, // String data (variable names, function names, etc.)

    /// Create a simple instruction with no operands
    pub fn simple(op: Opcode) Instruction {
        return .{ .op = op };
    }

    /// Create an instruction with one integer operand
    pub fn withInt(op: Opcode, value: i64) Instruction {
        return .{ .op = op, .operand1 = value };
    }

    /// Create an instruction with string data
    pub fn withString(op: Opcode, str: []const u8) Instruction {
        return .{ .op = op, .string_data = str };
    }

    /// Create an instruction with string and operand
    pub fn withStringAndOp(op: Opcode, str: []const u8, operand: i64) Instruction {
        return .{ .op = op, .string_data = str, .operand2 = operand };
    }
};

pub const Function = struct {
    name: []const u8,
    param_count: usize,
    param_names: [][]const u8 = &[_][]const u8{}, // Parameter names for LLVM/C codegen
    local_count: usize,
    instructions: []Instruction,
    type_params: [][]const u8 = &[_][]const u8{}, // Generic type parameters
    is_generic: bool = false, // Whether this is a generic template
    return_type: ValueType = .void, // Return type for codegen

    /// Check if function is the entry point
    pub fn isEntryPoint(self: Function, entry_name: []const u8) bool {
        return std.mem.eql(u8, self.name, entry_name);
    }
};

pub const Program = struct {
    functions: []Function,
    string_pool: [][]const u8,
    entry_point: []const u8, // Name of main/entry function
    modules: []Module = &[_]Module{}, // Imported modules

    pub const Module = struct {
        name: []const u8,
        path: []const u8,
        exports: [][]const u8, // Exported symbol names
    };

    pub fn init(_: std.mem.Allocator) Program {
        return .{
            .functions = &[_]Function{},
            .string_pool = &[_][]const u8{},
            .entry_point = "main",
        };
    }

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        // Free instructions for each function
        for (self.functions) |func| {
            allocator.free(func.instructions);
            allocator.free(func.param_names);
        }
        allocator.free(self.functions);

        // Free each string in the string pool
        for (self.string_pool) |str| {
            allocator.free(str);
        }
        allocator.free(self.string_pool);

        // Free module data
        for (self.modules) |module| {
            allocator.free(module.name);
            allocator.free(module.path);
            if (module.exports.len != 0) {
                allocator.free(module.exports);
            }
        }
        allocator.free(self.modules);
    }
};

/// IR Builder - helper for constructing IR programs
pub const Builder = struct {
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    string_pool: std.StringHashMap(usize),
    string_list: std.ArrayList([]const u8),
    label_counter: usize,
    struct_fields: std.StringHashMap(std.StringHashMap(usize)), // struct_name -> (field_name -> index)

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .instructions = std.ArrayList(Instruction).initCapacity(allocator, 0) catch unreachable,
            .string_pool = std.StringHashMap(usize).init(allocator),
            .string_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .label_counter = 0,
            .struct_fields = std.StringHashMap(std.StringHashMap(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.instructions.deinit(self.allocator);
        self.string_pool.deinit();
        self.string_list.deinit(self.allocator);

        // Clean up struct_fields
        var iter = self.struct_fields.iterator();
        while (iter.next()) |entry| {
            var field_map = entry.value_ptr.*;
            field_map.deinit();
        }
        self.struct_fields.deinit();
    }

    /// Add an instruction
    pub fn emit(self: *Builder, op: Opcode, op1: i64, op2: i64, op3: i64) !void {
        try self.instructions.append(self.allocator, .{
            .op = op,
            .operand1 = op1,
            .operand2 = op2,
            .operand3 = op3,
        });
    }

    /// Add an instruction with string data
    pub fn emitWithString(self: *Builder, op: Opcode, str: []const u8, op2: i64, op3: i64) !void {
        try self.instructions.append(self.allocator, .{
            .op = op,
            .operand1 = 0,
            .operand2 = op2,
            .operand3 = op3,
            .string_data = str,
        });
    }

    /// Add an instruction with string data and all three integer operands.
    pub fn emitFullWithString(self: *Builder, op: Opcode, str: []const u8, op1: i64, op2: i64, op3: i64) !void {
        try self.instructions.append(self.allocator, .{
            .op = op,
            .operand1 = op1,
            .operand2 = op2,
            .operand3 = op3,
            .string_data = str,
        });
    }

    /// Intern a string and return its index
    pub fn internString(self: *Builder, str: []const u8) !usize {
        if (self.string_pool.get(str)) |index| {
            return index;
        }
        const index = self.string_list.items.len;
        const owned = try self.allocator.dupe(u8, str);
        try self.string_list.append(self.allocator, owned);
        try self.string_pool.put(owned, index);
        return index;
    }

    /// Register a struct type with its field ordering
    pub fn registerStructType(self: *Builder, struct_name: []const u8, field_names: []const []const u8) !void {
        var field_map = std.StringHashMap(usize).init(self.allocator);
        for (field_names, 0..) |field_name, idx| {
            try field_map.put(field_name, idx);
        }
        try self.struct_fields.put(struct_name, field_map);
    }

    /// Get field index for a struct type
    pub fn getFieldIndex(self: *Builder, struct_name: []const u8, field_name: []const u8) !usize {
        if (self.struct_fields.get(struct_name)) |field_map| {
            if (field_map.get(field_name)) |idx| {
                return idx;
            }
        }
        // Fallback to global string interning (for compatibility)
        return try self.internString(field_name);
    }

    /// Resolve a field when the receiver's concrete type was erased from the IR.
    /// This is safe when every registered struct using the name assigns it the
    /// same index, which is common for nested generic containers.
    pub fn getFieldIndexByName(self: *Builder, field_name: []const u8) !usize {
        var resolved_index: ?usize = null;
        var iterator = self.struct_fields.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.get(field_name)) |index| {
                if (resolved_index) |resolved| {
                    if (resolved != index) return try self.internString(field_name);
                } else {
                    resolved_index = index;
                }
            }
        }
        return resolved_index orelse try self.internString(field_name);
    }

    /// Get current instruction position (for labels)
    pub fn position(self: *Builder) usize {
        return self.instructions.items.len;
    }

    /// Generate a unique label
    pub fn genLabel(self: *Builder) usize {
        const label = self.label_counter;
        self.label_counter += 1;
        return label;
    }

    /// Patch a jump instruction at given position
    pub fn patchJump(self: *Builder, pos: usize, target: usize) void {
        self.instructions.items[pos].operand1 = @intCast(target);
    }
};

/// Simple IR pretty printer for debugging
pub fn printProgram(program: Program, writer: anytype) !void {
    _ = writer; // We'll use debug print instead for simplicity
    std.debug.print("=== Elba IR Program ===\n", .{});
    std.debug.print("Entry point: {s}\n", .{program.entry_point});

    // Print modules if any
    if (program.modules.len > 0) {
        std.debug.print("\nModules:\n", .{});
        for (program.modules) |module| {
            std.debug.print("  - {s} (from: {s})\n", .{ module.name, module.path });
        }
    }

    std.debug.print("\n", .{});

    for (program.functions) |func| {
        std.debug.print("Function: {s}", .{func.name});

        // Print generic parameters if any
        if (func.is_generic and func.type_params.len > 0) {
            std.debug.print("<", .{});
            for (func.type_params, 0..) |param, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{param});
            }
            std.debug.print(">", .{});
        }
        std.debug.print("\n", .{});

        std.debug.print("  Params: {d}, Locals: {d}", .{ func.param_count, func.local_count });
        if (func.is_generic) {
            std.debug.print(" [GENERIC]", .{});
        }
        std.debug.print("\n", .{});
        std.debug.print("  Instructions:\n", .{});

        for (func.instructions, 0..) |inst, i| {
            std.debug.print("    {d:4}: {s}", .{ i, @tagName(inst.op) });

            // Print operands based on instruction type
            switch (inst.op) {
                .load_const_int => std.debug.print(" {d}", .{inst.operand1}),
                .load_const_float => {
                    const f: f64 = @bitCast(@as(u64, @intCast(inst.operand1)));
                    std.debug.print(" {d}", .{f});
                },
                .load_const_bool => std.debug.print(" {s}", .{if (inst.operand1 == 1) "true" else "false"}),
                .load_const_str => if (inst.string_data) |str| {
                    std.debug.print(" \"{s}\"", .{str});
                },
                .load_var, .store_var => if (inst.string_data) |str| {
                    std.debug.print(" {s}", .{str});
                },
                .jump, .jump_if_false, .jump_if_true => std.debug.print(" -> {d}", .{inst.operand1}),
                .call => std.debug.print(" {s}({d})", .{ inst.string_data orelse "?", inst.operand2 }),
                .array_new => std.debug.print(" size={d}", .{inst.operand1}),
                .struct_new => std.debug.print(" fields={d}", .{inst.operand1}),
                .field_get, .field_set => std.debug.print(" field_idx={d}", .{inst.operand1}),
                .type_check => std.debug.print(" type={d} not={d}", .{ inst.operand1, inst.operand2 }),
                else => {},
            }

            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
}

/// Write IR program to a file
pub fn writeProgramToFile(program: Program, file: std.fs.File, allocator: std.mem.Allocator) !void {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer buffer.deinit(allocator);

    const writer = buffer.writer(allocator);

    try writer.writeAll("=== Elba IR Program ===\n");
    try writer.print("Entry point: {s}\n", .{program.entry_point});

    // Write modules if any
    if (program.modules.len > 0) {
        try writer.writeAll("\nModules:\n");
        for (program.modules) |module| {
            try writer.print("  - {s} (from: {s})\n", .{ module.name, module.path });
        }
    }

    try writer.writeAll("\n");

    for (program.functions) |func| {
        try writer.print("Function: {s}", .{func.name});

        // Write generic parameters if any
        if (func.is_generic and func.type_params.len > 0) {
            try writer.writeAll("<");
            for (func.type_params, 0..) |param, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s}", .{param});
            }
            try writer.writeAll(">");
        }
        try writer.writeAll("\n");

        try writer.print("  Params: {d}, Locals: {d}", .{ func.param_count, func.local_count });
        if (func.is_generic) {
            try writer.writeAll(" [GENERIC]");
        }
        try writer.writeAll("\n");
        try writer.writeAll("  Instructions:\n");

        for (func.instructions, 0..) |inst, i| {
            try writer.print("    {d:4}: {s}", .{ i, @tagName(inst.op) });

            // Print operands based on instruction type
            switch (inst.op) {
                .load_const_int => try writer.print(" {d}", .{inst.operand1}),
                .load_const_float => {
                    const f: f64 = @bitCast(@as(u64, @intCast(inst.operand1)));
                    try writer.print(" {d}", .{f});
                },
                .load_const_bool => try writer.print(" {s}", .{if (inst.operand1 == 1) "true" else "false"}),
                .load_const_str => if (inst.string_data) |str| {
                    try writer.print(" \"{s}\"", .{str});
                },
                .load_var, .store_var => if (inst.string_data) |str| {
                    try writer.print(" {s}", .{str});
                },
                .jump, .jump_if_false, .jump_if_true => try writer.print(" -> {d}", .{inst.operand1}),
                .call => try writer.print(" {s}({d})", .{ inst.string_data orelse "?", inst.operand2 }),
                .array_new => try writer.print(" size={d}", .{inst.operand1}),
                .struct_new => try writer.print(" fields={d}", .{inst.operand1}),
                .field_get, .field_set => try writer.print(" field_idx={d}", .{inst.operand1}),
                .type_check => try writer.print(" type={d} not={d}", .{ inst.operand1, inst.operand2 }),
                else => {},
            }

            try writer.writeAll("\n");
        }
        try writer.writeAll("\n");
    }

    // Write buffer to file
    try file.writeAll(buffer.items);
}
// Simple test for IR builder basics
test "IR builder basics" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    // Build simple program: x = 10 + 20
    try builder.emit(.load_const_int, 10, 0, 0);
    try builder.emit(.load_const_int, 20, 0, 0);
    try builder.emit(.add, 0, 0, 0);
    try builder.emitWithString(.store_var, "x", 0, 0);
    try builder.emit(.halt, 0, 0, 0);

    try std.testing.expect(builder.instructions.items.len == 5);
}
