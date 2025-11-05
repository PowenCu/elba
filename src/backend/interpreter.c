#include "interpreter.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Hash function for interpreter environment
static size_t hash_slice(Slice s) {
    size_t hash = 5381;
    for (size_t i = 0; i < s.length; i++) {
        hash = ((hash << 5) + hash) + (unsigned char)s.data[i];
    }
    return hash % 256;
}

// Create interpreter environment
InterpEnvironment* interp_env_create(Arena* arena, InterpEnvironment* parent) {
    InterpEnvironment* env = (InterpEnvironment*)arena_alloc(arena, sizeof(InterpEnvironment));
    if (!env) return NULL;
    
    memset(env, 0, sizeof(InterpEnvironment));
    env->parent = parent;
    env->arena = arena;
    env->has_return = false;
    env->return_value = NULL;
    
    return env;
}

// Set variable in environment
void interp_env_set_var(InterpEnvironment* env, Slice name, Value value) {
    size_t idx = hash_slice(name);
    
    // Check if variable already exists (for reassignment)
    for (InterpEnvEntry* e = env->vars[idx]; e != NULL; e = e->next) {
        if (slice_equals(e->key, name)) {
            e->value = value;
            return;
        }
    }
    
    // Create new entry
    InterpEnvEntry* entry = (InterpEnvEntry*)arena_alloc(env->arena, sizeof(InterpEnvEntry));
    entry->key = name;
    entry->value = value;
    entry->next = env->vars[idx];
    env->vars[idx] = entry;
}

// Get variable from environment
Value* interp_env_get_var(InterpEnvironment* env, Slice name) {
    size_t idx = hash_slice(name);
    
    for (InterpEnvEntry* e = env->vars[idx]; e != NULL; e = e->next) {
        if (slice_equals(e->key, name)) {
            return &e->value;
        }
    }
    
    if (env->parent) {
        return interp_env_get_var(env->parent, name);
    }
    
    return NULL;
}

// Set function in environment
void interp_env_set_fn(InterpEnvironment* env, Slice name, FnValue fn_val) {
    size_t idx = hash_slice(name);
    
    InterpFnEntry* entry = (InterpFnEntry*)arena_alloc(env->arena, sizeof(InterpFnEntry));
    entry->key = name;
    entry->value = fn_val;
    entry->next = env->functions[idx];
    env->functions[idx] = entry;
}

// Get function from environment
FnValue* interp_env_get_fn(InterpEnvironment* env, Slice name) {
    size_t idx = hash_slice(name);
    
    for (InterpFnEntry* e = env->functions[idx]; e != NULL; e = e->next) {
        if (slice_equals(e->key, name)) {
            return &e->value;
        }
    }
    
    if (env->parent) {
        return interp_env_get_fn(env->parent, name);
    }
    
    return NULL;
}

// Forward declaration
static InterpResult eval_expr_impl(InterpEnvironment* env, Expr* expr);

