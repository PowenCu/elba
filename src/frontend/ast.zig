const std = @import("std");

pub const Type = union(enum) {
    int,
    float,
    string,
    bool,
    unit, // For expressions that don't return a value
    user_type: []const u8, // For user-defined structs, stores the struct name
    generic_param: []const u8, // Type parameter like T, U, etc.
    generic_instance: GenericInstance, // Instantiated generic type like Box<int>
    array: *Type, // Array type like [int], [str], etc.
    optional: *Type, // Optional type like int?, str?, etc.
    union_type: []Type, // Union type like int | str
    unknown,

    pub const GenericInstance = struct {
        base_type: []const u8, // Base type name (e.g., "Box", "List")
        type_args: []Type, // Type arguments (e.g., [int] for Box<int>)
    };

    pub fn isNumeric(self: Type) bool {
        return self == .int or self == .float;
    }

    pub fn eql(self: Type, other: Type) bool {
        const self_tag = @as(std.meta.Tag(Type), self);
        const other_tag = @as(std.meta.Tag(Type), other);

        if (self_tag != other_tag) {
            return false;
        }

        switch (self) {
            .user_type => |name| {
                return std.mem.eql(u8, name, other.user_type);
            },
            .generic_param => |name| {
                return std.mem.eql(u8, name, other.generic_param);
            },
            .generic_instance => |inst| {
                const other_inst = other.generic_instance;
                if (!std.mem.eql(u8, inst.base_type, other_inst.base_type)) {
                    return false;
                }
                if (inst.type_args.len != other_inst.type_args.len) {
                    return false;
                }
                for (inst.type_args, other_inst.type_args) |arg1, arg2| {
                    if (!arg1.eql(arg2)) {
                        return false;
                    }
                }
                return true;
            },
            .array => |elem_type| {
                return elem_type.eql(other.array.*);
            },
            .optional => |inner_type| {
                return inner_type.eql(other.optional.*);
            },
            .union_type => |types| {
                const other_types = other.union_type;
                if (types.len != other_types.len) {
                    return false;
                }
                for (types, other_types) |t1, t2| {
                    if (!t1.eql(t2)) {
                        return false;
                    }
                }
                return true;
            },
            else => return true,
        }
    }
};

pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
    unit: void,
    null_value: void,
    struct_instance: StructInstance,
    array: ArrayValue,

    pub const ArrayValue = struct {
        elements: []Value,
        element_type: ?Type,
    };

    pub const StructInstance = struct {
        type_name: []const u8,
        type_args: []const Type = &.{},
        fields: std.StringHashMap(Value),
    };
};

