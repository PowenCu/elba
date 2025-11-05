#include "ast.h"
#include <stdlib.h>
#include <string.h>

// ============= Type Functions =============

Type* type_create_int(void) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_INT;
    return type;
}

Type* type_create_float(void) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_FLOAT;
    return type;
}

Type* type_create_string(void) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_STRING;
    return type;
}

Type* type_create_bool(void) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_BOOL;
    return type;
}

Type* type_create_unit(void) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_UNIT;
    return type;
}

Type* type_create_unknown(void) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_UNKNOWN;
    return type;
}

Type* type_create_user(const char* name, size_t len) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_USER_TYPE;
    type->data.user_type = slice_from_ptr_len(name, len);
    return type;
}

Type* type_create_generic_param(const char* name, size_t len) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_GENERIC_PARAM;
    type->data.generic_param = slice_from_ptr_len(name, len);
    return type;
}

Type* type_create_array(Type* elem_type) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_ARRAY;
    type->data.array_elem_type = elem_type;
    return type;
}

Type* type_create_optional(Type* inner_type) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_OPTIONAL;
    type->data.optional_inner = inner_type;
    return type;
}

Type* type_create_union(Type* types, size_t count) {
    Type* type = (Type*)malloc(sizeof(Type));
    type->kind = TYPE_UNION;
    type->data.union_type.types = types;
    type->data.union_type.count = count;
    return type;
}

bool type_is_numeric(const Type* type) {
    return type->kind == TYPE_INT || type->kind == TYPE_FLOAT;
}

bool type_equals(const Type* a, const Type* b) {
    if (a->kind != b->kind) return false;
    
    switch (a->kind) {
        case TYPE_USER_TYPE:
            return slice_equals(a->data.user_type, b->data.user_type);
        case TYPE_GENERIC_PARAM:
            return slice_equals(a->data.generic_param, b->data.generic_param);
        case TYPE_ARRAY:
            return type_equals(a->data.array_elem_type, b->data.array_elem_type);
        case TYPE_OPTIONAL:
            return type_equals(a->data.optional_inner, b->data.optional_inner);
        case TYPE_UNION: {
            if (a->data.union_type.count != b->data.union_type.count) return false;
            for (size_t i = 0; i < a->data.union_type.count; i++) {
                if (!type_equals(&a->data.union_type.types[i], &b->data.union_type.types[i])) {
                    return false;
                }
            }
            return true;
        }
        default:
            return true;
    }
}

void type_free(Type* type) {
    if (!type) return;
    
    switch (type->kind) {
        case TYPE_ARRAY:
            type_free(type->data.array_elem_type);
            break;
        case TYPE_OPTIONAL:
            type_free(type->data.optional_inner);
            break;
        case TYPE_UNION:
            for (size_t i = 0; i < type->data.union_type.count; i++) {
                type_free(&type->data.union_type.types[i]);
            }
            free(type->data.union_type.types);
            break;
        default:
            break;
    }
    free(type);
}

// ============= Value Functions =============

Value* value_create_int(int64_t val) {
    Value* value = (Value*)malloc(sizeof(Value));
    value->kind = VALUE_INT;
    value->data.int_val = val;
    return value;
}

Value* value_create_float(double val) {
    Value* value = (Value*)malloc(sizeof(Value));
    value->kind = VALUE_FLOAT;
    value->data.float_val = val;
    return value;
}

Value* value_create_string(const char* str, size_t len) {
    Value* value = (Value*)malloc(sizeof(Value));
    value->kind = VALUE_STRING;
    value->data.string_val = slice_from_ptr_len(str, len);
    return value;
}

Value* value_create_bool(bool val) {
    Value* value = (Value*)malloc(sizeof(Value));
    value->kind = VALUE_BOOL;
    value->data.bool_val = val;
    return value;
}

Value* value_create_unit(void) {
    Value* value = (Value*)malloc(sizeof(Value));
    value->kind = VALUE_UNIT;
    return value;
}

Value* value_create_null(void) {
    Value* value = (Value*)malloc(sizeof(Value));
    value->kind = VALUE_NULL;
    return value;
}

void value_free(Value* val) {
    if (!val) return;
    
    switch (val->kind) {
        case VALUE_STRUCT_INSTANCE:
            free(val->data.struct_instance.fields.names);
            for (size_t i = 0; i < val->data.struct_instance.fields.count; i++) {
                value_free(&val->data.struct_instance.fields.values[i]);
            }
            free(val->data.struct_instance.fields.values);
            break;
        case VALUE_ARRAY:
            for (size_t i = 0; i < val->data.array.count; i++) {
                value_free(&val->data.array.elements[i]);
            }
            free(val->data.array.elements);
            break;
        default:
            break;
    }
    free(val);
}