// Evaluate binary expression
static InterpResult eval_binary(InterpEnvironment* env, BinaryExpr* binary) {
    InterpResult left_result = eval_expr_impl(env, binary->left);
    if (!left_result.success) return left_result;
    
    InterpResult right_result = eval_expr_impl(env, binary->right);
    if (!right_result.success) return right_result;
    
    Value left = left_result.result;
    Value right = right_result.result;
    
    InterpResult result;
    result.success = true;
    result.error_message = NULL;
    
    // Arithmetic operations
    switch (binary->op) {
        case BINOP_ADD:
            // String concatenation
            if (left.kind == VALUE_STRING && right.kind == VALUE_STRING) {
                char* new_str = (char*)arena_alloc(env->arena, left.data.string_val.length + right.data.string_val.length + 1);
                memcpy(new_str, left.data.string_val.data, left.data.string_val.length);
                memcpy(new_str + left.data.string_val.length, right.data.string_val.data, right.data.string_val.length);
                new_str[left.data.string_val.length + right.data.string_val.length] = '\0';
                result.result = *value_create_string(new_str, left.data.string_val.length + right.data.string_val.length);
                return result;
            }
            // Numeric addition
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_int(left.data.int_val + right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_FLOAT || right.kind == VALUE_FLOAT) {
                double left_f = left.kind == VALUE_FLOAT ? left.data.float_val : (double)left.data.int_val;
                double right_f = right.kind == VALUE_FLOAT ? right.data.float_val : (double)right.data.int_val;
                result.result = *value_create_float(left_f + right_f);
                return result;
            }
            break;
            
        case BINOP_SUB:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_int(left.data.int_val - right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_FLOAT || right.kind == VALUE_FLOAT) {
                double left_f = left.kind == VALUE_FLOAT ? left.data.float_val : (double)left.data.int_val;
                double right_f = right.kind == VALUE_FLOAT ? right.data.float_val : (double)right.data.int_val;
                result.result = *value_create_float(left_f - right_f);
                return result;
            }
            break;
            
        case BINOP_MUL:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_int(left.data.int_val * right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_FLOAT || right.kind == VALUE_FLOAT) {
                double left_f = left.kind == VALUE_FLOAT ? left.data.float_val : (double)left.data.int_val;
                double right_f = right.kind == VALUE_FLOAT ? right.data.float_val : (double)right.data.int_val;
                result.result = *value_create_float(left_f * right_f);
                return result;
            }
            break;
            
        case BINOP_DIV:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                if (right.data.int_val == 0) {
                    result.success = false;
                    result.error_message = "Division by zero";
                    return result;
                }
                result.result = *value_create_int(left.data.int_val / right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_FLOAT || right.kind == VALUE_FLOAT) {
                double left_f = left.kind == VALUE_FLOAT ? left.data.float_val : (double)left.data.int_val;
                double right_f = right.kind == VALUE_FLOAT ? right.data.float_val : (double)right.data.int_val;
                result.result = *value_create_float(left_f / right_f);
                return result;
            }
            break;
            
        case BINOP_MOD:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_int(left.data.int_val % right.data.int_val);
                return result;
            }
            break;
            
        case BINOP_POW:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_int((int64_t)pow(left.data.int_val, right.data.int_val));
                return result;
            }
            if (left.kind == VALUE_FLOAT || right.kind == VALUE_FLOAT) {
                double left_f = left.kind == VALUE_FLOAT ? left.data.float_val : (double)left.data.int_val;
                double right_f = right.kind == VALUE_FLOAT ? right.data.float_val : (double)right.data.int_val;
                result.result = *value_create_float(pow(left_f, right_f));
                return result;
            }
            break;
            
        // Comparison operations
        case BINOP_EQUAL:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_bool(left.data.int_val == right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_BOOL && right.kind == VALUE_BOOL) {
                result.result = *value_create_bool(left.data.bool_val == right.data.bool_val);
                return result;
            }
            result.result = *value_create_bool(false);
            return result;
            
        case BINOP_NOT_EQUAL:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_bool(left.data.int_val != right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_BOOL && right.kind == VALUE_BOOL) {
                result.result = *value_create_bool(left.data.bool_val != right.data.bool_val);
                return result;
            }
            result.result = *value_create_bool(true);
            return result;
            
        case BINOP_LESS:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_bool(left.data.int_val < right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_FLOAT || right.kind == VALUE_FLOAT) {
                double left_f = left.kind == VALUE_FLOAT ? left.data.float_val : (double)left.data.int_val;
                double right_f = right.kind == VALUE_FLOAT ? right.data.float_val : (double)right.data.int_val;
                result.result = *value_create_bool(left_f < right_f);
                return result;
            }
            break;
            
        case BINOP_LESS_EQUAL:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_bool(left.data.int_val <= right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_FLOAT || right.kind == VALUE_FLOAT) {
                double left_f = left.kind == VALUE_FLOAT ? left.data.float_val : (double)left.data.int_val;
                double right_f = right.kind == VALUE_FLOAT ? right.data.float_val : (double)right.data.int_val;
                result.result = *value_create_bool(left_f <= right_f);
                return result;
            }
            break;
            
        case BINOP_GREATER:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_bool(left.data.int_val > right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_FLOAT || right.kind == VALUE_FLOAT) {
                double left_f = left.kind == VALUE_FLOAT ? left.data.float_val : (double)left.data.int_val;
                double right_f = right.kind == VALUE_FLOAT ? right.data.float_val : (double)right.data.int_val;
                result.result = *value_create_bool(left_f > right_f);
                return result;
            }
            break;
            
        case BINOP_GREATER_EQUAL:
            if (left.kind == VALUE_INT && right.kind == VALUE_INT) {
                result.result = *value_create_bool(left.data.int_val >= right.data.int_val);
                return result;
            }
            if (left.kind == VALUE_FLOAT || right.kind == VALUE_FLOAT) {
                double left_f = left.kind == VALUE_FLOAT ? left.data.float_val : (double)left.data.int_val;
                double right_f = right.kind == VALUE_FLOAT ? right.data.float_val : (double)right.data.int_val;
                result.result = *value_create_bool(left_f >= right_f);
                return result;
            }
            break;
            
        // Logical operations
        case BINOP_LOGICAL_AND:
            if (left.kind == VALUE_BOOL && right.kind == VALUE_BOOL) {
                result.result = *value_create_bool(left.data.bool_val && right.data.bool_val);
                return result;
            }
            break;
            
        case BINOP_LOGICAL_OR:
            if (left.kind == VALUE_BOOL && right.kind == VALUE_BOOL) {
                result.result = *value_create_bool(left.data.bool_val || right.data.bool_val);
                return result;
            }
            break;
    }
    
    result.success = false;
    result.error_message = "Unsupported binary operation";
    return result;
}

