#include "ir_interp.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Stack-based IR interpreter
#define MAX_STACK_SIZE 1024
#define MAX_VARS 256

typedef struct {
    const char* name;
    Value value;
} IRVariable;

struct IRInterpreter {
    Arena* arena;
    Value stack[MAX_STACK_SIZE];
    size_t stack_top;
    IRVariable variables[MAX_VARS];
    size_t var_count;
    IRProgram* program;
};

// Create interpreter
IRInterpreter* ir_interp_create(Arena* arena) {
    IRInterpreter* interp = (IRInterpreter*)arena_alloc(arena, sizeof(IRInterpreter));
    if (!interp) return NULL;
    
    interp->arena = arena;
    interp->stack_top = 0;
    interp->var_count = 0;
    interp->program = NULL;
    
    return interp;
}

// Free interpreter
void ir_interp_free(IRInterpreter* interp) {
    // Arena handles memory
}

// Stack operations
static bool stack_push(IRInterpreter* interp, Value val) {
    if (interp->stack_top >= MAX_STACK_SIZE) {
        return false;
    }
    interp->stack[interp->stack_top++] = val;
    return true;
}

static Value stack_pop(IRInterpreter* interp) {
    if (interp->stack_top == 0) {
        return (Value){.kind = VALUE_NULL};
    }
    return interp->stack[--interp->stack_top];
}

static Value stack_peek(IRInterpreter* interp) {
    if (interp->stack_top == 0) {
        return (Value){.kind = VALUE_NULL};
    }
    return interp->stack[interp->stack_top - 1];
}

// Variable operations
static void set_variable(IRInterpreter* interp, const char* name, Value value) {
    // Check if variable exists
    for (size_t i = 0; i < interp->var_count; i++) {
        if (strcmp(interp->variables[i].name, name) == 0) {
            interp->variables[i].value = value;
            return;
        }
    }
    
    // Add new variable
    if (interp->var_count < MAX_VARS) {
        interp->variables[interp->var_count].name = name;
        interp->variables[interp->var_count].value = value;
        interp->var_count++;
    }
}

static Value get_variable(IRInterpreter* interp, const char* name) {
    for (size_t i = 0; i < interp->var_count; i++) {
        if (strcmp(interp->variables[i].name, name) == 0) {
            return interp->variables[i].value;
        }
    }
    return (Value){.kind = VALUE_NULL};
}

