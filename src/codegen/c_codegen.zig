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
    used_builtins: std.StringHashMap(bool),

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
                    .load_const_float => self.uses_floats = true,
                    .array_new, .array_get, .array_set => self.uses_arrays = true,
                    .struct_new, .field_get, .field_set => self.uses_structs = true,
                    .call => {
                        if (inst.string_data) |func_name| {
                            // Track which builtins are used
                            const is_builtin = std.mem.eql(u8, func_name, "println") or
                                std.mem.eql(u8, func_name, "print") or
                                std.mem.eql(u8, func_name, "str_len") or
                                std.mem.eql(u8, func_name, "str_concat") or
                                std.mem.eql(u8, func_name, "str_substring") or
                                std.mem.eql(u8, func_name, "int_to_str") or
                                std.mem.eql(u8, func_name, "float_to_str") or
                                std.mem.eql(u8, func_name, "abs") or
                                std.mem.eql(u8, func_name, "sqrt") or
                                std.mem.eql(u8, func_name, "floor") or
                                std.mem.eql(u8, func_name, "ceil") or
                                std.mem.eql(u8, func_name, "min") or
                                std.mem.eql(u8, func_name, "max");

                            if (is_builtin) {
                                try self.used_builtins.put(func_name, true);
                                if (std.mem.indexOf(u8, func_name, "str") != null) {
                                    self.uses_strings = true;
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

        // Only include string.h if strings are used
        if (self.uses_strings) {
            try self.writeLine("#include <string.h>");
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
        try self.writeLine("typedef union {");
        try self.writeLine("    ElbaInt i;");

        if (self.uses_floats) {
            try self.writeLine("    ElbaFloat f;");
        }

        try self.writeLine("    ElbaBool b;");

        if (self.uses_strings) {
            try self.writeLine("    ElbaString s;");
        }

        if (self.uses_arrays or self.uses_structs) {
            try self.writeLine("    void* ptr;");
        }

        try self.writeLine("} StackValue;");
        try self.writeLine("");
        try self.writeLine("static StackValue stack[STACK_SIZE];");
        try self.writeLine("static int stack_top = 0;");
        try self.writeLine("");

        // Memory management (only if dynamic allocation is used)
        if (self.uses_strings or self.uses_arrays or self.uses_structs) {
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
        try self.writeLine("    stack[stack_top++].i = value;");
        try self.writeLine("}");
        try self.writeLine("");

        if (self.uses_floats) {
            try self.writeLine("static inline void elba_push_float(ElbaFloat value) {");
            try self.writeLine("    elba_check_stack_overflow();");
            try self.writeLine("    stack[stack_top++].f = value;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        try self.writeLine("static inline void elba_push_bool(ElbaBool value) {");
        try self.writeLine("    elba_check_stack_overflow();");
        try self.writeLine("    stack[stack_top++].b = value;");
        try self.writeLine("}");
        try self.writeLine("");

        if (self.uses_strings) {
            try self.writeLine("static inline void elba_push_string(ElbaString value) {");
            try self.writeLine("    elba_check_stack_overflow();");
            try self.writeLine("    stack[stack_top++].s = value;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        if (self.uses_arrays or self.uses_structs) {
            try self.writeLine("static inline void elba_push_ptr(void* value) {");
            try self.writeLine("    elba_check_stack_overflow();");
            try self.writeLine("    stack[stack_top++].ptr = value;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        try self.writeLine("static inline ElbaInt elba_pop_int(void) {");
        try self.writeLine("    elba_check_stack_underflow();");
        try self.writeLine("    return stack[--stack_top].i;");
        try self.writeLine("}");
        try self.writeLine("");

        if (self.uses_floats) {
            try self.writeLine("static inline ElbaFloat elba_pop_float(void) {");
            try self.writeLine("    elba_check_stack_underflow();");
            try self.writeLine("    return stack[--stack_top].f;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        try self.writeLine("static inline ElbaBool elba_pop_bool(void) {");
        try self.writeLine("    elba_check_stack_underflow();");
        try self.writeLine("    return stack[--stack_top].b;");
        try self.writeLine("}");
        try self.writeLine("");

        if (self.uses_strings) {
            try self.writeLine("static inline ElbaString elba_pop_string(void) {");
            try self.writeLine("    elba_check_stack_underflow();");
            try self.writeLine("    return stack[--stack_top].s;");
            try self.writeLine("}");
            try self.writeLine("");
        }

        if (self.uses_arrays or self.uses_structs) {
            try self.writeLine("static inline void* elba_pop_ptr(void) {");
            try self.writeLine("    elba_check_stack_underflow();");
            try self.writeLine("    return stack[--stack_top].ptr;");
            try self.writeLine("}");
            try self.writeLine("");
        }

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
                    // If there's anything on the stack before ret, it returns a value
                    // For now, assume functions with params return values
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (has_return_value) {
            try self.write("ElbaInt elba_");
        } else {
            try self.write("void elba_");
        }
        try self.write(func.name);
        try self.write("(");

        // Add parameters
        var i: usize = 0;
        while (i < func.param_count) : (i += 1) {
            if (i > 0) try self.write(", ");
            try self.write("ElbaInt param");
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
            try self.write("ElbaInt elba_");
        } else {
            try self.write("void elba_");
        }
        try self.write(func.name);
        try self.write("(");

        // Add parameters
        var i: usize = 0;
        while (i < func.param_count) : (i += 1) {
            if (i > 0) try self.write(", ");
            try self.write("ElbaInt param");
            try self.writeInt(@intCast(i));
        }

        try self.writeLine(") {");
        self.indent_level += 1;

        // Collect all variables used in this function (both params and locals)
        var var_names = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer var_names.deinit(self.allocator);

        // First, collect parameter names from the first load_var instructions
        var param_names = try std.ArrayList([]const u8).initCapacity(self.allocator, func.param_count);
        defer param_names.deinit(self.allocator);

        // Parameters are variables that are loaded before they're ever stored
        var stored_vars = std.StringHashMap(void).init(self.allocator);
        defer stored_vars.deinit();

        for (func.instructions) |inst| {
            if (inst.op == .load_var) {
                if (inst.string_data) |var_name| {
                    // If we load a var before storing it, it must be a parameter
                    if (!stored_vars.contains(var_name) and param_names.items.len < func.param_count) {
                        var is_new = true;
                        for (param_names.items) |pname| {
                            if (std.mem.eql(u8, pname, var_name)) {
                                is_new = false;
                                break;
                            }
                        }
                        if (is_new) {
                            try param_names.append(self.allocator, var_name);
                        }
                    }
                }
            } else if (inst.op == .store_var) {
                if (inst.string_data) |var_name| {
                    try stored_vars.put(var_name, {});
                }
            }
        }

        // Map parameters to their C variable names
        for (param_names.items, 0..) |pname, idx| {
            try self.writeIndent();
            try self.write("ElbaInt ");
            try self.write(pname);
            try self.write(" = param");
            try self.writeInt(@intCast(idx));
            try self.writeLine(";");
        }
        if (param_names.items.len > 0) {
            try self.writeLine("");
        }

        // Collect all OTHER variables (non-parameters) used in this function
        for (func.instructions) |inst| {
            if (inst.op == .store_var) {
                if (inst.string_data) |var_name| {
                    // Check if this is not a parameter
                    var is_param = false;
                    for (param_names.items) |pname| {
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
                try self.write("ElbaInt ");
                try self.write(var_name);
                try self.writeLine(" = 0;");
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
                const f: f64 = @bitCast(@as(u64, @intCast(inst.operand1)));
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
                    try self.write("elba_push_int(");
                    try self.write(var_name);
                    try self.writeLine(");");
                }
            },
            .store_var => {
                if (inst.string_data) |var_name| {
                    try self.write(var_name);
                    try self.writeLine(" = elba_pop_int();");
                }
            },
            .add => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_int(_a + _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .sub => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_int(_a - _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .mul => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_int(_a * _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .div => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_int(_a / _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .mod => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_int(_a % _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .neg => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_int(-_a);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .pow => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaFloat _b = (ElbaFloat)elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaFloat _a = (ElbaFloat)elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_int((ElbaInt)pow(_a, _b));");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .eq => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_bool(_a == _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .neq => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_bool(_a != _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .lt => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_bool(_a < _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .lte => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_bool(_a <= _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .gt => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_bool(_a > _b);");
                self.indent_level -= 1;
                try self.writeIndent();
                try self.writeLine("}");
            },
            .gte => {
                try self.writeLine("{");
                self.indent_level += 1;
                try self.writeIndent();
                try self.writeLine("ElbaInt _b = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("ElbaInt _a = elba_pop_int();");
                try self.writeIndent();
                try self.writeLine("elba_push_bool(_a >= _b);");
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

                    // Handle built-in functions
                    if (std.mem.eql(u8, func_name, "println")) {
                        try self.writeLine("elba_println_string(elba_pop_string());");
                        try self.writeLine("elba_push_int(0);  // void return");
                    } else if (std.mem.eql(u8, func_name, "print")) {
                        try self.writeLine("elba_print_string(elba_pop_string());");
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
                    } else if (std.mem.eql(u8, func_name, "abs")) {
                        try self.writeLine("elba_push_int(elba_abs_int(elba_pop_int()));");
                    } else if (std.mem.eql(u8, func_name, "sqrt")) {
                        try self.writeLine("elba_push_float(elba_sqrt((ElbaFloat)elba_pop_int()));");
                    } else if (std.mem.eql(u8, func_name, "floor")) {
                        try self.writeLine("elba_push_float(elba_floor(elba_pop_float()));");
                    } else if (std.mem.eql(u8, func_name, "ceil")) {
                        try self.writeLine("elba_push_float(elba_ceil(elba_pop_float()));");
                    } else if (std.mem.eql(u8, func_name, "min")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaInt b = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt a = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine("elba_push_int(elba_min_int(a, b));");
                        self.indent_level -= 1;
                        try self.writeIndent();
                        try self.writeLine("}");
                    } else if (std.mem.eql(u8, func_name, "max")) {
                        try self.writeLine("{");
                        self.indent_level += 1;
                        try self.writeIndent();
                        try self.writeLine("ElbaInt b = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine("ElbaInt a = elba_pop_int();");
                        try self.writeIndent();
                        try self.writeLine("elba_push_int(elba_max_int(a, b));");
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
                                try self.write("ElbaInt arg");
                                try self.writeInt(@intCast(i));
                                try self.writeLine(" = elba_pop_int();");
                            }

                            // Call function and push result back
                            try self.writeIndent();
                            try self.write("ElbaInt result = elba_");
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
                            try self.writeLine("elba_push_int(result);");

                            self.indent_level -= 1;
                            try self.writeIndent();
                            try self.writeLine("}");
                        } else {
                            try self.write("elba_push_int(elba_");
                            try self.write(func_name);
                            try self.writeLine("());");
                        }
                    }
                }
            },
            .ret => {
                try self.writeLine("return elba_pop_int();");
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
                try self.writeIndent();
                try self.writeLine("elba_push_ptr((void*)arr);");
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
            .builtin_call => {
                if (inst.string_data) |func_name| {
                    try self.write("// Builtin call: ");
                    try self.write(func_name);
                    try self.writeLine("");
                }
            },
            .type_check => {
                // For now, just push true - proper type checking would need runtime type tags
                try self.writeLine("stack_top--;  // pop value to check");
                try self.writeLine("elba_push_bool(true);  // placeholder");
            },
            .cast => {
                // For now, no-op - value stays on stack
                try self.writeLine("// Type cast (no-op)");
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
