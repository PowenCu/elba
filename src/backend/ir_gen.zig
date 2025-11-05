const std = @import("std");
const ir = @import("ir.zig");
const ast = @import("../frontend/ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Type = ast.Type;

/// Generates IR from AST
pub const IrGenerator = struct {
    allocator: std.mem.Allocator,
    builder: ir.Builder,
    functions: std.ArrayList(ir.Function),
    current_function: ?[]const u8,
    break_stack: std.ArrayList(usize),
    continue_stack: std.ArrayList(usize),
    modules: std.ArrayList(ir.Program.Module),
    imported_symbols: std.StringHashMap([]const u8), // symbol -> module name
    struct_types: std.StringHashMap([]const []const u8), // struct_name -> field_names

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
            .struct_types = std.StringHashMap([]const []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *IrGenerator) void {
        self.builder.deinit();
        self.functions.deinit(self.allocator);
        self.break_stack.deinit(self.allocator);
        self.continue_stack.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.imported_symbols.deinit();

        // Clean up struct_types
        var iter = self.struct_types.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.struct_types.deinit();
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

    /// Generate IR for a statement
    pub fn genStmt(self: *IrGenerator, stmt: *const Stmt) !void {
        switch (stmt.*) {
            .const_decl, .let_decl => |decl| {
                // Evaluate the value
                try self.genExpr(decl.value);
                // Store to variable
                try self.builder.emitWithString(.store_var, decl.name, 0, 0);
            },
            .expr_stmt => |expr| {
                try self.genExpr(expr);
                // Pop the result since it's not used
                try self.builder.emit(.pop, 0, 0, 0);
            },
            .fn_decl => |decl| {
                const saved_instructions = try self.stashInstructions();
                var restored = false;
                defer if (!restored) {
                    self.restoreInstructions(saved_instructions) catch @panic("failed to restore IR builder state");
                };

                self.current_function = decl.name;
                defer self.current_function = null;

                try self.genExpr(decl.body);
                try self.builder.emit(.ret, 0, 0, 0);

                const func_instructions = try self.builder.instructions.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(func_instructions);

                const is_generic = decl.type_params.len > 0;
                const param_names = try self.copyParamNames(decl.parameters);
                errdefer self.allocator.free(param_names);

                // Compute local variable count by analyzing instructions
                const local_count = countLocalVariables(func_instructions, param_names);

                try self.functions.append(self.allocator, .{
                    .name = decl.name,
                    .param_count = decl.parameters.len,
                    .param_names = param_names,
                    .local_count = local_count,
                    .instructions = func_instructions,
                    .type_params = decl.type_params,
                    .is_generic = is_generic,
                });
                try self.restoreInstructions(saved_instructions);
                restored = true;
            },
            .return_stmt => |expr| {
                try self.genExpr(expr);
                try self.builder.emit(.ret, 0, 0, 0);
            },
            .struct_decl => |decl| {
                // Register struct type with field names for proper field index mapping
                var field_names = try self.allocator.alloc([]const u8, decl.fields.len);
                for (decl.fields, 0..) |field, i| {
                    field_names[i] = field.name;
                }
                try self.struct_types.put(decl.name, field_names);

                // Register in builder for IR generation
                try self.builder.registerStructType(decl.name, field_names);

                // NOTE: Struct methods are currently handled at AST interpretation level.
                // To lower methods to IR, we need to:
                // 1. Decide on calling convention (self as first param vs vtable)
                // 2. Name mangling scheme (Type_method vs type.method)
                // 3. Handle generic struct methods with monomorphization
                // For now, methods work fine in the AST interpreter.
            },
            .type_alias => {
                // Type aliases are compile-time only
            },
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
                    // Import all - will be resolved during linking
                    // NOTE: Wildcard imports require module loader to:
                    // 1. Parse the imported module to extract all exported symbols
                    // 2. Populate module.exports array with symbol names
                    // 3. Add each symbol to imported_symbols map
                    // Current module system handles selective imports; wildcard support
                    // would need parser integration to enumerate exports.
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
                try self.builder.emit(.load_const_float, @intCast(bits), 0, 0);
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
                try self.builder.emit(op, 0, 0, 0);
            },
            .unary => |unop| {
                try self.genExpr(unop.operand);

                const op: ir.Opcode = switch (unop.op) {
                    .negate => .neg,
                    .logical_not => .not_op,
                };
                try self.builder.emit(op, 0, 0, 0);
            },
            .fn_call => |call| {
                // Generate arguments
                for (call.arguments) |arg| {
                    try self.genExpr(arg);
                }

                // Call function
                try self.builder.emitWithString(.call, call.name, @intCast(call.arguments.len), 0);
            },
            .assignment => |assign| {
                try self.genExpr(assign.value);
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
                } else if (block.statements.len == 0) {
                    // If block is empty, push unit value
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
                try self.genExpr(while_expr.body);
                // Note: Block expressions handle their own cleanup, don't pop here

                // Jump back to start
                try self.builder.emit(.jump, @intCast(loop_start), 0, 0);

                // Patch exit jump
                const after_loop = self.builder.position();
                self.builder.patchJump(jump_out, after_loop);

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
                    try self.genExpr(field.value);
                    try self.builder.emit(.field_set, @intCast(field_idx), 0, 0);
                }
            },
            .field_access => |access| {
                // Generate the object
                try self.genExpr(access.object);

                // Access the field
                // Note: Without runtime type info, we use global field name interning
                // This works for single struct types but may conflict with multiple structs
                // having same field names. A proper fix requires passing type info through IR.
                const field_idx = try self.builder.internString(access.field_name);
                try self.builder.emit(.field_get, @intCast(field_idx), 0, 0);
            },
            .method_call => |call| {
                // Generate receiver (self)
                try self.genExpr(call.receiver);

                // Generate arguments
                for (call.arguments) |arg| {
                    try self.genExpr(arg);
                }

                // Call method (receiver is first argument)
                try self.builder.emitWithString(.call, call.method_name, @intCast(call.arguments.len + 1), // +1 for self
                    0);
            },
            .array_literal => |array| {
                // Push array size
                try self.builder.emit(.array_new, @intCast(array.elements.len), 0, 0);

                // Generate each element
                for (array.elements, 0..) |elem, i| {
                    try self.builder.emit(.dup, 0, 0, 0); // Duplicate array reference
                    try self.builder.emit(.load_const_int, @intCast(i), 0, 0); // Index
                    try self.genExpr(elem); // Value
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
                // Generate the expression to check
                try self.genExpr(check.expr);

                // Type check operation
                // We'll encode the type in operand1 (simplified for now)
                const type_id: i64 = switch (check.check_type) {
                    .int => 1,
                    .float => 2,
                    .string => 3,
                    .bool => 4,
                    else => 0,
                };

                try self.builder.emit(.type_check, type_id, if (check.is_not) 1 else 0, 0);
            },
            .for_expr => |for_expr| {
                // For now, lower for loops to while loops in IR
                // This is a simplified implementation
                // A proper implementation would add for_loop opcode

                // Evaluate iterable
                try self.genExpr(for_expr.iterable);

                // Store in temporary (we'll use a generated temp variable)
                const temp_name = "__for_temp__";
                try self.builder.emitWithString(.store_var, temp_name, 0, 0);

                // Initialize index to 0
                try self.builder.emit(.load_const_int, 0, 0, 0);
                const index_var = "__for_index__";
                try self.builder.emitWithString(.store_var, index_var, 0, 0);

                // Loop start
                const loop_start = self.builder.position();

                // Check if index < length
                try self.builder.emitWithString(.load_var, index_var, 0, 0);
                try self.builder.emitWithString(.load_var, temp_name, 0, 0);
                // TODO: Add array_len opcode or call builtin
                // For now, this is incomplete - would need runtime support

                // Jump out if done
                const jump_out = self.builder.position();
                try self.builder.emit(.jump_if_false, 0, 0, 0);

                // Load current element into iterator variable
                try self.builder.emitWithString(.load_var, temp_name, 0, 0);
                try self.builder.emitWithString(.load_var, index_var, 0, 0);
                try self.builder.emit(.array_get, 0, 0, 0);
                try self.builder.emitWithString(.store_var, for_expr.iterator, 0, 0);

                // Execute body
                try self.genExpr(for_expr.body);
                try self.builder.emit(.pop, 0, 0, 0); // Pop body result

                // Increment index
                try self.builder.emitWithString(.load_var, index_var, 0, 0);
                try self.builder.emit(.load_const_int, 1, 0, 0);
                try self.builder.emit(.add, 0, 0, 0);
                try self.builder.emitWithString(.store_var, index_var, 0, 0);

                // Jump back to start
                try self.builder.emit(.jump, @intCast(loop_start), 0, 0);

                // Patch exit
                const after_loop = self.builder.position();
                self.builder.patchJump(jump_out, after_loop);

                // Push unit result
                try self.builder.emit(.load_null, 0, 0, 0);
            },
            .match_expr => |match_expr| {
                // Generate match expression value
                try self.genExpr(match_expr.expr);
                const match_temp = "__match_temp__";
                try self.builder.emitWithString(.store_var, match_temp, 0, 0);

                // Generate each arm
                var jump_to_end = std.ArrayList(usize).initCapacity(self.allocator, 4) catch unreachable;
                defer jump_to_end.deinit(self.allocator);

                for (match_expr.arms, 0..) |arm, i| {
                    const is_last = i == match_expr.arms.len - 1;

                    // Generate pattern match check
                    try self.builder.emitWithString(.load_var, match_temp, 0, 0);

                    // Simplified: only handle literal and wildcard patterns
                    const matches = switch (arm.pattern) {
                        .wildcard => true,
                        .variable => true,
                        .literal => false, // Would need comparison
                        .range => false, // Would need range check
                    };

                    var next_arm_jump: ?usize = null;

                    if (!matches and !is_last) {
                        // Jump to next arm if no match
                        try self.builder.emit(.pop, 0, 0, 0); // Pop match value
                        next_arm_jump = self.builder.position();
                        try self.builder.emit(.jump, 0, 0, 0);
                    }

                    // Bind pattern variable if needed
                    if (arm.pattern == .variable) {
                        try self.builder.emitWithString(.store_var, arm.pattern.variable, 0, 0);
                    } else {
                        try self.builder.emit(.pop, 0, 0, 0);
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
                try self.genExpr(assign.value);

                // Get field index
                const field_idx = try self.builder.internString(assign.field_name);
                try self.builder.emit(.field_set, @intCast(field_idx), 0, 0);

                // Push unit result
                try self.builder.emit(.load_null, 0, 0, 0);
            },
            .array_assignment => |assign| {
                // Generate array
                try self.genExpr(assign.array);

                // Generate index
                try self.genExpr(assign.index);

                // Generate value
                try self.genExpr(assign.value);

                // Set array element
                try self.builder.emit(.array_set, 0, 0, 0);

                // Push unit result
                try self.builder.emit(.load_null, 0, 0, 0);
            },
        }
    }

    /// Generate a complete IR program from a list of statements
    pub fn generate(self: *IrGenerator, statements: []const Stmt) !ir.Program {
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
