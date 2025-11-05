#ifndef LLVM_CODEGEN_H
#define LLVM_CODEGEN_H

#include "../common.h"
#include "ir.h"

#ifdef ENABLE_LLVM
#include <llvm-c/Core.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#include <llvm-c/Analysis.h>
#endif

// LLVM Code Generator
// Compiles Elba IR to native machine code via LLVM

#ifdef ENABLE_LLVM

typedef struct LLVMCodeGen {
    Arena* arena;
    LLVMContextRef context;
    LLVMModuleRef module;
    LLVMBuilderRef builder;
    
    // Type cache
    LLVMTypeRef i64_type;
    LLVMTypeRef f64_type;
    LLVMTypeRef i1_type;
    LLVMTypeRef i8_type;
    LLVMTypeRef void_type;
    LLVMTypeRef ptr_type;
    
    // Function registry
    HashMap functions;  // name -> LLVMValueRef
    
    // Current function state
    LLVMValueRef current_function;
    DynamicArray stack;  // LLVMValueRef stack
    HashMap variables;   // name -> LLVMValueRef (allocas)
    HashMap variable_types;  // name -> LLVMTypeRef
    HashMap string_literals;  // string -> LLVMValueRef
    HashMap basic_blocks;  // label -> LLVMBasicBlockRef
    LLVMValueRef temp_slot;  // For passing values across basic blocks
} LLVMCodeGen;

// Initialize LLVM code generator
LLVMCodeGen* llvm_codegen_create(Arena* arena, const char* module_name);

// Generate LLVM IR from Elba IR
bool llvm_codegen_generate(LLVMCodeGen* gen, IRProgram* program);

// Emit LLVM IR to file
bool llvm_codegen_emit_ir(LLVMCodeGen* gen, const char* output_path);

// Emit object file
bool llvm_codegen_emit_object(LLVMCodeGen* gen, const char* output_path);

// Print LLVM IR to stdout
void llvm_codegen_dump(LLVMCodeGen* gen);

// Free resources
void llvm_codegen_free(LLVMCodeGen* gen);

#endif // ENABLE_LLVM

#endif // LLVM_CODEGEN_H
