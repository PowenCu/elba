#ifndef ELBA_IR_H
#define ELBA_IR_H

#include "../common.h"
#include <stdint.h>
#include <stdbool.h>

// IR Value Types
typedef enum {
    IR_TYPE_INT,
    IR_TYPE_FLOAT,
    IR_TYPE_BOOL,
    IR_TYPE_STRING,
    IR_TYPE_NULL,
    IR_TYPE_VOID,
} IRValueType;

// Register type (for later optimizations)
typedef uint32_t IRRegister;

// IR Opcodes
typedef enum {
    // Load/Store
    IR_LOAD_CONST_INT,
    IR_LOAD_CONST_FLOAT,
    IR_LOAD_CONST_BOOL,
    IR_LOAD_CONST_STR,
    IR_LOAD_NULL,
    IR_LOAD_VAR,
    IR_STORE_VAR,
    
    // Arithmetic
    IR_ADD,
    IR_SUB,
    IR_MUL,
    IR_DIV,
    IR_MOD,
    IR_NEG,
    IR_POW,
    
    // Comparison
    IR_EQ,
    IR_NEQ,
    IR_LT,
    IR_LTE,
    IR_GT,
    IR_GTE,
    
    // Logical
    IR_AND,
    IR_OR,
    IR_NOT,
    
    // Control Flow
    IR_JUMP,
    IR_JUMP_IF_FALSE,
    IR_JUMP_IF_TRUE,
    IR_CALL,
    IR_RET,
    
    // Stack operations
    IR_POP,
    IR_DUP,
    
    // Built-in functions
    IR_BUILTIN_CALL,
    
    // Array operations
    IR_ARRAY_NEW,
    IR_ARRAY_GET,
    IR_ARRAY_SET,
    
    // Struct operations
    IR_STRUCT_NEW,
    IR_FIELD_GET,
    IR_FIELD_SET,
    
    // Type operations
    IR_TYPE_CHECK,
    IR_CAST,
    
    // Special
    IR_HALT,
} IROpcode;

// IR Instruction
typedef struct {
    IROpcode op;
    int64_t operand1;
    int64_t operand2;
    int64_t operand3;
    const char* string_data;  // For string constants and variable names
} IRInstruction;

// IR Function
typedef struct {
    Slice name;
    size_t param_count;
    Slice* param_names;      // Array of parameter names
    size_t local_count;
    IRInstruction* instructions;
    size_t instruction_count;
    Slice* type_params;      // Generic type parameters
    size_t type_param_count;
    bool is_generic;
} IRFunction;

// IR Module (for imports)
typedef struct {
    Slice name;
    Slice path;
    Slice* exports;
    size_t export_count;
} IRModule;

// IR Program
typedef struct {
    IRFunction* functions;
    size_t function_count;
    const char** string_pool;
    size_t string_pool_size;
    Slice entry_point;
    IRModule* modules;
    size_t module_count;
} IRProgram;

// IR Builder (for constructing IR)
typedef struct IRBuilder {
    Arena* arena;
    DynamicArray* instructions;  // Array of IRInstruction
    DynamicArray* string_list;   // Array of char*
    size_t label_counter;
} IRBuilder;

// IR Program functions
IRProgram* ir_program_create(Arena* arena);
void ir_program_free(IRProgram* program);
IRFunction* ir_program_find_function(IRProgram* program, Slice name);

// IR Builder functions
IRBuilder* ir_builder_create(Arena* arena);
void ir_builder_free(IRBuilder* builder);
void ir_builder_emit(IRBuilder* builder, IROpcode op, int64_t op1, int64_t op2, int64_t op3);
void ir_builder_emit_with_string(IRBuilder* builder, IROpcode op, const char* str, int64_t op2, int64_t op3);
size_t ir_builder_intern_string(IRBuilder* builder, const char* str, size_t len);
size_t ir_builder_new_label(IRBuilder* builder);
void ir_builder_patch_jump(IRBuilder* builder, size_t instr_index, size_t target);
IRFunction ir_builder_build_function(IRBuilder* builder, Slice name, size_t param_count, size_t local_count);
void ir_builder_reset(IRBuilder* builder);

// Helper functions
const char* ir_opcode_to_string(IROpcode op);
void ir_instruction_print(const IRInstruction* instr);
void ir_function_print(const IRFunction* func);
void ir_program_print(const IRProgram* program);

#endif // ELBA_IR_H
