#include "typechecker.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// Simple hash function for strings
static size_t hash_slice(Slice s) {
    size_t hash = 5381;
    for (size_t i = 0; i < s.length; i++) {
        hash = ((hash << 5) + hash) + (unsigned char)s.data[i];
    }
    return hash % 256;
}

// Create type environment
TypeEnvironment* type_env_create(Arena* arena, TypeEnvironment* parent) {
    TypeEnvironment* env = (TypeEnvironment*)arena_alloc(arena, sizeof(TypeEnvironment));
    if (!env) return NULL;
    
    memset(env, 0, sizeof(TypeEnvironment));
    env->parent = parent;
    env->arena = arena;
    
    return env;
}

void type_env_free(TypeEnvironment* env) {
    // Memory is managed by arena, so we don't need to free individual entries
    (void)env;
}

// Set variable in environment
void type_env_set_var(TypeEnvironment* env, Slice name, VarInfo info) {
    size_t idx = hash_slice(name);
    
    TypeEnvEntry* entry = (TypeEnvEntry*)arena_alloc(env->arena, sizeof(TypeEnvEntry));
    entry->key = name;
    entry->value = info;
    entry->next = env->vars[idx];
    env->vars[idx] = entry;
}

// Get variable from environment
VarInfo* type_env_get_var(TypeEnvironment* env, Slice name) {
    size_t idx = hash_slice(name);
    
    for (TypeEnvEntry* e = env->vars[idx]; e != NULL; e = e->next) {
        if (slice_equals(e->key, name)) {
            return &e->value;
        }
    }
    
    if (env->parent) {
        return type_env_get_var(env->parent, name);
    }
    
    return NULL;
}

// Set function in environment
void type_env_set_fn(TypeEnvironment* env, Slice name, FnSignature sig) {
    size_t idx = hash_slice(name);
    
    FnEnvEntry* entry = (FnEnvEntry*)arena_alloc(env->arena, sizeof(FnEnvEntry));
    entry->key = name;
    entry->value = sig;
    entry->next = env->functions[idx];
    env->functions[idx] = entry;
}

// Get function from environment
FnSignature* type_env_get_fn(TypeEnvironment* env, Slice name) {
    size_t idx = hash_slice(name);
    
    for (FnEnvEntry* e = env->functions[idx]; e != NULL; e = e->next) {
        if (slice_equals(e->key, name)) {
            return &e->value;
        }
    }
    
    if (env->parent) {
        return type_env_get_fn(env->parent, name);
    }
    
    return NULL;
}

// Convert type to string for error messages
const char* type_to_string(const Type* typ, char* buf, size_t buf_size) {
    if (!typ) return "unknown";
    
    switch (typ->kind) {
        case TYPE_INT: return "int";
        case TYPE_FLOAT: return "float";
        case TYPE_STRING: return "str";
        case TYPE_BOOL: return "bool";
        case TYPE_UNIT: return "unit";
        case TYPE_UNKNOWN: return "unknown";
        case TYPE_USER_TYPE:
            snprintf(buf, buf_size, "%.*s", (int)typ->data.user_type.length, 
                    typ->data.user_type.data);
            return buf;
        case TYPE_ARRAY: {
            char inner_buf[128];
            const char* inner = type_to_string(typ->data.array_elem_type, inner_buf, sizeof(inner_buf));
            snprintf(buf, buf_size, "[]%s", inner);
            return buf;
        }
        case TYPE_OPTIONAL: {
            char inner_buf[128];
            const char* inner = type_to_string(typ->data.optional_inner, inner_buf, sizeof(inner_buf));
            snprintf(buf, buf_size, "%s?", inner);
            return buf;
        }
        default:
            return "complex_type";
    }
}

// Check if two types are compatible
bool types_compatible(const Type* a, const Type* b) {
    if (!a || !b) return false;
    return type_equals(a, b);
}

// Forward declarations for recursive type checking
static Type* typecheck_expr_impl(TypeEnvironment* env, Expr* expr, const ErrorReporter* reporter);

// Type check binary expression
static Type* typecheck_binary(TypeEnvironment* env, BinaryExpr* binary, 
                              const ErrorReporter* reporter) {
    Type* left_type = typecheck_expr_impl(env, binary->left, reporter);
    Type* right_type = typecheck_expr_impl(env, binary->right, reporter);
    
    if (!left_type || !right_type) {
        return type_create_unknown();
    }
    
    // Arithmetic operators
    if (binary->op >= BINOP_ADD && binary->op <= BINOP_POW) {
        if (type_is_numeric(left_type) && type_is_numeric(right_type)) {
            // If either is float, result is float
            if (left_type->kind == TYPE_FLOAT || right_type->kind == TYPE_FLOAT) {
                return type_create_float();
            }
            return type_create_int();
        }
        // String concatenation
        if (binary->op == BINOP_ADD && 
            left_type->kind == TYPE_STRING && right_type->kind == TYPE_STRING) {
            return type_create_string();
        }
        return type_create_unknown();
    }
    
    // Comparison operators
    if (binary->op >= BINOP_EQUAL && binary->op <= BINOP_GREATER_EQUAL) {
        // All comparison operators return bool
        return type_create_bool();
    }
    
    // Logical operators
    if (binary->op == BINOP_LOGICAL_AND || binary->op == BINOP_LOGICAL_OR) {
        if (left_type->kind == TYPE_BOOL && right_type->kind == TYPE_BOOL) {
            return type_create_bool();
        }
        return type_create_unknown();
    }
    
    return type_create_unknown();
}

