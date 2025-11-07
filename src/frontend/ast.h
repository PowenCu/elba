#ifndef ELBA_AST_H
#define ELBA_AST_H

#include "../common.h"

// Forward declarations
typedef struct Type Type;
typedef struct Expr Expr;
typedef struct Stmt Stmt;
typedef struct Value Value;

// ============= Type System =============

typedef enum {
    TYPE_INT,
    TYPE_FLOAT,
    TYPE_STRING,
    TYPE_BOOL,
    TYPE_UNIT,
    TYPE_USER_TYPE,
    TYPE_GENERIC_PARAM,
    TYPE_GENERIC_INSTANCE,
    TYPE_ARRAY,
    TYPE_OPTIONAL,
    TYPE_UNION,
    TYPE_UNKNOWN,
} TypeKind;

typedef struct {
    const char* base_type;
    size_t base_type_len;
    Type* type_args;
    size_t type_args_count;
} GenericInstance;

struct Type {
    TypeKind kind;
    union {
        Slice user_type;        // For user-defined structs
        Slice generic_param;    // Type parameter like T, U
        GenericInstance generic_instance;  // Like Box<int>
        Type* array_elem_type;  // Array element type
        Type* optional_inner;   // Optional inner type
        struct {
            Type* types;
            size_t count;
        } union_type;           // Union type like int | str
    } data;
};

// Type functions
Type* type_create_int(void);
Type* type_create_float(void);
Type* type_create_string(void);
Type* type_create_bool(void);
Type* type_create_unit(void);
Type* type_create_user(const char* name, size_t len);
Type* type_create_generic_param(const char* name, size_t len);
Type* type_create_array(Type* elem_type);
Type* type_create_optional(Type* inner_type);
Type* type_create_union(Type* types, size_t count);
Type* type_create_unknown(void);
bool type_is_numeric(const Type* type);
bool type_equals(const Type* a, const Type* b);
void type_free(Type* type);

// ============= Value System =============

typedef enum {
    VALUE_INT,
    VALUE_FLOAT,
    VALUE_STRING,
    VALUE_BOOL,
    VALUE_UNIT,
    VALUE_NULL,
    VALUE_STRUCT_INSTANCE,
    VALUE_ARRAY,
} ValueKind;

typedef struct {
    Slice type_name;
    // Simple field storage - name:value pairs
    struct {
        Slice* names;
        Value* values;
        size_t count;
    } fields;
} StructInstance;

struct Value {
    ValueKind kind;
    union {
        int64_t int_val;
        double float_val;
        Slice string_val;
        bool bool_val;
        StructInstance struct_instance;
        struct {
            Value* elements;
            size_t count;
        } array;
    } data;
};

// Value functions
Value* value_create_int(int64_t val);
Value* value_create_float(double val);
Value* value_create_string(const char* str, size_t len);
Value* value_create_bool(bool val);
Value* value_create_unit(void);
Value* value_create_null(void);
void value_free(Value* val);

// ============= Expression System =============

typedef enum {
    EXPR_INT_LITERAL,
    EXPR_FLOAT_LITERAL,
    EXPR_STRING_LITERAL,
    EXPR_BOOL_LITERAL,
    EXPR_NULL_LITERAL,
    EXPR_VARIABLE,
    EXPR_BINARY,
    EXPR_UNARY,
    EXPR_BLOCK,
    EXPR_IF,
    EXPR_WHILE,
    EXPR_FOR,
    EXPR_MATCH,
    EXPR_ASSIGNMENT,
    EXPR_FIELD_ASSIGNMENT,
    EXPR_ARRAY_ASSIGNMENT,
    EXPR_FN_CALL,
    EXPR_STRUCT_INIT,
    EXPR_FIELD_ACCESS,
    EXPR_METHOD_CALL,
    EXPR_ARRAY_LITERAL,
    EXPR_ARRAY_ACCESS,
    EXPR_IS_CHECK,
} ExprKind;

typedef enum {
    BINOP_ADD,
    BINOP_SUB,
    BINOP_MUL,
    BINOP_DIV,
    BINOP_MOD,
    BINOP_POW,
    BINOP_EQUAL,
    BINOP_NOT_EQUAL,
    BINOP_LESS,
    BINOP_LESS_EQUAL,
    BINOP_GREATER,
    BINOP_GREATER_EQUAL,
    BINOP_LOGICAL_AND,
    BINOP_LOGICAL_OR,
} BinaryOp;

typedef enum {
    UNOP_LOGICAL_NOT,
    UNOP_NEGATE,
} UnaryOp;

typedef struct {
    Expr* left;
    BinaryOp op;
    Expr* right;
} BinaryExpr;

typedef struct {
    UnaryOp op;
    Expr* operand;
} UnaryExpr;

typedef struct {
    Slice name;
    Expr* value;
} AssignmentExpr;

typedef struct {
    Stmt* statements;
    size_t stmt_count;
    Expr* return_expr;  // NULL if no return expression
} BlockExpr;

typedef struct {
    Expr* condition;
    Expr* then_block;
    Expr* else_block;  // NULL if no else
} IfExpr;

typedef struct {
    Expr* condition;
    Expr* body;
} WhileExpr;

typedef struct {
    Slice iterator;
    Expr* iterable;
    Expr* body;
    bool is_range;
} ForExpr;

