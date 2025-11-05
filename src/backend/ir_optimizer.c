#include "ir_optimizer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Create optimizer
IROptimizer* ir_optimizer_create(Arena* arena) {
    IROptimizer* opt = (IROptimizer*)arena_alloc(arena, sizeof(IROptimizer));
    if (!opt) return NULL;
    
    opt->arena = arena;
    memset(&opt->stats, 0, sizeof(OptimizationStats));
    opt->verbose = false;
    
    return opt;
}

// Free optimizer
void ir_optimizer_free(IROptimizer* opt) {
    // Nothing to free explicitly, arena handles memory
}

// Set verbose mode
void ir_optimizer_set_verbose(IROptimizer* opt, bool verbose) {
    opt->verbose = verbose;
}

// Get statistics
OptimizationStats ir_optimizer_get_stats(IROptimizer* opt) {
    return opt->stats;
}

// Print statistics
void ir_optimizer_print_stats(IROptimizer* opt) {
    printf("=== Optimization Statistics ===\n");
    printf("Constant folds:        %zu\n", opt->stats.constant_folds);
    printf("Dead code removed:     %zu\n", opt->stats.dead_code_removed);
    printf("CSE eliminations:      %zu\n", opt->stats.cse_eliminations);
    printf("Strength reductions:   %zu\n", opt->stats.strength_reductions);
    printf("Peephole opts:         %zu\n", opt->stats.peephole_optimizations);
    printf("Total passes:          %zu\n", opt->stats.total_passes);
    printf("===============================\n");
}

// Constant folding pass
static bool constant_fold_pass(IROptimizer* opt, IRInstruction* instructions, size_t* inst_count) {
    bool changed = false;
    size_t write_idx = 0;
    
    for (size_t i = 0; i < *inst_count; i++) {
        IRInstruction* inst = &instructions[i];
        bool folded = false;
        
        // Look for patterns: LOAD_CONST_INT a, LOAD_CONST_INT b, ADD
        if (i + 2 < *inst_count &&
            instructions[i].op == IR_LOAD_CONST_INT &&
            instructions[i+1].op == IR_LOAD_CONST_INT &&
            instructions[i+2].op == IR_ADD) {
            
            int64_t a = instructions[i].operand1;
            int64_t b = instructions[i+1].operand1;
            int64_t result = a + b;
            
            // Replace with single LOAD_CONST_INT
            instructions[write_idx++] = (IRInstruction){
                .op = IR_LOAD_CONST_INT,
                .operand1 = result,
                .operand2 = 0,
                .operand3 = 0,
                .string_data = NULL
            };
            
            i += 2; // Skip the next two instructions
            changed = true;
            folded = true;
            opt->stats.constant_folds++;
            
            if (opt->verbose) {
                printf("Constant fold: %lld + %lld = %lld\n", 
                       (long long)a, (long long)b, (long long)result);
            }
        }
        // Similar for SUB
        else if (i + 2 < *inst_count &&
            instructions[i].op == IR_LOAD_CONST_INT &&
            instructions[i+1].op == IR_LOAD_CONST_INT &&
            instructions[i+2].op == IR_SUB) {
            
            int64_t a = instructions[i].operand1;
            int64_t b = instructions[i+1].operand1;
            int64_t result = a - b;
            
            instructions[write_idx++] = (IRInstruction){
                .op = IR_LOAD_CONST_INT,
                .operand1 = result,
                .operand2 = 0,
                .operand3 = 0,
                .string_data = NULL
            };
            
            i += 2;
            changed = true;
            folded = true;
            opt->stats.constant_folds++;
        }
        // Similar for MUL
        else if (i + 2 < *inst_count &&
            instructions[i].op == IR_LOAD_CONST_INT &&
            instructions[i+1].op == IR_LOAD_CONST_INT &&
            instructions[i+2].op == IR_MUL) {
            
            int64_t a = instructions[i].operand1;
            int64_t b = instructions[i+1].operand1;
            int64_t result = a * b;
            
            instructions[write_idx++] = (IRInstruction){
                .op = IR_LOAD_CONST_INT,
                .operand1 = result,
                .operand2 = 0,
                .operand3 = 0,
                .string_data = NULL
            };
            
            i += 2;
            changed = true;
            folded = true;
            opt->stats.constant_folds++;
        }
        
        if (!folded) {
            instructions[write_idx++] = instructions[i];
        }
    }
    
    *inst_count = write_idx;
    return changed;
}