// ============= Expression Functions =============

Expr* expr_create_int_literal(int64_t val) {
    Expr* expr = (Expr*)malloc(sizeof(Expr));
    expr->kind = EXPR_INT_LITERAL;
    expr->data.int_literal = val;
    return expr;
}

Expr* expr_create_float_literal(double val) {
    Expr* expr = (Expr*)malloc(sizeof(Expr));
    expr->kind = EXPR_FLOAT_LITERAL;
    expr->data.float_literal = val;
    return expr;
}

Expr* expr_create_string_literal(const char* str, size_t len) {
    Expr* expr = (Expr*)malloc(sizeof(Expr));
    expr->kind = EXPR_STRING_LITERAL;
    expr->data.string_literal = slice_from_ptr_len(str, len);
    return expr;
}

Expr* expr_create_bool_literal(bool val) {
    Expr* expr = (Expr*)malloc(sizeof(Expr));
    expr->kind = EXPR_BOOL_LITERAL;
    expr->data.bool_literal = val;
    return expr;
}

Expr* expr_create_null_literal(void) {
    Expr* expr = (Expr*)malloc(sizeof(Expr));
    expr->kind = EXPR_NULL_LITERAL;
    return expr;
}

Expr* expr_create_variable(const char* name, size_t len) {
    Expr* expr = (Expr*)malloc(sizeof(Expr));
    expr->kind = EXPR_VARIABLE;
    expr->data.variable = slice_from_ptr_len(name, len);
    return expr;
}

Expr* expr_create_binary(Expr* left, BinaryOp op, Expr* right) {
    Expr* expr = (Expr*)malloc(sizeof(Expr));
    expr->kind = EXPR_BINARY;
    expr->data.binary.left = left;
    expr->data.binary.op = op;
    expr->data.binary.right = right;
    return expr;
}

Expr* expr_create_unary(UnaryOp op, Expr* operand) {
    Expr* expr = (Expr*)malloc(sizeof(Expr));
    expr->kind = EXPR_UNARY;
    expr->data.unary.op = op;
    expr->data.unary.operand = operand;
    return expr;
}

void expr_free(Expr* expr) {
    if (!expr) return;
    
    switch (expr->kind) {
        case EXPR_BINARY:
            expr_free(expr->data.binary.left);
            expr_free(expr->data.binary.right);
            break;
        case EXPR_UNARY:
            expr_free(expr->data.unary.operand);
            break;
        case EXPR_BLOCK:
            for (size_t i = 0; i < expr->data.block.stmt_count; i++) {
                stmt_free(&expr->data.block.statements[i]);
            }
            free(expr->data.block.statements);
            expr_free(expr->data.block.return_expr);
            break;
        case EXPR_IF:
            expr_free(expr->data.if_expr.condition);
            expr_free(expr->data.if_expr.then_block);
            expr_free(expr->data.if_expr.else_block);
            break;
        case EXPR_WHILE:
            expr_free(expr->data.while_expr.condition);
            expr_free(expr->data.while_expr.body);
            break;
        case EXPR_FOR:
            expr_free(expr->data.for_expr.iterable);
            expr_free(expr->data.for_expr.body);
            break;
        case EXPR_ASSIGNMENT:
            expr_free(expr->data.assignment.value);
            break;
        case EXPR_FN_CALL:
            for (size_t i = 0; i < expr->data.fn_call.arg_count; i++) {
                expr_free(expr->data.fn_call.arguments[i]);
            }
            free(expr->data.fn_call.arguments);
            for (size_t i = 0; i < expr->data.fn_call.type_args_count; i++) {
                type_free(&expr->data.fn_call.type_args[i]);
            }
            free(expr->data.fn_call.type_args);
            break;
        case EXPR_STRUCT_INIT:
            for (size_t i = 0; i < expr->data.struct_init.field_count; i++) {
                expr_free(expr->data.struct_init.fields[i].value);
            }
            free(expr->data.struct_init.fields);
            for (size_t i = 0; i < expr->data.struct_init.type_args_count; i++) {
                type_free(&expr->data.struct_init.type_args[i]);
            }
            free(expr->data.struct_init.type_args);
            break;
        case EXPR_FIELD_ACCESS:
            expr_free(expr->data.field_access.object);
            break;
        case EXPR_METHOD_CALL:
            expr_free(expr->data.method_call.receiver);
            for (size_t i = 0; i < expr->data.method_call.arg_count; i++) {
                expr_free(expr->data.method_call.arguments[i]);
            }
            free(expr->data.method_call.arguments);
            break;
        case EXPR_ARRAY_LITERAL:
            for (size_t i = 0; i < expr->data.array_literal.count; i++) {
                expr_free(expr->data.array_literal.elements[i]);
            }
            free(expr->data.array_literal.elements);
            break;
        case EXPR_ARRAY_ACCESS:
            expr_free(expr->data.array_access.array);
            expr_free(expr->data.array_access.index);
            break;
        case EXPR_FIELD_ASSIGNMENT:
            expr_free(expr->data.field_assignment.object);
            expr_free(expr->data.field_assignment.value);
            break;
        case EXPR_ARRAY_ASSIGNMENT:
            expr_free(expr->data.array_assignment.array);
            expr_free(expr->data.array_assignment.index);
            expr_free(expr->data.array_assignment.value);
            break;
        case EXPR_IS_CHECK:
            expr_free(expr->data.is_check.expr);
            type_free(expr->data.is_check.check_type);
            break;
        case EXPR_MATCH:
            expr_free(expr->data.match_expr.expr);
            for (size_t i = 0; i < expr->data.match_expr.arm_count; i++) {
                expr_free(expr->data.match_expr.arms[i].body);
            }
            free(expr->data.match_expr.arms);
            break;
        default:
            break;
    }
    free(expr);
}

