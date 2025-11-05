#include "ir.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Create IR program
IRProgram* ir_program_create(Arena* arena) {
    IRProgram* program = (IRProgram*)arena_alloc(arena, sizeof(IRProgram));
    if (!program) return NULL;
    
    memset(program, 0, sizeof(IRProgram));
    program->entry_point = slice_from_cstr("main");
    
    return program;
}

// Free IR program
void ir_program_free(IRProgram* program) {
    // Memory managed by arena, nothing to do
    (void)program;
}

// Find function in program
IRFunction* ir_program_find_function(IRProgram* program, Slice name) {
    for (size_t i = 0; i < program->function_count; i++) {
        if (slice_equals(program->functions[i].name, name)) {
            return &program->functions[i];
        }
    }
    return NULL;
}

// Create IR builder
IRBuilder* ir_builder_create(Arena* arena) {
    IRBuilder* builder = (IRBuilder*)arena_alloc(arena, sizeof(IRBuilder));
    if (!builder) return NULL;
    
    builder->arena = arena;
    builder->instructions = dyn_array_create(sizeof(IRInstruction));
    builder->string_list = dyn_array_create(sizeof(char*));
    builder->label_counter = 0;
    
    return builder;
}

// Free IR builder
void ir_builder_free(IRBuilder* builder) {
    if (!builder) return;
    dyn_array_free(builder->instructions);
    dyn_array_free(builder->string_list);
}

// Emit instruction
void ir_builder_emit(IRBuilder* builder, IROpcode op, int64_t op1, int64_t op2, int64_t op3) {
    IRInstruction instr = {
        .op = op,
        .operand1 = op1,
        .operand2 = op2,
        .operand3 = op3,
        .string_data = NULL
    };
    dyn_array_append(builder->instructions, &instr);
}

// Emit instruction with string
void ir_builder_emit_with_string(IRBuilder* builder, IROpcode op, const char* str, int64_t op2, int64_t op3) {
    IRInstruction instr = {
        .op = op,
        .operand1 = 0,
        .operand2 = op2,
        .operand3 = op3,
        .string_data = str
    };
    dyn_array_append(builder->instructions, &instr);
}

// Intern string
size_t ir_builder_intern_string(IRBuilder* builder, const char* str, size_t len) {
    // Check if string already exists
    for (size_t i = 0; i < builder->string_list->length; i++) {
        const char* existing = ((char**)builder->string_list->items)[i];
        if (strlen(existing) == len && strncmp(existing, str, len) == 0) {
            return i;
        }
    }
    
    // Add new string
    char* new_str = (char*)arena_alloc(builder->arena, len + 1);
    memcpy(new_str, str, len);
    new_str[len] = '\0';
    
    size_t index = builder->string_list->length;
    dyn_array_append(builder->string_list, &new_str);
    return index;
}

// Generate new label
size_t ir_builder_new_label(IRBuilder* builder) {
    return builder->label_counter++;
}

// Patch jump instruction
void ir_builder_patch_jump(IRBuilder* builder, size_t instr_index, size_t target) {
    if (instr_index < builder->instructions->length) {
        IRInstruction* instr = &((IRInstruction*)builder->instructions->items)[instr_index];
        instr->operand1 = (int64_t)target;
    }
}

// Build function from builder
IRFunction ir_builder_build_function(IRBuilder* builder, Slice name, size_t param_count, size_t local_count) {
    IRFunction func;
    func.name = name;
    func.param_count = param_count;
    func.local_count = local_count;
    func.is_generic = false;
    func.type_param_count = 0;
    func.type_params = NULL;
    func.param_names = NULL;
    
    // Copy instructions
    func.instruction_count = builder->instructions->length;
    func.instructions = (IRInstruction*)arena_alloc(builder->arena, 
                                                      sizeof(IRInstruction) * func.instruction_count);
    memcpy(func.instructions, builder->instructions->items, 
           sizeof(IRInstruction) * func.instruction_count);
    
    return func;
}

