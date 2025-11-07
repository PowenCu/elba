#include "llvm_codegen.h"
#include <stdio.h>
#include <string.h>

#ifdef ENABLE_LLVM

// LLVM Code Generator Implementation (Simplified)

LLVMCodeGen* llvm_codegen_create(Arena* arena, const char* module_name) {
    LLVMCodeGen* gen = arena_alloc(arena, sizeof(LLVMCodeGen));
    gen->arena = arena;
    
    // Initialize LLVM
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
    LLVMInitializeNativeAsmParser();
    
    // Create context and module
    gen->context = LLVMContextCreate();
    gen->module = LLVMModuleCreateWithNameInContext(module_name, gen->context);
    gen->builder = LLVMCreateBuilderInContext(gen->context);
    
    // Create type cache
    gen->i64_type = LLVMInt64TypeInContext(gen->context);
    gen->f64_type = LLVMDoubleTypeInContext(gen->context);
    gen->i1_type = LLVMInt1TypeInContext(gen->context);
    gen->i8_type = LLVMInt8TypeInContext(gen->context);
    gen->void_type = LLVMVoidTypeInContext(gen->context);
    gen->ptr_type = LLVMPointerTypeInContext(gen->context, 0);
    
    // Initialize hash maps
    gen->functions = hashmap_create(arena, 64);
    gen->variables = hashmap_create(arena, 256);
    gen->variable_types = hashmap_create(arena, 256);
    gen->string_literals = hashmap_create(arena, 64);
    gen->basic_blocks = hashmap_create(arena, 64);
    
    gen->stack = dyn_array_create(sizeof(LLVMValueRef));
    gen->current_function = NULL;
    gen->temp_slot = NULL;
    
    return gen;
}

bool llvm_codegen_generate(LLVMCodeGen* gen, IRProgram* program) {
    // Simplified implementation - generates minimal LLVM IR
    LLVMTypeRef main_type = LLVMFunctionType(gen->i64_type, NULL, 0, 0);
    LLVMValueRef main_func = LLVMAddFunction(gen->module, "main", main_type);
    
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(gen->context, main_func, "entry");
    LLVMPositionBuilderAtEnd(gen->builder, entry);
    
    LLVMValueRef zero = LLVMConstInt(gen->i64_type, 0, 0);
    LLVMBuildRet(gen->builder, zero);
    
    // Verify module
    char* error_msg = NULL;
    if (LLVMVerifyModule(gen->module, LLVMReturnStatusAction, &error_msg)) {
        fprintf(stderr, "LLVM module verification failed:\n%s\n", error_msg);
        LLVMDisposeMessage(error_msg);
        return false;
    }
    
    return true;
}

bool llvm_codegen_emit_ir(LLVMCodeGen* gen, const char* output_path) {
    char* error_msg = NULL;
    if (LLVMPrintModuleToFile(gen->module, output_path, &error_msg)) {
        fprintf(stderr, "Failed to write LLVM IR: %s\n", error_msg);
        LLVMDisposeMessage(error_msg);
        return false;
    }
    return true;
}

bool llvm_codegen_emit_object(LLVMCodeGen* gen, const char* output_path) {
    LLVMTargetRef target;
    char* target_triple = LLVMGetDefaultTargetTriple();
    char* error_msg = NULL;
    
    if (LLVMGetTargetFromTriple(target_triple, &target, &error_msg)) {
        fprintf(stderr, "Failed to get target: %s\n", error_msg);
        LLVMDisposeMessage(error_msg);
        LLVMDisposeMessage(target_triple);
        return false;
    }
    
    char* cpu = LLVMGetHostCPUName();
    char* features = LLVMGetHostCPUFeatures();
    
    LLVMTargetMachineRef machine = LLVMCreateTargetMachine(
        target, target_triple, cpu, features,
        LLVMCodeGenLevelDefault, LLVMRelocDefault, LLVMCodeModelDefault
    );
    
    LLVMDisposeMessage(target_triple);
    LLVMDisposeMessage(cpu);
    LLVMDisposeMessage(features);
    
    if (LLVMTargetMachineEmitToFile(machine, gen->module, (char*)output_path, 
                                   LLVMObjectFile, &error_msg)) {
        fprintf(stderr, "Failed to emit object file: %s\n", error_msg);
        LLVMDisposeMessage(error_msg);
        LLVMDisposeTargetMachine(machine);
        return false;
    }
    
    LLVMDisposeTargetMachine(machine);
    return true;
}

void llvm_codegen_dump(LLVMCodeGen* gen) {
    LLVMDumpModule(gen->module);
}

void llvm_codegen_free(LLVMCodeGen* gen) {
    if (gen->builder) LLVMDisposeBuilder(gen->builder);
    if (gen->module) LLVMDisposeModule(gen->module);
    if (gen->context) LLVMContextDispose(gen->context);
}

#endif // ENABLE_LLVM
