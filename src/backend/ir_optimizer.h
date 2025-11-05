#ifndef ELBA_IR_OPTIMIZER_H
#define ELBA_IR_OPTIMIZER_H

#include "ir.h"

// Optimization pass types
typedef enum {
    OPT_CONSTANT_FOLDING,
    OPT_DEAD_CODE_ELIMINATION,
    OPT_COMMON_SUBEXPRESSION_ELIMINATION,
    OPT_STRENGTH_REDUCTION,
    OPT_PEEPHOLE,
} OptimizationPass;

// Optimization statistics
typedef struct {
    size_t constant_folds;
    size_t dead_code_removed;
    size_t cse_eliminations;
    size_t strength_reductions;
    size_t peephole_optimizations;
    size_t total_passes;
} OptimizationStats;

// IR Optimizer
typedef struct {
    Arena* arena;
    OptimizationStats stats;
    bool verbose;
} IROptimizer;

// Optimizer functions
IROptimizer* ir_optimizer_create(Arena* arena);
void ir_optimizer_free(IROptimizer* opt);

// Optimize a function
void ir_optimizer_optimize_function(IROptimizer* opt, IRFunction* func);

// Optimize a program
void ir_optimizer_optimize_program(IROptimizer* opt, IRProgram* program);

// Enable verbose output
void ir_optimizer_set_verbose(IROptimizer* opt, bool verbose);

// Get optimization statistics
OptimizationStats ir_optimizer_get_stats(IROptimizer* opt);

// Print statistics
void ir_optimizer_print_stats(IROptimizer* opt);

#endif // ELBA_IR_OPTIMIZER_H
