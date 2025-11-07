#include "ir_gen.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Create IR generator
IRGenerator* ir_gen_create(Arena* arena) {
    IRGenerator* gen = (IRGenerator*)arena_alloc(arena, sizeof(IRGenerator));
    if (!gen) return NULL;
    
    gen->arena = arena;
    gen->builder = ir_builder_create(arena);
    gen->functions = dyn_array_create(sizeof(IRFunction));
    gen->has_current_function = false;
    
    return gen;
}

// Free IR generator
void ir_gen_free(IRGenerator* gen) {
    if (!gen) return;
    ir_builder_free(gen->builder);
    dyn_array_free(gen->functions);
}

// Forward declarations
static void gen_expr_impl(IRGenerator* gen, Expr* expr);

// Generate IR for binary expression
static void gen_binary(IRGenerator* gen, BinaryExpr* binary) {
    // Generate left operand
    gen_expr_impl(gen, binary->left);
    
    // Generate right operand
    gen_expr_impl(gen, binary->right);
    
    // Emit operation
    IROpcode op;
    switch (binary->op) {
        case BINOP_ADD: op = IR_ADD; break;
        case BINOP_SUB: op = IR_SUB; break;
        case BINOP_MUL: op = IR_MUL; break;
        case BINOP_DIV: op = IR_DIV; break;
        case BINOP_MOD: op = IR_MOD; break;
        case BINOP_POW: op = IR_POW; break;
        case BINOP_EQUAL: op = IR_EQ; break;
        case BINOP_NOT_EQUAL: op = IR_NEQ; break;
        case BINOP_LESS: op = IR_LT; break;
        case BINOP_LESS_EQUAL: op = IR_LTE; break;
        case BINOP_GREATER: op = IR_GT; break;
        case BINOP_GREATER_EQUAL: op = IR_GTE; break;
        case BINOP_LOGICAL_AND: op = IR_AND; break;
        case BINOP_LOGICAL_OR: op = IR_OR; break;
        default:
            fprintf(stderr, "Unsupported binary operator in IR generation\n");
            return;
    }
    
    ir_builder_emit(gen->builder, op, 0, 0, 0);
}

// Generate IR for unary expression
static void gen_unary(IRGenerator* gen, UnaryExpr* unary) {
    gen_expr_impl(gen, unary->operand);
    
    IROpcode op;
    switch (unary->op) {
        case UNOP_NEGATE: op = IR_NEG; break;
        case UNOP_LOGICAL_NOT: op = IR_NOT; break;
        default:
            fprintf(stderr, "Unsupported unary operator in IR generation\n");
            return;
    }
    
    ir_builder_emit(gen->builder, op, 0, 0, 0);
}

// Generate IR for function call
static void gen_fn_call(IRGenerator* gen, FnCallExpr* call) {
    // Generate arguments in order
    for (size_t i = 0; i < call->arg_count; i++) {
        gen_expr_impl(gen, call->arguments[i]);
    }
    
    // Create null-terminated string from Slice
    char* name_str = (char*)arena_alloc(gen->arena, call->name.length + 1);
    memcpy(name_str, call->name.data, call->name.length);
    name_str[call->name.length] = '\0';
    
    // Emit call instruction
    ir_builder_emit_with_string(gen->builder, IR_CALL, name_str, (int64_t)call->arg_count, 0);
}

// Generate IR for expression
static void gen_expr_impl(IRGenerator* gen, Expr* expr) {
    if (!expr) {
        ir_builder_emit(gen->builder, IR_LOAD_NULL, 0, 0, 0);
        return;
    }
    
    switch (expr->kind) {
        case EXPR_INT_LITERAL:
            ir_builder_emit(gen->builder, IR_LOAD_CONST_INT, expr->data.int_literal, 0, 0);
            break;
            
        case EXPR_FLOAT_LITERAL: {
            // Pack float as int64 for storage
            union { double f; int64_t i; } u;
            u.f = expr->data.float_literal;
            ir_builder_emit(gen->builder, IR_LOAD_CONST_FLOAT, u.i, 0, 0);
            break;
        }
        
        case EXPR_STRING_LITERAL: {
            // Intern the string
            size_t str_index = ir_builder_intern_string(gen->builder, 
                                                         expr->data.string_literal.data,
                                                         expr->data.string_literal.length);
            ir_builder_emit(gen->builder, IR_LOAD_CONST_STR, (int64_t)str_index, 0, 0);
            break;
        }
        
        case EXPR_BOOL_LITERAL:
            ir_builder_emit(gen->builder, IR_LOAD_CONST_BOOL, expr->data.bool_literal ? 1 : 0, 0, 0);
            break;
            
        case EXPR_NULL_LITERAL:
            ir_builder_emit(gen->builder, IR_LOAD_NULL, 0, 0, 0);
            break;
            
        case EXPR_VARIABLE: {
            // Create null-terminated string from Slice
            char* var_name = (char*)arena_alloc(gen->arena, expr->data.variable.length + 1);
            memcpy(var_name, expr->data.variable.data, expr->data.variable.length);
            var_name[expr->data.variable.length] = '\0';
            ir_builder_emit_with_string(gen->builder, IR_LOAD_VAR, var_name, 0, 0);
            break;
        }
        
        case EXPR_BINARY:
            gen_binary(gen, &expr->data.binary);
            break;
            
        case EXPR_UNARY:
            gen_unary(gen, &expr->data.unary);
            break;
            
        case EXPR_FN_CALL:
            gen_fn_call(gen, &expr->data.fn_call);
            break;
            
        case EXPR_ASSIGNMENT: {
            // Generate value
            gen_expr_impl(gen, expr->data.assignment.value);
            
            // Duplicate value to leave on stack
            ir_builder_emit(gen->builder, IR_DUP, 0, 0, 0);
            
            // Store to variable
            char* var_name = (char*)arena_alloc(gen->arena, expr->data.assignment.name.length + 1);
            memcpy(var_name, expr->data.assignment.name.data, expr->data.assignment.name.length);
            var_name[expr->data.assignment.name.length] = '\0';
            ir_builder_emit_with_string(gen->builder, IR_STORE_VAR, var_name, 0, 0);
            break;
        }
        
        default:
            fprintf(stderr, "Unsupported expression type in IR generation\n");
            ir_builder_emit(gen->builder, IR_LOAD_NULL, 0, 0, 0);
            break;
    }
}

