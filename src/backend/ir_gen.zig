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

    pub fn init(allocator: std.mem.Allocator) IrGenerator {
        return .{
            .allocator = allocator,
            .builder = ir.Builder.init(allocator),
            .functions = std.ArrayList(ir.Function).initCapacity(allocator, 0) catch @panic("OOM"),
            .current_function = null,
            .break_stack = std.ArrayList(usize).initCapacity(allocator, 0) catch @panic("OOM"),
            .continue_stack = std.ArrayList(usize).initCapacity(allocator, 0) catch @panic("OOM"),
            .modules = std.ArrayList(ir.Program.Module).initCapacity(allocator, 0) catch @panic("OOM"),
            .imported_symbols = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *IrGenerator) void {
        self.builder.deinit();
        self.functions.deinit(self.allocator);
        self.break_stack.deinit(self.allocator);
        self.continue_stack.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.imported_symbols.deinit();
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
                // Save current instructions for later function creation
                const saved_instructions = try self.builder.instructions.toOwnedSlice(self.allocator);

                // Generate function body
                self.current_function = decl.name;
                try self.genExpr(decl.body);
                try self.builder.emit(.ret, 0, 0, 0);

                // Create function
                const func_instructions = try self.builder.instructions.toOwnedSlice(self.allocator);

                // Determine if function is generic
                const is_generic = decl.type_params.len > 0;

                // Extract parameter names
                var param_names = try self.allocator.alloc([]const u8, decl.parameters.len);
                for (decl.parameters, 0..) |param, i| {
                    param_names[i] = param.name;
                }

                try self.functions.append(self.allocator, .{
                    .name = decl.name,
                    .param_count = decl.parameters.len,
                    .param_names = param_names,
                    .local_count = 0, // TODO: compute this
                    .instructions = func_instructions,
                    .type_params = decl.type_params,
                    .is_generic = is_generic,
                });
                // Restore instructions
                self.builder.instructions = std.ArrayList(ir.Instruction).initCapacity(self.allocator, 0) catch @panic("OOM");
                try self.builder.instructions.appendSlice(self.allocator, saved_instructions);
                self.allocator.free(saved_instructions);

                self.current_function = null;
            },
            .return_stmt => |expr| {
                try self.genExpr(expr);
                try self.builder.emit(.ret, 0, 0, 0);
            },
            .struct_decl => {
                // Structs are handled at compile-time, no IR needed
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

                // Generate each field value
                for (struct_init.fields) |field| {
                    // Push field name and value
                    const field_idx = try self.builder.internString(field.name);
                    try self.genExpr(field.value);
                    try self.builder.emit(.field_set, @intCast(field_idx), 0, 0);
                }
            },
            .field_access => |access| {
                // Generate the object
                try self.genExpr(access.object);

                // Access the field
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
