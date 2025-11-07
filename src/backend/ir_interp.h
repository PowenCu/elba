#ifndef ELBA_IR_INTERP_H
#define ELBA_IR_INTERP_H

#include "ir.h"
#include "../frontend/ast.h"

// IR Interpreter result
typedef struct {
    bool success;
    const char* error_message;
    Value result;
} IRInterpResult;

// IR Interpreter
typedef struct IRInterpreter IRInterpreter;

// Create interpreter
IRInterpreter* ir_interp_create(Arena* arena);
void ir_interp_free(IRInterpreter* interp);

// Execute IR program
IRInterpResult ir_interp_execute(IRInterpreter* interp, IRProgram* program);

// Execute IR function
IRInterpResult ir_interp_execute_function(IRInterpreter* interp, IRFunction* func);

#endif // ELBA_IR_INTERP_H
