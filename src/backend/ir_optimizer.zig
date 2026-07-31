const std = @import("std");
const ir = @import("ir.zig");
const checked_int = @import("checked_int.zig");
const Instruction = ir.Instruction;
const Opcode = ir.Opcode;

/// IR Optimizer - performs various optimization passes on IR code
pub const Optimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(_: *Optimizer) void {
        // Nothing to clean up yet
    }

    /// Run all optimization passes on a program
    pub fn optimize(self: *Optimizer, program: *ir.Program) !void {
        for (program.functions) |*func| {
            try self.optimizeFunction(func);
        }
    }

    /// Optimize a single function
    fn optimizeFunction(self: *Optimizer, func: *ir.Function) !void {
        // Skip optimization for generic functions (templates)
        if (func.is_generic) {
            return;
        }

        var instructions = try std.ArrayList(Instruction).initCapacity(self.allocator, func.instructions.len);
        defer instructions.deinit(self.allocator);

        try instructions.appendSlice(self.allocator, func.instructions);

        // Pass 1: Constant folding
        try self.constantFolding(&instructions);

        // Pass 2: Algebraic simplifications
        try self.algebraicSimplifications(&instructions);

        // Pass 3: Copy propagation
        try self.copyPropagation(&instructions);

        // Pass 4: Common subexpression elimination
        try self.commonSubexpressionElimination(&instructions);

        // Pass 5: Redundant load/store elimination
        try self.redundantLoadStoreElimination(&instructions);

        // Pass 6: Dead code elimination
        try self.deadCodeElimination(&instructions);

        // Pass 7: Peephole optimizations
        try self.peepholeOptimizations(&instructions);

        // Replace function instructions with optimized version
        self.allocator.free(func.instructions);
        func.instructions = try instructions.toOwnedSlice(self.allocator);
    }

    /// Constant Folding - evaluate constant expressions at compile time
    fn constantFolding(_: *Optimizer, instructions: *std.ArrayList(Instruction)) !void {
        var i: usize = 0;
        while (i < instructions.items.len) {
            // Look for pattern: load_const, load_const, binary_op
            if (i + 2 < instructions.items.len) {
                const inst1 = instructions.items[i];
                const inst2 = instructions.items[i + 1];
                const inst3 = instructions.items[i + 2];

                // Check if we have two constant loads followed by an operation
                if (isConstantLoad(inst1) and isConstantLoad(inst2) and isFoldableOp(inst3.op)) {
                    // Try to fold the operation
                    if (tryFoldOperation(inst1, inst2, inst3)) |folded| {
                        // Replace the three instructions with one
                        instructions.items[i] = folded;
                        _ = instructions.orderedRemove(i + 1);
                        _ = instructions.orderedRemove(i + 1);
                        continue;
                    }
                }
            }
            i += 1;
        }
    }

    /// Dead Code Elimination - remove unreachable code
    fn deadCodeElimination(self: *Optimizer, instructions: *std.ArrayList(Instruction)) !void {
        _ = self;
        var i: usize = 0;
        while (i < instructions.items.len) {
            const inst = instructions.items[i];

            // Remove code after unconditional jump or return
            if (inst.op == .jump or inst.op == .ret or inst.op == .halt) {
                // Look ahead to find the next valid target
                const target: usize = if (inst.op == .jump) @intCast(inst.operand1) else instructions.items.len;

                // Remove dead instructions between here and target
                const j = i + 1;
                while (j < instructions.items.len) {
                    // Stop if we hit a jump target
                    if (isJumpTarget(instructions.items, j)) {
                        break;
                    }

                    // Stop if we hit our target
                    if (j >= target) {
                        break;
                    }

                    // This instruction is unreachable, remove it
                    _ = instructions.orderedRemove(j);
                }
                break;
            }

            i += 1;
        }
    }

    /// Peephole Optimizations - local instruction pattern optimizations
    fn peepholeOptimizations(self: *Optimizer, instructions: *std.ArrayList(Instruction)) !void {
        _ = self;
        var i: usize = 0;
        while (i < instructions.items.len) {
            // Pattern: load var, store var (same var) -> nop (remove both)
            if (i + 1 < instructions.items.len) {
                const inst1 = instructions.items[i];
                const inst2 = instructions.items[i + 1];

                if (inst1.op == .load_var and inst2.op == .store_var) {
                    if (inst1.string_data != null and inst2.string_data != null) {
                        if (std.mem.eql(u8, inst1.string_data.?, inst2.string_data.?)) {
                            // Remove redundant load/store
                            _ = instructions.orderedRemove(i);
                            _ = instructions.orderedRemove(i);
                            continue;
                        }
                    }
                }

                // Pattern: push constant 0, add -> nop (remove both)
                if (inst1.op == .load_const_int and inst1.operand1 == 0 and inst2.op == .add) {
                    _ = instructions.orderedRemove(i);
                    _ = instructions.orderedRemove(i);
                    continue;
                }

                // Pattern: push constant 1, mul -> nop (remove both)
                if (inst1.op == .load_const_int and inst1.operand1 == 1 and inst2.op == .mul) {
                    _ = instructions.orderedRemove(i);
                    _ = instructions.orderedRemove(i);
                    continue;
                }

                // Pattern: dup, pop -> nop (remove both)
                if (inst1.op == .dup and inst2.op == .pop) {
                    _ = instructions.orderedRemove(i);
                    _ = instructions.orderedRemove(i);
                    continue;
                }
            }

            i += 1;
        }
    }

    /// Algebraic Simplifications - simplify algebraic expressions
    fn algebraicSimplifications(_: *Optimizer, instructions: *std.ArrayList(Instruction)) !void {
        var i: usize = 0;
        while (i < instructions.items.len) {
            if (i + 2 < instructions.items.len) {
                const inst1 = instructions.items[i];
                const inst2 = instructions.items[i + 1];
                const inst3 = instructions.items[i + 2];

                // Pattern: x - x = 0
                if (inst1.op == .load_var and inst2.op == .load_var and inst3.op == .sub) {
                    if (inst1.string_data != null and inst2.string_data != null) {
                        if (std.mem.eql(u8, inst1.string_data.?, inst2.string_data.?)) {
                            // Replace with load 0
                            instructions.items[i] = Instruction{
                                .op = .load_const_int,
                                .operand1 = 0,
                                .operand2 = 0,
                                .operand3 = 0,
                                .string_data = null,
                            };
                            _ = instructions.orderedRemove(i + 1);
                            _ = instructions.orderedRemove(i + 1);
                            continue;
                        }
                    }
                }

                // Pattern: x * 0 = 0 or 0 * x = 0
                if (inst3.op == .mul) {
                    if ((inst1.op == .load_const_int and inst1.operand1 == 0) or
                        (inst2.op == .load_const_int and inst2.operand1 == 0))
                    {
                        // Replace with load 0
                        instructions.items[i] = Instruction{
                            .op = .load_const_int,
                            .operand1 = 0,
                            .operand2 = 0,
                            .operand3 = 0,
                            .string_data = null,
                        };
                        _ = instructions.orderedRemove(i + 1);
                        _ = instructions.orderedRemove(i + 1);
                        continue;
                    }
                }

                // Pattern: x / x = 1 (for non-zero x)
                if (inst1.op == .load_var and inst2.op == .load_var and inst3.op == .div) {
                    if (inst1.string_data != null and inst2.string_data != null) {
                        if (std.mem.eql(u8, inst1.string_data.?, inst2.string_data.?)) {
                            // Replace with load 1 (assuming non-zero)
                            instructions.items[i] = Instruction{
                                .op = .load_const_int,
                                .operand1 = 1,
                                .operand2 = 0,
                                .operand3 = 0,
                                .string_data = null,
                            };
                            _ = instructions.orderedRemove(i + 1);
                            _ = instructions.orderedRemove(i + 1);
                            continue;
                        }
                    }
                }
            }
            i += 1;
        }
    }

    /// Copy Propagation - replace variable loads with their known values
    fn copyPropagation(_: *Optimizer, instructions: *std.ArrayList(Instruction)) !void {
        var value_map = std.StringHashMap(i64).init(std.heap.page_allocator);
        defer value_map.deinit();

        var i: usize = 0;
        while (i < instructions.items.len) {
            const inst = instructions.items[i];

            // Track constant assignments
            if (i > 0) {
                const prev = instructions.items[i - 1];
                if (prev.op == .load_const_int and inst.op == .store_var) {
                    if (inst.string_data) |var_name| {
                        try value_map.put(var_name, prev.operand1);
                    }
                }
            }

            // Replace loads with known constant values
            if (inst.op == .load_var) {
                if (inst.string_data) |var_name| {
                    if (value_map.get(var_name)) |value| {
                        // Replace load_var with load_const_int
                        instructions.items[i] = Instruction{
                            .op = .load_const_int,
                            .operand1 = value,
                            .operand2 = 0,
                            .operand3 = 0,
                            .string_data = null,
                        };
                    }
                }
            }

            // Invalidate on reassignment
            if (inst.op == .store_var) {
                if (inst.string_data) |var_name| {
                    _ = value_map.remove(var_name);
                }
            }

            i += 1;
        }
    }

    /// Common Subexpression Elimination - avoid recomputing same expressions
    fn commonSubexpressionElimination(_: *Optimizer, instructions: *std.ArrayList(Instruction)) !void {
        // Simple CSE: detect duplicate load sequences
        var i: usize = 0;
        while (i + 5 < instructions.items.len) {
            // Look for pattern: load a, load b, op, ... , load a, load b, op
            const seq1_1 = instructions.items[i];
            const seq1_2 = instructions.items[i + 1];
            const seq1_3 = instructions.items[i + 2];

            if (!isConstantLoad(seq1_1) or !isConstantLoad(seq1_2)) {
                i += 1;
                continue;
            }

            // Search for duplicate sequence
            var j = i + 3;
            while (j + 2 < instructions.items.len) {
                const seq2_1 = instructions.items[j];
                const seq2_2 = instructions.items[j + 1];
                const seq2_3 = instructions.items[j + 2];

                // Check if sequences match
                if (seq1_1.op == seq2_1.op and seq1_1.operand1 == seq2_1.operand1 and
                    seq1_2.op == seq2_2.op and seq1_2.operand1 == seq2_2.operand1 and
                    seq1_3.op == seq2_3.op)
                {
                    // Found duplicate - could optimize by storing result
                    // Stack IR cannot safely reuse this expression without an
                    // explicit value location, so leave it unchanged.
                    break;
                }
                j += 1;
            }

            i += 1;
        }
    }

    /// Redundant Load/Store Elimination - remove unnecessary memory operations
    fn redundantLoadStoreElimination(self: *Optimizer, instructions: *std.ArrayList(Instruction)) !void {
        var i: usize = 0;
        while (i + 1 < instructions.items.len) {
            const inst1 = instructions.items[i];
            const inst2 = instructions.items[i + 1];

            // Pattern: store x, load x -> store x (keep value on stack)
            if (inst1.op == .store_var and inst2.op == .load_var) {
                if (inst1.string_data != null and inst2.string_data != null) {
                    if (std.mem.eql(u8, inst1.string_data.?, inst2.string_data.?)) {
                        // Insert dup before store, remove load
                        const dup_inst = Instruction{
                            .op = .dup,
                            .operand1 = 0,
                            .operand2 = 0,
                            .operand3 = 0,
                            .string_data = null,
                        };
                        try instructions.insert(self.allocator, i, dup_inst);
                        _ = instructions.orderedRemove(i + 2); // Remove the load
                        continue;
                    }
                }
            }

            // Pattern: store x, store x -> store x (remove first)
            if (inst1.op == .store_var and inst2.op == .store_var) {
                if (inst1.string_data != null and inst2.string_data != null) {
                    if (std.mem.eql(u8, inst1.string_data.?, inst2.string_data.?)) {
                        _ = instructions.orderedRemove(i);
                        continue;
                    }
                }
            }

            i += 1;
        }
    }
};