// Reset builder for reuse
void ir_builder_reset(IRBuilder* builder) {
    builder->instructions->length = 0;
    builder->label_counter = 0;
}

// Convert opcode to string
const char* ir_opcode_to_string(IROpcode op) {
    switch (op) {
        case IR_LOAD_CONST_INT: return "LOAD_CONST_INT";
        case IR_LOAD_CONST_FLOAT: return "LOAD_CONST_FLOAT";
        case IR_LOAD_CONST_BOOL: return "LOAD_CONST_BOOL";
        case IR_LOAD_CONST_STR: return "LOAD_CONST_STR";
        case IR_LOAD_NULL: return "LOAD_NULL";
        case IR_LOAD_VAR: return "LOAD_VAR";
        case IR_STORE_VAR: return "STORE_VAR";
        case IR_ADD: return "ADD";
        case IR_SUB: return "SUB";
        case IR_MUL: return "MUL";
        case IR_DIV: return "DIV";
        case IR_MOD: return "MOD";
        case IR_NEG: return "NEG";
        case IR_POW: return "POW";
        case IR_EQ: return "EQ";
        case IR_NEQ: return "NEQ";
        case IR_LT: return "LT";
        case IR_LTE: return "LTE";
        case IR_GT: return "GT";
        case IR_GTE: return "GTE";
        case IR_AND: return "AND";
        case IR_OR: return "OR";
        case IR_NOT: return "NOT";
        case IR_JUMP: return "JUMP";
        case IR_JUMP_IF_FALSE: return "JUMP_IF_FALSE";
        case IR_JUMP_IF_TRUE: return "JUMP_IF_TRUE";
        case IR_CALL: return "CALL";
        case IR_RET: return "RET";
        case IR_POP: return "POP";
        case IR_DUP: return "DUP";
        case IR_BUILTIN_CALL: return "BUILTIN_CALL";
        case IR_ARRAY_NEW: return "ARRAY_NEW";
        case IR_ARRAY_GET: return "ARRAY_GET";
        case IR_ARRAY_SET: return "ARRAY_SET";
        case IR_STRUCT_NEW: return "STRUCT_NEW";
        case IR_FIELD_GET: return "FIELD_GET";
        case IR_FIELD_SET: return "FIELD_SET";
        case IR_TYPE_CHECK: return "TYPE_CHECK";
        case IR_CAST: return "CAST";
        case IR_HALT: return "HALT";
        default: return "UNKNOWN";
    }
}

// Print instruction
void ir_instruction_print(const IRInstruction* instr) {
    printf("  %-20s", ir_opcode_to_string(instr->op));
    
    if (instr->string_data) {
        printf(" \"%s\"", instr->string_data);
    } else if (instr->operand1 != 0 || instr->operand2 != 0 || instr->operand3 != 0) {
        printf(" %lld", (long long)instr->operand1);
        if (instr->operand2 != 0 || instr->operand3 != 0) {
            printf(", %lld", (long long)instr->operand2);
            if (instr->operand3 != 0) {
                printf(", %lld", (long long)instr->operand3);
            }
        }
    }
    printf("\n");
}

// Print function
void ir_function_print(const IRFunction* func) {
    printf("Function: %.*s (params: %zu, locals: %zu)\n", 
           (int)func->name.length, func->name.data,
           func->param_count, func->local_count);
    
    for (size_t i = 0; i < func->instruction_count; i++) {
        printf("  %04zu: ", i);
        ir_instruction_print(&func->instructions[i]);
    }
    printf("\n");
}

// Print program
void ir_program_print(const IRProgram* program) {
    printf("=== IR Program ===\n");
    printf("Entry point: %.*s\n", (int)program->entry_point.length, program->entry_point.data);
    printf("Functions: %zu\n", program->function_count);
    printf("String pool size: %zu\n\n", program->string_pool_size);
    
    for (size_t i = 0; i < program->function_count; i++) {
        ir_function_print(&program->functions[i]);
    }
}
