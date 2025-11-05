#ifndef ELBA_IR_GEN_H
#define ELBA_IR_GEN_H

#include "ir.h"
#include "../frontend/ast.h"

// IR Generator
typedef struct {
    Arena* arena;
    IRBuilder* builder;
    DynamicArray* functions;  // Array of IRFunction
    Slice current_function;
    bool has_current_function;
} IRGenerator;

// Generator functions
IRGenerator* ir_gen_create(Arena* arena);
void ir_gen_free(IRGenerator* gen);

// Generate IR from AST
void ir_gen_stmt(IRGenerator* gen, Stmt* stmt);
void ir_gen_expr(IRGenerator* gen, Expr* expr);

// Build final program
IRProgram* ir_gen_build_program(IRGenerator* gen);

#endif // ELBA_IR_GEN_H
