const std = @import("std");
const ir = @import("ir.zig");
const Instruction = ir.Instruction;
const Program = ir.Program;
const Function = ir.Function;
const Opcode = ir.Opcode;

// LLVM C API bindings
const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
    @cInclude("llvm-c/Analysis.h");
});

/// Error set for LLVM code generation
pub const Error = error{
    ModuleVerificationFailed,
    FunctionNotFound,
    UndefinedVariable,
    UndefinedFunction,
    UnimplementedInstruction,
    WriteFailed,
    TargetCreationFailed,
    ObjectEmissionFailed,
};

/// LLVM Code Generator - Compiles Elba IR to native machine code via LLVM
pub const LLVMCodeGen = struct {
    allocator: std.mem.Allocator,
    context: c.LLVMContextRef,
    module: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,

    // Type cache - commonly used LLVM types
    i64_type: c.LLVMTypeRef,
    f64_type: c.LLVMTypeRef,
    i1_type: c.LLVMTypeRef,
    i8_type: c.LLVMTypeRef,
    void_type: c.LLVMTypeRef,
    ptr_type: c.LLVMTypeRef,

    // Function registry - maps Elba function names to LLVM functions
    functions: std.StringHashMap(c.LLVMValueRef),

    // Current function compilation state
    current_function: ?c.LLVMValueRef,
    stack: std.ArrayList(c.LLVMValueRef),
    variables: std.StringHashMap(c.LLVMValueRef),
    variable_types: std.StringHashMap(c.LLVMTypeRef),
    string_literals: std.StringHashMap(c.LLVMValueRef),
    basic_blocks: std.StringHashMap(c.LLVMBasicBlockRef),
    // Temporary value slot for passing values across basic blocks
    temp_slot: ?c.LLVMValueRef,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, module_name: []const u8) !Self {
        // Initialize LLVM native target for code generation
        _ = c.LLVMInitializeNativeTarget();
        _ = c.LLVMInitializeNativeAsmPrinter();
        _ = c.LLVMInitializeNativeAsmParser();

        const context = c.LLVMContextCreate();
        const module_name_z = try allocator.dupeZ(u8, module_name);
        defer allocator.free(module_name_z);

        const module = c.LLVMModuleCreateWithNameInContext(module_name_z.ptr, context);
        const builder = c.LLVMCreateBuilderInContext(context);

        // Create commonly used LLVM types
        const i64_type = c.LLVMInt64TypeInContext(context);
        const f64_type = c.LLVMDoubleTypeInContext(context);
        const i1_type = c.LLVMInt1TypeInContext(context);
        const i8_type = c.LLVMInt8TypeInContext(context);
        const void_type = c.LLVMVoidTypeInContext(context);
        const ptr_type = c.LLVMPointerTypeInContext(context, 0);

        return Self{
            .allocator = allocator,
            .context = context,
            .module = module,
            .builder = builder,
            .i64_type = i64_type,
            .f64_type = f64_type,
            .i1_type = i1_type,
            .i8_type = i8_type,
            .void_type = void_type,
            .ptr_type = ptr_type,
            .functions = std.StringHashMap(c.LLVMValueRef).init(allocator),
            .current_function = null,
            .stack = try std.ArrayList(c.LLVMValueRef).initCapacity(allocator, 256),
            .variables = std.StringHashMap(c.LLVMValueRef).init(allocator),
            .variable_types = std.StringHashMap(c.LLVMTypeRef).init(allocator),
            .string_literals = std.StringHashMap(c.LLVMValueRef).init(allocator),
            .basic_blocks = std.StringHashMap(c.LLVMBasicBlockRef).init(allocator),
            .temp_slot = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.functions.deinit();
        self.stack.deinit(self.allocator);
        self.variables.deinit();
        self.variable_types.deinit();
        self.string_literals.deinit();

        // Free basic_blocks keys before deinit
        var bb_iter = self.basic_blocks.keyIterator();
        while (bb_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.basic_blocks.deinit();

        c.LLVMDisposeBuilder(self.builder);
        c.LLVMDisposeModule(self.module);
        c.LLVMContextDispose(self.context);
    }

    /// Generate LLVM IR from Elba IR program
    pub fn generate(self: *Self, program: Program) !void {
        // Declare built-in C library functions
        try self.declareBuiltins();

        // Forward declare all functions
        for (program.functions) |func| {
            try self.declareLLVMFunction(func);
        }

        // Generate function bodies
        for (program.functions) |func| {
            try self.generateFunction(func);
        }

        // Verify module
        var error_msg: [*c]u8 = undefined;
        if (c.LLVMVerifyModule(self.module, c.LLVMReturnStatusAction, &error_msg) != 0) {
            std.debug.print("LLVM module verification failed:\n{s}\n", .{error_msg});
            c.LLVMDisposeMessage(error_msg);
            return error.ModuleVerificationFailed;
        }
    }

    /// Helper to declare C library functions
    fn declareCFunction(
        self: *Self,
        name: []const u8,
        return_type: c.LLVMTypeRef,
        param_types: []const c.LLVMTypeRef,
        is_variadic: bool,
    ) !void {
        const func_type = c.LLVMFunctionType(
            return_type,
            @constCast(param_types.ptr),
            @intCast(param_types.len),
            if (is_variadic) 1 else 0,
        );
        const func = c.LLVMAddFunction(self.module, name.ptr, func_type);
        try self.functions.put(name, func);
    }

    fn declareBuiltins(self: *Self) !void {
        // printf - variadic print function
        try self.declareCFunction("printf", self.i64_type, &[_]c.LLVMTypeRef{self.ptr_type}, true);

        // malloc - memory allocation
        try self.declareCFunction("malloc", self.ptr_type, &[_]c.LLVMTypeRef{self.i64_type}, false);

        // free - memory deallocation
        try self.declareCFunction("free", self.void_type, &[_]c.LLVMTypeRef{self.ptr_type}, false);

        // String manipulation functions
        try self.declareStringFunctions();
    }

    fn declareStringFunctions(self: *Self) !void {
        // strlen - get string length
        try self.declareCFunction("strlen", self.i64_type, &[_]c.LLVMTypeRef{self.ptr_type}, false);

        // strcpy - copy string
        try self.declareCFunction("strcpy", self.ptr_type, &[_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type }, false);

        // strcat - concatenate strings
        try self.declareCFunction("strcat", self.ptr_type, &[_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type }, false);

        // snprintf - formatted string print (variadic)
        try self.declareCFunction("snprintf", self.i64_type, &[_]c.LLVMTypeRef{ self.ptr_type, self.i64_type, self.ptr_type }, true);
    }

    fn declareLLVMFunction(self: *Self, func: Function) !void {
        // Create function type
        const return_type = self.i64_type; // For now, all functions return i64

        var param_types = try self.allocator.alloc(c.LLVMTypeRef, func.param_count);
        defer self.allocator.free(param_types);

        for (0..func.param_count) |i| {
            param_types[i] = self.i64_type;
        }

        const func_type = c.LLVMFunctionType(
            return_type,
            param_types.ptr,
            @intCast(func.param_count),
            0,
        );

        // Convert function name to null-terminated string
        const func_name_z = try self.allocator.dupeZ(u8, func.name);
        defer self.allocator.free(func_name_z);

        const llvm_func = c.LLVMAddFunction(self.module, func_name_z.ptr, func_type);
        try self.functions.put(func.name, llvm_func);
    }

    fn generateFunction(self: *Self, func: Function) !void {
        const llvm_func = self.functions.get(func.name) orelse return error.FunctionNotFound;
        self.current_function = llvm_func;

        // Reset function-local state
        self.stack.clearRetainingCapacity();
        self.variables.clearRetainingCapacity();
        self.variable_types.clearRetainingCapacity();

        // Free basic_blocks keys before clearing
        var bb_iter = self.basic_blocks.keyIterator();
        while (bb_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.basic_blocks.clearRetainingCapacity();

        // Create entry block
        const entry_block = c.LLVMAppendBasicBlockInContext(
            self.context,
            llvm_func,
            "entry",
        );

        // Pre-scan to find all labels and create basic blocks
        var label_set = std.AutoHashMap(i64, void).init(self.allocator);
        defer label_set.deinit();

        for (func.instructions) |inst| {
            switch (inst.op) {
                .jump, .jump_if_false, .jump_if_true => {
                    try label_set.put(inst.operand1, {});
                },
                else => {},
            }
        }

        // Create basic blocks for all labels
        var label_iter = label_set.keyIterator();
        while (label_iter.next()) |label_id| {
            const label_name = try std.fmt.allocPrint(self.allocator, "L{d}", .{label_id.*});
            // Keep label_name for HashMap key - will be freed when basic_blocks is cleared

            const label_name_z = try self.allocator.dupeZ(u8, label_name);
            defer self.allocator.free(label_name_z);

            const block = c.LLVMAppendBasicBlockInContext(self.context, llvm_func, label_name_z.ptr);
            try self.basic_blocks.put(label_name, block);
        }

        // Position at entry and set up parameters
        c.LLVMPositionBuilderAtEnd(self.builder, entry_block);

        // Create a temporary slot for passing values across basic blocks
        self.temp_slot = c.LLVMBuildAlloca(self.builder, self.i64_type, "temp");

        // Allocate space for parameters (use actual parameter names from IR)
        for (0..func.param_count) |i| {
            const param = c.LLVMGetParam(llvm_func, @intCast(i));

            // Use actual parameter name if available, otherwise fallback to param{n}
            const param_name = if (i < func.param_names.len)
                func.param_names[i]
            else
                try std.fmt.allocPrint(self.allocator, "param{d}", .{i});

            const needs_free = i >= func.param_names.len;
            defer if (needs_free) self.allocator.free(param_name);

            const param_name_z = try self.allocator.dupeZ(u8, param_name);
            defer self.allocator.free(param_name_z);

            const alloca = c.LLVMBuildAlloca(self.builder, self.i64_type, param_name_z.ptr);
            _ = c.LLVMBuildStore(self.builder, param, alloca);
            try self.variables.put(param_name, alloca);
            try self.variable_types.put(param_name, self.i64_type);
        }

        // Generate instructions with label handling
        var current_label: ?i64 = null;
        for (func.instructions, 0..) |inst, idx| {
            // Check if NEXT instruction is a label target
            const next_idx = idx + 1;
            const next_is_label = if (next_idx < func.instructions.len)
                label_set.contains(@intCast(next_idx))
            else
                false;

            // Check if THIS instruction is a label target
            if (label_set.contains(@intCast(idx))) {
                // We're at a label - need to position builder
                const label_name = try std.fmt.allocPrint(self.allocator, "L{d}", .{idx});
                defer self.allocator.free(label_name);

                if (self.basic_blocks.get(label_name)) |label_block| {
                    // Check if current block needs terminator before jumping to label
                    const current_block = c.LLVMGetInsertBlock(self.builder);
                    if (c.LLVMGetBasicBlockTerminator(current_block) == null) {
                        // Save stack value if any before branching
                        if (self.stack.items.len > 0 and self.temp_slot != null) {
                            const value = self.stack.items[self.stack.items.len - 1];
                            _ = c.LLVMBuildStore(self.builder, value, self.temp_slot.?);
                        }
                        // Add unconditional branch to the label
                        _ = c.LLVMBuildBr(self.builder, label_block);
                    }

                    // Position builder at the label block
                    c.LLVMPositionBuilderAtEnd(self.builder, label_block);
                    current_label = @intCast(idx);

                    // Load value from temp_slot if coming from a jump
                    if (self.temp_slot) |slot| {
                        const loaded = c.LLVMBuildLoad2(self.builder, self.i64_type, slot, "temp_load");
                        // Push the loaded value onto stack
                        try self.stack.append(self.allocator, loaded);
                    }
                }
            }

            try self.generateInstruction(inst);

            // If next instruction is a label and current block has no terminator, save stack value
            if (next_is_label and self.temp_slot != null) {
                const current_block = c.LLVMGetInsertBlock(self.builder);
                if (c.LLVMGetBasicBlockTerminator(current_block) == null and self.stack.items.len > 0) {
                    const value = self.stack.items[self.stack.items.len - 1];
                    _ = c.LLVMBuildStore(self.builder, value, self.temp_slot.?);
                }
            }
        }

        // Add default return if missing
        const final_block = c.LLVMGetInsertBlock(self.builder);
        if (c.LLVMGetBasicBlockTerminator(final_block) == null) {
            const zero = c.LLVMConstInt(self.i64_type, 0, 0);
            _ = c.LLVMBuildRet(self.builder, zero);
        }

        self.current_function = null;
    }

    fn generateInstruction(self: *Self, inst: Instruction) !void {
        switch (inst.op) {
            .load_const_int => {
                const value = c.LLVMConstInt(self.i64_type, @bitCast(inst.operand1), 0);
                try self.stack.append(self.allocator, value);
            },
            .load_const_float => {
                const value = c.LLVMConstReal(self.f64_type, @bitCast(inst.operand1));
                try self.stack.append(self.allocator, value);
            },
            .load_const_str => {
                if (inst.string_data) |str| {
                    const str_value = try self.createStringConstant(str);
                    try self.stack.append(self.allocator, str_value);
                }
            },
            .load_null => {
                const null_value = c.LLVMConstNull(self.ptr_type);
                try self.stack.append(self.allocator, null_value);
            },
            .load_var => {
                if (inst.string_data) |var_name| {
                    const alloca = self.variables.get(var_name) orelse return error.UndefinedVariable;
                    const elem_ty = self.variable_types.get(var_name) orelse self.i64_type;
                    const loaded = c.LLVMBuildLoad2(self.builder, elem_ty, alloca, "load_var");
                    try self.stack.append(self.allocator, loaded);
                }
            },
            .store_var => |_| {
                if (inst.string_data) |var_name| {
                    const value = self.stack.pop() orelse unreachable;
                    const val_ty = c.LLVMTypeOf(value);

                    if (self.variables.get(var_name)) |alloca| {
                        // Existing variable: ensure stored type matches expected; if we tracked a different
                        // type, we still attempt the store (LLVM will catch mismatches during verify).
                        _ = c.LLVMBuildStore(self.builder, value, alloca);
                        // Update recorded type to current value type for subsequent loads
                        try self.variable_types.put(var_name, val_ty);
                    } else {
                        // Create new variable with element type matching the value
                        // Use a sanitized name for the alloca label: we expect var_name may not be nul-terminated
                        const var_name_z = self.allocator.dupeZ(u8, var_name) catch null;
                        defer if (var_name_z) |p| self.allocator.free(p);
                        const name_ptr: [*:0]const u8 = if (var_name_z) |p| p.ptr else "var";
                        const alloca = c.LLVMBuildAlloca(self.builder, val_ty, name_ptr);
                        _ = c.LLVMBuildStore(self.builder, value, alloca);
                        try self.variables.put(var_name, alloca);
                        try self.variable_types.put(var_name, val_ty);
                    }
                }
            },
            .add => try self.generateBinaryOp(.add),
            .sub => try self.generateBinaryOp(.sub),
            .mul => try self.generateBinaryOp(.mul),
            .div => try self.generateBinaryOp(.div),
            .mod => try self.generateBinaryOp(.mod),
            .eq => try self.generateCompareOp(.eq),
            .neq => try self.generateCompareOp(.neq),
            .lt => try self.generateCompareOp(.lt),
            .lte => try self.generateCompareOp(.lte),
            .gt => try self.generateCompareOp(.gt),
            .gte => try self.generateCompareOp(.gte),
            .and_op => try self.generateLogicalOp(.and_op),
            .or_op => try self.generateLogicalOp(.or_op),
            .not_op => {
                const value = self.stack.pop() orelse unreachable;
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, value, zero, "not");
                const result = c.LLVMBuildZExt(self.builder, cmp, self.i64_type, "not_ext");
                try self.stack.append(self.allocator, result);
            },
            .neg => {
                const value = self.stack.pop() orelse unreachable;
                const result = c.LLVMBuildNeg(self.builder, value, "neg");
                try self.stack.append(self.allocator, result);
            },
            .jump => {
                // Save stack top to temp_slot before jumping (if there's a value on stack)
                if (self.stack.items.len > 0 and self.temp_slot != null) {
                    const value = self.stack.items[self.stack.items.len - 1];
                    _ = c.LLVMBuildStore(self.builder, value, self.temp_slot.?);
                }

                const target_label = try std.fmt.allocPrint(self.allocator, "L{d}", .{inst.operand1});
                defer self.allocator.free(target_label);

                if (self.basic_blocks.get(target_label)) |target_block| {
                    _ = c.LLVMBuildBr(self.builder, target_block);
                }
            },
            .jump_if_false => {
                const condition = self.stack.pop() orelse unreachable;
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, condition, zero, "is_false");

                const true_label = try std.fmt.allocPrint(self.allocator, "L{d}", .{inst.operand1});
                defer self.allocator.free(true_label);

                // Create a "continue" block for fall-through
                const continue_label = try std.fmt.allocPrint(self.allocator, "continue{d}", .{inst.operand1});
                defer self.allocator.free(continue_label);
                const continue_label_z = try self.allocator.dupeZ(u8, continue_label);
                defer self.allocator.free(continue_label_z);

                const true_block = self.basic_blocks.get(true_label) orelse unreachable;
                const continue_block = c.LLVMAppendBasicBlockInContext(self.context, self.current_function.?, continue_label_z.ptr);

                _ = c.LLVMBuildCondBr(self.builder, cmp, true_block, continue_block);
                c.LLVMPositionBuilderAtEnd(self.builder, continue_block);
            },
            .call => {
                if (inst.string_data) |func_name| {
                    try self.generateCall(func_name, inst.operand2);
                }
            },
            .ret => {
                if (self.stack.items.len > 0) {
                    const value = self.stack.pop() orelse unreachable;
                    _ = c.LLVMBuildRet(self.builder, value);
                } else {
                    const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                    _ = c.LLVMBuildRet(self.builder, zero);
                }
            },
            .pop => {
                _ = self.stack.pop() orelse unreachable;
            },
            .dup => {
                const value = self.stack.items[self.stack.items.len - 1];
                try self.stack.append(self.allocator, value);
            },
            .halt => {
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                _ = c.LLVMBuildRet(self.builder, zero);
            },
            .array_new => {
                // Create array: allocate (size + 1) * 8 bytes (size + elements)
                const size = c.LLVMConstInt(self.i64_type, @bitCast(inst.operand1), 0);

                // Calculate total bytes: (size + 1) * 8
                const one = c.LLVMConstInt(self.i64_type, 1, 0);
                const size_plus_one = c.LLVMBuildAdd(self.builder, size, one, "size_plus_one");
                const eight = c.LLVMConstInt(self.i64_type, 8, 0);
                const total_bytes = c.LLVMBuildMul(self.builder, size_plus_one, eight, "total_bytes");

                // Get malloc function
                const malloc_fn = blk: {
                    if (self.functions.get("malloc")) |fn_val| {
                        break :blk fn_val;
                    }
                    var param_types = [_]c.LLVMTypeRef{self.i64_type};
                    const malloc_type = c.LLVMFunctionType(self.ptr_type, param_types[0..].ptr, 1, 0);
                    const malloc_func = c.LLVMAddFunction(self.module, "malloc", malloc_type);
                    try self.functions.put("malloc", malloc_func);
                    break :blk malloc_func;
                };

                var param_types2 = [_]c.LLVMTypeRef{self.i64_type};
                const malloc_type = c.LLVMFunctionType(self.ptr_type, param_types2[0..].ptr, 1, 0);
                var args = [_]c.LLVMValueRef{total_bytes};
                const arr_ptr = c.LLVMBuildCall2(self.builder, malloc_type, malloc_fn, args[0..].ptr, 1, "arr");

                // Store size at index 0
                const size_ptr = c.LLVMBuildBitCast(self.builder, arr_ptr, c.LLVMPointerTypeInContext(self.context, 0), "size_ptr");
                _ = c.LLVMBuildStore(self.builder, size, size_ptr);

                // Convert pointer to i64 for stack storage (since our stack is i64-based)
                const arr_as_i64 = c.LLVMBuildPtrToInt(self.builder, arr_ptr, self.i64_type, "arr_as_i64");
                try self.stack.append(self.allocator, arr_as_i64);
            },
            .array_get => {
                // Pop index and array pointer
                const index = self.stack.pop() orelse unreachable;
                const arr_val = self.stack.pop() orelse unreachable;

                // Convert i64 to pointer if needed
                const arr_ptr = if (c.LLVMTypeOf(arr_val) == self.ptr_type)
                    arr_val
                else
                    c.LLVMBuildIntToPtr(self.builder, arr_val, self.ptr_type, "arr_ptr");

                // Calculate offset: index + 1 (skip size element)
                const one = c.LLVMConstInt(self.i64_type, 1, 0);
                const offset = c.LLVMBuildAdd(self.builder, index, one, "offset");

                // GEP to get element pointer
                var indices = [_]c.LLVMValueRef{offset};
                const elem_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, arr_ptr, indices[0..].ptr, 1, "elem_ptr");

                // Load value
                const value = c.LLVMBuildLoad2(self.builder, self.i64_type, elem_ptr, "arr_elem");
                try self.stack.append(self.allocator, value);
            },
            .array_set => {
                // Pop value, index, and array pointer
                const value = self.stack.pop() orelse unreachable;
                const index = self.stack.pop() orelse unreachable;
                const arr_val = self.stack.pop() orelse unreachable;

                // Convert i64 to pointer if needed
                const arr_ptr = if (c.LLVMTypeOf(arr_val) == self.ptr_type)
                    arr_val
                else
                    c.LLVMBuildIntToPtr(self.builder, arr_val, self.ptr_type, "arr_ptr");

                // Calculate offset: index + 1 (skip size element)
                const one = c.LLVMConstInt(self.i64_type, 1, 0);
                const offset = c.LLVMBuildAdd(self.builder, index, one, "offset");

                // GEP to get element pointer
                var indices = [_]c.LLVMValueRef{offset};
                const elem_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, arr_ptr, indices[0..].ptr, 1, "elem_ptr");

                // Store value
                _ = c.LLVMBuildStore(self.builder, value, elem_ptr);
            },
            .struct_new => {
                // Create struct: allocate field_count * 8 bytes
                const field_count = c.LLVMConstInt(self.i64_type, @bitCast(inst.operand1), 0);

                // Calculate total bytes: field_count * 8
                const eight = c.LLVMConstInt(self.i64_type, 8, 0);
                const total_bytes = c.LLVMBuildMul(self.builder, field_count, eight, "total_bytes");

                // Get malloc function
                const malloc_fn = blk: {
                    if (self.functions.get("malloc")) |fn_val| {
                        break :blk fn_val;
                    }
                    var param_types = [_]c.LLVMTypeRef{self.i64_type};
                    const malloc_type = c.LLVMFunctionType(self.ptr_type, param_types[0..].ptr, 1, 0);
                    const malloc_func = c.LLVMAddFunction(self.module, "malloc", malloc_type);
                    try self.functions.put("malloc", malloc_func);
                    break :blk malloc_func;
                };

                var param_types2 = [_]c.LLVMTypeRef{self.i64_type};
                const malloc_type = c.LLVMFunctionType(self.ptr_type, param_types2[0..].ptr, 1, 0);
                var args = [_]c.LLVMValueRef{total_bytes};
                const struct_ptr = c.LLVMBuildCall2(self.builder, malloc_type, malloc_fn, args[0..].ptr, 1, "struct");

                // Convert pointer to i64 for stack storage
                const struct_as_i64 = c.LLVMBuildPtrToInt(self.builder, struct_ptr, self.i64_type, "struct_as_i64");
                try self.stack.append(self.allocator, struct_as_i64);
            },
            .field_get => {
                // Pop struct pointer and get field
                const struct_val = self.stack.pop() orelse unreachable;

                // Convert i64 to pointer if needed
                const struct_ptr = if (c.LLVMTypeOf(struct_val) == self.ptr_type)
                    struct_val
                else
                    c.LLVMBuildIntToPtr(self.builder, struct_val, self.ptr_type, "struct_ptr");

                // Get field index
                const field_idx = c.LLVMConstInt(self.i64_type, @bitCast(inst.operand1), 0);

                // GEP to get field pointer
                var indices = [_]c.LLVMValueRef{field_idx};
                const field_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, struct_ptr, indices[0..].ptr, 1, "field_ptr");

                // Load value
                const value = c.LLVMBuildLoad2(self.builder, self.i64_type, field_ptr, "field_val");
                try self.stack.append(self.allocator, value);
            },
            .field_set => {
                // Pop value and struct pointer
                const value = self.stack.pop() orelse unreachable;
                const struct_val = self.stack.pop() orelse unreachable;

                // Convert i64 to pointer if needed
                const struct_ptr = if (c.LLVMTypeOf(struct_val) == self.ptr_type)
                    struct_val
                else
                    c.LLVMBuildIntToPtr(self.builder, struct_val, self.ptr_type, "struct_ptr");

                // Get field index
                const field_idx = c.LLVMConstInt(self.i64_type, @bitCast(inst.operand1), 0);

                // GEP to get field pointer
                var indices = [_]c.LLVMValueRef{field_idx};
                const field_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, struct_ptr, indices[0..].ptr, 1, "field_ptr");

                // Store value
                _ = c.LLVMBuildStore(self.builder, value, field_ptr);

                // Push struct back onto stack for chaining
                try self.stack.append(self.allocator, struct_val);
            },
            else => {
                std.debug.print("Unimplemented LLVM instruction: {s}\n", .{@tagName(inst.op)});
                return error.UnimplementedInstruction;
            },
        }
    }

    fn generateBinaryOp(self: *Self, op: Opcode) !void {
        const right = self.stack.pop() orelse unreachable;
        const left = self.stack.pop() orelse unreachable;

        const result = switch (op) {
            .add => c.LLVMBuildAdd(self.builder, left, right, "add"),
            .sub => c.LLVMBuildSub(self.builder, left, right, "sub"),
            .mul => c.LLVMBuildMul(self.builder, left, right, "mul"),
            .div => c.LLVMBuildSDiv(self.builder, left, right, "div"),
            .mod => c.LLVMBuildSRem(self.builder, left, right, "mod"),
            else => unreachable,
        };

        try self.stack.append(self.allocator, result);
    }

    fn generateCompareOp(self: *Self, op: Opcode) !void {
        const right = self.stack.pop() orelse unreachable;
        const left = self.stack.pop() orelse unreachable;

        const predicate: c.LLVMIntPredicate = switch (op) {
            .eq => c.LLVMIntEQ,
            .neq => c.LLVMIntNE,
            .lt => c.LLVMIntSLT,
            .lte => c.LLVMIntSLE,
            .gt => c.LLVMIntSGT,
            .gte => c.LLVMIntSGE,
            else => unreachable,
        };

        const cmp = c.LLVMBuildICmp(self.builder, predicate, left, right, "cmp");
        const result = c.LLVMBuildZExt(self.builder, cmp, self.i64_type, "cmp_ext");
        try self.stack.append(self.allocator, result);
    }

    fn generateLogicalOp(self: *Self, op: Opcode) !void {
        const right = self.stack.pop() orelse unreachable;
        const left = self.stack.pop() orelse unreachable;

        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const left_bool = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, left, zero, "left_bool");
        const right_bool = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, right, zero, "right_bool");

        const result_bool = switch (op) {
            .and_op => c.LLVMBuildAnd(self.builder, left_bool, right_bool, "and"),
            .or_op => c.LLVMBuildOr(self.builder, left_bool, right_bool, "or"),
            else => unreachable,
        };

        const result = c.LLVMBuildZExt(self.builder, result_bool, self.i64_type, "logic_ext");
        try self.stack.append(self.allocator, result);
    }

    fn generateCall(self: *Self, func_name: []const u8, arg_count: i64) !void {
        // Handle built-in functions
        if (std.mem.eql(u8, func_name, "println")) {
            try self.generatePrintln();
            return;
        }

        if (std.mem.eql(u8, func_name, "int_to_str")) {
            try self.generateIntToStr();
            return;
        }

        if (std.mem.eql(u8, func_name, "str_len")) {
            try self.generateStrLen();
            return;
        }

        if (std.mem.eql(u8, func_name, "str_concat")) {
            try self.generateStrConcat();
            return;
        }

        // Regular function call
        const llvm_func = self.functions.get(func_name) orelse return error.UndefinedFunction;

        var args = try self.allocator.alloc(c.LLVMValueRef, @intCast(arg_count));
        defer self.allocator.free(args);

        var i: usize = @intCast(arg_count);
        while (i > 0) {
            i -= 1;
            args[i] = self.stack.pop() orelse unreachable;
        }

        const result = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(llvm_func),
            llvm_func,
            args.ptr,
            @intCast(arg_count),
            "call",
        );

        try self.stack.append(self.allocator, result);
    }

    fn generatePrintln(self: *Self) !void {
        const string = self.stack.pop() orelse unreachable;
        const printf_func = self.functions.get("printf").?;

        // Create format string with newline
        const fmt = try self.createStringConstant("%s\n");

        var args = [_]c.LLVMValueRef{ fmt, string };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(printf_func),
            printf_func,
            &args,
            2,
            "println",
        );

        // Push dummy return value
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        try self.stack.append(self.allocator, zero);
    }

    fn generateIntToStr(self: *Self) !void {
        const value = self.stack.pop() orelse unreachable;

        // Allocate buffer
        const size = c.LLVMConstInt(self.i64_type, 32, 0);
        const malloc_func = self.functions.get("malloc").?;
        var malloc_args = [_]c.LLVMValueRef{size};
        const buffer = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(malloc_func),
            malloc_func,
            &malloc_args,
            1,
            "buffer",
        );

        // Create format string
        const fmt = try self.createStringConstant("%lld");

        // Call snprintf
        const snprintf_func = self.functions.get("snprintf").?;
        var snprintf_args = [_]c.LLVMValueRef{ buffer, size, fmt, value };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(snprintf_func),
            snprintf_func,
            &snprintf_args,
            4,
            "int_to_str",
        );

        try self.stack.append(self.allocator, buffer);
    }

    fn generateStrLen(self: *Self) !void {
        const string = self.stack.pop() orelse unreachable;
        const strlen_func = self.functions.get("strlen").?;

        var args = [_]c.LLVMValueRef{string};
        const result = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strlen_func),
            strlen_func,
            &args,
            1,
            "str_len",
        );

        try self.stack.append(self.allocator, result);
    }

    fn generateStrConcat(self: *Self) !void {
        const str2 = self.stack.pop() orelse unreachable;
        const str1 = self.stack.pop() orelse unreachable;

        // Get lengths
        const strlen_func = self.functions.get("strlen").?;
        var args1 = [_]c.LLVMValueRef{str1};
        const len1 = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strlen_func),
            strlen_func,
            &args1,
            1,
            "len1",
        );

        var args2 = [_]c.LLVMValueRef{str2};
        const len2 = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strlen_func),
            strlen_func,
            &args2,
            1,
            "len2",
        );

        // Calculate total size
        const total_len = c.LLVMBuildAdd(self.builder, len1, len2, "total_len");
        const one = c.LLVMConstInt(self.i64_type, 1, 0);
        const size = c.LLVMBuildAdd(self.builder, total_len, one, "size");

        // Allocate buffer
        const malloc_func = self.functions.get("malloc").?;
        var malloc_args = [_]c.LLVMValueRef{size};
        const buffer = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(malloc_func),
            malloc_func,
            &malloc_args,
            1,
            "buffer",
        );

        // Copy strings
        const strcpy_func = self.functions.get("strcpy").?;
        var strcpy_args = [_]c.LLVMValueRef{ buffer, str1 };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strcpy_func),
            strcpy_func,
            &strcpy_args,
            2,
            "strcpy",
        );

        const strcat_func = self.functions.get("strcat").?;
        var strcat_args = [_]c.LLVMValueRef{ buffer, str2 };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strcat_func),
            strcat_func,
            &strcat_args,
            2,
            "strcat",
        );

        try self.stack.append(self.allocator, buffer);
    }

    fn createStringConstant(self: *Self, str: []const u8) !c.LLVMValueRef {
        // Check if we've already created this string
        if (self.string_literals.get(str)) |existing| {
            return existing;
        }

        // Create global string constant
        const str_z = try self.allocator.dupeZ(u8, str);
        defer self.allocator.free(str_z);

        const global = c.LLVMBuildGlobalStringPtr(self.builder, str_z.ptr, "str");
        try self.string_literals.put(str, global);

        return global;
    }

    fn getOrCreateBasicBlock(self: *Self, name: [:0]const u8) c.LLVMBasicBlockRef {
        const func = self.current_function.?;

        // Check if block already exists
        var block = c.LLVMGetFirstBasicBlock(func);
        while (block != null) {
            const block_name = c.LLVMGetBasicBlockName(block);
            if (std.mem.eql(u8, std.mem.span(block_name), name)) {
                return block.?;
            }
            block = c.LLVMGetNextBasicBlock(block);
        }

        // Create new block
        return c.LLVMAppendBasicBlockInContext(self.context, func, name.ptr);
    }

    /// Write LLVM IR to a file
    pub fn emitLLVMIR(self: *const LLVMCodeGen, output_path: []const u8) !void {
        const path_z = try self.allocator.dupeZ(u8, output_path);
        defer self.allocator.free(path_z);

        var error_msg: [*c]u8 = undefined;
        if (c.LLVMPrintModuleToFile(self.module, path_z.ptr, &error_msg) != 0) {
            std.debug.print("Failed to write LLVM IR: {s}\n", .{error_msg});
            c.LLVMDisposeMessage(error_msg);
            return error.WriteFailed;
        }
    }

    /// Compile to object file
    pub fn emitObjectFile(self: *const LLVMCodeGen, output_path: []const u8) !void {
        const path_z = try self.allocator.dupeZ(u8, output_path);
        defer self.allocator.free(path_z);

        // Get native target
        var target: c.LLVMTargetRef = undefined;
        const target_triple = c.LLVMGetDefaultTargetTriple();
        defer c.LLVMDisposeMessage(target_triple);

        var error_msg: [*c]u8 = undefined;
        if (c.LLVMGetTargetFromTriple(target_triple, &target, &error_msg) != 0) {
            std.debug.print("Failed to get target: {s}\n", .{error_msg});
            c.LLVMDisposeMessage(error_msg);
            return error.TargetCreationFailed;
        }

        // Create target machine
        const cpu = c.LLVMGetHostCPUName();
        const features = c.LLVMGetHostCPUFeatures();
        defer c.LLVMDisposeMessage(cpu);
        defer c.LLVMDisposeMessage(features);

        const target_machine = c.LLVMCreateTargetMachine(
            target,
            target_triple,
            cpu,
            features,
            c.LLVMCodeGenLevelDefault,
            c.LLVMRelocDefault,
            c.LLVMCodeModelDefault,
        );
        defer c.LLVMDisposeTargetMachine(target_machine);

        // Emit object file
        if (c.LLVMTargetMachineEmitToFile(
            target_machine,
            self.module,
            path_z.ptr,
            c.LLVMObjectFile,
            &error_msg,
        ) != 0) {
            std.debug.print("Failed to emit object file: {s}\n", .{error_msg});
            c.LLVMDisposeMessage(error_msg);
            return error.ObjectEmissionFailed;
        }
    }

    /// Print LLVM IR to stdout
    pub fn dumpModule(self: *const LLVMCodeGen) void {
        c.LLVMDumpModule(self.module);
    }
};