// Execute instruction
static IRInterpResult execute_instruction(IRInterpreter* interp, IRInstruction* inst) {
    IRInterpResult result = {true, NULL, {.kind = VALUE_NULL}};
    
    switch (inst->op) {
        case IR_LOAD_CONST_INT: {
            Value val = *value_create_int(inst->operand1);
            if (!stack_push(interp, val)) {
                result.success = false;
                result.error_message = "Stack overflow";
            }
            break;
        }
        
        case IR_LOAD_CONST_FLOAT: {
            union { int64_t i; double f; } u;
            u.i = inst->operand1;
            Value val = *value_create_float(u.f);
            if (!stack_push(interp, val)) {
                result.success = false;
                result.error_message = "Stack overflow";
            }
            break;
        }
        
        case IR_LOAD_CONST_BOOL: {
            Value val = *value_create_bool(inst->operand1 != 0);
            if (!stack_push(interp, val)) {
                result.success = false;
                result.error_message = "Stack overflow";
            }
            break;
        }
        
        case IR_LOAD_CONST_STR: {
            if (interp->program && inst->operand1 < (int64_t)interp->program->string_pool_size) {
                const char* str = interp->program->string_pool[inst->operand1];
                Value val = *value_create_string(str, strlen(str));
                if (!stack_push(interp, val)) {
                    result.success = false;
                    result.error_message = "Stack overflow";
                }
            }
            break;
        }
        
        case IR_LOAD_NULL: {
            Value val = {.kind = VALUE_NULL};
            if (!stack_push(interp, val)) {
                result.success = false;
                result.error_message = "Stack overflow";
            }
            break;
        }
        
        case IR_LOAD_VAR: {
            Value val = get_variable(interp, inst->string_data);
            if (!stack_push(interp, val)) {
                result.success = false;
                result.error_message = "Stack overflow";
            }
            break;
        }
        
        case IR_STORE_VAR: {
            Value val = stack_pop(interp);
            set_variable(interp, inst->string_data, val);
            break;
        }
        
        case IR_ADD: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                Value result_val = *value_create_int(a.data.int_val + b.data.int_val);
                stack_push(interp, result_val);
            } else if ((a.kind == VALUE_FLOAT || a.kind == VALUE_INT) &&
                       (b.kind == VALUE_FLOAT || b.kind == VALUE_INT)) {
                double a_f = a.kind == VALUE_FLOAT ? a.data.float_val : (double)a.data.int_val;
                double b_f = b.kind == VALUE_FLOAT ? b.data.float_val : (double)b.data.int_val;
                Value result_val = *value_create_float(a_f + b_f);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_SUB: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                Value result_val = *value_create_int(a.data.int_val - b.data.int_val);
                stack_push(interp, result_val);
            } else if ((a.kind == VALUE_FLOAT || a.kind == VALUE_INT) &&
                       (b.kind == VALUE_FLOAT || b.kind == VALUE_INT)) {
                double a_f = a.kind == VALUE_FLOAT ? a.data.float_val : (double)a.data.int_val;
                double b_f = b.kind == VALUE_FLOAT ? b.data.float_val : (double)b.data.int_val;
                Value result_val = *value_create_float(a_f - b_f);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_MUL: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                Value result_val = *value_create_int(a.data.int_val * b.data.int_val);
                stack_push(interp, result_val);
            } else if ((a.kind == VALUE_FLOAT || a.kind == VALUE_INT) &&
                       (b.kind == VALUE_FLOAT || b.kind == VALUE_INT)) {
                double a_f = a.kind == VALUE_FLOAT ? a.data.float_val : (double)a.data.int_val;
                double b_f = b.kind == VALUE_FLOAT ? b.data.float_val : (double)b.data.int_val;
                Value result_val = *value_create_float(a_f * b_f);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_DIV: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (b.kind == VALUE_INT && b.data.int_val == 0) {
                result.success = false;
                result.error_message = "Division by zero";
                break;
            }
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                Value result_val = *value_create_int(a.data.int_val / b.data.int_val);
                stack_push(interp, result_val);
            } else if ((a.kind == VALUE_FLOAT || a.kind == VALUE_INT) &&
                       (b.kind == VALUE_FLOAT || b.kind == VALUE_INT)) {
                double a_f = a.kind == VALUE_FLOAT ? a.data.float_val : (double)a.data.int_val;
                double b_f = b.kind == VALUE_FLOAT ? b.data.float_val : (double)b.data.int_val;
                Value result_val = *value_create_float(a_f / b_f);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_MOD: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                Value result_val = *value_create_int(a.data.int_val % b.data.int_val);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_POW: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            double a_f = a.kind == VALUE_FLOAT ? a.data.float_val : (double)a.data.int_val;
            double b_f = b.kind == VALUE_FLOAT ? b.data.float_val : (double)b.data.int_val;
            Value result_val = *value_create_float(pow(a_f, b_f));
            stack_push(interp, result_val);
            break;
        }
        
        case IR_NEG: {
            Value a = stack_pop(interp);
            if (a.kind == VALUE_INT) {
                Value result_val = *value_create_int(-a.data.int_val);
                stack_push(interp, result_val);
            } else if (a.kind == VALUE_FLOAT) {
                Value result_val = *value_create_float(-a.data.float_val);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_EQ: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            bool equal = false;
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                equal = a.data.int_val == b.data.int_val;
            } else if (a.kind == VALUE_BOOL && b.kind == VALUE_BOOL) {
                equal = a.data.bool_val == b.data.bool_val;
            }
            
            Value result_val = *value_create_bool(equal);
            stack_push(interp, result_val);
            break;
        }
        
        case IR_NEQ: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            bool not_equal = false;
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                not_equal = a.data.int_val != b.data.int_val;
            } else if (a.kind == VALUE_BOOL && b.kind == VALUE_BOOL) {
                not_equal = a.data.bool_val != b.data.bool_val;
            }
            
            Value result_val = *value_create_bool(not_equal);
            stack_push(interp, result_val);
            break;
        }
        
        case IR_LT: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                Value result_val = *value_create_bool(a.data.int_val < b.data.int_val);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_LTE: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                Value result_val = *value_create_bool(a.data.int_val <= b.data.int_val);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_GT: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                Value result_val = *value_create_bool(a.data.int_val > b.data.int_val);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_GTE: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_INT && b.kind == VALUE_INT) {
                Value result_val = *value_create_bool(a.data.int_val >= b.data.int_val);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_AND: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_BOOL && b.kind == VALUE_BOOL) {
                Value result_val = *value_create_bool(a.data.bool_val && b.data.bool_val);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_OR: {
            Value b = stack_pop(interp);
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_BOOL && b.kind == VALUE_BOOL) {
                Value result_val = *value_create_bool(a.data.bool_val || b.data.bool_val);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_NOT: {
            Value a = stack_pop(interp);
            
            if (a.kind == VALUE_BOOL) {
                Value result_val = *value_create_bool(!a.data.bool_val);
                stack_push(interp, result_val);
            }
            break;
        }
        
        case IR_POP: {
            stack_pop(interp);
            break;
        }
        
        case IR_DUP: {
            Value val = stack_peek(interp);
            stack_push(interp, val);
            break;
        }
        
        case IR_CALL: {
            // For built-in print function
            if (strcmp(inst->string_data, "print") == 0) {
                size_t arg_count = (size_t)inst->operand1;
                
                for (size_t i = 0; i < arg_count; i++) {
                    Value arg = stack_pop(interp);
                    
                    switch (arg.kind) {
                        case VALUE_INT:
                            printf("%lld", (long long)arg.data.int_val);
                            break;
                        case VALUE_FLOAT:
                            printf("%g", arg.data.float_val);
                            break;
                        case VALUE_BOOL:
                            printf("%s", arg.data.bool_val ? "true" : "false");
                            break;
                        case VALUE_STRING:
                            printf("%.*s", (int)arg.data.string_val.length, arg.data.string_val.data);
                            break;
                        case VALUE_NULL:
                            printf("null");
                            break;
                        default:
                            break;
                    }
                    
                    if (i < arg_count - 1) {
                        printf(" ");
                    }
                }
                printf("\n");
                
                // Push null result
                Value null_val = {.kind = VALUE_NULL};
                stack_push(interp, null_val);
            }
            break;
        }
        
        case IR_RET: {
            if (interp->stack_top > 0) {
                result.result = stack_pop(interp);
            }
            break;
        }
        
        default:
            // Unimplemented instruction
            break;
    }
    
    return result;
}

