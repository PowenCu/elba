#ifndef ELBA_INTERPRETER_H
#define ELBA_INTERPRETER_H

#include "../common.h"
#include "../frontend/ast.h"

// Function value for user-defined functions
typedef struct {
    Parameter* parameters;
    size_t param_count;
    Expr* body;
} FnValue;

// Interpreter environment entry
typedef struct InterpEnvEntry {
    Slice key;
    Value value;
    struct InterpEnvEntry* next;
} InterpEnvEntry;

typedef struct InterpFnEntry {
    Slice key;
    FnValue value;
    struct InterpFnEntry* next;
} InterpFnEntry;

// Interpreter environment
typedef struct InterpEnvironment {
    InterpEnvEntry* vars[256];      // Hash table for variables
    InterpFnEntry* functions[256];   // Hash table for functions
    struct InterpEnvironment* parent;  // Parent scope
    Arena* arena;                    // Arena allocator
    Value* return_value;            // For early returns
    bool has_return;                // Flag for return
} InterpEnvironment;

// Interpreter result
typedef struct {
    bool success;
    const char* error_message;
    Value result;
} InterpResult;

// Environment functions
InterpEnvironment* interp_env_create(Arena* arena, InterpEnvironment* parent);
void interp_env_set_var(InterpEnvironment* env, Slice name, Value value);
Value* interp_env_get_var(InterpEnvironment* env, Slice name);
void interp_env_set_fn(InterpEnvironment* env, Slice name, FnValue fn_val);
FnValue* interp_env_get_fn(InterpEnvironment* env, Slice name);

// Evaluation functions
InterpResult interp_eval_stmt(InterpEnvironment* env, Stmt* stmt);
InterpResult interp_eval_expr(InterpEnvironment* env, Expr* expr);

// Main interpreter entry point
InterpResult interp_run_program(Stmt** stmts, size_t stmt_count, Arena* arena);

#endif // ELBA_INTERPRETER_H