pub const Expr = union(enum) {
    int_literal: i64,
    float_literal: f64,
    string_literal: []const u8,
    bool_literal: bool,
    null_literal: void,
    variable: []const u8,
    binary: Binary,
    unary: Unary,
    block: Block,
    if_expr: If,
    while_expr: While,
    for_expr: For,
    match_expr: Match,
    assignment: Assignment,
    field_assignment: FieldAssignment,
    array_assignment: ArrayAssignment,
    fn_call: FnCall,
    struct_init: StructInit,
    field_access: FieldAccess,
    method_call: MethodCall,
    array_literal: ArrayLiteral,
    array_access: ArrayAccess,
    is_check: IsCheck,
    optional_unwrap: *Expr,
    optional_coalesce: OptionalCoalesce,

    pub const OptionalCoalesce = struct {
        optional: *Expr,
        fallback: *Expr,
    };

    pub const For = struct {
        iterator: []const u8, // Variable name for iterator
        iterable: *Expr, // Expression to iterate over (array or range)
        range_end: ?*Expr = null, // End expression for range loops (start..end)
        range_inclusive: bool = false, // true for start..=end, false for start..end
        body: *Expr, // Loop body
        is_range: bool, // true if iterating over range (start..end)
    };

    pub const Match = struct {
        expr: *Expr, // Expression to match against
        arms: []MatchArm, // Match arms
    };

    pub const MatchArm = struct {
        pattern: Pattern, // Pattern to match
        body: *Expr, // Expression to evaluate if pattern matches
    };

    pub const Pattern = union(enum) {
        literal: Value, // Literal value (int, string, bool, etc.)
        variable: []const u8, // Variable binding (catches anything)
        wildcard: void, // _ pattern (catches anything without binding)
        range: Range, // Range pattern like 1..10
    };

    pub const Range = struct {
        start: i64,
        end: i64,
        inclusive: bool, // true for ..=, false for ..
    };

    pub const FieldAssignment = struct {
        object: *Expr, // Object to assign to
        field_name: []const u8, // Field name
        value: *Expr, // Value to assign
    };

    pub const ArrayAssignment = struct {
        array: *Expr, // Array to assign to
        index: *Expr, // Index expression
        value: *Expr, // Value to assign
    };

    pub const IsCheck = struct {
        expr: *Expr,
        check_type: Type,
        is_not: bool, // true for "is not", false for "is"
        // Filled by the typechecker when the expression has a concrete,
        // non-tagged type. The pointer permits annotation through a const AST.
        static_result: *?bool,
        resolved_type: *?Type,
        resolved_source_type: *?Type,
    };

    pub const ArrayLiteral = struct {
        elements: []*Expr,
        resolved_element_type: *?Type,
        resolved_array_type: *?Type,
    };

    pub const ArrayAccess = struct {
        array: *Expr,
        index: *Expr,
    };

    pub const Binary = struct {
        left: *Expr,
        op: BinaryOp,
        right: *Expr,
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    pub const Assignment = struct {
        name: []const u8,
        value: *Expr,
    };

    pub const Block = struct {
        statements: []Stmt,
        return_expr: ?*Expr,
    };

    pub const If = struct {
        condition: *Expr,
        then_block: *Expr,
        else_block: ?*Expr,
    };

    pub const While = struct {
        condition: *Expr,
        body: *Expr,
    };

    pub const FnCall = struct {
        name: []const u8,
        type_args: []Type, // Type arguments for generic function calls
        arguments: []*Expr,
    };

    pub const StructInit = struct {
        type_name: []const u8,
        type_args: []Type, // Type arguments for generic struct instantiation
        fields: []FieldInit,
    };

    pub const FieldInit = struct {
        name: []const u8,
        value: *Expr,
    };

    pub const FieldAccess = struct {
        object: *Expr,
        field_name: []const u8,
    };

    pub const MethodCall = struct {
        receiver: *Expr, // The object on which the method is called
        method_name: []const u8,
        arguments: []*Expr,
    };

    pub const BinaryOp = enum {
        // Arithmetic
        add,
        sub,
        mul,
        div,
        mod,
        pow,
        // Comparison
        equal,
        not_equal,
        less,
        less_equal,
        greater,
        greater_equal,
        // Logical
        logical_and,
        logical_or,
    };

    pub const UnaryOp = enum {
        logical_not,
        negate,
    };
};

pub const Stmt = union(enum) {
    const_decl: VarDecl,
    let_decl: VarDecl,
    fn_decl: FnDecl,
    struct_decl: StructDecl,
    type_alias: TypeAlias,
    import_stmt: ImportStmt,
    return_stmt: ?*Expr,
    break_stmt: void,
    continue_stmt: void,
    expr_stmt: *Expr,

    pub const ImportStmt = struct {
        module_path: []const u8,
        imports: ?[][]const u8, // null means import all, otherwise selective imports
    };

    pub const TypeAlias = struct {
        name: []const u8,
        target_type: Type,
    };

    pub const VarDecl = struct {
        name: []const u8,
        type_annotation: ?Type,
        value: *Expr,
    };

    pub const FnDecl = struct {
        name: []const u8,
        type_params: [][]const u8, // Generic type parameters like [T, U]
        parameters: []Parameter,
        return_type: Type,
        body: *Expr,
    };

    pub const Parameter = struct {
        name: []const u8,
        typ: Type,
    };

    pub const StructDecl = struct {
        name: []const u8,
        type_params: [][]const u8, // Generic type parameters
        fields: []FieldDecl,
        methods: []MethodDecl,
    };

    pub const FieldDecl = struct {
        name: []const u8,
        typ: Type,
    };

    pub const MethodDecl = struct {
        name: []const u8,
        parameters: []Parameter, // First parameter should be 'self'
        return_type: Type,
        body: *Expr,
    };
};