// Execute IR function
IRInterpResult ir_interp_execute_function(IRInterpreter* interp, IRFunction* func) {
    IRInterpResult result = {true, NULL, {.kind = VALUE_NULL}};
    
    if (!func) {
        result.success = false;
        result.error_message = "Null function";
        return result;
    }
    
    for (size_t i = 0; i < func->instruction_count; i++) {
        result = execute_instruction(interp, &func->instructions[i]);
        
        if (!result.success) {
            return result;
        }
        
        // Early return
        if (func->instructions[i].op == IR_RET) {
            break;
        }
    }
    
    return result;
}

// Execute IR program
IRInterpResult ir_interp_execute(IRInterpreter* interp, IRProgram* program) {
    IRInterpResult result = {true, NULL, {.kind = VALUE_NULL}};
    
    if (!program) {
        result.success = false;
        result.error_message = "Null program";
        return result;
    }
    
    interp->program = program;
    
    // Find main function
    IRFunction* main_func = NULL;
    for (size_t i = 0; i < program->function_count; i++) {
        if (program->functions[i].name.length == 4 &&
            memcmp(program->functions[i].name.data, "main", 4) == 0) {
            main_func = &program->functions[i];
            break;
        }
    }
    
    if (main_func) {
        result = ir_interp_execute_function(interp, main_func);
    } else {
        // No main function, execute top-level statements
        // (Not applicable in our current IR generation)
    }
    
    return result;
}
