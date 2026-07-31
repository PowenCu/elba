const std = @import("std");
const ir = @import("../backend/ir.zig");
const Instruction = ir.Instruction;
const Program = ir.Program;
const Function = ir.Function;
const Opcode = ir.Opcode;
const ValueType = ir.ValueType;

/// C Code Generator - Transpiles Elba IR to C code
pub const CCodeGen = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    indent_level: usize,
    label_counter: usize,
    variables: std.StringHashMap(bool), // Track declared variables

    // Track which features are used for optimized code generation
    uses_strings: bool,
    uses_arrays: bool,
    uses_structs: bool,
    uses_floats: bool,
    uses_tagged_values: bool,
    used_builtins: std.StringHashMap(bool),

    const BuiltinFunction = enum {
        println,
        print,
        str_len,
        str_concat,
        str_substring,
        str_split,
        str_trim,
        str_contains,
        str_to_int,
        str_to_float,
        int_to_str,
        float_to_str,
        bool_to_str,
        int_to_float,
        float_to_int,
        array_len,
        array_push,
        array_pop,
        array_slice,
        abs,
        sqrt,
        floor,
        ceil,
        min,
        max,

        pub fn fromName(name: []const u8) ?BuiltinFunction {
            const map = std.StaticStringMap(BuiltinFunction).initComptime(.{
                .{ "println", .println },
                .{ "print", .print },
                .{ "str_len", .str_len },
                .{ "str_concat", .str_concat },
                .{ "str_substring", .str_substring },
                .{ "str_split", .str_split },
                .{ "str_trim", .str_trim },
                .{ "str_contains", .str_contains },
                .{ "str_to_int", .str_to_int },
                .{ "str_to_float", .str_to_float },
                .{ "int_to_str", .int_to_str },
                .{ "float_to_str", .float_to_str },
                .{ "bool_to_str", .bool_to_str },
                .{ "int_to_float", .int_to_float },
                .{ "float_to_int", .float_to_int },
                .{ "array_len", .array_len },
                .{ "array_push", .array_push },
                .{ "array_pop", .array_pop },
                .{ "array_slice", .array_slice },
                .{ "abs", .abs },
                .{ "sqrt", .sqrt },
                .{ "floor", .floor },
                .{ "ceil", .ceil },
                .{ "min", .min },
                .{ "max", .max },
            });
            return map.get(name);
        }

        pub fn usesStrings(self: BuiltinFunction) bool {
            return switch (self) {
                .println, .print, .str_len, .str_concat, .str_substring, .str_split, .str_trim, .str_contains, .str_to_int, .str_to_float, .int_to_str, .float_to_str, .bool_to_str => true,
                else => false,
            };
        }

        pub fn usesFloats(self: BuiltinFunction) bool {
            return switch (self) {
                .str_to_float,
                .float_to_str,
                .int_to_float,
                .float_to_int,
                .sqrt,
                .floor,
                .ceil,
                .abs,
                .min,
                .max,
                => true,
                else => false,
            };
        }

        pub fn usesArrays(self: BuiltinFunction) bool {
            return switch (self) {
                .array_len, .array_push, .array_pop, .array_slice, .str_split => true,
                else => false,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) !CCodeGen {
        return .{
            .allocator = allocator,
            .output = try std.ArrayList(u8).initCapacity(allocator, 4096),
            .indent_level = 0,
            .label_counter = 0,
            .variables = std.StringHashMap(bool).init(allocator),
            .uses_strings = false,
            .uses_arrays = false,
            .uses_structs = false,
            .uses_floats = false,
            .uses_tagged_values = false,
            .used_builtins = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn deinit(self: *CCodeGen) void {
        self.output.deinit(self.allocator);
        self.variables.deinit();
        self.used_builtins.deinit();
    }

    /// Generate C code from IR program
    pub fn generate(self: *CCodeGen, program: Program) ![]const u8 {
        // Analyze program to detect used features
        try self.analyzeProgram(program);

        // Write header
        try self.writeHeader();

        // Write runtime support functions (only what's needed)
        try self.writeRuntimeSupport();

        // Forward declare all functions
        try self.writeLine("// ============================================");
        try self.writeLine("// Function Declarations");
        try self.writeLine("// ============================================");
        for (program.functions) |func| {
            try self.writeFunctionDeclaration(func);
        }
        try self.writeLine("");

        // Generate all functions
        try self.writeLine("// ============================================");
        try self.writeLine("// Function Implementations");
        try self.writeLine("// ============================================");
        for (program.functions) |func| {
            try self.generateFunction(func);
            try self.writeLine("");
        }

        // Generate main entry point
        try self.writeLine("// ============================================");
        try self.writeLine("// Program Entry Point");
        try self.writeLine("// ============================================");
        try self.generateMain(program.entry_point);

        return self.output.items;
    }

    /// Analyze program to detect which features are used
    fn analyzeProgram(self: *CCodeGen, program: Program) !void {
        for (program.functions) |func| {
            for (func.instructions) |inst| {
                switch (inst.op) {
                    .load_const_str => self.uses_strings = true,
                    .load_const_float, .pow => self.uses_floats = true,
                    .add => {
                        if (ir.decodeBinaryLeft(inst.operand3) == .string and
                            ir.decodeBinaryRight(inst.operand3) == .string)
                        {
                            self.uses_strings = true;
                            try self.used_builtins.put("str_concat", true);
                        }
                        if (ir.decodeBinaryLeft(inst.operand3) == .float or
                            ir.decodeBinaryRight(inst.operand3) == .float)
                        {
                            self.uses_floats = true;
                        }
                    },
                    .sub, .mul, .div, .mod, .eq, .neq, .lt, .lte, .gt, .gte => {
                        if (ir.decodeBinaryLeft(inst.operand3) == .float or
                            ir.decodeBinaryRight(inst.operand3) == .float)
                        {
                            self.uses_floats = true;
                        }
                    },
                    .neg => if (ir.decodeValueType(inst.operand3) == .float) {
                        self.uses_floats = true;
                    },
                    .array_new, .array_get, .array_set => self.uses_arrays = true,
                    .struct_new, .field_get, .field_set => self.uses_structs = true,
                    .optional_wrap, .optional_unwrap, .optional_is_null => self.uses_tagged_values = true,
                    .type_check => {
                        const checked_type = ir.decodeValueType(inst.operand3);
                        if (checked_type == .optional or checked_type == .union_type) self.uses_tagged_values = true;
                    },
                    .call => {
                        if (inst.string_data) |func_name| {
                            // Check if this is a builtin function
                            if (BuiltinFunction.fromName(func_name)) |builtin| {
                                try self.used_builtins.put(func_name, true);
                                if (builtin.usesStrings()) {
                                    self.uses_strings = true;
                                }
                                if (builtin.usesFloats()) {
                                    self.uses_floats = true;
                                }
                                if (builtin.usesArrays()) {
                                    self.uses_arrays = true;
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// Write C header includes and definitions
    fn writeHeader(self: *CCodeGen) !void {
        try self.writeLine("// Generated by Elba Compiler");
        try self.writeLine("// Do not edit this file manually");
        try self.writeLine("// Optimized for performance");
        try self.writeLine("");

        // Enable compiler optimizations
        try self.writeLine("#ifdef __GNUC__");
        try self.writeLine("#pragma GCC optimize(\"O3,inline,fast-math\")");
        try self.writeLine("#endif");
        try self.writeLine("");

        try self.writeLine("#include <stdio.h>");
        try self.writeLine("#include <stdlib.h>");
        try self.writeLine("#include <stdint.h>");
        try self.writeLine("#include <stdbool.h>");
        try self.writeLine("#include <string.h>");
        if (self.used_builtins.contains("str_trim") or
            self.used_builtins.contains("str_to_int") or
            self.used_builtins.contains("str_to_float"))
        {
            try self.writeLine("#include <ctype.h>");
        }
        if (self.used_builtins.contains("str_to_int") or self.used_builtins.contains("str_to_float")) {
            try self.writeLine("#include <errno.h>");
        }

        // Only include math.h if math functions are used
        if (self.uses_floats or self.used_builtins.contains("sqrt") or
            self.used_builtins.contains("floor") or self.used_builtins.contains("ceil") or
            self.used_builtins.contains("abs"))
        {
            try self.writeLine("#include <math.h>");
        }

        try self.writeLine("");
        try self.writeLine("// ============================================");
        try self.writeLine("// Elba Runtime Types");
        try self.writeLine("// ============================================");
        try self.writeLine("typedef int64_t ElbaInt;");

        if (self.uses_floats) {
            try self.writeLine("typedef double ElbaFloat;");
        }

        try self.writeLine("typedef bool ElbaBool;");

        if (self.uses_strings) {
            try self.writeLine("typedef const char* ElbaString;");
        }

        try self.writeLine("");
        try self.writeLine("// ============================================");
        try self.writeLine("// Stack-Based VM");
        try self.writeLine("// ============================================");
        try self.writeLine("#define STACK_SIZE 4096");
        try self.writeLine("typedef struct {");
        try self.writeLine("    uint64_t bits;");
        try self.writeLine("} StackValue;");
        if (self.uses_tagged_values) {
            try self.writeLine("typedef struct {");
            try self.writeLine("    ElbaInt tag;");
            try self.writeLine("    uint64_t bits;");
            try self.writeLine("    const char* type_name;");
            try self.writeLine("} ElbaTaggedValue;");
        }
        try self.writeLine("");
        try self.writeLine("static StackValue stack[STACK_SIZE];");
        try self.writeLine("static int stack_top = 0;");
        try self.writeLine("");

        // Memory management (only if dynamic allocation is used)
        if (self.uses_strings or self.uses_arrays or self.uses_structs or self.uses_tagged_values) {
            try self.writeLine("// ============================================");
            try self.writeLine("// Memory Management");
            try self.writeLine("// ============================================");
            try self.writeLine("#define MAX_ALLOCATIONS 1024");
            try self.writeLine("static void* allocations[MAX_ALLOCATIONS];");
            try self.writeLine("static int allocation_count = 0;");
            try self.writeLine("");
            try self.writeLine("static void* elba_malloc(size_t size) {");
            try self.writeLine("    void* ptr = malloc(size);");
            try self.writeLine("    if (ptr && allocation_count < MAX_ALLOCATIONS) {");
            try self.writeLine("        allocations[allocation_count++] = ptr;");
            try self.writeLine("    }");
            try self.writeLine("    return ptr;");
            try self.writeLine("}");
            try self.writeLine("");
            try self.writeLine("static void elba_cleanup(void) {");
            try self.writeLine("    for (int i = 0; i < allocation_count; i++) {");
            try self.writeLine("        free(allocations[i]);");
            try self.writeLine("    }");
            try self.writeLine("    allocation_count = 0;");
            try self.writeLine("}");
            try self.writeLine("");
        } else {
            // Simple cleanup for no dynamic allocations
            try self.writeLine("static void elba_cleanup(void) { /* no cleanup needed */ }");
            try self.writeLine("");
        }

        try self.writeLine("static void elba_check_stack_overflow(void) {");
        try self.writeLine("    if (stack_top >= STACK_SIZE) {");
        try self.writeLine("        fprintf(stderr, \"Stack overflow!\\n\");");
        try self.writeLine("        elba_cleanup();");
        try self.writeLine("        exit(1);");
        try self.writeLine("    }");
        try self.writeLine("}");
        try self.writeLine("");
        try self.writeLine("static void elba_check_stack_underflow(void) {");
        try self.writeLine("    if (stack_top <= 0) {");
        try self.writeLine("        fprintf(stderr, \"Stack underflow!\\n\");");
        try self.writeLine("        elba_cleanup();");
        try self.writeLine("        exit(1);");
        try self.writeLine("    }");
        try self.writeLine("}");
        try self.writeLine("");
    }

    /// Write runtime support functions
    fn writeRuntimeSupport(self: *CCodeGen) !void {
        try self.writeLine("// ============================================");
        try self.writeLine("// Runtime Support Functions");
        try self.writeLine("// ============================================");
        try self.writeLine("");

        // Always generate core stack operations
        try self.writeLine("// Stack manipulation");
        try self.writeLine("static inline void elba_push_int(ElbaInt value) {");
        try self.writeLine("    elba_check_stack_overflow();");
        try self.writeLine("    StackValue slot;");
        try self.writeLine("    memcpy(&slot.bits, &value, sizeof(value));");
        try self.writeLine("    stack[stack_top++] = slot;");
        try self.writeLine("}");
        try self.writeLine("");

        if (self.uses_floats) {
            try self.writeLine("static inline void elba_push_float(ElbaFloat value) {");
            try self.writeLine("    elba_check_stack_overflow();");
            try self.writeLine("    StackValue slot;");
            try self.writeLine("    memcpy(&slot.bits, &value, sizeof(value));");
            try self.writeLine("    stack[stack_top++] = slot;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        try self.writeLine("static inline void elba_push_bool(ElbaBool value) {");
        try self.writeLine("    elba_check_stack_overflow();");
        try self.writeLine("    stack[stack_top++].bits = value ? 1u : 0u;");
        try self.writeLine("}");
        try self.writeLine("");

        if (self.uses_strings) {
            try self.writeLine("static inline void elba_push_string(ElbaString value) {");
            try self.writeLine("    elba_check_stack_overflow();");
            try self.writeLine("    stack[stack_top++].bits = (uint64_t)(uintptr_t)value;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        if (self.uses_arrays or self.uses_structs or self.uses_tagged_values) {
            try self.writeLine("static inline void elba_push_ptr(void* value) {");
            try self.writeLine("    elba_check_stack_overflow();");
            try self.writeLine("    stack[stack_top++].bits = (uint64_t)(uintptr_t)value;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        try self.writeLine("static inline ElbaInt elba_pop_int(void) {");
        try self.writeLine("    elba_check_stack_underflow();");
        try self.writeLine("    StackValue slot = stack[--stack_top];");
        try self.writeLine("    ElbaInt value;");
        try self.writeLine("    memcpy(&value, &slot.bits, sizeof(value));");
        try self.writeLine("    return value;");
        try self.writeLine("}");
        try self.writeLine("");

        if (self.uses_floats) {
            try self.writeLine("static inline ElbaFloat elba_pop_float(void) {");
            try self.writeLine("    elba_check_stack_underflow();");
            try self.writeLine("    StackValue slot = stack[--stack_top];");
            try self.writeLine("    ElbaFloat value;");
            try self.writeLine("    memcpy(&value, &slot.bits, sizeof(value));");
            try self.writeLine("    return value;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        try self.writeLine("static inline ElbaBool elba_pop_bool(void) {");
        try self.writeLine("    elba_check_stack_underflow();");
        try self.writeLine("    return stack[--stack_top].bits != 0;");
        try self.writeLine("}");
        try self.writeLine("");

        if (self.uses_strings) {
            try self.writeLine("static inline ElbaString elba_pop_string(void) {");
            try self.writeLine("    elba_check_stack_underflow();");
            try self.writeLine("    return (ElbaString)(uintptr_t)stack[--stack_top].bits;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        if (self.uses_arrays or self.uses_structs or self.uses_tagged_values) {
            try self.writeLine("static inline void* elba_pop_ptr(void) {");
            try self.writeLine("    elba_check_stack_underflow();");
            try self.writeLine("    return (void*)(uintptr_t)stack[--stack_top].bits;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        if (self.uses_tagged_values) {
            try self.write("#define ELBA_TAG_FLOAT ");
            try self.writeInt(@intFromEnum(ValueType.float));
            try self.writeLine("");
            try self.write("#define ELBA_TAG_STRING ");
            try self.writeInt(@intFromEnum(ValueType.string));
            try self.writeLine("");
            try self.write("#define ELBA_TAG_OPTIONAL ");
            try self.writeInt(@intFromEnum(ValueType.optional));
            try self.writeLine("");
            try self.write("#define ELBA_TAG_UNION ");
            try self.writeInt(@intFromEnum(ValueType.union_type));
            try self.writeLine("");
            try self.writeLine("static bool elba_tagged_equal(const ElbaTaggedValue* left, const ElbaTaggedValue* right) {");
            try self.writeLine("    if (!left || !right) return left == right;");
            try self.writeLine("    if (left->tag != right->tag) return false;");
            try self.writeLine("    if (strcmp(left->type_name, right->type_name) != 0) return false;");
            try self.writeLine("    if (left->tag == ELBA_TAG_FLOAT) {");
            try self.writeLine("        double left_value, right_value;");
            try self.writeLine("        memcpy(&left_value, &left->bits, sizeof(left_value));");
            try self.writeLine("        memcpy(&right_value, &right->bits, sizeof(right_value));");
            try self.writeLine("        return left_value == right_value;");
            try self.writeLine("    }");
            try self.writeLine("    if (left->tag == ELBA_TAG_STRING) {");
            try self.writeLine("        return strcmp((const char*)(uintptr_t)left->bits, (const char*)(uintptr_t)right->bits) == 0;");
            try self.writeLine("    }");
            try self.writeLine("    if (left->tag == ELBA_TAG_OPTIONAL || left->tag == ELBA_TAG_UNION) {");
            try self.writeLine("        return elba_tagged_equal((const ElbaTaggedValue*)(uintptr_t)left->bits, (const ElbaTaggedValue*)(uintptr_t)right->bits);");
            try self.writeLine("    }");
            try self.writeLine("    return left->bits == right->bits;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        try self.writeLine("// Checked integer arithmetic");
        try self.writeLine("static void elba_arithmetic_error(const char* message) {");
        try self.writeLine("    fprintf(stderr, \"%s\\n\", message);");
        try self.writeLine("    elba_cleanup();");
        try self.writeLine("    exit(1);");
        try self.writeLine("}");
        try self.writeLine("");
        try self.writeLine("static ElbaInt elba_checked_add(ElbaInt left, ElbaInt right) {");
        try self.writeLine("    ElbaInt result;");
        try self.writeLine("    if (__builtin_add_overflow(left, right, &result)) elba_arithmetic_error(\"Integer overflow!\");");
        try self.writeLine("    return result;");
        try self.writeLine("}");
        try self.writeLine("");
        try self.writeLine("static ElbaInt elba_checked_sub(ElbaInt left, ElbaInt right) {");
        try self.writeLine("    ElbaInt result;");
        try self.writeLine("    if (__builtin_sub_overflow(left, right, &result)) elba_arithmetic_error(\"Integer overflow!\");");
        try self.writeLine("    return result;");
        try self.writeLine("}");
        try self.writeLine("");
        try self.writeLine("static ElbaInt elba_checked_mul(ElbaInt left, ElbaInt right) {");
        try self.writeLine("    ElbaInt result;");
        try self.writeLine("    if (__builtin_mul_overflow(left, right, &result)) elba_arithmetic_error(\"Integer overflow!\");");
        try self.writeLine("    return result;");
        try self.writeLine("}");
        try self.writeLine("");
        try self.writeLine("static ElbaInt elba_checked_div(ElbaInt left, ElbaInt right) {");
        try self.writeLine("    if (right == 0) elba_arithmetic_error(\"Division by zero!\");");
        try self.writeLine("    if (left == INT64_MIN && right == -1) elba_arithmetic_error(\"Integer overflow!\");");
        try self.writeLine("    return left / right;");
        try self.writeLine("}");
        try self.writeLine("");
        try self.writeLine("static ElbaInt elba_checked_mod(ElbaInt left, ElbaInt right) {");
        try self.writeLine("    if (right == 0) elba_arithmetic_error(\"Division by zero!\");");
        try self.writeLine("    if (left == INT64_MIN && right == -1) elba_arithmetic_error(\"Integer overflow!\");");
        try self.writeLine("    return left % right;");
        try self.writeLine("}");
        try self.writeLine("");
        try self.writeLine("static ElbaInt elba_checked_pow(ElbaInt base, ElbaInt exponent) {");
        try self.writeLine("    if (exponent < 0) elba_arithmetic_error(\"Negative integer exponent!\");");
        try self.writeLine("    ElbaInt result = 1;");
        try self.writeLine("    while (exponent != 0) {");
        try self.writeLine("        if ((exponent & 1) != 0) result = elba_checked_mul(result, base);");
        try self.writeLine("        exponent >>= 1;");
        try self.writeLine("        if (exponent != 0) base = elba_checked_mul(base, base);");
        try self.writeLine("    }");
        try self.writeLine("    return result;");
        try self.writeLine("}");
        try self.writeLine("");

        // Generate I/O functions only if used
        if (self.used_builtins.contains("print") or self.used_builtins.contains("println")) {
            try self.writeLine("// I/O functions");

            if (self.uses_strings and (self.used_builtins.contains("print") or self.used_builtins.contains("println"))) {
                try self.writeLine("static void elba_print_int(ElbaInt value) {");
                try self.writeLine("    printf(\"%lld\", (long long)value);");
                try self.writeLine("}");
                try self.writeLine("");

                if (self.uses_floats) {
                    try self.writeLine("static void elba_print_float(ElbaFloat value) {");
                    try self.writeLine("    printf(\"%g\", value);");
                    try self.writeLine("}");
                    try self.writeLine("");
                }

                try self.writeLine("static void elba_print_string(ElbaString value) {");
                try self.writeLine("    printf(\"%s\", value);");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("println")) {
                try self.writeLine("static void elba_println_int(ElbaInt value) {");
                try self.writeLine("    printf(\"%lld\\n\", (long long)value);");
                try self.writeLine("}");
                try self.writeLine("");

                if (self.uses_floats) {
                    try self.writeLine("static void elba_println_float(ElbaFloat value) {");
                    try self.writeLine("    printf(\"%g\\n\", value);");
                    try self.writeLine("}");
                    try self.writeLine("");
                }

                try self.writeLine("static void elba_println_string(ElbaString value) {");
                try self.writeLine("    printf(\"%s\\n\", value);");
                try self.writeLine("}");
                try self.writeLine("");
            }
        }

        // Generate string functions only if used
        if (self.uses_strings) {
            try self.writeLine("// String functions");

            if (self.used_builtins.contains("str_len")) {
                try self.writeLine("static ElbaInt elba_str_len(ElbaString str) {");
                try self.writeLine("    return (ElbaInt)strlen(str);");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("str_concat")) {
                try self.writeLine("static ElbaString elba_str_concat(ElbaString a, ElbaString b) {");
                try self.writeLine("    size_t len_a = strlen(a);");
                try self.writeLine("    size_t len_b = strlen(b);");
                try self.writeLine("    char* result = (char*)elba_malloc(len_a + len_b + 1);");
                try self.writeLine("    if (!result) {");
                try self.writeLine("        fprintf(stderr, \"Memory allocation failed!\\n\");");
                try self.writeLine("        elba_cleanup();");
                try self.writeLine("        exit(1);");
                try self.writeLine("    }");
                try self.writeLine("    strcpy(result, a);");
                try self.writeLine("    strcat(result, b);");
                try self.writeLine("    return result;");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("str_substring")) {
                try self.writeLine("static ElbaString elba_str_substring(ElbaString str, ElbaInt start, ElbaInt end) {");
                try self.writeLine("    if (start < 0 || end < start || end > (ElbaInt)strlen(str)) {");
                try self.writeLine("        fprintf(stderr, \"String index out of bounds!\\n\");");
                try self.writeLine("        elba_cleanup();");
                try self.writeLine("        exit(1);");
                try self.writeLine("    }");
                try self.writeLine("    size_t len = end - start;");
                try self.writeLine("    char* result = (char*)elba_malloc(len + 1);");
                try self.writeLine("    if (!result) {");
                try self.writeLine("        fprintf(stderr, \"Memory allocation failed!\\n\");");
                try self.writeLine("        elba_cleanup();");
                try self.writeLine("        exit(1);");
                try self.writeLine("    }");
                try self.writeLine("    strncpy(result, str + start, len);");
                try self.writeLine("    result[len] = '\\0';");
                try self.writeLine("    return result;");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("int_to_str")) {
                try self.writeLine("static ElbaString elba_int_to_str(ElbaInt value) {");
                try self.writeLine("    char* result = (char*)elba_malloc(32);");
                try self.writeLine("    if (!result) {");
                try self.writeLine("        fprintf(stderr, \"Memory allocation failed!\\n\");");
                try self.writeLine("        elba_cleanup();");
                try self.writeLine("        exit(1);");
                try self.writeLine("    }");
                try self.writeLine("    snprintf(result, 32, \"%lld\", (long long)value);");
                try self.writeLine("    return result;");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("float_to_str")) {
                try self.writeLine("static ElbaString elba_float_to_str(ElbaFloat value) {");
                try self.writeLine("    char* result = (char*)elba_malloc(32);");
                try self.writeLine("    if (!result) {");
                try self.writeLine("        fprintf(stderr, \"Memory allocation failed!\\n\");");
                try self.writeLine("        elba_cleanup();");
                try self.writeLine("        exit(1);");
                try self.writeLine("    }");
                try self.writeLine("    snprintf(result, 32, \"%g\", value);");
                try self.writeLine("    return result;");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("bool_to_str")) {
                try self.writeLine("static ElbaString elba_bool_to_str(ElbaBool value) {");
                try self.writeLine("    return value ? \"true\" : \"false\";");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("str_contains")) {
                try self.writeLine("static ElbaBool elba_str_contains(ElbaString str, ElbaString needle) {");
                try self.writeLine("    return strstr(str, needle) != NULL;");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("str_trim")) {
                try self.writeLine("static ElbaString elba_str_trim(ElbaString str) {");
                try self.writeLine("    const char* start = str;");
                try self.writeLine("    while (*start && isspace((unsigned char)*start)) start++;");
                try self.writeLine("    const char* end = str + strlen(str);");
                try self.writeLine("    while (end > start && isspace((unsigned char)*(end - 1))) end--;");
                try self.writeLine("    size_t len = (size_t)(end - start);");
                try self.writeLine("    char* result = (char*)elba_malloc(len + 1);");
                try self.writeLine("    if (!result) { fprintf(stderr, \"Memory allocation failed!\\n\"); elba_cleanup(); exit(1); }");
                try self.writeLine("    memcpy(result, start, len);");
                try self.writeLine("    result[len] = '\\0';");
                try self.writeLine("    return result;");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("str_split")) {
                try self.writeLine("static ElbaInt* elba_str_split(ElbaString str, ElbaString delimiter) {");
                try self.writeLine("    size_t delimiter_len = strlen(delimiter);");
                try self.writeLine("    if (delimiter_len == 0) { fprintf(stderr, \"String split delimiter cannot be empty!\\n\"); elba_cleanup(); exit(1); }");
                try self.writeLine("    ElbaInt count = 1;");
                try self.writeLine("    const char* cursor = str;");
                try self.writeLine("    const char* match;");
                try self.writeLine("    while ((match = strstr(cursor, delimiter)) != NULL) { count++; cursor = match + delimiter_len; }");
                try self.writeLine("    ElbaInt* result = (ElbaInt*)elba_malloc((count + 1) * sizeof(ElbaInt));");
                try self.writeLine("    result[0] = count;");
                try self.writeLine("    cursor = str;");
                try self.writeLine("    for (ElbaInt index = 1; index <= count; index++) {");
                try self.writeLine("        match = strstr(cursor, delimiter);");
                try self.writeLine("        size_t len = match ? (size_t)(match - cursor) : strlen(cursor);");
                try self.writeLine("        char* part = (char*)elba_malloc(len + 1);");
                try self.writeLine("        memcpy(part, cursor, len);");
                try self.writeLine("        part[len] = '\\0';");
                try self.writeLine("        result[index] = (ElbaInt)(intptr_t)part;");
                try self.writeLine("        if (!match) break;");
                try self.writeLine("        cursor = match + delimiter_len;");
                try self.writeLine("    }");
                try self.writeLine("    return result;");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("str_to_int")) {
                try self.writeLine("static ElbaInt elba_str_to_int(ElbaString str) {");
                try self.writeLine("    char* end = NULL;");
                try self.writeLine("    errno = 0;");
                try self.writeLine("    long long value = strtoll(str, &end, 10);");
                try self.writeLine("    if (str == end || *end != '\\0' || isspace((unsigned char)*str) || errno == ERANGE) {");
                try self.writeLine("        fprintf(stderr, \"Invalid integer string!\\n\"); elba_cleanup(); exit(1);");
                try self.writeLine("    }");
                try self.writeLine("    return (ElbaInt)value;");
                try self.writeLine("}");
                try self.writeLine("");
            }

            if (self.used_builtins.contains("str_to_float")) {
                try self.writeLine("static ElbaFloat elba_str_to_float(ElbaString str) {");
                try self.writeLine("    char* end = NULL;");
                try self.writeLine("    errno = 0;");
                try self.writeLine("    ElbaFloat value = strtod(str, &end);");
                try self.writeLine("    if (str == end || *end != '\\0' || isspace((unsigned char)*str) || errno == ERANGE || !isfinite(value)) {");
                try self.writeLine("        fprintf(stderr, \"Invalid float string!\\n\"); elba_cleanup(); exit(1);");
                try self.writeLine("    }");
                try self.writeLine("    return value;");
                try self.writeLine("}");
                try self.writeLine("");
            }
        }

        // Generate math functions only if used
        if (self.used_builtins.contains("abs")) {
            try self.writeLine("// Math functions");
            if (self.uses_floats) {
                try self.writeLine("static ElbaFloat elba_abs_float(ElbaFloat value) {");
                try self.writeLine("    return fabs(value);");
                try self.writeLine("}");
                try self.writeLine("");
            }

            try self.writeLine("static ElbaInt elba_abs_int(ElbaInt value) {");
            try self.writeLine("    if (value == INT64_MIN) { fprintf(stderr, \"Absolute value is outside the int range!\\n\"); elba_cleanup(); exit(1); }");
            try self.writeLine("    return value < 0 ? -value : value;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        if (self.used_builtins.contains("sqrt")) {
            try self.writeLine("static ElbaFloat elba_sqrt(ElbaFloat value) {");
            try self.writeLine("    return sqrt(value);");
            try self.writeLine("}");
            try self.writeLine("");
        }

        if (self.used_builtins.contains("floor")) {
            try self.writeLine("static ElbaFloat elba_floor(ElbaFloat value) {");
            try self.writeLine("    return floor(value);");
            try self.writeLine("}");
            try self.writeLine("");
        }

        if (self.used_builtins.contains("ceil")) {
            try self.writeLine("static ElbaFloat elba_ceil(ElbaFloat value) {");
            try self.writeLine("    return ceil(value);");
            try self.writeLine("}");
            try self.writeLine("");
        }

        if (self.used_builtins.contains("min")) {
            try self.writeLine("static ElbaInt elba_min_int(ElbaInt a, ElbaInt b) {");
            try self.writeLine("    return a < b ? a : b;");
            try self.writeLine("}");
            try self.writeLine("");

            if (self.uses_floats) {
                try self.writeLine("static ElbaFloat elba_min_float(ElbaFloat a, ElbaFloat b) {");
                try self.writeLine("    return a < b ? a : b;");
                try self.writeLine("}");
                try self.writeLine("");
            }
        }

        if (self.used_builtins.contains("max")) {
            try self.writeLine("static ElbaInt elba_max_int(ElbaInt a, ElbaInt b) {");
            try self.writeLine("    return a > b ? a : b;");
            try self.writeLine("}");
            try self.writeLine("");

            if (self.uses_floats) {
                try self.writeLine("static ElbaFloat elba_max_float(ElbaFloat a, ElbaFloat b) {");
                try self.writeLine("    return a > b ? a : b;");
                try self.writeLine("}");
                try self.writeLine("");
            }
        }
    }

    /// Write function declaration
    fn writeFunctionDeclaration(self: *CCodeGen, func: Function) !void {
        // Check if function returns a value (has ret instruction that doesn't just return)
        const has_return_value = blk: {
            for (func.instructions) |inst| {
                if (inst.op == .ret) {
                    // IR return instructions use the shared StackValue carrier.
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (has_return_value) {
            try self.write("StackValue elba_");
        } else {
            try self.write("void elba_");
        }
        try self.write(func.name);
        try self.write("(");

        // Add parameters
        var i: usize = 0;
        while (i < func.param_count) : (i += 1) {
            if (i > 0) try self.write(", ");
            try self.write("StackValue param");
            try self.writeInt(@intCast(i));
        }

        try self.writeLine(");");
    }

    /// Generate a complete function
    fn generateFunction(self: *CCodeGen, func: Function) !void {
        // Clear variables for this function
        self.variables.clearRetainingCapacity();

        // Check if function returns a value
        const has_return_value = blk: {
            for (func.instructions) |inst| {
                if (inst.op == .ret) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (has_return_value) {
            try self.write("StackValue elba_");
        } else {
            try self.write("void elba_");
        }
        try self.write(func.name);
        try self.write("(");

        // Add parameters
        var i: usize = 0;
        while (i < func.param_count) : (i += 1) {
            if (i > 0) try self.write(", ");
            try self.write("StackValue param");
            try self.writeInt(@intCast(i));
        }

        try self.writeLine(") {");
        self.indent_level += 1;

        // Collect all variables used in this function (both params and locals)
        var var_names = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer var_names.deinit(self.allocator);

        const param_names = func.param_names;

        // Map parameters to their C variable names
        for (param_names, 0..) |pname, idx| {
            try self.writeIndent();
            try self.write("StackValue ");
            try self.write(pname);
            try self.write(" = param");
            try self.writeInt(@intCast(idx));
            try self.writeLine(";");
        }
        if (param_names.len > 0) {
            try self.writeLine("");
        }

        // Collect all OTHER variables (non-parameters) used in this function
        for (func.instructions) |inst| {
            if (inst.op == .store_var) {
                if (inst.string_data) |var_name| {
                    // Check if this is not a parameter
                    var is_param = false;
                    for (param_names) |pname| {
                        if (std.mem.eql(u8, pname, var_name)) {
                            is_param = true;
                            break;
                        }
                    }

                    if (!is_param) {
                        const result = try self.variables.getOrPut(var_name);
                        if (!result.found_existing) {
                            result.value_ptr.* = true;
                            try var_names.append(self.allocator, var_name);
                        }
                    }
                }
            }
        }

        // Declare all local variables (non-parameters) at the top of the function
        if (var_names.items.len > 0) {
            for (var_names.items) |var_name| {
                try self.writeIndent();
                try self.write("StackValue ");
                try self.write(var_name);
                try self.writeLine(" = { .bits = 0 };");
            }
            try self.writeLine("");
        }

        // Generate instructions
        try self.generateInstructions(func.instructions);

        self.indent_level -= 1;
        try self.writeLine("}");
    }

    /// Generate instructions with labels for jumps
    fn generateInstructions(self: *CCodeGen, instructions: []const Instruction) !void {
        // First pass: identify jump targets
        var jump_targets = std.AutoHashMap(usize, void).init(self.allocator);
        defer jump_targets.deinit();

        for (instructions) |inst| {
            switch (inst.op) {
                .jump, .jump_if_false, .jump_if_true => {
                    try jump_targets.put(@intCast(inst.operand1), {});
                },
                else => {},
            }
        }

        // Second pass: generate code
        for (instructions, 0..) |inst, i| {
            // Add label if this is a jump target
            if (jump_targets.contains(i)) {
                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("L");
                try self.writeInt(@intCast(i));
                try self.writeLine(":");
                self.indent_level += 1;
            }

            try self.generateInstruction(inst, i);
        }
    }

    /// Generate a single instruction
    fn generateInstruction(self: *CCodeGen, inst: Instruction, ip: usize) !void {
        _ = ip;

        try self.writeIndent();

        switch (inst.op) {
            .load_const_int => {
                try self.write("elba_push_int(");
                try self.writeInt(inst.operand1);
                try self.writeLine(");");
            },
            .load_const_float => {
                const f: f64 = @bitCast(inst.operand1);
                try self.write("elba_push_float(");
                try self.writeFloat(f);
                try self.writeLine(");");
            },
            .load_const_bool => {
                try self.write("elba_push_bool(");
                try self.write(if (inst.operand1 != 0) "true" else "false");
                try self.writeLine(");");
            },
            .load_const_str => {
                if (inst.string_data) |str| {
                    try self.write("elba_push_string(\"");
                    try self.writeEscapedString(str);
                    try self.writeLine("\");");
                }
            },
            .load_null => {
                try self.writeLine("elba_push_int(0); // null");
            },
            .load_var => {
                if (inst.string_data) |var_name| {
                    try self.writeLine("elba_check_stack_overflow();");
                    try self.write("stack[stack_top++] = ");
                    try self.write(var_name);
                    try self.writeLine(";");
                }
            },
            .store_var => {
                if (inst.string_data) |var_name| {
                    try self.writeLine("elba_check_stack_underflow();");
                    try self.write(var_name);
                    try self.writeLine(" = stack[--stack_top];");
                }
            },
            .add, .sub, .mul, .div, .mod => {
                try self.writeLine("{");
                self.indent_level += 1;
                const left_type = ir.decodeBinaryLeft(inst.operand3);
                const right_type = ir.decodeBinaryRight(inst.operand3);

                if (inst.op == .add and left_type == .string and right_type == .string) {
                    try self.writeIndent();
                    try self.writeLine("ElbaString _b = elba_pop_string();");
                    try self.writeIndent();
                    try self.writeLine("ElbaString _a = elba_pop_string();");
                    try self.writeIndent();
                    try self.writeLine("elba_push_string(elba_str_concat(_a, _b));");
                } else if (left_type == .float or right_type == .float) {
                    try self.writeIndent();
                    try self.write("ElbaFloat _b = ");
                    try self.writeLine(if (right_type == .float) "elba_pop_float();" else "(ElbaFloat)elba_pop_int();");
                    try self.writeIndent();
                    try self.write("ElbaFloat _a = ");
                    try self.writeLine(if (left_type == .float) "elba_pop_float();" else "(ElbaFloat)elba_pop_int();");
                    try self.writeIndent();
                    if (inst.op == .mod) {
                        try self.writeLine("elba_push_float(fmod(_a, _b));");
                    } else {
                        try self.write("elba_push_float(_a ");
                        try self.write(switch (inst.op) {
                            .add => "+",
                            .sub => "-",
                            .mul => "*",
                            .div => "/",
                            else => unreachable,
                        });
                        try self.writeLine(" _b);");
                    }
                } else {
                    try self.writeIndent();
                    try self.writeLine("ElbaInt _b = elba_pop_int();");
                    try self.writeIndent();
                    try self.writeLine("ElbaInt _a = elba_pop_int();");
                    try self.writeIndent();
                    try self.write("elba_push_int(");
                    try self.write(switch (inst.op) {
                        .add => "elba_checked_add",
                        .sub => "elba_checked_sub",
                        .mul => "elba_checked_mul",
                        .div => "elba_checked_div",
                        .mod => "elba_checked_mod",
                        else => unreachable,
                    });
                    try self.writeLine("(_a, _b));");
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .neg => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                if (ir.decodeValueType(inst.operand3) == .float) {
                    try self.writeLine("ElbaFloat _a = elba_pop_float();");
                    try self.writeIndent();
                    try self.writeLine("elba_push_float(-_a);");
                } else {
                    try self.writeLine("ElbaInt _a = elba_pop_int();");
                    try self.writeIndent();
                    try self.writeLine("elba_push_int(elba_checked_sub(0, _a));");
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .pow => {
                try self.writeLine("{");
                self.indent_level += 1;
                const left_type = ir.decodeBinaryLeft(inst.operand3);
                const right_type = ir.decodeBinaryRight(inst.operand3);
                if (left_type == .float or right_type == .float) {
                    try self.writeIndent();
                    try self.write("ElbaFloat _b = ");
                    try self.writeLine(if (right_type == .float) "elba_pop_float();" else "(ElbaFloat)elba_pop_int();");
                    try self.writeIndent();
                    try self.write("ElbaFloat _a = ");
                    try self.writeLine(if (left_type == .float) "elba_pop_float();" else "(ElbaFloat)elba_pop_int();");
                    try self.writeIndent();
                    try self.writeLine("elba_push_float(pow(_a, _b));");
                } else {
                    try self.writeIndent();
                    try self.writeLine("ElbaInt _b = elba_pop_int();");
                    try self.writeIndent();
                    try self.writeLine("ElbaInt _a = elba_pop_int();");
                    try self.writeIndent();
                    try self.writeLine("elba_push_int(elba_checked_pow(_a, _b));");
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .eq, .neq, .lt, .lte, .gt, .gte => {
                try self.writeLine("{");
                self.indent_level += 1;
                const left_type = ir.decodeBinaryLeft(inst.operand3);
                const right_type = ir.decodeBinaryRight(inst.operand3);

                const left_is_tagged = left_type == .optional or left_type == .union_type;
                const right_is_tagged = right_type == .optional or right_type == .union_type;
                if ((left_is_tagged or right_is_tagged) and (inst.op == .eq or inst.op == .neq)) {
                    try self.writeIndent();
                    try self.writeLine("elba_check_stack_underflow();");
                    try self.writeIndent();
                    try self.writeLine("ElbaTaggedValue* _b = (ElbaTaggedValue*)(uintptr_t)stack[--stack_top].bits;");
                    try self.writeIndent();
                    try self.writeLine("elba_check_stack_underflow();");
                    try self.writeIndent();
                    try self.writeLine("ElbaTaggedValue* _a = (ElbaTaggedValue*)(uintptr_t)stack[--stack_top].bits;");
                    try self.writeIndent();
                    try self.writeLine(if (inst.op == .eq)
                        "elba_push_bool(elba_tagged_equal(_a, _b));"
                    else
                        "elba_push_bool(!elba_tagged_equal(_a, _b));");
                } else if (left_type == .string and right_type == .string and (inst.op == .eq or inst.op == .neq)) {
                    try self.writeIndent();
                    try self.writeLine("ElbaString _b = elba_pop_string();");
                    try self.writeIndent();
                    try self.writeLine("ElbaString _a = elba_pop_string();");
                    try self.writeIndent();
                    try self.writeLine(if (inst.op == .eq)
                        "elba_push_bool(strcmp(_a, _b) == 0);"
                    else
                        "elba_push_bool(strcmp(_a, _b) != 0);");
                } else if (left_type == .float or right_type == .float) {
                    try self.writeIndent();
                    try self.write("ElbaFloat _b = ");
                    try self.writeLine(if (right_type == .float) "elba_pop_float();" else "(ElbaFloat)elba_pop_int();");
                    try self.writeIndent();
                    try self.write("ElbaFloat _a = ");
                    try self.writeLine(if (left_type == .float) "elba_pop_float();" else "(ElbaFloat)elba_pop_int();");
                    try self.writeIndent();
                    try self.write("elba_push_bool(_a ");
                    try self.write(switch (inst.op) {
                        .eq => "==",
                        .neq => "!=",
                        .lt => "<",
                        .lte => "<=",
                        .gt => ">",
                        .gte => ">=",
                        else => unreachable,
                    });
                    try self.writeLine(" _b);");
                } else {
                    try self.writeIndent();
                    try self.writeLine("ElbaInt _b = elba_pop_int();");
                    try self.writeIndent();
                    try self.writeLine("ElbaInt _a = elba_pop_int();");
                    try self.writeIndent();
                    try self.write("elba_push_bool(_a ");
                    try self.write(switch (inst.op) {
                        .eq => "==",
                        .neq => "!=",
                        .lt => "<",
                        .lte => "<=",
                        .gt => ">",
                        .gte => ">=",
                        else => unreachable,
                    });
                    try self.writeLine(" _b);");
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .and_op => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaBool _b = elba_pop_bool();");
                try self.writeIndent();
                try self.writeLine("ElbaBool _a = elba_pop_bool();");
                try self.writeIndent();
                try self.writeLine("elba_push_bool(_a && _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .or_op => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaBool _b = elba_pop_bool();");
                try self.writeIndent();
                try self.writeLine("ElbaBool _a = elba_pop_bool();");
                try self.writeIndent();
                try self.writeLine("elba_push_bool(_a || _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .not_op => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaBool _a = elba_pop_bool();");
                try self.writeIndent();
                try self.writeLine("elba_push_bool(!_a);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .jump => {
                try self.write("goto L");
                try self.writeInt(inst.operand1);
                try self.writeLine(";");
            },
            .jump_if_false => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaBool _cond = elba_pop_bool();");
                try self.writeIndent();
                try self.write("if (!_cond) goto L");
                try self.writeInt(inst.operand1);
                try self.writeLine(";");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .jump_if_true => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaBool _cond = elba_pop_bool();");
                try self.writeIndent();
                try self.write("if (_cond) goto L");
                try self.writeInt(inst.operand1);
                try self.writeLine(";");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .call => {
                if (inst.string_data) |func_name| {
                    const arg_count = inst.operand2;
                    const argument_type = ir.decodeValueType(inst.operand3);

                    // Handle built-in functions
                    if (std.mem.eql(u8, func_name, "println")) {
                        if (argument_type == .int) {
                            try self.writeLine("elba_println_int(elba_pop_int());");
                        } else if (argument_type == .float) {
                            try self.writeLine("elba_println_float(elba_pop_float());");
                        } else if (argument_type == .bool) {
                            try self.writeLine("printf(\"%s\\n\", elba_pop_bool() ? \"true\" : \"false\");");
                        } else {
                            try self.writeLine("elba_println_string(elba_pop_string());");
                        }
                        try self.writeLine("elba_push_int(0);  // void return");
                    } else if (std.mem.eql(u8, func_name, "print")) {
                        if (argument_type == .int) {
                            try self.writeLine("elba_print_int(elba_pop_int());");
                        } else if (argument_type == .float) {
                            try self.writeLine("elba_print_float(elba_pop_float());");
                        } else if (argument_type == .bool) {
                            try self.writeLine("printf(\"%s\", elba_pop_bool() ? \"true\" : \"false\");");
                        } else {
                            try self.writeLine("elba_print_string(elba_pop_string());");
                        }
                        try self.writeLine("elba_push_int(0);  // void return");
                    } else if (std.mem.eql(u8, func_name, "str_len")) {
                        try self.writeLine("elba_push_int(elba_str_len(elba_pop_string()));");
                    } else if (std.mem.eql(u8, func_name, "str_concat")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaString b = elba_pop_string();");
                        try self.writeIndent();
                        try self.writeLine("ElbaString a = elba_pop_string();");
                        try self.writeIndent();
                        try self.writeLine("elba_push_string(elba_str_concat(a, b));");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "str_substring")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaInt end = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt start = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine("ElbaString str = elba_pop_string();");
                        try self.writeIndent();
                        try self.writeLine("elba_push_string(elba_str_substring(str, start, end));");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "int_to_str")) {
                        try self.writeLine("elba_push_string(elba_int_to_str(elba_pop_int()));");
                    } else if (std.mem.eql(u8, func_name, "float_to_str")) {
                        try self.writeLine("elba_push_string(elba_float_to_str(elba_pop_float()));");
                    } else if (std.mem.eql(u8, func_name, "bool_to_str")) {
                        try self.writeLine("elba_push_string(elba_bool_to_str(elba_pop_bool()));");
                    } else if (std.mem.eql(u8, func_name, "str_contains")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaString needle = elba_pop_string();");
                        try self.writeIndent();
                        try self.writeLine("ElbaString str = elba_pop_string();");
                        try self.writeIndent();
                        try self.writeLine("elba_push_bool(elba_str_contains(str, needle));");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "str_trim")) {
                        try self.writeLine("elba_push_string(elba_str_trim(elba_pop_string()));");
                    } else if (std.mem.eql(u8, func_name, "str_split")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaString delimiter = elba_pop_string();");
                        try self.writeIndent();
                        try self.writeLine("ElbaString str = elba_pop_string();");
                        try self.writeIndent();
                        try self.writeLine("elba_push_ptr((void*)elba_str_split(str, delimiter));");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "str_to_int")) {
                        try self.writeLine("elba_push_int(elba_str_to_int(elba_pop_string()));");
                    } else if (std.mem.eql(u8, func_name, "str_to_float")) {
                        try self.writeLine("elba_push_float(elba_str_to_float(elba_pop_string()));");
                    } else if (std.mem.eql(u8, func_name, "int_to_float")) {
                        try self.writeLine("elba_push_float((ElbaFloat)elba_pop_int());");
                    } else if (std.mem.eql(u8, func_name, "float_to_int")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaFloat value = elba_pop_float();");
                        try self.writeIndent();
                        try self.writeLine("if (!isfinite(value) || value < -9223372036854775808.0 || value >= 9223372036854775808.0) { fprintf(stderr, \"Float cannot be represented as int!\\n\"); elba_cleanup(); exit(1); }");
                        try self.writeIndent();
                        try self.writeLine("elba_push_int((ElbaInt)value);");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "array_len")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaInt* arr = (ElbaInt*)elba_pop_ptr();");
                        try self.writeIndent();
                        try self.writeLine("elba_push_int(arr[0]);");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "array_push")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaInt value = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt* arr = (ElbaInt*)elba_pop_ptr();");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt size = arr[0];");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt* result = (ElbaInt*)elba_malloc((size + 2) * sizeof(ElbaInt));");
                        try self.writeIndent();
                        try self.writeLine("memcpy(result, arr, (size + 1) * sizeof(ElbaInt));");
                        try self.writeIndent();
                        try self.writeLine("result[0] = size + 1;");
                        try self.writeIndent();
                        try self.writeLine("result[size + 1] = value;");
                        try self.writeIndent();
                        try self.writeLine("elba_push_ptr((void*)result);");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "array_pop")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaInt* arr = (ElbaInt*)elba_pop_ptr();");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt size = arr[0];");
                        try self.writeIndent();
                        try self.writeLine("if (size <= 0) { fprintf(stderr, \"Cannot pop an empty array!\\n\"); elba_cleanup(); exit(1); }");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt* result = (ElbaInt*)elba_malloc(size * sizeof(ElbaInt));");
                        try self.writeIndent();
                        try self.writeLine("result[0] = size - 1;");
                        try self.writeIndent();
                        try self.writeLine("memcpy(result + 1, arr + 1, (size - 1) * sizeof(ElbaInt));");
                        try self.writeIndent();
                        try self.writeLine("elba_push_ptr((void*)result);");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "array_slice")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaInt end = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt start = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt* arr = (ElbaInt*)elba_pop_ptr();");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt size = arr[0];");
                        try self.writeIndent();
                        try self.writeLine("if (start < 0 || end < start || end > size) { fprintf(stderr, \"Array slice out of bounds!\\n\"); elba_cleanup(); exit(1); }");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt length = end - start;");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt* result = (ElbaInt*)elba_malloc((length + 1) * sizeof(ElbaInt));");
                        try self.writeIndent();
                        try self.writeLine("result[0] = length;");
                        try self.writeIndent();
                        try self.writeLine("memcpy(result + 1, arr + start + 1, length * sizeof(ElbaInt));");
                        try self.writeIndent();
                        try self.writeLine("elba_push_ptr((void*)result);");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "abs")) {
                        try self.writeLine(if (argument_type == .float)
                            "elba_push_float(elba_abs_float(elba_pop_float()));"
                        else
                            "elba_push_int(elba_abs_int(elba_pop_int()));");
                    } else if (std.mem.eql(u8, func_name, "sqrt")) {
                        try self.writeLine("elba_push_float(elba_sqrt(elba_pop_float()));");
                    } else if (std.mem.eql(u8, func_name, "floor")) {
                        try self.writeLine("elba_push_float(elba_floor(elba_pop_float()));");
                    } else if (std.mem.eql(u8, func_name, "ceil")) {
                        try self.writeLine("elba_push_float(elba_ceil(elba_pop_float()));");
                    } else if (std.mem.eql(u8, func_name, "min")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine(if (argument_type == .float) "ElbaFloat b = elba_pop_float();" else "ElbaInt b = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine(if (argument_type == .float) "ElbaFloat a = elba_pop_float();" else "ElbaInt a = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine(if (argument_type == .float) "elba_push_float(elba_min_float(a, b));" else "elba_push_int(elba_min_int(a, b));");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "max")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine(if (argument_type == .float) "ElbaFloat b = elba_pop_float();" else "ElbaInt b = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine(if (argument_type == .float) "ElbaFloat a = elba_pop_float();" else "ElbaInt a = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine(if (argument_type == .float) "elba_push_float(elba_max_float(a, b));" else "elba_push_int(elba_max_int(a, b));");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else {
                        // User-defined function - pop arguments in reverse order
                        if (arg_count > 0) {
                            try self.writeLine("{");
                            self.indent_level += 1;

                            // Pop arguments from stack in reverse order
                            var i: i64 = @intCast(arg_count - 1);
                            while (i >= 0) : (i -= 1) {
                                try self.writeIndent();
                                try self.write("StackValue arg");
                                try self.writeInt(@intCast(i));
                                try self.writeLine(" = stack[--stack_top];");
                            }

                            // Call function and push result back
                            try self.writeIndent();
                            try self.write("StackValue result = elba_");
                            try self.write(func_name);
                            try self.write("(");

                            i = 0;
                            while (i < arg_count) : (i += 1) {
                                if (i > 0) try self.write(", ");
                                try self.write("arg");
                                try self.writeInt(i);
                            }

                            try self.writeLine(");");
                            try self.writeIndent();
                            try self.writeLine("elba_check_stack_overflow();");
                            try self.writeIndent();
                            try self.writeLine("stack[stack_top++] = result;");

                            self.indent_level -= 1;
                            try self.writeIndent();
                            try self.writeLine("}");
                        } else {
                            try self.writeLine("{");
                            self.indent_level += 1;
                            try self.writeIndent();
                            try self.write("StackValue result = elba_");
                            try self.write(func_name);
                            try self.writeLine("();");
                            try self.writeIndent();
                            try self.writeLine("elba_check_stack_overflow();");
                            try self.writeIndent();
                            try self.writeLine("stack[stack_top++] = result;");
                            self.indent_level -= 1;
                            try self.writeIndent();
                            try self.writeLine("}");
                        }
                    }
                }
            },
            .ret => {
                try self.writeLine("elba_check_stack_underflow();");
                try self.writeLine("return stack[--stack_top];");
            },
            .pop => {
                try self.writeLine("elba_check_stack_underflow();");
                try self.writeLine("stack_top--;");
            },
            .dup => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("elba_check_stack_underflow();");
                try self.writeIndent();
                try self.writeLine("elba_check_stack_overflow();");
                try self.writeIndent();
                try self.writeLine("stack[stack_top] = stack[stack_top - 1];");
                try self.writeIndent();
                try self.writeLine("stack_top++;");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .stack_reset => try self.writeLine("/* compiler stack synchronization */"),
            .halt => {
                try self.writeLine("return;");
            },
            .array_new => {
                // Create array - allocate memory with size tracking
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.write("ElbaInt size = ");
                try self.writeInt(inst.operand1);
                try self.writeLine(";");
                try self.writeIndent();
                try self.writeLine("ElbaInt* arr = (ElbaInt*)elba_malloc((size + 1) * sizeof(ElbaInt));");
                try self.writeIndent();
                try self.writeLine("if (!arr) {");
                try self.writeIndent();
                try self.writeLine("    fprintf(stderr, \"Array allocation failed!\\n\");");
                try self.writeIndent();
                try self.writeLine("    elba_cleanup();");
                try self.writeIndent();
                try self.writeLine("    exit(1);");
                try self.writeIndent();
                try self.writeLine("}");
                try self.writeIndent();
                try self.writeLine("arr[0] = size;  // Store size in first element");
                try self.writeIndent();
                try self.writeLine("elba_push_ptr((void*)arr);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .array_get => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt index = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt* arr = (ElbaInt*)elba_pop_ptr();");
                try self.writeIndent();
                try self.writeLine("ElbaInt size = arr[0];");
                try self.writeIndent();
                try self.writeLine("if (index < 0 || index >= size) {");
                try self.writeIndent();
                try self.writeLine("    fprintf(stderr, \"Array index out of bounds: %lld (size: %lld)\\n\", (long long)index, (long long)size);");
                try self.writeIndent();
                try self.writeLine("    elba_cleanup();");
                try self.writeIndent();
                try self.writeLine("    exit(1);");
                try self.writeIndent();
                try self.writeLine("}");
                try self.writeIndent();
                try self.writeLine("elba_push_int(arr[index + 1]);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .array_set => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt value = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt index = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt* arr = (ElbaInt*)elba_pop_ptr();");
                try self.writeIndent();
                try self.writeLine("ElbaInt size = arr[0];");
                try self.writeIndent();
                try self.writeLine("if (index < 0 || index >= size) {");
                try self.writeIndent();
                try self.writeLine("    fprintf(stderr, \"Array index out of bounds: %lld (size: %lld)\\n\", (long long)index, (long long)size);");
                try self.writeIndent();
                try self.writeLine("    elba_cleanup();");
                try self.writeIndent();
                try self.writeLine("    exit(1);");
                try self.writeIndent();
                try self.writeLine("}");
                try self.writeIndent();
                try self.writeLine("arr[index + 1] = value;");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .struct_new => {
                // Create struct - allocate memory for fields
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.write("ElbaInt field_count = ");
                try self.writeInt(inst.operand1);
                try self.writeLine(";");
                try self.writeIndent();
                try self.writeLine("ElbaInt* strct = (ElbaInt*)elba_malloc(field_count * sizeof(ElbaInt));");
                try self.writeIndent();
                try self.writeLine("if (!strct) {");
                try self.writeIndent();
                try self.writeLine("    fprintf(stderr, \"Struct allocation failed!\\n\");");
                try self.writeIndent();
                try self.writeLine("    elba_cleanup();");
                try self.writeIndent();
                try self.writeLine("    exit(1);");
                try self.writeIndent();
                try self.writeLine("}");
                try self.writeIndent();
                try self.writeLine("elba_push_ptr((void*)strct);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .field_get => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.write("ElbaInt field_idx = ");
                try self.writeInt(inst.operand1);
                try self.writeLine(";");
                try self.writeIndent();
                try self.writeLine("ElbaInt* strct = (ElbaInt*)elba_pop_ptr();");
                try self.writeIndent();
                try self.writeLine("elba_push_int(strct[field_idx]);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .field_set => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt value = elba_pop_int();");
                try self.writeIndent();
                try self.write("ElbaInt field_idx = ");
                try self.writeInt(inst.operand1);
                try self.writeLine(";");
                try self.writeIndent();
                try self.writeLine("ElbaInt* strct = (ElbaInt*)elba_pop_ptr();");
                try self.writeIndent();
                try self.writeLine("strct[field_idx] = value;");
                try self.writeIndent();
                try self.writeLine("elba_push_ptr((void*)strct);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .type_check => {
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
                    const target_tag: i64 = switch (inst.operand1) {
                        1 => @intFromEnum(ValueType.int),
                        2 => @intFromEnum(ValueType.float),
                        3 => @intFromEnum(ValueType.string),
                        4 => @intFromEnum(ValueType.bool),
                        5 => @intFromEnum(ValueType.struct_type),
                        6 => @intFromEnum(ValueType.array),
                        7 => @intFromEnum(ValueType.null_type),
                        8 => @intFromEnum(ValueType.optional),
                        9 => @intFromEnum(ValueType.union_type),
                        else => -1,
                    };
                    try self.writeLine("{");
                    self.indent_level += 1;
                    try self.writeIndent();
                    try self.writeLine("ElbaTaggedValue* tagged = (ElbaTaggedValue*)elba_pop_ptr();");
                    try self.writeIndent();
                    try self.write("ElbaBool matches = tagged != NULL && tagged->tag == ");
                    try self.writeInt(target_tag);
                    try self.write(" && strcmp(tagged->type_name, \"");
                    try self.writeEscapedString(inst.string_data orelse "unknown");
                    try self.writeLine("\") == 0;");
                    try self.writeIndent();
                    try self.writeLine(if (negate) "elba_push_bool(!matches);" else "elba_push_bool(matches);");
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.writeLine("}");
                } else {
                    try self.writeLine("elba_check_stack_underflow();");
                    try self.writeLine("stack_top--;  // discard the checked value");
                    try self.write("elba_push_bool(");
                    const static_matches = if (inst.operand1 == 10) true else if (inst.operand1 == 11) false else matches;
                    try self.write(if (if (negate) !static_matches else static_matches) "true" else "false");
                    try self.writeLine(");");
                }
            },
            .array_len => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt* arr = (ElbaInt*)elba_pop_ptr();");
                try self.writeIndent();
                try self.writeLine("elba_push_int(arr[0]);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .optional_wrap => {
                const payload_type = ir.decodeValueType(inst.operand3) orelse .null_type;
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("elba_check_stack_underflow();");
                try self.writeIndent();
                try self.writeLine("StackValue payload = stack[--stack_top];");
                try self.writeIndent();
                try self.writeLine("ElbaTaggedValue* tagged = (ElbaTaggedValue*)elba_malloc(sizeof(ElbaTaggedValue));");
                try self.writeIndent();
                try self.write("tagged->tag = ");
                try self.writeInt(@intFromEnum(payload_type));
                try self.writeLine(";");
                try self.writeIndent();
                try self.writeLine("tagged->bits = payload.bits;");
                try self.writeIndent();
                try self.write("tagged->type_name = \"");
                try self.writeEscapedString(inst.string_data orelse "unknown");
                try self.writeLine("\";");
                try self.writeIndent();
                try self.writeLine("elba_push_ptr((void*)tagged);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .optional_unwrap => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaTaggedValue* tagged = (ElbaTaggedValue*)elba_pop_ptr();");
                try self.writeIndent();
                try self.writeLine("if (!tagged) elba_arithmetic_error(\"Cannot unwrap null!\");");
                try self.writeIndent();
                try self.writeLine("elba_check_stack_overflow();");
                try self.writeIndent();
                try self.writeLine("stack[stack_top++].bits = tagged->bits;");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .optional_is_null => {
                try self.writeLine("elba_push_bool(elba_pop_ptr() == NULL);");
            },
        }
    }

    /// Generate main function
    fn generateMain(self: *CCodeGen, entry_point: []const u8) !void {
        try self.writeLine("int main(void) {");
        self.indent_level += 1;
        try self.writeIndent();
        try self.writeLine("atexit(elba_cleanup);");
        try self.writeIndent();
        try self.write("elba_");
        try self.write(entry_point);
        try self.writeLine("();");
        try self.writeIndent();
        try self.writeLine("elba_cleanup();");
        try self.writeIndent();
        try self.writeLine("return 0;");
        self.indent_level -= 1;
        try self.writeLine("}");
    }

    // Helper functions for writing
    fn writeIndent(self: *CCodeGen) !void {
        var i: usize = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.write("    ");
        }
    }

    fn write(self: *CCodeGen, str: []const u8) !void {
        try self.output.appendSlice(self.allocator, str);
    }

    fn writeLine(self: *CCodeGen, str: []const u8) !void {
        try self.output.appendSlice(self.allocator, str);
        try self.output.append(self.allocator, '\n');
    }

    fn writeInt(self: *CCodeGen, value: i64) !void {
        var buf: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.write(str);
    }

    fn writeFloat(self: *CCodeGen, value: f64) !void {
        var buf: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.write(str);
    }

    fn writeEscapedString(self: *CCodeGen, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '\n' => try self.write("\\n"),
                '\r' => try self.write("\\r"),
                '\t' => try self.write("\\t"),
                '\"' => try self.write("\\\""),
                '\\' => try self.write("\\\\"),
                else => try self.output.append(self.allocator, c),
            }
        }
    }
};
