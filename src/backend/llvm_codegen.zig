const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const Instruction = ir.Instruction;
const Program = ir.Program;
const Function = ir.Function;
const Opcode = ir.Opcode;

const errno_function_name = switch (builtin.os.tag) {
    .windows => "_errno",
    .macos => "__error",
    else => "__errno_location",
};

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
    WriteFailed,
    TargetCreationFailed,
    ObjectEmissionFailed,
    StackUnderflow, // New: stack operation on empty stack
    InvalidBasicBlock, // New: basic block lookup failed
};

/// LLVM Code Generator - Compiles Elba IR to native machine code via LLVM
pub const LLVMCodeGen = struct {
    allocator: std.mem.Allocator,
    context: c.LLVMContextRef,
    module: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,

    // Type cache - commonly used LLVM types
    i64_type: c.LLVMTypeRef,
    i32_type: c.LLVMTypeRef,
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
        const i32_type = c.LLVMInt32TypeInContext(context);
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
            .i32_type = i32_type,
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
        try self.declareCFunction("puts", self.i32_type, &[_]c.LLVMTypeRef{self.ptr_type}, false);

        // malloc - memory allocation
        try self.declareCFunction("malloc", self.ptr_type, &[_]c.LLVMTypeRef{self.i64_type}, false);

        // free - memory deallocation
        try self.declareCFunction("free", self.void_type, &[_]c.LLVMTypeRef{self.ptr_type}, false);
        try self.declareCFunction("exit", self.void_type, &[_]c.LLVMTypeRef{self.i32_type}, false);
        try self.declareCFunction(errno_function_name, self.ptr_type, &[_]c.LLVMTypeRef{}, false);

        // pow - exponentiation used by the integer and float power opcode
        try self.declareCFunction("pow", self.f64_type, &[_]c.LLVMTypeRef{ self.f64_type, self.f64_type }, false);
        try self.declareCFunction("sqrt", self.f64_type, &[_]c.LLVMTypeRef{self.f64_type}, false);
        try self.declareCFunction("floor", self.f64_type, &[_]c.LLVMTypeRef{self.f64_type}, false);
        try self.declareCFunction("ceil", self.f64_type, &[_]c.LLVMTypeRef{self.f64_type}, false);

        try self.declareOverflowIntrinsic("llvm.sadd.with.overflow.i64");
        try self.declareOverflowIntrinsic("llvm.ssub.with.overflow.i64");
        try self.declareOverflowIntrinsic("llvm.smul.with.overflow.i64");
        try self.defineCheckedIntegerPow();

        // String manipulation functions
        try self.declareStringFunctions();
        try self.defineTaggedEquality();
        try self.defineTaggedTypeCheck();
    }

    fn declareOverflowIntrinsic(self: *Self, name: []const u8) !void {
        var result_fields = [_]c.LLVMTypeRef{ self.i64_type, self.i1_type };
        const result_type = c.LLVMStructTypeInContext(self.context, &result_fields, result_fields.len, 0);
        var parameter_types = [_]c.LLVMTypeRef{ self.i64_type, self.i64_type };
        const function_type = c.LLVMFunctionType(result_type, &parameter_types, parameter_types.len, 0);
        const function = c.LLVMAddFunction(self.module, name.ptr, function_type);
        try self.functions.put(name, function);
    }

    fn buildOverflowingCall(
        self: *Self,
        intrinsic_name: []const u8,
        left: c.LLVMValueRef,
        right: c.LLVMValueRef,
        name: [*:0]const u8,
    ) struct { value: c.LLVMValueRef, overflow: c.LLVMValueRef } {
        const intrinsic = self.functions.get(intrinsic_name).?;
        var arguments = [_]c.LLVMValueRef{ left, right };
        const pair = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(intrinsic),
            intrinsic,
            &arguments,
            arguments.len,
            name,
        );
        return .{
            .value = c.LLVMBuildExtractValue(self.builder, pair, 0, "checked_value"),
            .overflow = c.LLVMBuildExtractValue(self.builder, pair, 1, "checked_overflow"),
        };
    }

    fn defineCheckedIntegerPow(self: *Self) !void {
        var parameter_types = [_]c.LLVMTypeRef{ self.i64_type, self.i64_type };
        const function_type = c.LLVMFunctionType(self.i64_type, &parameter_types, parameter_types.len, 0);
        const function = c.LLVMAddFunction(self.module, "elba_checked_pow_i64", function_type);
        try self.functions.put("elba_checked_pow_i64", function);

        const entry = c.LLVMAppendBasicBlockInContext(self.context, function, "entry");
        const loop = c.LLVMAppendBasicBlockInContext(self.context, function, "pow_loop");
        const body = c.LLVMAppendBasicBlockInContext(self.context, function, "pow_body");
        const after_result = c.LLVMAppendBasicBlockInContext(self.context, function, "pow_after_result");
        const after_square = c.LLVMAppendBasicBlockInContext(self.context, function, "pow_after_square");
        const done = c.LLVMAppendBasicBlockInContext(self.context, function, "pow_done");
        const failure = c.LLVMAppendBasicBlockInContext(self.context, function, "pow_failure");

        c.LLVMPositionBuilderAtEnd(self.builder, entry);
        const result_slot = c.LLVMBuildAlloca(self.builder, self.i64_type, "pow_result_slot");
        const base_slot = c.LLVMBuildAlloca(self.builder, self.i64_type, "pow_base_slot");
        const exponent_slot = c.LLVMBuildAlloca(self.builder, self.i64_type, "pow_exponent_slot");
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.i64_type, 1, 0), result_slot);
        _ = c.LLVMBuildStore(self.builder, c.LLVMGetParam(function, 0), base_slot);
        const exponent_parameter = c.LLVMGetParam(function, 1);
        _ = c.LLVMBuildStore(self.builder, exponent_parameter, exponent_slot);
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const exponent_is_negative = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, exponent_parameter, zero, "negative_exponent");
        _ = c.LLVMBuildCondBr(self.builder, exponent_is_negative, failure, loop);

        c.LLVMPositionBuilderAtEnd(self.builder, loop);
        const exponent = c.LLVMBuildLoad2(self.builder, self.i64_type, exponent_slot, "pow_exponent");
        const exponent_is_zero = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, exponent, zero, "pow_complete");
        _ = c.LLVMBuildCondBr(self.builder, exponent_is_zero, done, body);

        c.LLVMPositionBuilderAtEnd(self.builder, body);
        const result = c.LLVMBuildLoad2(self.builder, self.i64_type, result_slot, "pow_result");
        const base = c.LLVMBuildLoad2(self.builder, self.i64_type, base_slot, "pow_base");
        const low_bit = c.LLVMBuildAnd(self.builder, exponent, c.LLVMConstInt(self.i64_type, 1, 0), "pow_low_bit");
        const multiply_result = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, low_bit, zero, "pow_multiply_result");
        const result_product = self.buildOverflowingCall("llvm.smul.with.overflow.i64", result, base, "pow_result_product");
        const result_overflow = c.LLVMBuildAnd(self.builder, multiply_result, result_product.overflow, "pow_result_overflow");
        _ = c.LLVMBuildCondBr(self.builder, result_overflow, failure, after_result);

        c.LLVMPositionBuilderAtEnd(self.builder, after_result);
        _ = c.LLVMBuildStore(self.builder, c.LLVMBuildSelect(self.builder, multiply_result, result_product.value, result, "pow_next_result"), result_slot);
        const next_exponent = c.LLVMBuildLShr(self.builder, exponent, c.LLVMConstInt(self.i64_type, 1, 0), "pow_next_exponent");
        _ = c.LLVMBuildStore(self.builder, next_exponent, exponent_slot);
        const needs_square = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, next_exponent, zero, "pow_needs_square");
        const base_square = self.buildOverflowingCall("llvm.smul.with.overflow.i64", base, base, "pow_base_square");
        const square_overflow = c.LLVMBuildAnd(self.builder, needs_square, base_square.overflow, "pow_square_overflow");
        _ = c.LLVMBuildCondBr(self.builder, square_overflow, failure, after_square);

        c.LLVMPositionBuilderAtEnd(self.builder, after_square);
        _ = c.LLVMBuildStore(self.builder, c.LLVMBuildSelect(self.builder, needs_square, base_square.value, base, "pow_next_base"), base_slot);
        _ = c.LLVMBuildBr(self.builder, loop);

        c.LLVMPositionBuilderAtEnd(self.builder, done);
        _ = c.LLVMBuildRet(self.builder, c.LLVMBuildLoad2(self.builder, self.i64_type, result_slot, "pow_final_result"));

        c.LLVMPositionBuilderAtEnd(self.builder, failure);
        const puts_function = self.functions.get("puts").?;
        var message_arguments = [_]c.LLVMValueRef{try self.createStringConstant("Integer exponentiation failed!")};
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(puts_function), puts_function, &message_arguments, message_arguments.len, "");
        const exit_function = self.functions.get("exit").?;
        var exit_arguments = [_]c.LLVMValueRef{c.LLVMConstInt(self.i32_type, 1, 0)};
        _ = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(exit_function), exit_function, &exit_arguments, exit_arguments.len, "");
        _ = c.LLVMBuildUnreachable(self.builder);
    }

    fn defineTaggedEquality(self: *Self) !void {
        var parameter_types = [_]c.LLVMTypeRef{ self.i64_type, self.i64_type };
        const function_type = c.LLVMFunctionType(self.i1_type, &parameter_types, parameter_types.len, 0);
        const function = c.LLVMAddFunction(self.module, "elba_tagged_equal", function_type);
        try self.functions.put("elba_tagged_equal", function);

        const entry = c.LLVMAppendBasicBlockInContext(self.context, function, "entry");
        const left_null_block = c.LLVMAppendBasicBlockInContext(self.context, function, "left_null");
        const right_null_check = c.LLVMAppendBasicBlockInContext(self.context, function, "right_null_check");
        const tagged_block = c.LLVMAppendBasicBlockInContext(self.context, function, "tagged");
        const descriptor_check = c.LLVMAppendBasicBlockInContext(self.context, function, "descriptor_check");
        const tag_dispatch = c.LLVMAppendBasicBlockInContext(self.context, function, "tag_dispatch");
        const float_check = c.LLVMAppendBasicBlockInContext(self.context, function, "float_check");
        const string_check = c.LLVMAppendBasicBlockInContext(self.context, function, "string_check");
        const nested_check = c.LLVMAppendBasicBlockInContext(self.context, function, "nested_check");
        const bits_check = c.LLVMAppendBasicBlockInContext(self.context, function, "bits_check");
        const return_true = c.LLVMAppendBasicBlockInContext(self.context, function, "return_true");
        const return_false = c.LLVMAppendBasicBlockInContext(self.context, function, "return_false");

        const left = c.LLVMGetParam(function, 0);
        const right = c.LLVMGetParam(function, 1);
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);

        c.LLVMPositionBuilderAtEnd(self.builder, entry);
        const left_is_null = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, left, zero, "left_is_null");
        _ = c.LLVMBuildCondBr(self.builder, left_is_null, left_null_block, right_null_check);

        c.LLVMPositionBuilderAtEnd(self.builder, left_null_block);
        const right_is_also_null = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, right, zero, "right_is_also_null");
        _ = c.LLVMBuildCondBr(self.builder, right_is_also_null, return_true, return_false);

        c.LLVMPositionBuilderAtEnd(self.builder, right_null_check);
        const right_is_null = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, right, zero, "right_is_null");
        _ = c.LLVMBuildCondBr(self.builder, right_is_null, return_false, tagged_block);

        c.LLVMPositionBuilderAtEnd(self.builder, tagged_block);
        const left_ptr = c.LLVMBuildIntToPtr(self.builder, left, self.ptr_type, "left_tagged_ptr");
        const right_ptr = c.LLVMBuildIntToPtr(self.builder, right, self.ptr_type, "right_tagged_ptr");
        var tag_index = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 0, 0)};
        var payload_index = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 1, 0)};
        var descriptor_index = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 2, 0)};
        const left_tag_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, left_ptr, &tag_index, 1, "left_tag_ptr");
        const right_tag_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, right_ptr, &tag_index, 1, "right_tag_ptr");
        const left_payload_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, left_ptr, &payload_index, 1, "left_payload_ptr");
        const right_payload_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, right_ptr, &payload_index, 1, "right_payload_ptr");
        const left_descriptor_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, left_ptr, &descriptor_index, 1, "left_descriptor_ptr");
        const right_descriptor_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, right_ptr, &descriptor_index, 1, "right_descriptor_ptr");
        const left_tag = c.LLVMBuildLoad2(self.builder, self.i64_type, left_tag_ptr, "left_tag");
        const right_tag = c.LLVMBuildLoad2(self.builder, self.i64_type, right_tag_ptr, "right_tag");
        const tags_match = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, left_tag, right_tag, "tags_match");
        _ = c.LLVMBuildCondBr(self.builder, tags_match, descriptor_check, return_false);

        c.LLVMPositionBuilderAtEnd(self.builder, descriptor_check);
        const left_descriptor = c.LLVMBuildLoad2(self.builder, self.i64_type, left_descriptor_ptr, "left_descriptor");
        const right_descriptor = c.LLVMBuildLoad2(self.builder, self.i64_type, right_descriptor_ptr, "right_descriptor");
        const strcmp_function = self.functions.get("strcmp").?;
        var descriptor_arguments = [_]c.LLVMValueRef{
            c.LLVMBuildIntToPtr(self.builder, left_descriptor, self.ptr_type, "left_descriptor_string"),
            c.LLVMBuildIntToPtr(self.builder, right_descriptor, self.ptr_type, "right_descriptor_string"),
        };
        const descriptors_match = c.LLVMBuildICmp(
            self.builder,
            c.LLVMIntEQ,
            c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(strcmp_function), strcmp_function, &descriptor_arguments, descriptor_arguments.len, "descriptor_compare"),
            c.LLVMConstInt(self.i32_type, 0, 0),
            "descriptors_match",
        );
        _ = c.LLVMBuildCondBr(self.builder, descriptors_match, tag_dispatch, return_false);

        c.LLVMPositionBuilderAtEnd(self.builder, tag_dispatch);
        const left_payload = c.LLVMBuildLoad2(self.builder, self.i64_type, left_payload_ptr, "left_payload");
        const right_payload = c.LLVMBuildLoad2(self.builder, self.i64_type, right_payload_ptr, "right_payload");
        const is_float = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, left_tag, c.LLVMConstInt(self.i64_type, @intFromEnum(ir.ValueType.float), 0), "tag_is_float");
        const after_float_dispatch = c.LLVMAppendBasicBlockInContext(self.context, function, "after_float_dispatch");
        _ = c.LLVMBuildCondBr(self.builder, is_float, float_check, after_float_dispatch);

        c.LLVMPositionBuilderAtEnd(self.builder, after_float_dispatch);
        const is_string = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, left_tag, c.LLVMConstInt(self.i64_type, @intFromEnum(ir.ValueType.string), 0), "tag_is_string");
        const after_string_dispatch = c.LLVMAppendBasicBlockInContext(self.context, function, "after_string_dispatch");
        _ = c.LLVMBuildCondBr(self.builder, is_string, string_check, after_string_dispatch);

        c.LLVMPositionBuilderAtEnd(self.builder, after_string_dispatch);
        const is_optional = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, left_tag, c.LLVMConstInt(self.i64_type, @intFromEnum(ir.ValueType.optional), 0), "tag_is_optional");
        const is_union = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, left_tag, c.LLVMConstInt(self.i64_type, @intFromEnum(ir.ValueType.union_type), 0), "tag_is_union");
        _ = c.LLVMBuildCondBr(self.builder, c.LLVMBuildOr(self.builder, is_optional, is_union, "tag_is_nested"), nested_check, bits_check);

        c.LLVMPositionBuilderAtEnd(self.builder, float_check);
        const floats_match = c.LLVMBuildFCmp(self.builder, c.LLVMRealOEQ, c.LLVMBuildBitCast(self.builder, left_payload, self.f64_type, "left_float"), c.LLVMBuildBitCast(self.builder, right_payload, self.f64_type, "right_float"), "floats_match");
        _ = c.LLVMBuildRet(self.builder, floats_match);

        c.LLVMPositionBuilderAtEnd(self.builder, string_check);
        var strcmp_arguments = [_]c.LLVMValueRef{
            c.LLVMBuildIntToPtr(self.builder, left_payload, self.ptr_type, "left_string"),
            c.LLVMBuildIntToPtr(self.builder, right_payload, self.ptr_type, "right_string"),
        };
        const strcmp_result = c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(strcmp_function), strcmp_function, &strcmp_arguments, strcmp_arguments.len, "strcmp_result");
        _ = c.LLVMBuildRet(self.builder, c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, strcmp_result, c.LLVMConstInt(self.i32_type, 0, 0), "strings_match"));

        c.LLVMPositionBuilderAtEnd(self.builder, nested_check);
        var nested_arguments = [_]c.LLVMValueRef{ left_payload, right_payload };
        _ = c.LLVMBuildRet(self.builder, c.LLVMBuildCall2(self.builder, function_type, function, &nested_arguments, nested_arguments.len, "nested_equal"));

        c.LLVMPositionBuilderAtEnd(self.builder, bits_check);
        _ = c.LLVMBuildRet(self.builder, c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, left_payload, right_payload, "bits_match"));

        c.LLVMPositionBuilderAtEnd(self.builder, return_true);
        _ = c.LLVMBuildRet(self.builder, c.LLVMConstInt(self.i1_type, 1, 0));
        c.LLVMPositionBuilderAtEnd(self.builder, return_false);
        _ = c.LLVMBuildRet(self.builder, c.LLVMConstInt(self.i1_type, 0, 0));
    }

    fn defineTaggedTypeCheck(self: *Self) !void {
        var parameter_types = [_]c.LLVMTypeRef{ self.i64_type, self.i64_type, self.ptr_type };
        const function_type = c.LLVMFunctionType(self.i1_type, &parameter_types, parameter_types.len, 0);
        const function = c.LLVMAddFunction(self.module, "elba_tagged_is_type", function_type);
        try self.functions.put("elba_tagged_is_type", function);
        const entry = c.LLVMAppendBasicBlockInContext(self.context, function, "entry");
        const tagged = c.LLVMAppendBasicBlockInContext(self.context, function, "tagged");
        const absent = c.LLVMAppendBasicBlockInContext(self.context, function, "absent");

        const value = c.LLVMGetParam(function, 0);
        const target_tag = c.LLVMGetParam(function, 1);
        const target_descriptor = c.LLVMGetParam(function, 2);
        c.LLVMPositionBuilderAtEnd(self.builder, entry);
        const is_null = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, value, c.LLVMConstInt(self.i64_type, 0, 0), "tagged_is_null");
        _ = c.LLVMBuildCondBr(self.builder, is_null, absent, tagged);

        c.LLVMPositionBuilderAtEnd(self.builder, tagged);
        const tagged_ptr = c.LLVMBuildIntToPtr(self.builder, value, self.ptr_type, "tagged_ptr");
        var tag_index = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 0, 0)};
        var descriptor_index = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 2, 0)};
        const tag_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, tagged_ptr, tag_index[0..].ptr, 1, "tag_ptr");
        const descriptor_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, tagged_ptr, descriptor_index[0..].ptr, 1, "descriptor_ptr");
        const payload_tag = c.LLVMBuildLoad2(self.builder, self.i64_type, tag_ptr, "payload_tag");
        const payload_descriptor = c.LLVMBuildLoad2(self.builder, self.i64_type, descriptor_ptr, "payload_descriptor");
        const tag_matches = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, payload_tag, target_tag, "tag_matches");
        const strcmp_function = self.functions.get("strcmp").?;
        var descriptor_arguments = [_]c.LLVMValueRef{
            c.LLVMBuildIntToPtr(self.builder, payload_descriptor, self.ptr_type, "payload_descriptor_string"),
            target_descriptor,
        };
        const descriptor_matches = c.LLVMBuildICmp(
            self.builder,
            c.LLVMIntEQ,
            c.LLVMBuildCall2(self.builder, c.LLVMGlobalGetValueType(strcmp_function), strcmp_function, &descriptor_arguments, descriptor_arguments.len, "descriptor_compare"),
            c.LLVMConstInt(self.i32_type, 0, 0),
            "descriptor_matches",
        );
        _ = c.LLVMBuildRet(self.builder, c.LLVMBuildAnd(self.builder, tag_matches, descriptor_matches, "type_matches"));

        c.LLVMPositionBuilderAtEnd(self.builder, absent);
        _ = c.LLVMBuildRet(self.builder, c.LLVMConstInt(self.i1_type, 0, 0));
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

        // Scalar string helpers from the C runtime
        try self.declareCFunction("strcmp", self.i32_type, &[_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type }, false);
        try self.declareCFunction("strstr", self.ptr_type, &[_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type }, false);
        try self.declareCFunction("strtoll", self.i64_type, &[_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type, self.i32_type }, false);
        try self.declareCFunction("strtod", self.f64_type, &[_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type }, false);
        try self.declareCFunction("memcpy", self.ptr_type, &[_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type, self.i64_type }, false);
        try self.declareCFunction("isspace", self.i32_type, &[_]c.LLVMTypeRef{self.i32_type}, false);
    }

    fn declareLLVMFunction(self: *Self, func: Function) !void {
        // Create function type
        // The stack IR uses an i64 carrier for scalar bits and heap pointers;
        // instruction metadata selects the concrete operations on that carrier.
        const return_type = self.i64_type;

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

        // Allocate every local in the entry block. Lazily creating allocas at a
        // store site places variables inside whichever branch happens to contain
        // the first store, so later loads may not be dominated by that alloca.
        // IR values use an i64 carrier for scalars, pointers, and float bits.
        for (func.instructions) |inst| {
            if (inst.op != .store_var) continue;
            const var_name = inst.string_data orelse continue;
            if (self.variables.contains(var_name)) continue;

            const var_name_z = try self.allocator.dupeZ(u8, var_name);
            defer self.allocator.free(var_name_z);
            const alloca = c.LLVMBuildAlloca(self.builder, self.i64_type, var_name_z.ptr);
            try self.variables.put(var_name, alloca);
            try self.variable_types.put(var_name, self.i64_type);
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
                            const value = self.toI64(self.stack.items[self.stack.items.len - 1]);
                            _ = c.LLVMBuildStore(self.builder, value, self.temp_slot.?);
                        }
                        // Add unconditional branch to the label
                        _ = c.LLVMBuildBr(self.builder, label_block);
                    }

                    // Position builder at the label block
                    c.LLVMPositionBuilderAtEnd(self.builder, label_block);
                    current_label = @intCast(idx);

                    // Load the top stack value shared by branch predecessors.
                    // The current backend only materializes one join value; full
                    // multi-value stack joins remain tracked in LANGUAGE_STATUS.md.
                    if (inst.op != .stack_reset) if (self.temp_slot) |slot| {
                        const loaded = c.LLVMBuildLoad2(self.builder, self.i64_type, slot, "temp_load");
                        try self.stack.append(self.allocator, loaded);
                    };
                }
            }

            // Instructions after an unconditional jump or return are unreachable
            // until the next label. Emitting them into the terminated block makes
            // invalid LLVM IR (a terminator in the middle of a basic block).
            const insertion_block = c.LLVMGetInsertBlock(self.builder);
            if (c.LLVMGetBasicBlockTerminator(insertion_block) != null) {
                continue;
            }

            try self.generateInstruction(inst);

            // If next instruction is a label and current block has no terminator, save stack value
            if (next_is_label and self.temp_slot != null) {
                const current_block = c.LLVMGetInsertBlock(self.builder);
                if (c.LLVMGetBasicBlockTerminator(current_block) == null and self.stack.items.len > 0) {
                    const value = self.toI64(self.stack.items[self.stack.items.len - 1]);
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
            .load_const_bool => {
                const value = c.LLVMConstInt(self.i64_type, @intCast(inst.operand1), 0);
                try self.stack.append(self.allocator, value);
            },
            .load_null => {
                const null_value = c.LLVMConstInt(self.i64_type, 0, 0);
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
                    const value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
                    const alloca = self.variables.get(var_name) orelse return error.UndefinedVariable;
                    _ = c.LLVMBuildStore(self.builder, value, alloca);
                }
            },
            .add => try self.generateBinaryOp(.add, inst.operand3),
            .sub => try self.generateBinaryOp(.sub, inst.operand3),
            .mul => try self.generateBinaryOp(.mul, inst.operand3),
            .div => try self.generateBinaryOp(.div, inst.operand3),
            .mod => try self.generateBinaryOp(.mod, inst.operand3),
            .pow => {
                const exponent_value = self.stack.pop() orelse return error.StackUnderflow;
                const base_value = self.stack.pop() orelse return error.StackUnderflow;
                const left_type = ir.decodeBinaryLeft(inst.operand3);
                const right_type = ir.decodeBinaryRight(inst.operand3);
                const operands_are_float = left_type == .float or right_type == .float;
                if (operands_are_float) {
                    const base = self.asFloatOperand(base_value, left_type, "pow_base");
                    const exponent = self.asFloatOperand(exponent_value, right_type, "pow_exponent");
                    const pow_function = self.functions.get("pow").?;
                    var arguments = [_]c.LLVMValueRef{ base, exponent };
                    const result = c.LLVMBuildCall2(
                        self.builder,
                        c.LLVMGlobalGetValueType(pow_function),
                        pow_function,
                        &arguments,
                        2,
                        "pow",
                    );
                    try self.stack.append(self.allocator, result);
                } else {
                    const pow_function = self.functions.get("elba_checked_pow_i64").?;
                    var arguments = [_]c.LLVMValueRef{ self.toI64(base_value), self.toI64(exponent_value) };
                    const result = c.LLVMBuildCall2(
                        self.builder,
                        c.LLVMGlobalGetValueType(pow_function),
                        pow_function,
                        &arguments,
                        2,
                        "checked_pow",
                    );
                    try self.stack.append(self.allocator, result);
                }
            },
            .eq => try self.generateCompareOp(.eq, inst.operand3),
            .neq => try self.generateCompareOp(.neq, inst.operand3),
            .lt => try self.generateCompareOp(.lt, inst.operand3),
            .lte => try self.generateCompareOp(.lte, inst.operand3),
            .gt => try self.generateCompareOp(.gt, inst.operand3),
            .gte => try self.generateCompareOp(.gte, inst.operand3),
            .and_op => try self.generateLogicalOp(.and_op),
            .or_op => try self.generateLogicalOp(.or_op),
            .not_op => {
                const value = self.stack.pop() orelse return error.StackUnderflow;
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, value, zero, "not");
                const result = c.LLVMBuildZExt(self.builder, cmp, self.i64_type, "not_ext");
                try self.stack.append(self.allocator, result);
            },
            .neg => {
                const value = self.stack.pop() orelse return error.StackUnderflow;
                const result = if (ir.decodeValueType(inst.operand3) == .float)
                    c.LLVMBuildFNeg(self.builder, self.toF64(value), "neg_float")
                else
                    try self.generateCheckedIntegerBinary(
                        .sub,
                        c.LLVMConstInt(self.i64_type, 0, 0),
                        self.toI64(value),
                    );
                try self.stack.append(self.allocator, result);
            },
            .jump => {
                // Save stack top to temp_slot before jumping (if there's a value on stack)
                if (self.stack.items.len > 0 and self.temp_slot != null) {
                    const value = self.toI64(self.stack.items[self.stack.items.len - 1]);
                    _ = c.LLVMBuildStore(self.builder, value, self.temp_slot.?);
                }

                const target_label = try std.fmt.allocPrint(self.allocator, "L{d}", .{inst.operand1});
                defer self.allocator.free(target_label);

                const target_block = self.basic_blocks.get(target_label) orelse return error.InvalidBasicBlock;
                _ = c.LLVMBuildBr(self.builder, target_block);
            },
            .jump_if_false, .jump_if_true => {
                const condition = self.stack.pop() orelse return error.StackUnderflow;
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                const cmp = c.LLVMBuildICmp(
                    self.builder,
                    if (inst.op == .jump_if_false) c.LLVMIntEQ else c.LLVMIntNE,
                    condition,
                    zero,
                    if (inst.op == .jump_if_false) "is_false" else "is_true",
                );

                const true_label = try std.fmt.allocPrint(self.allocator, "L{d}", .{inst.operand1});
                defer self.allocator.free(true_label);

                // Create a "continue" block for fall-through
                const continue_label = try std.fmt.allocPrint(self.allocator, "continue{d}", .{inst.operand1});
                defer self.allocator.free(continue_label);
                const continue_label_z = try self.allocator.dupeZ(u8, continue_label);
                defer self.allocator.free(continue_label_z);

                const true_block = self.basic_blocks.get(true_label) orelse return error.InvalidBasicBlock;
                const continue_block = c.LLVMAppendBasicBlockInContext(self.context, self.current_function.?, continue_label_z.ptr);

                _ = c.LLVMBuildCondBr(self.builder, cmp, true_block, continue_block);
                c.LLVMPositionBuilderAtEnd(self.builder, continue_block);
            },
            .call => {
                if (inst.string_data) |func_name| {
                    try self.generateCall(func_name, inst.operand2, inst.operand3);
                }
            },
            .ret => {
                if (self.stack.items.len > 0) {
                    const value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
                    _ = c.LLVMBuildRet(self.builder, value);
                } else {
                    const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                    _ = c.LLVMBuildRet(self.builder, zero);
                }
            },
            .pop => {
                _ = self.stack.pop() orelse return error.StackUnderflow;
            },
            .dup => {
                if (self.stack.items.len == 0) return error.StackUnderflow;
                const value = self.stack.items[self.stack.items.len - 1];
                try self.stack.append(self.allocator, value);
            },
            .stack_reset => {},
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
                const index = self.stack.pop() orelse return error.StackUnderflow;
                const arr_val = self.stack.pop() orelse return error.StackUnderflow;

                // Convert i64 to pointer if needed
                const arr_ptr = if (c.LLVMTypeOf(arr_val) == self.ptr_type)
                    arr_val
                else
                    c.LLVMBuildIntToPtr(self.builder, arr_val, self.ptr_type, "arr_ptr");

                const length = c.LLVMBuildLoad2(self.builder, self.i64_type, arr_ptr, "array_bounds_len");
                try self.emitIndexBoundsCheck(index, length);

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
                const value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
                const index = self.stack.pop() orelse return error.StackUnderflow;
                const arr_val = self.stack.pop() orelse return error.StackUnderflow;

                // Convert i64 to pointer if needed
                const arr_ptr = if (c.LLVMTypeOf(arr_val) == self.ptr_type)
                    arr_val
                else
                    c.LLVMBuildIntToPtr(self.builder, arr_val, self.ptr_type, "arr_ptr");

                const length = c.LLVMBuildLoad2(self.builder, self.i64_type, arr_ptr, "array_bounds_len");
                try self.emitIndexBoundsCheck(index, length);

                // Calculate offset: index + 1 (skip size element)
                const one = c.LLVMConstInt(self.i64_type, 1, 0);
                const offset = c.LLVMBuildAdd(self.builder, index, one, "offset");

                // GEP to get element pointer
                var indices = [_]c.LLVMValueRef{offset};
                const elem_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, arr_ptr, indices[0..].ptr, 1, "elem_ptr");

                // Store value
                _ = c.LLVMBuildStore(self.builder, value, elem_ptr);
            },
            .array_len => {
                const array_value = self.stack.pop() orelse return error.StackUnderflow;
                const array_ptr = self.toPtr(array_value);
                const length = c.LLVMBuildLoad2(self.builder, self.i64_type, array_ptr, "array_len");
                try self.stack.append(self.allocator, length);
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
                const struct_val = self.stack.pop() orelse return error.StackUnderflow;

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
                const value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
                const struct_val = self.stack.pop() orelse return error.StackUnderflow;

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
            .optional_wrap => {
                const payload = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
                const payload_type = ir.decodeValueType(inst.operand3) orelse .null_type;
                const malloc_function = self.functions.get("malloc").?;
                var malloc_arguments = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 24, 0)};
                const tagged_ptr = c.LLVMBuildCall2(
                    self.builder,
                    c.LLVMGlobalGetValueType(malloc_function),
                    malloc_function,
                    &malloc_arguments,
                    malloc_arguments.len,
                    "tagged_value",
                );
                var tag_index = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 0, 0)};
                var payload_index = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 1, 0)};
                var descriptor_index = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 2, 0)};
                const tag_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, tagged_ptr, tag_index[0..].ptr, 1, "tag_ptr");
                const payload_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, tagged_ptr, payload_index[0..].ptr, 1, "payload_ptr");
                const descriptor_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, tagged_ptr, descriptor_index[0..].ptr, 1, "descriptor_ptr");
                _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.i64_type, @intFromEnum(payload_type), 0), tag_ptr);
                _ = c.LLVMBuildStore(self.builder, payload, payload_ptr);
                _ = c.LLVMBuildStore(self.builder, c.LLVMBuildPtrToInt(self.builder, try self.createStringConstant(inst.string_data orelse "unknown"), self.i64_type, "descriptor_bits"), descriptor_ptr);
                try self.stack.append(self.allocator, tagged_ptr);
            },
            .optional_unwrap => {
                const tagged_value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
                const is_null = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, tagged_value, c.LLVMConstInt(self.i64_type, 0, 0), "optional_is_null");
                try self.emitRuntimeGuardWithMessage(is_null, "Cannot unwrap null!");
                const tagged_ptr = c.LLVMBuildIntToPtr(self.builder, tagged_value, self.ptr_type, "tagged_ptr");
                var payload_index = [_]c.LLVMValueRef{c.LLVMConstInt(self.i64_type, 1, 0)};
                const payload_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, tagged_ptr, payload_index[0..].ptr, 1, "payload_ptr");
                try self.stack.append(self.allocator, c.LLVMBuildLoad2(self.builder, self.i64_type, payload_ptr, "unwrapped_payload"));
            },
            .optional_is_null => {
                const tagged_value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
                const is_null = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, tagged_value, c.LLVMConstInt(self.i64_type, 0, 0), "optional_is_null");
                try self.stack.append(self.allocator, c.LLVMBuildZExt(self.builder, is_null, self.i64_type, "optional_is_null_ext"));
            },
            .type_check => {
                const checked_value = self.stack.pop() orelse return error.StackUnderflow;
                const actual_type = ir.decodeValueType(inst.operand3);
                const matches = switch (inst.operand1) {
                    1 => actual_type == .int,
                    2 => actual_type == .float,
                    3 => actual_type == .string,
                    4 => actual_type == .bool,
                    else => false,
                };
                const negate = inst.operand2 != 0;
                if (actual_type == .optional or actual_type == .union_type) {
                    const tagged_value = self.toI64(checked_value);
                    const target_tag: i64 = switch (inst.operand1) {
                        1 => @intFromEnum(ir.ValueType.int),
                        2 => @intFromEnum(ir.ValueType.float),
                        3 => @intFromEnum(ir.ValueType.string),
                        4 => @intFromEnum(ir.ValueType.bool),
                        5 => @intFromEnum(ir.ValueType.struct_type),
                        6 => @intFromEnum(ir.ValueType.array),
                        7 => @intFromEnum(ir.ValueType.null_type),
                        8 => @intFromEnum(ir.ValueType.optional),
                        9 => @intFromEnum(ir.ValueType.union_type),
                        else => -1,
                    };
                    const type_check_function = self.functions.get("elba_tagged_is_type").?;
                    var arguments = [_]c.LLVMValueRef{
                        tagged_value,
                        c.LLVMConstInt(self.i64_type, @bitCast(target_tag), 0),
                        try self.createStringConstant(inst.string_data orelse "unknown"),
                    };
                    const value_matches = c.LLVMBuildCall2(
                        self.builder,
                        c.LLVMGlobalGetValueType(type_check_function),
                        type_check_function,
                        &arguments,
                        arguments.len,
                        "tagged_type_matches",
                    );
                    const result = if (negate) c.LLVMBuildNot(self.builder, value_matches, "tagged_type_not_matches") else value_matches;
                    try self.stack.append(self.allocator, c.LLVMBuildZExt(self.builder, result, self.i64_type, "type_check_ext"));
                } else {
                    const static_matches = if (inst.operand1 == 10) true else if (inst.operand1 == 11) false else matches;
                    const result = if (negate) !static_matches else static_matches;
                    try self.stack.append(self.allocator, c.LLVMConstInt(self.i64_type, if (result) 1 else 0, 0));
                }
            },
        }
    }

    fn generateBinaryOp(self: *Self, op: Opcode, type_metadata: i64) !void {
        const left_type = ir.decodeBinaryLeft(type_metadata);
        const right_type = ir.decodeBinaryRight(type_metadata);

        if (op == .add and left_type == .string and right_type == .string) {
            try self.generateStrConcat();
            return;
        }

        const right = self.stack.pop() orelse return error.StackUnderflow;
        const left = self.stack.pop() orelse return error.StackUnderflow;

        const result = if (left_type == .float or right_type == .float) blk: {
            const left_float = self.asFloatOperand(left, left_type, "left_float");
            const right_float = self.asFloatOperand(right, right_type, "right_float");
            break :blk switch (op) {
                .add => c.LLVMBuildFAdd(self.builder, left_float, right_float, "add_float"),
                .sub => c.LLVMBuildFSub(self.builder, left_float, right_float, "sub_float"),
                .mul => c.LLVMBuildFMul(self.builder, left_float, right_float, "mul_float"),
                .div => c.LLVMBuildFDiv(self.builder, left_float, right_float, "div_float"),
                .mod => c.LLVMBuildFRem(self.builder, left_float, right_float, "mod_float"),
                else => unreachable,
            };
        } else try self.generateCheckedIntegerBinary(op, self.toI64(left), self.toI64(right));

        try self.stack.append(self.allocator, result);
    }

    fn generateCheckedIntegerBinary(
        self: *Self,
        op: Opcode,
        left: c.LLVMValueRef,
        right: c.LLVMValueRef,
    ) !c.LLVMValueRef {
        switch (op) {
            .add, .sub, .mul => {
                const intrinsic_name: []const u8 = switch (op) {
                    .add => "llvm.sadd.with.overflow.i64",
                    .sub => "llvm.ssub.with.overflow.i64",
                    .mul => "llvm.smul.with.overflow.i64",
                    else => unreachable,
                };
                const checked = self.buildOverflowingCall(intrinsic_name, left, right, "checked_integer_op");
                try self.emitRuntimeGuardWithMessage(checked.overflow, "Integer overflow!");
                return checked.value;
            },
            .div, .mod => {
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                const minus_one = c.LLVMConstInt(self.i64_type, @bitCast(@as(i64, -1)), 0);
                const minimum = c.LLVMConstInt(self.i64_type, @bitCast(@as(i64, std.math.minInt(i64))), 0);
                const divisor_is_zero = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, right, zero, "integer_divisor_is_zero");
                const dividend_is_minimum = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, left, minimum, "integer_dividend_is_minimum");
                const divisor_is_minus_one = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, right, minus_one, "integer_divisor_is_minus_one");
                const division_overflows = c.LLVMBuildAnd(self.builder, dividend_is_minimum, divisor_is_minus_one, "integer_division_overflows");
                try self.emitRuntimeGuardWithMessage(divisor_is_zero, "Division by zero!");
                try self.emitRuntimeGuardWithMessage(division_overflows, "Integer overflow!");
                return if (op == .div)
                    c.LLVMBuildSDiv(self.builder, left, right, "checked_div")
                else
                    c.LLVMBuildSRem(self.builder, left, right, "checked_mod");
            },
            else => unreachable,
        }
    }

    fn toI64(self: *Self, value: c.LLVMValueRef) c.LLVMValueRef {
        const value_type = c.LLVMTypeOf(value);
        if (value_type == self.i64_type) return value;
        if (value_type == self.ptr_type) {
            return c.LLVMBuildPtrToInt(self.builder, value, self.i64_type, "ptr_as_i64");
        }
        if (value_type == self.i1_type) {
            return c.LLVMBuildZExt(self.builder, value, self.i64_type, "bool_as_i64");
        }
        if (value_type == self.f64_type) {
            return c.LLVMBuildBitCast(self.builder, value, self.i64_type, "float_as_i64");
        }
        return c.LLVMBuildBitCast(self.builder, value, self.i64_type, "value_as_i64");
    }

    fn toF64(self: *Self, value: c.LLVMValueRef) c.LLVMValueRef {
        const value_type = c.LLVMTypeOf(value);
        if (value_type == self.f64_type) return value;
        if (value_type == self.i64_type) {
            return c.LLVMBuildBitCast(self.builder, value, self.f64_type, "bits_as_float");
        }
        return c.LLVMBuildBitCast(self.builder, self.toI64(value), self.f64_type, "value_as_float");
    }

    fn asFloatOperand(self: *Self, value: c.LLVMValueRef, declared_type: ?ir.ValueType, name: [*:0]const u8) c.LLVMValueRef {
        if (declared_type == .float or c.LLVMTypeOf(value) == self.f64_type) return self.toF64(value);
        return c.LLVMBuildSIToFP(self.builder, self.toI64(value), self.f64_type, name);
    }

    fn toPtr(self: *Self, value: c.LLVMValueRef) c.LLVMValueRef {
        if (c.LLVMTypeOf(value) == self.ptr_type) return value;
        return c.LLVMBuildIntToPtr(self.builder, self.toI64(value), self.ptr_type, "value_as_ptr");
    }

    fn emitRuntimeGuard(self: *Self, invalid: c.LLVMValueRef) !void {
        try self.emitRuntimeGuardWithMessage(invalid, null);
    }

    fn emitRuntimeGuardWithMessage(self: *Self, invalid: c.LLVMValueRef, message: ?[]const u8) !void {
        const llvm_function = self.current_function orelse return error.FunctionNotFound;
        const failure_block = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "runtime_guard_failure");
        const success_block = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "runtime_guard_success");
        _ = c.LLVMBuildCondBr(self.builder, invalid, failure_block, success_block);

        c.LLVMPositionBuilderAtEnd(self.builder, failure_block);
        if (message) |text| {
            const puts_function = self.functions.get("puts").?;
            var message_arguments = [_]c.LLVMValueRef{try self.createStringConstant(text)};
            _ = c.LLVMBuildCall2(
                self.builder,
                c.LLVMGlobalGetValueType(puts_function),
                puts_function,
                &message_arguments,
                message_arguments.len,
                "",
            );
        }
        const exit_func = self.functions.get("exit").?;
        var arguments = [_]c.LLVMValueRef{c.LLVMConstInt(self.i32_type, 1, 0)};
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(exit_func),
            exit_func,
            &arguments,
            1,
            "",
        );
        _ = c.LLVMBuildUnreachable(self.builder);
        c.LLVMPositionBuilderAtEnd(self.builder, success_block);
    }

    fn emitIndexBoundsCheck(self: *Self, index: c.LLVMValueRef, length: c.LLVMValueRef) !void {
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const is_negative = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, index, zero, "index_is_negative");
        const is_too_large = c.LLVMBuildICmp(self.builder, c.LLVMIntSGE, index, length, "index_is_too_large");
        try self.emitRuntimeGuard(c.LLVMBuildOr(self.builder, is_negative, is_too_large, "index_out_of_bounds"));
    }

    fn resetErrno(self: *Self) c.LLVMValueRef {
        const errno_func = self.functions.get(errno_function_name).?;
        const errno_pointer = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(errno_func),
            errno_func,
            null,
            0,
            "errno_pointer",
        );
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.i32_type, 0, 0), errno_pointer);
        return errno_pointer;
    }

    fn emitErrnoGuard(self: *Self, errno_pointer: c.LLVMValueRef) !void {
        const errno_value = c.LLVMBuildLoad2(self.builder, self.i32_type, errno_pointer, "parse_errno");
        const has_error = c.LLVMBuildICmp(
            self.builder,
            c.LLVMIntNE,
            errno_value,
            c.LLVMConstInt(self.i32_type, 0, 0),
            "parse_errno_set",
        );
        try self.emitRuntimeGuard(has_error);
    }

    fn emitFiniteFloatGuard(self: *Self, value: c.LLVMValueRef) !void {
        const max_float = c.LLVMConstReal(self.f64_type, std.math.floatMax(f64));
        const min_float = c.LLVMConstReal(self.f64_type, -std.math.floatMax(f64));
        const is_nan = c.LLVMBuildFCmp(self.builder, c.LLVMRealUNO, value, value, "parse_is_nan");
        const too_large = c.LLVMBuildFCmp(self.builder, c.LLVMRealOGT, value, max_float, "parse_too_large");
        const too_small = c.LLVMBuildFCmp(self.builder, c.LLVMRealOLT, value, min_float, "parse_too_small");
        const infinite = c.LLVMBuildOr(self.builder, too_large, too_small, "parse_is_infinite");
        try self.emitRuntimeGuard(c.LLVMBuildOr(self.builder, is_nan, infinite, "parse_not_finite"));
    }

    fn emitStrictParseGuard(self: *Self, string: c.LLVMValueRef, end_pointer: c.LLVMValueRef) !void {
        const zero_i64 = c.LLVMConstInt(self.i64_type, 0, 0);
        const consumed_nothing = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, string, end_pointer, "parse_consumed_nothing");
        const starts_with_space = self.buildIsSpace(string, zero_i64);
        const end_char = c.LLVMBuildLoad2(self.builder, self.i8_type, end_pointer, "parse_end_char");
        const has_trailing_input = c.LLVMBuildICmp(
            self.builder,
            c.LLVMIntNE,
            end_char,
            c.LLVMConstInt(self.i8_type, 0, 0),
            "parse_has_trailing_input",
        );
        const invalid_start = c.LLVMBuildOr(self.builder, consumed_nothing, starts_with_space, "parse_invalid_start");
        try self.emitRuntimeGuard(c.LLVMBuildOr(self.builder, invalid_start, has_trailing_input, "parse_invalid"));
    }

    fn generateCompareOp(self: *Self, op: Opcode, type_metadata: i64) !void {
        const right_value = self.stack.pop() orelse return error.StackUnderflow;
        const left_value = self.stack.pop() orelse return error.StackUnderflow;
        const left_type = ir.decodeBinaryLeft(type_metadata);
        const right_type = ir.decodeBinaryRight(type_metadata);

        const left_is_tagged = left_type == .optional or left_type == .union_type;
        const right_is_tagged = right_type == .optional or right_type == .union_type;
        const cmp = if ((left_is_tagged or right_is_tagged) and (op == .eq or op == .neq)) blk: {
            const equality_function = self.functions.get("elba_tagged_equal").?;
            var arguments = [_]c.LLVMValueRef{ self.toI64(left_value), self.toI64(right_value) };
            const equal = c.LLVMBuildCall2(
                self.builder,
                c.LLVMGlobalGetValueType(equality_function),
                equality_function,
                &arguments,
                arguments.len,
                "tagged_equal",
            );
            break :blk if (op == .eq) equal else c.LLVMBuildNot(self.builder, equal, "tagged_not_equal");
        } else if (left_type == .string and right_type == .string and (op == .eq or op == .neq)) blk: {
            const strcmp_func = self.functions.get("strcmp").?;
            var arguments = [_]c.LLVMValueRef{ self.toPtr(left_value), self.toPtr(right_value) };
            const comparison = c.LLVMBuildCall2(
                self.builder,
                c.LLVMGlobalGetValueType(strcmp_func),
                strcmp_func,
                &arguments,
                2,
                "strcmp_result",
            );
            const zero = c.LLVMConstInt(self.i32_type, 0, 0);
            break :blk c.LLVMBuildICmp(
                self.builder,
                if (op == .eq) c.LLVMIntEQ else c.LLVMIntNE,
                comparison,
                zero,
                "string_cmp",
            );
        } else if (left_type == .float or right_type == .float) blk: {
            const left = self.asFloatOperand(left_value, left_type, "compare_left_float");
            const right = self.asFloatOperand(right_value, right_type, "compare_right_float");
            const predicate: c.LLVMRealPredicate = switch (op) {
                .eq => c.LLVMRealOEQ,
                .neq => c.LLVMRealUNE,
                .lt => c.LLVMRealOLT,
                .lte => c.LLVMRealOLE,
                .gt => c.LLVMRealOGT,
                .gte => c.LLVMRealOGE,
                else => unreachable,
            };
            break :blk c.LLVMBuildFCmp(self.builder, predicate, left, right, "float_cmp");
        } else blk: {
            const predicate: c.LLVMIntPredicate = switch (op) {
                .eq => c.LLVMIntEQ,
                .neq => c.LLVMIntNE,
                .lt => c.LLVMIntSLT,
                .lte => c.LLVMIntSLE,
                .gt => c.LLVMIntSGT,
                .gte => c.LLVMIntSGE,
                else => unreachable,
            };
            break :blk c.LLVMBuildICmp(self.builder, predicate, self.toI64(left_value), self.toI64(right_value), "cmp");
        };
        const result = c.LLVMBuildZExt(self.builder, cmp, self.i64_type, "cmp_ext");
        try self.stack.append(self.allocator, result);
    }

    fn generateLogicalOp(self: *Self, op: Opcode) !void {
        const right = self.stack.pop() orelse return error.StackUnderflow;
        const left = self.stack.pop() orelse return error.StackUnderflow;

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

    fn generateCall(self: *Self, func_name: []const u8, arg_count: i64, type_metadata: i64) !void {
        const argument_type = ir.decodeValueType(type_metadata);
        // Handle built-in functions
        if (std.mem.eql(u8, func_name, "println")) {
            try self.generatePrint(true, argument_type);
            return;
        }

        if (std.mem.eql(u8, func_name, "print")) {
            try self.generatePrint(false, argument_type);
            return;
        }

        if (std.mem.eql(u8, func_name, "int_to_str")) {
            try self.generateIntToStr();
            return;
        }

        if (std.mem.eql(u8, func_name, "float_to_str")) {
            try self.generateFloatToStr();
            return;
        }

        if (std.mem.eql(u8, func_name, "bool_to_str")) {
            const value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
            const zero = c.LLVMConstInt(self.i64_type, 0, 0);
            const condition = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, value, zero, "bool_to_str_cond");
            const true_string = try self.createStringConstant("true");
            const false_string = try self.createStringConstant("false");
            try self.stack.append(self.allocator, c.LLVMBuildSelect(self.builder, condition, true_string, false_string, "bool_to_str"));
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

        if (std.mem.eql(u8, func_name, "str_substring")) {
            try self.generateStrSubstring();
            return;
        }

        if (std.mem.eql(u8, func_name, "str_contains")) {
            const needle = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
            const string = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
            const strstr_func = self.functions.get("strstr").?;
            var arguments = [_]c.LLVMValueRef{ string, needle };
            const found = c.LLVMBuildCall2(
                self.builder,
                c.LLVMGlobalGetValueType(strstr_func),
                strstr_func,
                &arguments,
                2,
                "str_contains_ptr",
            );
            const null_pointer = c.LLVMConstNull(self.ptr_type);
            const result = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, found, null_pointer, "str_contains");
            try self.stack.append(self.allocator, c.LLVMBuildZExt(self.builder, result, self.i64_type, "str_contains_ext"));
            return;
        }

        if (std.mem.eql(u8, func_name, "str_trim")) {
            try self.generateStrTrim();
            return;
        }

        if (std.mem.eql(u8, func_name, "str_split")) {
            try self.generateStrSplit();
            return;
        }

        if (std.mem.eql(u8, func_name, "str_to_int")) {
            const string = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
            const strtoll_func = self.functions.get("strtoll").?;
            const errno_pointer = self.resetErrno();
            const end_slot = c.LLVMBuildAlloca(self.builder, self.ptr_type, "str_to_int_end");
            var arguments = [_]c.LLVMValueRef{
                string,
                end_slot,
                c.LLVMConstInt(self.i32_type, 10, 0),
            };
            const result = c.LLVMBuildCall2(
                self.builder,
                c.LLVMGlobalGetValueType(strtoll_func),
                strtoll_func,
                &arguments,
                3,
                "str_to_int",
            );
            const end_pointer = c.LLVMBuildLoad2(self.builder, self.ptr_type, end_slot, "str_to_int_end_ptr");
            try self.emitStrictParseGuard(string, end_pointer);
            try self.emitErrnoGuard(errno_pointer);
            try self.stack.append(self.allocator, result);
            return;
        }

        if (std.mem.eql(u8, func_name, "str_to_float")) {
            const string = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
            const strtod_func = self.functions.get("strtod").?;
            const errno_pointer = self.resetErrno();
            const end_slot = c.LLVMBuildAlloca(self.builder, self.ptr_type, "str_to_float_end");
            var arguments = [_]c.LLVMValueRef{ string, end_slot };
            const result = c.LLVMBuildCall2(
                self.builder,
                c.LLVMGlobalGetValueType(strtod_func),
                strtod_func,
                &arguments,
                2,
                "str_to_float",
            );
            const end_pointer = c.LLVMBuildLoad2(self.builder, self.ptr_type, end_slot, "str_to_float_end_ptr");
            try self.emitStrictParseGuard(string, end_pointer);
            try self.emitErrnoGuard(errno_pointer);
            try self.emitFiniteFloatGuard(result);
            try self.stack.append(self.allocator, result);
            return;
        }

        if (std.mem.eql(u8, func_name, "int_to_float")) {
            const value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
            try self.stack.append(self.allocator, c.LLVMBuildSIToFP(self.builder, value, self.f64_type, "int_to_float"));
            return;
        }

        if (std.mem.eql(u8, func_name, "float_to_int")) {
            const value = self.toF64(self.stack.pop() orelse return error.StackUnderflow);
            try self.emitFiniteFloatGuard(value);
            const lower = c.LLVMConstReal(self.f64_type, -9223372036854775808.0);
            const upper = c.LLVMConstReal(self.f64_type, 9223372036854775808.0);
            const too_small = c.LLVMBuildFCmp(self.builder, c.LLVMRealOLT, value, lower, "float_to_int_too_small");
            const too_large = c.LLVMBuildFCmp(self.builder, c.LLVMRealOGE, value, upper, "float_to_int_too_large");
            try self.emitRuntimeGuard(c.LLVMBuildOr(self.builder, too_small, too_large, "float_to_int_out_of_range"));
            try self.stack.append(self.allocator, c.LLVMBuildFPToSI(self.builder, value, self.i64_type, "float_to_int"));
            return;
        }

        if (std.mem.eql(u8, func_name, "array_len")) {
            const array = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
            const length = c.LLVMBuildLoad2(self.builder, self.i64_type, array, "array_len");
            try self.stack.append(self.allocator, length);
            return;
        }

        if (std.mem.eql(u8, func_name, "array_push")) {
            try self.generateArrayPush();
            return;
        }

        if (std.mem.eql(u8, func_name, "array_pop")) {
            try self.generateArrayPop();
            return;
        }

        if (std.mem.eql(u8, func_name, "array_slice")) {
            try self.generateArraySlice();
            return;
        }

        if (std.mem.eql(u8, func_name, "abs")) {
            const raw_value = self.stack.pop() orelse return error.StackUnderflow;
            if (argument_type == .float) {
                const value = self.toF64(raw_value);
                const zero = c.LLVMConstReal(self.f64_type, 0.0);
                const is_negative = c.LLVMBuildFCmp(self.builder, c.LLVMRealOLT, value, zero, "abs_float_negative");
                const negated = c.LLVMBuildFNeg(self.builder, value, "abs_float_negated");
                try self.stack.append(self.allocator, c.LLVMBuildSelect(self.builder, is_negative, negated, value, "abs_float"));
            } else {
                const value = self.toI64(raw_value);
                const minimum = c.LLVMConstInt(self.i64_type, @bitCast(@as(i64, std.math.minInt(i64))), 0);
                try self.emitRuntimeGuard(c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, value, minimum, "abs_int_overflow"));
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                const is_negative = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, value, zero, "abs_negative");
                const negated = c.LLVMBuildNeg(self.builder, value, "abs_negated");
                try self.stack.append(self.allocator, c.LLVMBuildSelect(self.builder, is_negative, negated, value, "abs"));
            }
            return;
        }

        if (std.mem.eql(u8, func_name, "min") or std.mem.eql(u8, func_name, "max")) {
            const right_value = self.stack.pop() orelse return error.StackUnderflow;
            const left_value = self.stack.pop() orelse return error.StackUnderflow;
            if (argument_type == .float) {
                const right = self.toF64(right_value);
                const left = self.toF64(left_value);
                const predicate: c.LLVMRealPredicate = if (std.mem.eql(u8, func_name, "min")) c.LLVMRealOLT else c.LLVMRealOGT;
                const select_left = c.LLVMBuildFCmp(self.builder, predicate, left, right, "minmax_float_cmp");
                try self.stack.append(self.allocator, c.LLVMBuildSelect(self.builder, select_left, left, right, "minmax_float"));
            } else {
                const right = self.toI64(right_value);
                const left = self.toI64(left_value);
                const predicate: c.LLVMIntPredicate = if (std.mem.eql(u8, func_name, "min")) c.LLVMIntSLT else c.LLVMIntSGT;
                const select_left = c.LLVMBuildICmp(self.builder, predicate, left, right, "minmax_cmp");
                try self.stack.append(self.allocator, c.LLVMBuildSelect(self.builder, select_left, left, right, "minmax"));
            }
            return;
        }

        if (std.mem.eql(u8, func_name, "sqrt") or
            std.mem.eql(u8, func_name, "floor") or
            std.mem.eql(u8, func_name, "ceil"))
        {
            const value = self.toF64(self.stack.pop() orelse return error.StackUnderflow);
            const math_func = self.functions.get(func_name).?;
            var arguments = [_]c.LLVMValueRef{value};
            const result = c.LLVMBuildCall2(
                self.builder,
                c.LLVMGlobalGetValueType(math_func),
                math_func,
                &arguments,
                1,
                "math_result",
            );
            try self.stack.append(self.allocator, result);
            return;
        }

        // Regular function call
        const llvm_func = self.functions.get(func_name) orelse return error.UndefinedFunction;

        var args = try self.allocator.alloc(c.LLVMValueRef, @intCast(arg_count));
        defer self.allocator.free(args);

        var i: usize = @intCast(arg_count);
        while (i > 0) {
            i -= 1;
            args[i] = self.toI64(self.stack.pop() orelse unreachable);
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

    fn generatePrint(self: *Self, newline: bool, argument_type: ?ir.ValueType) !void {
        const value = self.stack.pop() orelse unreachable;
        const printf_func = self.functions.get("printf").?;

        const fmt = try self.createStringConstant(switch (argument_type orelse .string) {
            .int => if (newline) "%lld\n" else "%lld",
            .float => if (newline) "%g\n" else "%g",
            .bool, .string => if (newline) "%s\n" else "%s",
            else => if (newline) "%s\n" else "%s",
        });
        const printable = switch (argument_type orelse .string) {
            .int => self.toI64(value),
            .float => self.toF64(value),
            .bool => blk: {
                const condition = c.LLVMBuildICmp(
                    self.builder,
                    c.LLVMIntNE,
                    self.toI64(value),
                    c.LLVMConstInt(self.i64_type, 0, 0),
                    "print_bool_condition",
                );
                const true_string = try self.createStringConstant("true");
                const false_string = try self.createStringConstant("false");
                break :blk c.LLVMBuildSelect(self.builder, condition, true_string, false_string, "print_bool");
            },
            .string => self.toPtr(value),
            else => self.toPtr(value),
        };

        var args = [_]c.LLVMValueRef{ fmt, printable };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(printf_func),
            printf_func,
            &args,
            2,
            if (newline) "println" else "print",
        );

        // Push dummy return value
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        try self.stack.append(self.allocator, zero);
    }

    fn generateIntToStr(self: *Self) !void {
        const value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);

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

    fn generateFloatToStr(self: *Self) !void {
        const value = self.toF64(self.stack.pop() orelse return error.StackUnderflow);

        const size = c.LLVMConstInt(self.i64_type, 64, 0);
        const malloc_func = self.functions.get("malloc").?;
        var malloc_args = [_]c.LLVMValueRef{size};
        const buffer = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(malloc_func),
            malloc_func,
            &malloc_args,
            1,
            "float_buffer",
        );

        const fmt = try self.createStringConstant("%g");
        const snprintf_func = self.functions.get("snprintf").?;
        var snprintf_args = [_]c.LLVMValueRef{ buffer, size, fmt, value };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(snprintf_func),
            snprintf_func,
            &snprintf_args,
            4,
            "float_to_str",
        );

        try self.stack.append(self.allocator, buffer);
    }

    fn generateStrLen(self: *Self) !void {
        const string = self.toPtr(self.stack.pop() orelse unreachable);
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
        const str2 = self.toPtr(self.stack.pop() orelse unreachable);
        const str1 = self.toPtr(self.stack.pop() orelse unreachable);

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

    fn generateStrSubstring(self: *Self) !void {
        const end_value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
        const start_value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
        const string = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
        const strlen_func = self.functions.get("strlen").?;
        var strlen_args = [_]c.LLVMValueRef{string};
        const string_length = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strlen_func),
            strlen_func,
            &strlen_args,
            1,
            "substring_string_length",
        );
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const start_negative = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, start_value, zero, "substring_start_negative");
        const end_before_start = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, end_value, start_value, "substring_end_before_start");
        const end_too_large = c.LLVMBuildICmp(self.builder, c.LLVMIntSGT, end_value, string_length, "substring_end_too_large");
        const invalid_order = c.LLVMBuildOr(self.builder, start_negative, end_before_start, "substring_invalid_order");
        try self.emitRuntimeGuard(c.LLVMBuildOr(self.builder, invalid_order, end_too_large, "substring_out_of_bounds"));
        const length = c.LLVMBuildSub(self.builder, end_value, start_value, "substring_length");
        const one = c.LLVMConstInt(self.i64_type, 1, 0);
        const allocation_size = c.LLVMBuildAdd(self.builder, length, one, "substring_size");

        const malloc_func = self.functions.get("malloc").?;
        var malloc_args = [_]c.LLVMValueRef{allocation_size};
        const buffer = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(malloc_func),
            malloc_func,
            &malloc_args,
            1,
            "substring_buffer",
        );

        var source_indices = [_]c.LLVMValueRef{start_value};
        const source = c.LLVMBuildGEP2(self.builder, self.i8_type, string, &source_indices, 1, "substring_source");
        const memcpy_func = self.functions.get("memcpy").?;
        var copy_args = [_]c.LLVMValueRef{ buffer, source, length };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(memcpy_func),
            memcpy_func,
            &copy_args,
            3,
            "substring_copy",
        );

        var end_indices = [_]c.LLVMValueRef{length};
        const terminator = c.LLVMBuildGEP2(self.builder, self.i8_type, buffer, &end_indices, 1, "substring_end");
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.i8_type, 0, 0), terminator);
        try self.stack.append(self.allocator, buffer);
    }

    fn buildIsSpace(self: *Self, string: c.LLVMValueRef, index: c.LLVMValueRef) c.LLVMValueRef {
        var indices = [_]c.LLVMValueRef{index};
        const char_ptr = c.LLVMBuildGEP2(self.builder, self.i8_type, string, &indices, 1, "trim_char_ptr");
        const char_value = c.LLVMBuildLoad2(self.builder, self.i8_type, char_ptr, "trim_char");
        const char_i32 = c.LLVMBuildZExt(self.builder, char_value, self.i32_type, "trim_char_i32");
        const isspace_func = self.functions.get("isspace").?;
        var arguments = [_]c.LLVMValueRef{char_i32};
        const result = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(isspace_func),
            isspace_func,
            &arguments,
            1,
            "trim_isspace",
        );
        const zero = c.LLVMConstInt(self.i32_type, 0, 0);
        return c.LLVMBuildICmp(self.builder, c.LLVMIntNE, result, zero, "trim_is_space");
    }

    fn generateStrTrim(self: *Self) !void {
        const string = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
        const llvm_function = self.current_function orelse return error.FunctionNotFound;
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const one = c.LLVMConstInt(self.i64_type, 1, 0);

        const strlen_func = self.functions.get("strlen").?;
        var strlen_args = [_]c.LLVMValueRef{string};
        const total_length = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strlen_func),
            strlen_func,
            &strlen_args,
            1,
            "trim_total_length",
        );
        const start_slot = c.LLVMBuildAlloca(self.builder, self.i64_type, "trim_start");
        const end_slot = c.LLVMBuildAlloca(self.builder, self.i64_type, "trim_end");
        _ = c.LLVMBuildStore(self.builder, zero, start_slot);
        _ = c.LLVMBuildStore(self.builder, total_length, end_slot);

        const leading_cond = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "trim_leading_cond");
        const leading_check = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "trim_leading_check");
        const leading_advance = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "trim_leading_advance");
        const trailing_cond = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "trim_trailing_cond");
        const trailing_check = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "trim_trailing_check");
        const trailing_advance = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "trim_trailing_advance");
        const done = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "trim_done");
        _ = c.LLVMBuildBr(self.builder, leading_cond);

        c.LLVMPositionBuilderAtEnd(self.builder, leading_cond);
        const leading_start = c.LLVMBuildLoad2(self.builder, self.i64_type, start_slot, "trim_leading_start");
        const leading_end = c.LLVMBuildLoad2(self.builder, self.i64_type, end_slot, "trim_leading_end");
        const has_leading_char = c.LLVMBuildICmp(self.builder, c.LLVMIntULT, leading_start, leading_end, "trim_has_leading_char");
        _ = c.LLVMBuildCondBr(self.builder, has_leading_char, leading_check, trailing_cond);

        c.LLVMPositionBuilderAtEnd(self.builder, leading_check);
        const leading_space = self.buildIsSpace(string, leading_start);
        _ = c.LLVMBuildCondBr(self.builder, leading_space, leading_advance, trailing_cond);

        c.LLVMPositionBuilderAtEnd(self.builder, leading_advance);
        const next_start = c.LLVMBuildAdd(self.builder, leading_start, one, "trim_next_start");
        _ = c.LLVMBuildStore(self.builder, next_start, start_slot);
        _ = c.LLVMBuildBr(self.builder, leading_cond);

        c.LLVMPositionBuilderAtEnd(self.builder, trailing_cond);
        const trailing_start = c.LLVMBuildLoad2(self.builder, self.i64_type, start_slot, "trim_trailing_start");
        const trailing_end = c.LLVMBuildLoad2(self.builder, self.i64_type, end_slot, "trim_trailing_end");
        const has_trailing_char = c.LLVMBuildICmp(self.builder, c.LLVMIntUGT, trailing_end, trailing_start, "trim_has_trailing_char");
        _ = c.LLVMBuildCondBr(self.builder, has_trailing_char, trailing_check, done);

        c.LLVMPositionBuilderAtEnd(self.builder, trailing_check);
        const last_index = c.LLVMBuildSub(self.builder, trailing_end, one, "trim_last_index");
        const trailing_space = self.buildIsSpace(string, last_index);
        _ = c.LLVMBuildCondBr(self.builder, trailing_space, trailing_advance, done);

        c.LLVMPositionBuilderAtEnd(self.builder, trailing_advance);
        _ = c.LLVMBuildStore(self.builder, last_index, end_slot);
        _ = c.LLVMBuildBr(self.builder, trailing_cond);

        c.LLVMPositionBuilderAtEnd(self.builder, done);
        const final_start = c.LLVMBuildLoad2(self.builder, self.i64_type, start_slot, "trim_final_start");
        const final_end = c.LLVMBuildLoad2(self.builder, self.i64_type, end_slot, "trim_final_end");
        const final_length = c.LLVMBuildSub(self.builder, final_end, final_start, "trim_final_length");
        const allocation_size = c.LLVMBuildAdd(self.builder, final_length, one, "trim_size");
        const malloc_func = self.functions.get("malloc").?;
        var malloc_args = [_]c.LLVMValueRef{allocation_size};
        const buffer = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(malloc_func),
            malloc_func,
            &malloc_args,
            1,
            "trim_buffer",
        );
        var source_indices = [_]c.LLVMValueRef{final_start};
        const source = c.LLVMBuildGEP2(self.builder, self.i8_type, string, &source_indices, 1, "trim_source");
        const memcpy_func = self.functions.get("memcpy").?;
        var copy_args = [_]c.LLVMValueRef{ buffer, source, final_length };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(memcpy_func),
            memcpy_func,
            &copy_args,
            3,
            "trim_copy",
        );
        var terminator_indices = [_]c.LLVMValueRef{final_length};
        const terminator = c.LLVMBuildGEP2(self.builder, self.i8_type, buffer, &terminator_indices, 1, "trim_terminator");
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.i8_type, 0, 0), terminator);
        try self.stack.append(self.allocator, buffer);
    }

    fn copyStringBytes(self: *Self, source: c.LLVMValueRef, length: c.LLVMValueRef) c.LLVMValueRef {
        const one = c.LLVMConstInt(self.i64_type, 1, 0);
        const allocation_size = c.LLVMBuildAdd(self.builder, length, one, "string_copy_size");
        const malloc_func = self.functions.get("malloc").?;
        var malloc_args = [_]c.LLVMValueRef{allocation_size};
        const buffer = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(malloc_func),
            malloc_func,
            &malloc_args,
            1,
            "string_copy_buffer",
        );
        const memcpy_func = self.functions.get("memcpy").?;
        var copy_args = [_]c.LLVMValueRef{ buffer, source, length };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(memcpy_func),
            memcpy_func,
            &copy_args,
            3,
            "string_copy",
        );
        var terminator_indices = [_]c.LLVMValueRef{length};
        const terminator = c.LLVMBuildGEP2(self.builder, self.i8_type, buffer, &terminator_indices, 1, "string_copy_end");
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.i8_type, 0, 0), terminator);
        return buffer;
    }

    fn generateStrSplit(self: *Self) !void {
        const delimiter = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
        const string = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
        const llvm_function = self.current_function orelse return error.FunctionNotFound;
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const one = c.LLVMConstInt(self.i64_type, 1, 0);
        const strlen_func = self.functions.get("strlen").?;
        const strstr_func = self.functions.get("strstr").?;

        var delimiter_args = [_]c.LLVMValueRef{delimiter};
        const delimiter_length = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strlen_func),
            strlen_func,
            &delimiter_args,
            1,
            "split_delimiter_length",
        );
        const count_slot = c.LLVMBuildAlloca(self.builder, self.i64_type, "split_count");
        const cursor_slot = c.LLVMBuildAlloca(self.builder, self.ptr_type, "split_cursor");
        const match_slot = c.LLVMBuildAlloca(self.builder, self.ptr_type, "split_match");
        const index_slot = c.LLVMBuildAlloca(self.builder, self.i64_type, "split_index");
        _ = c.LLVMBuildStore(self.builder, one, count_slot);
        _ = c.LLVMBuildStore(self.builder, string, cursor_slot);

        const invalid_delimiter = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "split_invalid_delimiter");
        const count_cond = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "split_count_cond");
        const count_found = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "split_count_found");
        const count_done = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "split_count_done");
        const fill_cond = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "split_fill_cond");
        const fill_found = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "split_fill_found");
        const fill_last = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "split_fill_last");
        const done = c.LLVMAppendBasicBlockInContext(self.context, llvm_function, "split_done");

        const delimiter_is_empty = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, delimiter_length, zero, "split_empty_delimiter");
        _ = c.LLVMBuildCondBr(self.builder, delimiter_is_empty, invalid_delimiter, count_cond);

        c.LLVMPositionBuilderAtEnd(self.builder, invalid_delimiter);
        const exit_func = self.functions.get("exit").?;
        var exit_args = [_]c.LLVMValueRef{c.LLVMConstInt(self.i32_type, 1, 0)};
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(exit_func),
            exit_func,
            &exit_args,
            1,
            "",
        );
        _ = c.LLVMBuildUnreachable(self.builder);

        c.LLVMPositionBuilderAtEnd(self.builder, count_cond);
        const count_cursor = c.LLVMBuildLoad2(self.builder, self.ptr_type, cursor_slot, "split_count_cursor");
        var find_args = [_]c.LLVMValueRef{ count_cursor, delimiter };
        const count_match = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strstr_func),
            strstr_func,
            &find_args,
            2,
            "split_count_match",
        );
        _ = c.LLVMBuildStore(self.builder, count_match, match_slot);
        const count_has_match = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, count_match, c.LLVMConstNull(self.ptr_type), "split_count_has_match");
        _ = c.LLVMBuildCondBr(self.builder, count_has_match, count_found, count_done);

        c.LLVMPositionBuilderAtEnd(self.builder, count_found);
        const old_count = c.LLVMBuildLoad2(self.builder, self.i64_type, count_slot, "split_old_count");
        _ = c.LLVMBuildStore(self.builder, c.LLVMBuildAdd(self.builder, old_count, one, "split_next_count"), count_slot);
        const found_match = c.LLVMBuildLoad2(self.builder, self.ptr_type, match_slot, "split_found_match");
        var next_cursor_indices = [_]c.LLVMValueRef{delimiter_length};
        const next_cursor = c.LLVMBuildGEP2(self.builder, self.i8_type, found_match, &next_cursor_indices, 1, "split_next_cursor");
        _ = c.LLVMBuildStore(self.builder, next_cursor, cursor_slot);
        _ = c.LLVMBuildBr(self.builder, count_cond);

        c.LLVMPositionBuilderAtEnd(self.builder, count_done);
        const part_count = c.LLVMBuildLoad2(self.builder, self.i64_type, count_slot, "split_part_count");
        const result = self.allocateArray(part_count, "split_result");
        _ = c.LLVMBuildStore(self.builder, part_count, result);
        _ = c.LLVMBuildStore(self.builder, string, cursor_slot);
        _ = c.LLVMBuildStore(self.builder, one, index_slot);
        _ = c.LLVMBuildBr(self.builder, fill_cond);

        c.LLVMPositionBuilderAtEnd(self.builder, fill_cond);
        const fill_cursor = c.LLVMBuildLoad2(self.builder, self.ptr_type, cursor_slot, "split_fill_cursor");
        var fill_find_args = [_]c.LLVMValueRef{ fill_cursor, delimiter };
        const fill_match = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strstr_func),
            strstr_func,
            &fill_find_args,
            2,
            "split_fill_match",
        );
        _ = c.LLVMBuildStore(self.builder, fill_match, match_slot);
        const fill_has_match = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, fill_match, c.LLVMConstNull(self.ptr_type), "split_fill_has_match");
        _ = c.LLVMBuildCondBr(self.builder, fill_has_match, fill_found, fill_last);

        c.LLVMPositionBuilderAtEnd(self.builder, fill_found);
        const fill_cursor_int = c.LLVMBuildPtrToInt(self.builder, fill_cursor, self.i64_type, "split_cursor_int");
        const fill_match_int = c.LLVMBuildPtrToInt(self.builder, fill_match, self.i64_type, "split_match_int");
        const part_length = c.LLVMBuildSub(self.builder, fill_match_int, fill_cursor_int, "split_part_length");
        const part = self.copyStringBytes(fill_cursor, part_length);
        const part_as_int = c.LLVMBuildPtrToInt(self.builder, part, self.i64_type, "split_part_as_int");
        const fill_index = c.LLVMBuildLoad2(self.builder, self.i64_type, index_slot, "split_fill_index");
        var part_indices = [_]c.LLVMValueRef{fill_index};
        const part_slot = c.LLVMBuildGEP2(self.builder, self.i64_type, result, &part_indices, 1, "split_part_slot");
        _ = c.LLVMBuildStore(self.builder, part_as_int, part_slot);
        _ = c.LLVMBuildStore(self.builder, c.LLVMBuildAdd(self.builder, fill_index, one, "split_next_index"), index_slot);
        var fill_next_indices = [_]c.LLVMValueRef{delimiter_length};
        const fill_next_cursor = c.LLVMBuildGEP2(self.builder, self.i8_type, fill_match, &fill_next_indices, 1, "split_fill_next_cursor");
        _ = c.LLVMBuildStore(self.builder, fill_next_cursor, cursor_slot);
        _ = c.LLVMBuildBr(self.builder, fill_cond);

        c.LLVMPositionBuilderAtEnd(self.builder, fill_last);
        var last_length_args = [_]c.LLVMValueRef{fill_cursor};
        const last_length = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(strlen_func),
            strlen_func,
            &last_length_args,
            1,
            "split_last_length",
        );
        const last_part = self.copyStringBytes(fill_cursor, last_length);
        const last_part_as_int = c.LLVMBuildPtrToInt(self.builder, last_part, self.i64_type, "split_last_as_int");
        const last_index = c.LLVMBuildLoad2(self.builder, self.i64_type, index_slot, "split_last_index");
        var last_indices = [_]c.LLVMValueRef{last_index};
        const last_slot = c.LLVMBuildGEP2(self.builder, self.i64_type, result, &last_indices, 1, "split_last_slot");
        _ = c.LLVMBuildStore(self.builder, last_part_as_int, last_slot);
        _ = c.LLVMBuildBr(self.builder, done);

        c.LLVMPositionBuilderAtEnd(self.builder, done);
        try self.stack.append(self.allocator, result);
    }

    fn allocateArray(self: *Self, element_count: c.LLVMValueRef, name: [*:0]const u8) c.LLVMValueRef {
        const one = c.LLVMConstInt(self.i64_type, 1, 0);
        const eight = c.LLVMConstInt(self.i64_type, 8, 0);
        const slot_count = c.LLVMBuildAdd(self.builder, element_count, one, "array_slots");
        const byte_count = c.LLVMBuildMul(self.builder, slot_count, eight, "array_bytes");
        const malloc_func = self.functions.get("malloc").?;
        var arguments = [_]c.LLVMValueRef{byte_count};
        return c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(malloc_func),
            malloc_func,
            &arguments,
            1,
            name,
        );
    }

    fn copyArrayElements(
        self: *Self,
        destination: c.LLVMValueRef,
        source: c.LLVMValueRef,
        element_count: c.LLVMValueRef,
    ) void {
        const eight = c.LLVMConstInt(self.i64_type, 8, 0);
        const byte_count = c.LLVMBuildMul(self.builder, element_count, eight, "array_copy_bytes");
        const memcpy_func = self.functions.get("memcpy").?;
        var arguments = [_]c.LLVMValueRef{ destination, source, byte_count };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMGlobalGetValueType(memcpy_func),
            memcpy_func,
            &arguments,
            3,
            "array_copy",
        );
    }

    fn generateArrayPush(self: *Self) !void {
        const value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
        const array = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
        const old_length = c.LLVMBuildLoad2(self.builder, self.i64_type, array, "array_old_len");
        const one = c.LLVMConstInt(self.i64_type, 1, 0);
        const new_length = c.LLVMBuildAdd(self.builder, old_length, one, "array_new_len");
        const result = self.allocateArray(new_length, "array_push_result");

        // Copy the old header and elements, then update the header and append.
        self.copyArrayElements(result, array, new_length);
        _ = c.LLVMBuildStore(self.builder, new_length, result);
        var value_indices = [_]c.LLVMValueRef{new_length};
        const value_ptr = c.LLVMBuildGEP2(self.builder, self.i64_type, result, &value_indices, 1, "array_push_slot");
        _ = c.LLVMBuildStore(self.builder, value, value_ptr);
        try self.stack.append(self.allocator, result);
    }

    fn generateArrayPop(self: *Self) !void {
        const array = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
        const old_length = c.LLVMBuildLoad2(self.builder, self.i64_type, array, "array_old_len");
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const is_empty = c.LLVMBuildICmp(self.builder, c.LLVMIntSLE, old_length, zero, "array_pop_empty");
        try self.emitRuntimeGuard(is_empty);
        const one = c.LLVMConstInt(self.i64_type, 1, 0);
        const new_length = c.LLVMBuildSub(self.builder, old_length, one, "array_new_len");
        const result = self.allocateArray(new_length, "array_pop_result");
        _ = c.LLVMBuildStore(self.builder, new_length, result);

        var first_indices = [_]c.LLVMValueRef{one};
        const destination = c.LLVMBuildGEP2(self.builder, self.i64_type, result, &first_indices, 1, "array_pop_dest");
        const source = c.LLVMBuildGEP2(self.builder, self.i64_type, array, &first_indices, 1, "array_pop_source");
        self.copyArrayElements(destination, source, new_length);
        try self.stack.append(self.allocator, result);
    }

    fn generateArraySlice(self: *Self) !void {
        const end_value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
        const start_value = self.toI64(self.stack.pop() orelse return error.StackUnderflow);
        const array = self.toPtr(self.stack.pop() orelse return error.StackUnderflow);
        const array_length = c.LLVMBuildLoad2(self.builder, self.i64_type, array, "array_slice_array_len");
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const start_negative = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, start_value, zero, "array_slice_start_negative");
        const end_before_start = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, end_value, start_value, "array_slice_end_before_start");
        const end_too_large = c.LLVMBuildICmp(self.builder, c.LLVMIntSGT, end_value, array_length, "array_slice_end_too_large");
        const invalid_order = c.LLVMBuildOr(self.builder, start_negative, end_before_start, "array_slice_invalid_order");
        try self.emitRuntimeGuard(c.LLVMBuildOr(self.builder, invalid_order, end_too_large, "array_slice_out_of_bounds"));
        const length = c.LLVMBuildSub(self.builder, end_value, start_value, "array_slice_len");
        const result = self.allocateArray(length, "array_slice_result");
        _ = c.LLVMBuildStore(self.builder, length, result);

        const one = c.LLVMConstInt(self.i64_type, 1, 0);
        var destination_indices = [_]c.LLVMValueRef{one};
        const destination = c.LLVMBuildGEP2(self.builder, self.i64_type, result, &destination_indices, 1, "array_slice_dest");
        const source_index = c.LLVMBuildAdd(self.builder, start_value, one, "array_slice_source_index");
        var source_indices = [_]c.LLVMValueRef{source_index};
        const source = c.LLVMBuildGEP2(self.builder, self.i64_type, array, &source_indices, 1, "array_slice_source");
        self.copyArrayElements(destination, source, length);
        try self.stack.append(self.allocator, result);
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