/// Check if instruction is a constant load
fn isConstantLoad(inst: Instruction) bool {
    return inst.op == .load_const_int or
        inst.op == .load_const_float or
        inst.op == .load_const_bool;
}

/// Check if operation can be folded at compile time
fn isFoldableOp(op: Opcode) bool {
    return op == .add or op == .sub or op == .mul or op == .div or op == .mod;
}

/// Try to fold a constant operation
fn tryFoldOperation(inst1: Instruction, inst2: Instruction, inst3: Instruction) ?Instruction {
    // Integer folding is exact and checked; float operations remain in IR so
    // every execution backend applies the same runtime semantics.
    if (inst1.op != .load_const_int or inst2.op != .load_const_int) {
        return null;
    }

    const a = inst1.operand1;
    const b = inst2.operand1;

    const result: i64 = switch (inst3.op) {
        .add => checked_int.add(a, b) catch return null,
        .sub => checked_int.sub(a, b) catch return null,
        .mul => checked_int.mul(a, b) catch return null,
        .div => checked_int.div(a, b) catch return null,
        .mod => checked_int.mod(a, b) catch return null,
        else => return null,
    };

    return Instruction{
        .op = .load_const_int,
        .operand1 = result,
        .operand2 = 0,
        .operand3 = 0,
        .string_data = null,
    };
}

/// Check if an instruction position is a jump target
fn isJumpTarget(instructions: []Instruction, pos: usize) bool {
    for (instructions) |inst| {
        if (inst.op == .jump or inst.op == .jump_if_false or inst.op == .jump_if_true) {
            if (inst.operand1 == @as(i64, @intCast(pos))) {
                return true;
            }
        }
    }
    return false;
}