// ============= Statement Functions =============

Stmt* stmt_create_const_decl(const char* name, size_t name_len, Type* type_annotation, Expr* value) {
    Stmt* stmt = (Stmt*)malloc(sizeof(Stmt));
    stmt->kind = STMT_CONST_DECL;
    stmt->data.var_decl.name = slice_from_ptr_len(name, name_len);
    stmt->data.var_decl.type_annotation = type_annotation;
    stmt->data.var_decl.value = value;
    return stmt;
}

Stmt* stmt_create_let_decl(const char* name, size_t name_len, Type* type_annotation, Expr* value) {
    Stmt* stmt = (Stmt*)malloc(sizeof(Stmt));
    stmt->kind = STMT_LET_DECL;
    stmt->data.var_decl.name = slice_from_ptr_len(name, name_len);
    stmt->data.var_decl.type_annotation = type_annotation;
    stmt->data.var_decl.value = value;
    return stmt;
}

Stmt* stmt_create_return(Expr* expr) {
    Stmt* stmt = (Stmt*)malloc(sizeof(Stmt));
    stmt->kind = STMT_RETURN;
    stmt->data.return_stmt = expr;
    return stmt;
}

Stmt* stmt_create_expr(Expr* expr) {
    Stmt* stmt = (Stmt*)malloc(sizeof(Stmt));
    stmt->kind = STMT_EXPR;
    stmt->data.expr_stmt = expr;
    return stmt;
}

void stmt_free(Stmt* stmt) {
    if (!stmt) return;
    
    switch (stmt->kind) {
        case STMT_CONST_DECL:
        case STMT_LET_DECL:
            type_free(stmt->data.var_decl.type_annotation);
            expr_free(stmt->data.var_decl.value);
            break;
        case STMT_FN_DECL:
            free(stmt->data.fn_decl.type_params);
            for (size_t i = 0; i < stmt->data.fn_decl.param_count; i++) {
                type_free(stmt->data.fn_decl.parameters[i].typ);
            }
            free(stmt->data.fn_decl.parameters);
            type_free(stmt->data.fn_decl.return_type);
            expr_free(stmt->data.fn_decl.body);
            break;
        case STMT_STRUCT_DECL:
            free(stmt->data.struct_decl.type_params);
            for (size_t i = 0; i < stmt->data.struct_decl.field_count; i++) {
                type_free(stmt->data.struct_decl.fields[i].typ);
            }
            free(stmt->data.struct_decl.fields);
            for (size_t i = 0; i < stmt->data.struct_decl.method_count; i++) {
                for (size_t j = 0; j < stmt->data.struct_decl.methods[i].param_count; j++) {
                    type_free(stmt->data.struct_decl.methods[i].parameters[j].typ);
                }
                free(stmt->data.struct_decl.methods[i].parameters);
                type_free(stmt->data.struct_decl.methods[i].return_type);
                expr_free(stmt->data.struct_decl.methods[i].body);
            }
            free(stmt->data.struct_decl.methods);
            break;
        case STMT_TYPE_ALIAS:
            type_free(stmt->data.type_alias.target_type);
            break;
        case STMT_IMPORT:
            free(stmt->data.import_stmt.imports);
            break;
        case STMT_RETURN:
            expr_free(stmt->data.return_stmt);
            break;
        case STMT_EXPR:
            expr_free(stmt->data.expr_stmt);
            break;
    }
    free(stmt);
}