// Type check unary expression
static Type* typecheck_unary(TypeEnvironment* env, UnaryExpr* unary, 
                             const ErrorReporter* reporter) {
    Type* operand_type = typecheck_expr_impl(env, unary->operand, reporter);
    
    if (!operand_type) {
        return type_create_unknown();
    }
    
    if (unary->op == UNOP_NEGATE) {
        if (type_is_numeric(operand_type)) {
            return operand_type;
        }
    }
    
    if (unary->op == UNOP_LOGICAL_NOT) {
        if (operand_type->kind == TYPE_BOOL) {
            return type_create_bool();
        }
    }
    
    return type_create_unknown();
}

// Type check function call
static Type* typecheck_fn_call(TypeEnvironment* env, FnCallExpr* call, 
                               const ErrorReporter* reporter) {
    FnSignature* sig = type_env_get_fn(env, call->name);
    
    if (!sig) {
        // Unknown function - return unknown type
        return type_create_unknown();
    }
    
    // Check argument count
    if (call->arg_count != sig->param_count) {
        char msg[256];
        snprintf(msg, sizeof(msg), "Function '%.*s' expects %zu arguments, got %zu",
                (int)call->name.length, call->name.data, 
                sig->param_count, call->arg_count);
        fprintf(stderr, "Type error: %s\n", msg);
        return type_create_unknown();
    }
    
    // Check argument types
    for (size_t i = 0; i < call->arg_count; i++) {
        Type* arg_type = typecheck_expr_impl(env, call->arguments[i], reporter);
        if (!types_compatible(arg_type, sig->param_types[i])) {
            char buf1[128], buf2[128];
            fprintf(stderr, "Type error: Argument %zu type mismatch: expected %s, got %s\n",
                   i + 1,
                   type_to_string(sig->param_types[i], buf1, sizeof(buf1)),
                   type_to_string(arg_type, buf2, sizeof(buf2)));
        }
    }
    
    return sig->return_type;
}

// Type check assignment
static Type* typecheck_assignment(TypeEnvironment* env, AssignmentExpr* assign,
                                  const ErrorReporter* reporter) {
    VarInfo* var_info = type_env_get_var(env, assign->name);
    
    if (!var_info) {
        fprintf(stderr, "Type error: Undefined variable '%.*s'\n",
               (int)assign->name.length, assign->name.data);
        return type_create_unknown();
    }
    
    if (!var_info->mutable) {
        fprintf(stderr, "Type error: Cannot assign to immutable variable '%.*s'\n",
               (int)assign->name.length, assign->name.data);
        return type_create_unknown();
    }
    
    Type* value_type = typecheck_expr_impl(env, assign->value, reporter);
    
    if (!types_compatible(var_info->typ, value_type)) {
        char buf1[128], buf2[128];
        fprintf(stderr, "Type error: Cannot assign %s to variable of type %s\n",
               type_to_string(value_type, buf1, sizeof(buf1)),
               type_to_string(var_info->typ, buf2, sizeof(buf2)));
    }
    
    return var_info->typ;
}

// Type check expression
static Type* typecheck_expr_impl(TypeEnvironment* env, Expr* expr, 
                                 const ErrorReporter* reporter) {
    if (!expr) return type_create_unknown();
    
    switch (expr->kind) {
        case EXPR_INT_LITERAL:
            return type_create_int();
        
        case EXPR_FLOAT_LITERAL:
            return type_create_float();
        
        case EXPR_STRING_LITERAL:
            return type_create_string();
        
        case EXPR_BOOL_LITERAL:
            return type_create_bool();
        
        case EXPR_NULL_LITERAL:
            return type_create_unit();  // Simplified - should be optional type
        
        case EXPR_VARIABLE: {
            VarInfo* var_info = type_env_get_var(env, expr->data.variable);
            if (!var_info) {
                fprintf(stderr, "Type error: Undefined variable '%.*s'\n",
                       (int)expr->data.variable.length, expr->data.variable.data);
                return type_create_unknown();
            }
            return var_info->typ;
        }
        
        case EXPR_BINARY:
            return typecheck_binary(env, &expr->data.binary, reporter);
        
        case EXPR_UNARY:
            return typecheck_unary(env, &expr->data.unary, reporter);
        
        case EXPR_FN_CALL:
            return typecheck_fn_call(env, &expr->data.fn_call, reporter);
        
        case EXPR_ASSIGNMENT:
            return typecheck_assignment(env, &expr->data.assignment, reporter);
        
        default:
            return type_create_unknown();
    }
}

