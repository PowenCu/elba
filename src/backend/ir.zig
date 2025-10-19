const std = @import("std");

/// Simple Intermediate Representation for Elba
/// This is a stack-based IR with basic operations
pub const ValueType = enum {
    int,
    float,
    bool,
    string,
    null_type,
    void,
};

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

    // Built-in functions
    builtin_call, // Call builtin function

    // Array operations
    array_new, // Create new array
    array_get, // Get array element
    array_set, // Set array element

    // Struct operations
    struct_new, // Create new struct
    field_get, // Get struct field
    field_set, // Set struct field

    // Type operations
    type_check, // Check type
    cast, // Type cast

    // Special
    halt, // Stop execution
};

pub const Instruction = struct {
    op: Opcode,
    operand1: i64 = 0,
    operand2: i64 = 0,
    operand3: i64 = 0,
    string_data: ?[]const u8 = null,
};

pub const Function = struct {
    name: []const u8,
    param_count: usize,
    param_names: [][]const u8 = &[_][]const u8{}, // Parameter names for LLVM/C codegen
    local_count: usize,
    instructions: []Instruction,
    type_params: [][]const u8 = &[_][]const u8{}, // Generic type parameters
    is_generic: bool = false, // Whether this is a generic template
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
            allocator.free(module.exports);
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

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .instructions = std.ArrayList(Instruction).initCapacity(allocator, 0) catch @panic("OOM"),
            .string_pool = std.StringHashMap(usize).init(allocator),
            .string_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch @panic("OOM"),
            .label_counter = 0,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.instructions.deinit(self.allocator);
        self.string_pool.deinit();
        self.string_list.deinit(self.allocator);
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
                .builtin_call => std.debug.print(" {s}({d})", .{ inst.string_data orelse "?", inst.operand2 }),
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
                .builtin_call => try writer.print(" {s}({d})", .{ inst.string_data orelse "?", inst.operand2 }),
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