typedef struct {
    Slice name;
    Type* type_args;
    size_t type_args_count;
    Expr** arguments;
    size_t arg_count;
} FnCallExpr;

typedef struct {
    Slice name;
    Expr* value;
} FieldInit;

typedef struct {
    Slice type_name;
    Type* type_args;
    size_t type_args_count;
    FieldInit* fields;
    size_t field_count;
} StructInitExpr;

typedef struct {
    Expr* object;
    Slice field_name;
} FieldAccessExpr;

typedef struct {
    Expr* receiver;
    Slice method_name;
    Expr** arguments;
    size_t arg_count;
} MethodCallExpr;

typedef struct {
    Expr** elements;
    size_t count;
} ArrayLiteralExpr;

typedef struct {
    Expr* array;
    Expr* index;
} ArrayAccessExpr;

typedef struct {
    Expr* object;
    Slice field_name;
    Expr* value;
} FieldAssignmentExpr;

typedef struct {
    Expr* array;
    Expr* index;
    Expr* value;
} ArrayAssignmentExpr;

typedef struct {
    Expr* expr;
    Type* check_type;
    bool is_not;
} IsCheckExpr;

typedef enum {
    PATTERN_LITERAL,
    PATTERN_VARIABLE,
    PATTERN_WILDCARD,
    PATTERN_RANGE,
} PatternKind;

typedef struct {
    int64_t start;
    int64_t end;
    bool inclusive;
} RangePattern;

typedef struct {
    PatternKind kind;
    union {
        Value literal;
        Slice variable;
        RangePattern range;
    } data;
} Pattern;

typedef struct {
    Pattern pattern;
    Expr* body;
} MatchArm;

typedef struct {
    Expr* expr;
    MatchArm* arms;
    size_t arm_count;
} MatchExpr;

struct Expr {
    ExprKind kind;
    union {
        int64_t int_literal;
        double float_literal;
        Slice string_literal;
        bool bool_literal;
        Slice variable;
        BinaryExpr binary;
        UnaryExpr unary;
        BlockExpr block;
        IfExpr if_expr;
        WhileExpr while_expr;
        ForExpr for_expr;
        MatchExpr match_expr;
        AssignmentExpr assignment;
        FieldAssignmentExpr field_assignment;
        ArrayAssignmentExpr array_assignment;
        FnCallExpr fn_call;
        StructInitExpr struct_init;
        FieldAccessExpr field_access;
        MethodCallExpr method_call;
        ArrayLiteralExpr array_literal;
        ArrayAccessExpr array_access;
        IsCheckExpr is_check;
    } data;
};

// Expression functions
Expr* expr_create_int_literal(int64_t val);
Expr* expr_create_float_literal(double val);
Expr* expr_create_string_literal(const char* str, size_t len);
Expr* expr_create_bool_literal(bool val);
Expr* expr_create_null_literal(void);
Expr* expr_create_variable(const char* name, size_t len);
Expr* expr_create_binary(Expr* left, BinaryOp op, Expr* right);
Expr* expr_create_unary(UnaryOp op, Expr* operand);
void expr_free(Expr* expr);

// ============= Statement System =============

typedef enum {
    STMT_CONST_DECL,
    STMT_LET_DECL,
    STMT_FN_DECL,
    STMT_STRUCT_DECL,
    STMT_TYPE_ALIAS,
    STMT_IMPORT,
    STMT_RETURN,
    STMT_EXPR,
} StmtKind;

typedef struct {
    Slice name;
    Type* type_annotation;  // NULL if none
    Expr* value;
} VarDeclStmt;

typedef struct {
    Slice name;
    Type* typ;
} Parameter;

typedef struct {
    Slice name;
    Slice* type_params;
    size_t type_param_count;
    Parameter* parameters;
    size_t param_count;
    Type* return_type;
    Expr* body;
} FnDeclStmt;

typedef struct {
    Slice name;
    Type* typ;
} FieldDecl;

typedef struct {
    Slice name;
    Parameter* parameters;
    size_t param_count;
    Type* return_type;
    Expr* body;
} MethodDecl;

typedef struct {
    Slice name;
    Slice* type_params;
    size_t type_param_count;
    FieldDecl* fields;
    size_t field_count;
    MethodDecl* methods;
    size_t method_count;
} StructDeclStmt;

typedef struct {
    Slice name;
    Type* target_type;
} TypeAliasStmt;

typedef struct {
    Slice module_path;
    Slice* imports;  // NULL means import all
    size_t import_count;
} ImportStmt;

struct Stmt {
    StmtKind kind;
    union {
        VarDeclStmt var_decl;
        FnDeclStmt fn_decl;
        StructDeclStmt struct_decl;
        TypeAliasStmt type_alias;
        ImportStmt import_stmt;
        Expr* return_stmt;
        Expr* expr_stmt;
    } data;
};

// Statement functions
Stmt* stmt_create_const_decl(const char* name, size_t name_len, Type* type_annotation, Expr* value);
Stmt* stmt_create_let_decl(const char* name, size_t name_len, Type* type_annotation, Expr* value);
Stmt* stmt_create_return(Expr* expr);
Stmt* stmt_create_expr(Expr* expr);
void stmt_free(Stmt* stmt);

#endif // ELBA_AST_H