void ir_gen_expr(IRGenerator* gen, Expr* expr) {
    gen_expr_impl(gen, expr);
}

// Generate IR for statement
void ir_gen_stmt(IRGenerator* gen, Stmt* stmt) {
    if (!stmt) return;
    
    switch (stmt->kind) {
        case STMT_CONST_DECL:
        case STMT_LET_DECL: {
            // Generate value
            gen_expr_impl(gen, stmt->data.var_decl.value);
            
            // Store to variable
            char* var_name = (char*)arena_alloc(gen->arena, stmt->data.var_decl.name.length + 1);
            memcpy(var_name, stmt->data.var_decl.name.data, stmt->data.var_decl.name.length);
            var_name[stmt->data.var_decl.name.length] = '\0';
            ir_builder_emit_with_string(gen->builder, IR_STORE_VAR, var_name, 0, 0);
            break;
        }
        
        case STMT_FN_DECL: {
            // Save current builder state
            DynamicArray* saved_instructions = gen->builder->instructions;
            gen->builder->instructions = dyn_array_create(sizeof(IRInstruction));
            
            // Remember current function
            Slice prev_function = gen->current_function;
            bool had_function = gen->has_current_function;
            gen->current_function = stmt->data.fn_decl.name;
            gen->has_current_function = true;
            
            // Generate function body
            gen_expr_impl(gen, stmt->data.fn_decl.body);
            
            // Emit return
            ir_builder_emit(gen->builder, IR_RET, 0, 0, 0);
            
            // Build function
            IRFunction func = ir_builder_build_function(gen->builder, 
                                                        stmt->data.fn_decl.name,
                                                        stmt->data.fn_decl.param_count,
                                                        0);  // local_count computed later
            
            // Add to function list
            dyn_array_append(gen->functions, &func);
            
            // Restore builder state
            dyn_array_free(gen->builder->instructions);
            gen->builder->instructions = saved_instructions;
            gen->current_function = prev_function;
            gen->has_current_function = had_function;
            break;
        }
        
        case STMT_RETURN:
            gen_expr_impl(gen, stmt->data.return_stmt);
            ir_builder_emit(gen->builder, IR_RET, 0, 0, 0);
            break;
            
        case STMT_EXPR:
            gen_expr_impl(gen, stmt->data.expr_stmt);
            // Pop unused result
            ir_builder_emit(gen->builder, IR_POP, 0, 0, 0);
            break;
            
        default:
            fprintf(stderr, "Unsupported statement type in IR generation\n");
            break;
    }
}

// Build final IR program
IRProgram* ir_gen_build_program(IRGenerator* gen) {
    IRProgram* program = ir_program_create(gen->arena);
    if (!program) return NULL;
    
    // Copy functions
    program->function_count = gen->functions->length;
    program->functions = (IRFunction*)arena_alloc(gen->arena, 
                                                    sizeof(IRFunction) * program->function_count);
    memcpy(program->functions, gen->functions->items, 
           sizeof(IRFunction) * program->function_count);
    
    // Copy string pool
    program->string_pool_size = gen->builder->string_list->length;
    program->string_pool = (const char**)arena_alloc(gen->arena, 
                                                       sizeof(char*) * program->string_pool_size);
    memcpy(program->string_pool, gen->builder->string_list->items,
           sizeof(char*) * program->string_pool_size);
    
    program->entry_point = slice_from_cstr("main");
    program->module_count = 0;
    program->modules = NULL;
    
    return program;
}