// Evaluate unary expression
static InterpResult eval_unary(InterpEnvironment* env, UnaryExpr* unary) {
    InterpResult operand_result = eval_expr_impl(env, unary->operand);
    if (!operand_result.success) return operand_result;
    
    Value operand = operand_result.result;
    InterpResult result;
    result.success = true;
    result.error_message = NULL;
    
    switch (unary->op) {
        case UNOP_NEGATE:
            if (operand.kind == VALUE_INT) {
                result.result = *value_create_int(-operand.data.int_val);
                return result;
            }
            if (operand.kind == VALUE_FLOAT) {
                result.result = *value_create_float(-operand.data.float_val);
                return result;
            }
            break;
            
        case UNOP_LOGICAL_NOT:
            if (operand.kind == VALUE_BOOL) {
                result.result = *value_create_bool(!operand.data.bool_val);
                return result;
            }
            break;
    }
    
    result.success = false;
    result.error_message = "Unsupported unary operation";
    return result;
}

// Built-in print function
static InterpResult builtin_print(InterpEnvironment* env, Expr** args, size_t arg_count) {
    InterpResult result;
    result.success = true;
    result.error_message = NULL;
    result.result = *value_create_unit();
    
    for (size_t i = 0; i < arg_count; i++) {
        InterpResult arg_result = eval_expr_impl(env, args[i]);
        if (!arg_result.success) return arg_result;
        
        Value val = arg_result.result;
        switch (val.kind) {
            case VALUE_INT:
                printf("%lld", (long long)val.data.int_val);
                break;
            case VALUE_FLOAT:
                printf("%g", val.data.float_val);
                break;
            case VALUE_STRING:
                printf("%.*s", (int)val.data.string_val.length, val.data.string_val.data);
                break;
            case VALUE_BOOL:
                printf("%s", val.data.bool_val ? "true" : "false");
                break;
            case VALUE_NULL:
                printf("null");
                break;
            default:
                printf("<value>");
                break;
        }
        if (i < arg_count - 1) printf(" ");
    }
    printf("\n");
    
    return result;
}

// Evaluate function call
static InterpResult eval_fn_call(InterpEnvironment* env, FnCallExpr* call) {
    InterpResult result;
    
    // Check for built-in functions
    if (slice_equals(call->name, slice_from_cstr("print"))) {
        return builtin_print(env, call->arguments, call->arg_count);
    }
    
    // Look up user-defined function
    FnValue* fn = interp_env_get_fn(env, call->name);
    if (!fn) {
        result.success = false;
        result.error_message = "Undefined function";
        return result;
    }
    
    // Check argument count
    if (call->arg_count != fn->param_count) {
        result.success = false;
        result.error_message = "Wrong number of arguments";
        return result;
    }
    
    // Create new scope for function execution
    InterpEnvironment* fn_env = interp_env_create(env->arena, env);
    
    // Bind parameters
    for (size_t i = 0; i < fn->param_count; i++) {
        InterpResult arg_result = eval_expr_impl(env, call->arguments[i]);
        if (!arg_result.success) return arg_result;
        
        interp_env_set_var(fn_env, fn->parameters[i].name, arg_result.result);
    }
    
    // Execute function body
    result = eval_expr_impl(fn_env, fn->body);
    
    // Check for return value
    if (fn_env->has_return && fn_env->return_value) {
        result.result = *fn_env->return_value;
        result.success = true;
    }
    
    return result;
}