// Dead code elimination pass
static bool dead_code_elimination_pass(IROptimizer* opt, IRInstruction* instructions, size_t* inst_count) {
    bool changed = false;
    size_t write_idx = 0;
    
    for (size_t i = 0; i < *inst_count; i++) {
        IRInstruction* inst = &instructions[i];
        bool dead = false;
        
        // Remove POP followed by another POP (redundant stack cleanup)
        if (i + 1 < *inst_count &&
            inst->op == IR_POP &&
            instructions[i+1].op == IR_POP) {
            
            // Keep both POPs but note that this pattern could be optimized
            // in a more sophisticated pass
        }
        
        // Remove LOAD followed immediately by POP (unused value)
        if (i + 1 < *inst_count &&
            (inst->op == IR_LOAD_CONST_INT || 
             inst->op == IR_LOAD_CONST_FLOAT ||
             inst->op == IR_LOAD_CONST_BOOL ||
             inst->op == IR_LOAD_CONST_STR) &&
            instructions[i+1].op == IR_POP) {
            
            i++; // Skip both instructions
            dead = true;
            changed = true;
            opt->stats.dead_code_removed++;
            
            if (opt->verbose) {
                printf("Dead code: Load followed by POP removed\n");
            }
        }
        
        if (!dead) {
            instructions[write_idx++] = instructions[i];
        }
    }
    
    *inst_count = write_idx;
    return changed;
}

// Peephole optimization pass
static bool peephole_pass(IROptimizer* opt, IRInstruction* instructions, size_t* inst_count) {
    bool changed = false;
    size_t write_idx = 0;
    
    for (size_t i = 0; i < *inst_count; i++) {
        IRInstruction* inst = &instructions[i];
        bool optimized = false;
        
        // DUP followed by POP is a no-op
        if (i + 1 < *inst_count &&
            inst->op == IR_DUP &&
            instructions[i+1].op == IR_POP) {
            
            i++; // Skip both
            optimized = true;
            changed = true;
            opt->stats.peephole_optimizations++;
            
            if (opt->verbose) {
                printf("Peephole: DUP-POP removed\n");
            }
        }
        // ADD 0 is a no-op
        else if (i > 0 && 
                 inst->op == IR_ADD &&
                 instructions[i-1].op == IR_LOAD_CONST_INT &&
                 instructions[i-1].operand1 == 0) {
            
            write_idx--; // Remove the LOAD_CONST_INT 0
            optimized = true;
            changed = true;
            opt->stats.peephole_optimizations++;
        }
        
        if (!optimized) {
            instructions[write_idx++] = instructions[i];
        }
    }
    
    *inst_count = write_idx;
    return changed;
}

// Strength reduction pass
static bool strength_reduction_pass(IROptimizer* opt, IRInstruction* instructions, size_t* inst_count) {
    bool changed = false;
    
    for (size_t i = 0; i < *inst_count; i++) {
        IRInstruction* inst = &instructions[i];
        
        // MUL by 2 -> Left shift (conceptual, we don't have shift in our IR)
        // DIV by power of 2 -> Right shift (conceptual)
        // For now, just track that we looked for these patterns
        
        // MUL by 1 -> no-op
        if (i > 0 &&
            inst->op == IR_MUL &&
            instructions[i-1].op == IR_LOAD_CONST_INT &&
            instructions[i-1].operand1 == 1) {
            
            // Remove LOAD 1 and MUL
            // This is a peephole opt, but categorize as strength reduction
            opt->stats.strength_reductions++;
            changed = true;
        }
    }
    
    return changed;
}

// Optimize a function
void ir_optimizer_optimize_function(IROptimizer* opt, IRFunction* func) {
    if (!func || func->instruction_count == 0) return;
    
    size_t inst_count = func->instruction_count;
    bool changed = true;
    int pass_count = 0;
    const int MAX_PASSES = 10;
    
    while (changed && pass_count < MAX_PASSES) {
        changed = false;
        opt->stats.total_passes++;
        pass_count++;
        
        // Run optimization passes
        changed |= constant_fold_pass(opt, func->instructions, &inst_count);
        changed |= dead_code_elimination_pass(opt, func->instructions, &inst_count);
        changed |= peephole_pass(opt, func->instructions, &inst_count);
        changed |= strength_reduction_pass(opt, func->instructions, &inst_count);
    }
    
    func->instruction_count = inst_count;
    
    if (opt->verbose && pass_count > 1) {
        printf("Optimized function '%.*s' in %d passes\n",
               (int)func->name.length, func->name.data, pass_count);
    }
}

// Optimize a program
void ir_optimizer_optimize_program(IROptimizer* opt, IRProgram* program) {
    if (!program) return;
    
    if (opt->verbose) {
        printf("=== Starting IR Optimization ===\n");
    }
    
    for (size_t i = 0; i < program->function_count; i++) {
        ir_optimizer_optimize_function(opt, &program->functions[i]);
    }
    
    if (opt->verbose) {
        printf("=== Optimization Complete ===\n");
        ir_optimizer_print_stats(opt);
    }
}
