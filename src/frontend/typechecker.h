#ifndef ELBA_TYPECHECKER_H
#define ELBA_TYPECHECKER_H

#include "../common.h"
#include "ast.h"
#include "../utils/error_reporter.h"

// Variable information in type environment
typedef struct {
    Type* typ;
    bool mutable;
} VarInfo;

// Function signature
typedef struct {
    Type** param_types;
    size_t param_count;
    Type* return_type;
} FnSignature;

// Simple hash map for type environment
typedef struct TypeEnvEntry {
    Slice key;
    VarInfo value;
    struct TypeEnvEntry* next;
} TypeEnvEntry;

typedef struct FnEnvEntry {
    Slice key;
    FnSignature value;
    struct FnEnvEntry* next;
} FnEnvEntry;

typedef struct TypeEnvironment TypeEnvironment;

struct TypeEnvironment {
    TypeEnvEntry* vars[256];      // Simple hash table for variables
    FnEnvEntry* functions[256];   // Simple hash table for functions
    TypeEnvironment* parent;       // Parent scope for lexical scoping
    Arena* arena;                  // For allocations
};

// Type checking result
typedef struct {
    bool success;
    const char* error_message;
} TypeCheckResult;

// Type environment functions
TypeEnvironment* type_env_create(Arena* arena, TypeEnvironment* parent);
void type_env_free(TypeEnvironment* env);
void type_env_set_var(TypeEnvironment* env, Slice name, VarInfo info);
VarInfo* type_env_get_var(TypeEnvironment* env, Slice name);
void type_env_set_fn(TypeEnvironment* env, Slice name, FnSignature sig);
FnSignature* type_env_get_fn(TypeEnvironment* env, Slice name);

// Type checking functions
TypeCheckResult typecheck_stmt(TypeEnvironment* env, Stmt* stmt, const ErrorReporter* reporter);
Type* typecheck_expr(TypeEnvironment* env, Expr* expr, const ErrorReporter* reporter);
bool types_compatible(const Type* a, const Type* b);
const char* type_to_string(const Type* typ, char* buf, size_t buf_size);

// Main typechecker entry point
TypeCheckResult typecheck_program(Stmt** stmts, size_t stmt_count, 
                                   const ErrorReporter* reporter, Arena* arena);

#endif // ELBA_TYPECHECKER_H