// Evaluate expression
static InterpResult eval_expr_impl(InterpEnvironment* env, Expr* expr) {
    InterpResult result;
    result.success = true;
    result.error_message = NULL;
    
    if (!expr) {
        result.success = false;
        result.error_message = "Null expression";
        return result;
    }
    
    switch (expr->kind) {
        case EXPR_INT_LITERAL:
            result.result = *value_create_int(expr->data.int_literal);
            return result;
            
        case EXPR_FLOAT_LITERAL:
            result.result = *value_create_float(expr->data.float_literal);
            return result;
            
        case EXPR_STRING_LITERAL:
            result.result = *value_create_string(expr->data.string_literal.data, 
                                                 expr->data.string_literal.length);
            return result;
            
        case EXPR_BOOL_LITERAL:
            result.result = *value_create_bool(expr->data.bool_literal);
            return result;
            
        case EXPR_NULL_LITERAL:
            result.result = *value_create_null();
            return result;
            
        case EXPR_VARIABLE: {
            Value* val = interp_env_get_var(env, expr->data.variable);
            if (!val) {
                result.success = false;
                result.error_message = "Undefined variable";
                return result;
            }
            result.result = *val;
            return result;
        }
        
        case EXPR_BINARY:
            return eval_binary(env, &expr->data.binary);
            
        case EXPR_UNARY:
            return eval_unary(env, &expr->data.unary);
            
        case EXPR_FN_CALL:
            return eval_fn_call(env, &expr->data.fn_call);
            
        case EXPR_ASSIGNMENT: {
            InterpResult value_result = eval_expr_impl(env, expr->data.assignment.value);
            if (!value_result.success) return value_result;
            
            interp_env_set_var(env, expr->data.assignment.name, value_result.result);
            result.result = value_result.result;
            return result;
        }
        
        default:
            result.success = false;
            result.error_message = "Unsupported expression type";
            return result;
    }
}

InterpResult interp_eval_expr(InterpEnvironment* env, Expr* expr) {
    return eval_expr_impl(env, expr);
}

// Evaluate statement
InterpResult interp_eval_stmt(InterpEnvironment* env, Stmt* stmt) {
    InterpResult result;
    result.success = true;
    result.error_message = NULL;
    result.result = *value_create_unit();
    
    if (!stmt) return result;
    
    switch (stmt->kind) {
        case STMT_CONST_DECL:
        case STMT_LET_DECL: {
            InterpResult value_result = eval_expr_impl(env, stmt->data.var_decl.value);
            if (!value_result.success) return value_result;
            
            interp_env_set_var(env, stmt->data.var_decl.name, value_result.result);
            return result;
        }
        
        case STMT_FN_DECL: {
            FnValue fn_val;
            fn_val.parameters = stmt->data.fn_decl.parameters;
            fn_val.param_count = stmt->data.fn_decl.param_count;
            fn_val.body = stmt->data.fn_decl.body;
            
            interp_env_set_fn(env, stmt->data.fn_decl.name, fn_val);
            return result;
        }
        
        case STMT_RETURN: {
            InterpResult value_result = eval_expr_impl(env, stmt->data.return_stmt);
            if (!value_result.success) return value_result;
            
            Value* ret_val = (Value*)arena_alloc(env->arena, sizeof(Value));
            *ret_val = value_result.result;
            env->return_value = ret_val;
            env->has_return = true;
            
            result.result = value_result.result;
            return result;
        }
        
        case STMT_EXPR:
            return eval_expr_impl(env, stmt->data.expr_stmt);
        
        default:
            return result;
    }
}

// Run program
InterpResult interp_run_program(Stmt** stmts, size_t stmt_count, Arena* arena) {
    InterpEnvironment* env = interp_env_create(arena, NULL);
    
    InterpResult result;
    result.success = true;
    result.error_message = NULL;
    result.result = *value_create_unit();
    
    if (!env) {
        result.success = false;
        result.error_message = "Failed to create interpreter environment";
        return result;
    }
    
    // Execute each statement
    for (size_t i = 0; i < stmt_count; i++) {
        result = interp_eval_stmt(env, stmts[i]);
        if (!result.success) {
            return result;
        }
        
        // Check for early return
        if (env->has_return) {
            break;
        }
    }
    
    return result;
}