Type* typecheck_expr(TypeEnvironment* env, Expr* expr, const ErrorReporter* reporter) {
    return typecheck_expr_impl(env, expr, reporter);
}

// Type check statement
TypeCheckResult typecheck_stmt(TypeEnvironment* env, Stmt* stmt, 
                               const ErrorReporter* reporter) {
    if (!stmt) {
        return (TypeCheckResult){true, NULL};
    }
    
    switch (stmt->kind) {
        case STMT_CONST_DECL:
        case STMT_LET_DECL: {
            VarDeclStmt* decl = &stmt->data.var_decl;
            Type* value_type = typecheck_expr(env, decl->value, reporter);
            
            // If type annotation provided, check compatibility
            if (decl->type_annotation) {
                if (!types_compatible(decl->type_annotation, value_type)) {
                    char buf1[128], buf2[128];
                    fprintf(stderr, "Type error: Variable '%.*s' declared as %s but initialized with %s\n",
                           (int)decl->name.length, decl->name.data,
                           type_to_string(decl->type_annotation, buf1, sizeof(buf1)),
                           type_to_string(value_type, buf2, sizeof(buf2)));
                    return (TypeCheckResult){false, "Type mismatch in variable declaration"};
                }
            }
            
            // Add variable to environment
            VarInfo info;
            info.typ = decl->type_annotation ? decl->type_annotation : value_type;
            info.mutable = (stmt->kind == STMT_LET_DECL);
            type_env_set_var(env, decl->name, info);
            
            return (TypeCheckResult){true, NULL};
        }
        
        case STMT_FN_DECL: {
            FnDeclStmt* fn_decl = &stmt->data.fn_decl;
            
            // Register function signature
            FnSignature sig;
            sig.param_count = fn_decl->param_count;
            sig.param_types = (Type**)arena_alloc(env->arena, sizeof(Type*) * fn_decl->param_count);
            
            for (size_t i = 0; i < fn_decl->param_count; i++) {
                sig.param_types[i] = fn_decl->parameters[i].typ;
            }
            sig.return_type = fn_decl->return_type;
            
            type_env_set_fn(env, fn_decl->name, sig);
            
            // Type check function body in new scope
            TypeEnvironment* fn_env = type_env_create(env->arena, env);
            
            // Add parameters to function scope
            for (size_t i = 0; i < fn_decl->param_count; i++) {
                VarInfo param_info;
                param_info.typ = fn_decl->parameters[i].typ;
                param_info.mutable = false;  // Parameters are immutable
                type_env_set_var(fn_env, fn_decl->parameters[i].name, param_info);
            }
            
            // Check body
            Type* body_type = typecheck_expr(fn_env, fn_decl->body, reporter);
            
            if (!types_compatible(fn_decl->return_type, body_type)) {
                char buf1[128], buf2[128];
                fprintf(stderr, "Type error: Function '%.*s' should return %s but returns %s\n",
                       (int)fn_decl->name.length, fn_decl->name.data,
                       type_to_string(fn_decl->return_type, buf1, sizeof(buf1)),
                       type_to_string(body_type, buf2, sizeof(buf2)));
            }
            
            return (TypeCheckResult){true, NULL};
        }
        
        case STMT_RETURN: {
            typecheck_expr(env, stmt->data.return_stmt, reporter);
            return (TypeCheckResult){true, NULL};
        }
        
        case STMT_EXPR:
            typecheck_expr(env, stmt->data.expr_stmt, reporter);
            return (TypeCheckResult){true, NULL};
        
        default:
            return (TypeCheckResult){true, NULL};
    }
}

// Type check entire program
TypeCheckResult typecheck_program(Stmt** stmts, size_t stmt_count,
                                  const ErrorReporter* reporter, Arena* arena) {
    TypeEnvironment* env = type_env_create(arena, NULL);
    
    if (!env) {
        return (TypeCheckResult){false, "Failed to create type environment"};
    }
    
    // Add built-in functions
    // print function: print(str) -> unit
    FnSignature print_sig;
    print_sig.param_count = 1;
    print_sig.param_types = (Type**)arena_alloc(arena, sizeof(Type*));
    print_sig.param_types[0] = type_create_string();
    print_sig.return_type = type_create_unit();
    type_env_set_fn(env, slice_from_cstr("print"), print_sig);
    
    // Type check each statement
    for (size_t i = 0; i < stmt_count; i++) {
        TypeCheckResult result = typecheck_stmt(env, stmts[i], reporter);
        if (!result.success) {
            return result;
        }
    }
    
    return (TypeCheckResult){true, NULL};
}
