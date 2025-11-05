#ifndef C_CODEGEN_H
#define C_CODEGEN_H

#include "../common.h"
#include "../backend/ir.h"

// C Code Generator
// Transpiles Elba IR to C code

typedef struct {
    Arena* arena;
    DynamicArray* output;  // char array - generated C code
    size_t indent_level;
    size_t label_counter;
    HashMap variables;  // Track declared variables
    
    // Feature flags
    bool uses_strings;
    bool uses_arrays;
    bool uses_structs;
    bool uses_floats;
    HashMap used_builtins;  // Track which built-ins are used
} CCodeGen;

// Initialize C code generator
CCodeGen* c_codegen_create(Arena* arena);

// Generate C code from IR
const char* c_codegen_generate(CCodeGen* gen, IRProgram* program);

// Write generated C code to file
bool c_codegen_write_file(CCodeGen* gen, const char* output_path);

// Free resources
void c_codegen_free(CCodeGen* gen);

#endif // C_CODEGEN_H
