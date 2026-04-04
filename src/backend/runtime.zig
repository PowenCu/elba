const std = @import("std");

/// Elba Runtime Library
/// Provides core runtime support for all backends (IR interpreter, C codegen, LLVM)
/// Includes memory management, type information, and runtime utilities.

// ============================================
// Type Tags for Runtime Type Information (RTTI)
// ============================================

/// Runtime type identifier for dynamic type checking
pub const TypeTag = enum(u8) {
    null_type = 0,
    int = 1,
    float = 2,
    bool = 3,
    string = 4,
    array = 5,
    struct_type = 6,
    function = 7,
    optional = 8,
    union_type = 9,

    pub fn name(self: TypeTag) []const u8 {
        return switch (self) {
            .null_type => "null",
            .int => "int",
            .float => "float",
            .bool => "bool",
            .string => "str",
            .array => "array",
            .struct_type => "struct",
            .function => "function",
            .optional => "optional",
            .union_type => "union",
        };
    }
};

// ============================================
// Runtime Values
// ============================================

/// A boxed runtime value with type tag (for dynamic typing scenarios)
pub const BoxedValue = struct {
    tag: TypeTag,
    data: ValueData,

    pub const ValueData = union {
        null_val: void,
        int_val: i64,
        float_val: f64,
        bool_val: bool,
        string_val: StringRef,
        array_val: *ArrayObj,
        struct_val: *StructObj,
        function_val: *FunctionObj,
    };

    pub fn initNull() BoxedValue {
        return .{ .tag = .null_type, .data = .{ .null_val = {} } };
    }

    pub fn initInt(val: i64) BoxedValue {
        return .{ .tag = .int, .data = .{ .int_val = val } };
    }

    pub fn initFloat(val: f64) BoxedValue {
        return .{ .tag = .float, .data = .{ .float_val = val } };
    }

    pub fn initBool(val: bool) BoxedValue {
        return .{ .tag = .bool, .data = .{ .bool_val = val } };
    }

    pub fn initString(val: StringRef) BoxedValue {
        return .{ .tag = .string, .data = .{ .string_val = val } };
    }

    pub fn initArray(val: *ArrayObj) BoxedValue {
        return .{ .tag = .array, .data = .{ .array_val = val } };
    }

    pub fn initStruct(val: *StructObj) BoxedValue {
        return .{ .tag = .struct_type, .data = .{ .struct_val = val } };
    }

    /// Check if value is truthy (for conditionals)
    pub fn isTruthy(self: BoxedValue) bool {
        return switch (self.tag) {
            .null_type => false,
            .bool => self.data.bool_val,
            .int => self.data.int_val != 0,
            .float => self.data.float_val != 0.0,
            .string => self.data.string_val.len > 0,
            .array => self.data.array_val.len > 0,
            else => true,
        };
    }

    /// Format value for printing
    pub fn format(self: BoxedValue, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.tag) {
            .null_type => try writer.writeAll("null"),
            .int => try writer.print("{d}", .{self.data.int_val}),
            .float => try writer.print("{d}", .{self.data.float_val}),
            .bool => try writer.print("{}", .{self.data.bool_val}),
            .string => try writer.print("{s}", .{self.data.string_val.ptr[0..self.data.string_val.len]}),
            .array => try writer.print("[array of {d} elements]", .{self.data.array_val.len}),
            .struct_type => try writer.print("[struct {s}]", .{self.data.struct_val.type_name}),
            .function => try writer.writeAll("[function]"),
            .optional => try writer.writeAll("[optional]"),
            .union_type => try writer.writeAll("[union]"),
        }
    }
};

// ============================================
// String Reference (for interned/managed strings)
// ============================================

/// A reference to a string (may be interned or heap-allocated)
pub const StringRef = struct {
    ptr: [*]const u8,
    len: usize,
    flags: Flags = .{},

    pub const Flags = packed struct {
        interned: bool = false, // String is in intern pool (don't free)
        heap: bool = false, // String is heap-allocated (must free)
        _padding: u6 = 0,
    };

    pub fn fromSlice(s: []const u8) StringRef {
        return .{ .ptr = s.ptr, .len = s.len };
    }

    pub fn toSlice(self: StringRef) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn eql(self: StringRef, other: StringRef) bool {
        if (self.len != other.len) return false;
        return std.mem.eql(u8, self.toSlice(), other.toSlice());
    }
};

// ============================================
// Array Object
// ============================================

/// Runtime array object with type info and capacity
pub const ArrayObj = struct {
    element_type: TypeTag,
    len: usize,
    capacity: usize,
    data: [*]BoxedValue,

    /// Create a new array with given capacity
    pub fn create(allocator: std.mem.Allocator, element_type: TypeTag, capacity: usize) !*ArrayObj {
        const arr = try allocator.create(ArrayObj);
        const data = try allocator.alloc(BoxedValue, capacity);

        // Initialize all elements to null
        for (data) |*elem| {
            elem.* = BoxedValue.initNull();
        }

        arr.* = .{
            .element_type = element_type,
            .len = 0,
            .capacity = capacity,
            .data = data.ptr,
        };
        return arr;
    }

    /// Create array from slice of values
    pub fn fromSlice(allocator: std.mem.Allocator, element_type: TypeTag, values: []const BoxedValue) !*ArrayObj {
        const arr = try create(allocator, element_type, values.len);
        for (values, 0..) |val, i| {
            arr.data[i] = val;
        }
        arr.len = values.len;
        return arr;
    }

    /// Get element at index (bounds checked)
    pub fn get(self: *ArrayObj, index: usize) !BoxedValue {
        if (index >= self.len) {
            return error.IndexOutOfBounds;
        }
        return self.data[index];
    }

    /// Set element at index (bounds checked)
    pub fn set(self: *ArrayObj, index: usize, value: BoxedValue) !void {
        if (index >= self.len) {
            return error.IndexOutOfBounds;
        }
        self.data[index] = value;
    }

    /// Push element (grow if needed)
    pub fn push(self: *ArrayObj, allocator: std.mem.Allocator, value: BoxedValue) !void {
        if (self.len >= self.capacity) {
            try self.grow(allocator);
        }
        self.data[self.len] = value;
        self.len += 1;
    }

    /// Pop last element
    pub fn pop(self: *ArrayObj) !BoxedValue {
        if (self.len == 0) {
            return error.IndexOutOfBounds;
        }
        self.len -= 1;
        return self.data[self.len];
    }

    /// Grow array capacity (double it)
    fn grow(self: *ArrayObj, allocator: std.mem.Allocator) !void {
        const new_capacity = if (self.capacity == 0) 8 else self.capacity * 2;
        const new_data = try allocator.alloc(BoxedValue, new_capacity);

        // Copy existing data
        for (0..self.len) |i| {
            new_data[i] = self.data[i];
        }

        // Initialize rest to null
        for (self.len..new_capacity) |i| {
            new_data[i] = BoxedValue.initNull();
        }

        // Free old data if it was allocated
        if (self.capacity > 0) {
            allocator.free(self.data[0..self.capacity]);
        }

        self.data = new_data.ptr;
        self.capacity = new_capacity;
    }

    /// Free array resources
    pub fn destroy(self: *ArrayObj, allocator: std.mem.Allocator) void {
        if (self.capacity > 0) {
            allocator.free(self.data[0..self.capacity]);
        }
        allocator.destroy(self);
    }
};

// ============================================
// Struct Object
// ============================================

/// Runtime struct object with named fields
pub const StructObj = struct {
    type_name: []const u8,
    field_count: usize,
    field_names: [*][]const u8,
    field_values: [*]BoxedValue,

    /// Create a new struct instance
    pub fn create(allocator: std.mem.Allocator, type_name: []const u8, field_names: []const []const u8) !*StructObj {
        const obj = try allocator.create(StructObj);
        const names = try allocator.alloc([]const u8, field_names.len);
        const values = try allocator.alloc(BoxedValue, field_names.len);

        for (field_names, 0..) |name, i| {
            names[i] = name;
            values[i] = BoxedValue.initNull();
        }

        obj.* = .{
            .type_name = type_name,
            .field_count = field_names.len,
            .field_names = names.ptr,
            .field_values = values.ptr,
        };
        return obj;
    }

    /// Get field by name
    pub fn getField(self: *StructObj, name: []const u8) !BoxedValue {
        for (0..self.field_count) |i| {
            if (std.mem.eql(u8, self.field_names[i], name)) {
                return self.field_values[i];
            }
        }
        return error.FieldNotFound;
    }

    /// Set field by name
    pub fn setField(self: *StructObj, name: []const u8, value: BoxedValue) !void {
        for (0..self.field_count) |i| {
            if (std.mem.eql(u8, self.field_names[i], name)) {
                self.field_values[i] = value;
                return;
            }
        }
        return error.FieldNotFound;
    }

    /// Get field by index (faster for IR)
    pub fn getFieldByIndex(self: *StructObj, index: usize) !BoxedValue {
        if (index >= self.field_count) {
            return error.FieldNotFound;
        }
        return self.field_values[index];
    }

    /// Set field by index (faster for IR)
    pub fn setFieldByIndex(self: *StructObj, index: usize, value: BoxedValue) !void {
        if (index >= self.field_count) {
            return error.FieldNotFound;
        }
        self.field_values[index] = value;
    }

    /// Free struct resources
    pub fn destroy(self: *StructObj, allocator: std.mem.Allocator) void {
        allocator.free(self.field_names[0..self.field_count]);
        allocator.free(self.field_values[0..self.field_count]);
        allocator.destroy(self);
    }
};

// ============================================
// Function Object (for first-class functions)
// ============================================

/// Runtime function reference
pub const FunctionObj = struct {
    name: []const u8,
    param_count: usize,
    param_names: [][]const u8,
    // For IR: instruction pointer
    ip: usize,
    // For closures: captured environment
    captures: ?*StructObj,

    pub fn create(allocator: std.mem.Allocator, name: []const u8, param_names: []const []const u8, ip: usize) !*FunctionObj {
        const obj = try allocator.create(FunctionObj);
        const names = try allocator.dupe([]const u8, param_names);
        obj.* = .{
            .name = name,
            .param_count = param_names.len,
            .param_names = names,
            .ip = ip,
            .captures = null,
        };
        return obj;
    }
};

// ============================================
// String Interning Pool
// ============================================

/// String intern pool for efficient string storage and comparison
pub const StringPool = struct {
    allocator: std.mem.Allocator,
    strings: std.StringHashMap(StringRef),
    allocated: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{
            .allocator = allocator,
            .strings = std.StringHashMap(StringRef).init(allocator),
            .allocated = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *StringPool) void {
        // Free all allocated strings
        for (self.allocated.items) |s| {
            self.allocator.free(s);
        }
        self.allocated.deinit(self.allocator);
        self.strings.deinit();
    }

    /// Intern a string (returns existing ref if already interned)
    pub fn intern(self: *StringPool, s: []const u8) !StringRef {
        if (self.strings.get(s)) |ref| {
            return ref;
        }

        // Allocate new string
        const owned = try self.allocator.dupe(u8, s);
        try self.allocated.append(self.allocator, owned);

        const ref = StringRef{
            .ptr = owned.ptr,
            .len = owned.len,
            .flags = .{ .interned = true },
        };
        try self.strings.put(owned, ref);
        return ref;
    }
};

// ============================================
// Memory Management
// ============================================

/// Simple allocation tracker for cleanup
pub const AllocationTracker = struct {
    allocator: std.mem.Allocator,
    arrays: std.ArrayList(*ArrayObj),
    structs: std.ArrayList(*StructObj),
    functions: std.ArrayList(*FunctionObj),
    strings: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) AllocationTracker {
        return .{
            .allocator = allocator,
            .arrays = std.ArrayList(*ArrayObj).initCapacity(allocator, 0) catch unreachable,
            .structs = std.ArrayList(*StructObj).initCapacity(allocator, 0) catch unreachable,
            .functions = std.ArrayList(*FunctionObj).initCapacity(allocator, 0) catch unreachable,
            .strings = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *AllocationTracker) void {
        // Free all tracked allocations
        for (self.arrays.items) |arr| {
            arr.destroy(self.allocator);
        }
        self.arrays.deinit(self.allocator);

        for (self.structs.items) |obj| {
            obj.destroy(self.allocator);
        }
        self.structs.deinit(self.allocator);

        for (self.functions.items) |func| {
            self.allocator.free(func.param_names);
            self.allocator.destroy(func);
        }
        self.functions.deinit(self.allocator);

        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
    }

    pub fn trackArray(self: *AllocationTracker, arr: *ArrayObj) !void {
        try self.arrays.append(self.allocator, arr);
    }

    pub fn trackStruct(self: *AllocationTracker, obj: *StructObj) !void {
        try self.structs.append(self.allocator, obj);
    }

    pub fn trackFunction(self: *AllocationTracker, func: *FunctionObj) !void {
        try self.functions.append(self.allocator, func);
    }

    pub fn trackString(self: *AllocationTracker, s: []const u8) !void {
        try self.strings.append(self.allocator, s);
    }
};

// ============================================
// Runtime Context
// ============================================

/// Main runtime context holding all runtime state
pub const RuntimeContext = struct {
    allocator: std.mem.Allocator,
    string_pool: StringPool,
    tracker: AllocationTracker,
    // Global variables
    globals: std.StringHashMap(BoxedValue),
    // Call stack depth (for recursion limit)
    call_depth: usize,
    max_call_depth: usize,

    pub const DEFAULT_MAX_CALL_DEPTH = 1000;

    pub fn init(allocator: std.mem.Allocator) RuntimeContext {
        return .{
            .allocator = allocator,
            .string_pool = StringPool.init(allocator),
            .tracker = AllocationTracker.init(allocator),
            .globals = std.StringHashMap(BoxedValue).init(allocator),
            .call_depth = 0,
            .max_call_depth = DEFAULT_MAX_CALL_DEPTH,
        };
    }

    pub fn deinit(self: *RuntimeContext) void {
        self.string_pool.deinit();
        self.tracker.deinit();
        self.globals.deinit();
    }

    /// Create an interned string
    pub fn internString(self: *RuntimeContext, s: []const u8) !StringRef {
        return self.string_pool.intern(s);
    }

    /// Create a heap string (tracked for cleanup)
    pub fn allocString(self: *RuntimeContext, s: []const u8) !StringRef {
        const owned = try self.allocator.dupe(u8, s);
        try self.tracker.trackString(owned);
        return StringRef{
            .ptr = owned.ptr,
            .len = owned.len,
            .flags = .{ .heap = true },
        };
    }

    /// Concatenate two strings
    pub fn concatStrings(self: *RuntimeContext, a: StringRef, b: StringRef) !StringRef {
        const result = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ a.toSlice(), b.toSlice() });
        try self.tracker.trackString(result);
        return StringRef{
            .ptr = result.ptr,
            .len = result.len,
            .flags = .{ .heap = true },
        };
    }

    /// Create a new array
    pub fn createArray(self: *RuntimeContext, element_type: TypeTag, capacity: usize) !*ArrayObj {
        const arr = try ArrayObj.create(self.allocator, element_type, capacity);
        try self.tracker.trackArray(arr);
        return arr;
    }

    /// Create a new struct
    pub fn createStruct(self: *RuntimeContext, type_name: []const u8, field_names: []const []const u8) !*StructObj {
        const obj = try StructObj.create(self.allocator, type_name, field_names);
        try self.tracker.trackStruct(obj);
        return obj;
    }

    /// Enter a function call (check stack depth)
    pub fn enterCall(self: *RuntimeContext) !void {
        if (self.call_depth >= self.max_call_depth) {
            return error.StackOverflow;
        }
        self.call_depth += 1;
    }

    /// Leave a function call
    pub fn leaveCall(self: *RuntimeContext) void {
        if (self.call_depth > 0) {
            self.call_depth -= 1;
        }
    }
};

// ============================================
// Builtin Functions
// ============================================

/// Standard builtin function implementations
pub const Builtins = struct {
    fn debugPrintValue(value: BoxedValue) void {
        switch (value.tag) {
            .null_type => std.debug.print("null", .{}),
            .int => std.debug.print("{d}", .{value.data.int_val}),
            .float => std.debug.print("{d}", .{value.data.float_val}),
            .bool => std.debug.print("{}", .{value.data.bool_val}),
            .string => std.debug.print("{s}", .{value.data.string_val.toSlice()}),
            .array => std.debug.print("[array of {d} elements]", .{value.data.array_val.len}),
            .struct_type => std.debug.print("[struct {s}]", .{value.data.struct_val.type_name}),
            .function => std.debug.print("[function]", .{}),
            .optional => std.debug.print("[optional]", .{}),
            .union_type => std.debug.print("[union]", .{}),
        }
    }

    /// Dispatch a builtin by language-level name.
    pub fn call(ctx: *RuntimeContext, name: []const u8, args: []const BoxedValue) !BoxedValue {
        if (std.mem.eql(u8, name, "print")) return print(ctx, args);
        if (std.mem.eql(u8, name, "println")) return println(ctx, args);
        if (std.mem.eql(u8, name, "str_len")) return strLen(ctx, args);
        if (std.mem.eql(u8, name, "str_concat")) return strConcat(ctx, args);
        if (std.mem.eql(u8, name, "str_substring")) return strSubstring(ctx, args);
        if (std.mem.eql(u8, name, "str_split")) return strSplit(ctx, args);
        if (std.mem.eql(u8, name, "str_trim")) return strTrim(ctx, args);
        if (std.mem.eql(u8, name, "str_contains")) return strContains(ctx, args);
        if (std.mem.eql(u8, name, "str_to_int")) return strToInt(ctx, args);
        if (std.mem.eql(u8, name, "str_to_float")) return strToFloat(ctx, args);
        if (std.mem.eql(u8, name, "abs")) return abs(ctx, args);
        if (std.mem.eql(u8, name, "min")) return min(ctx, args);
        if (std.mem.eql(u8, name, "max")) return max(ctx, args);
        if (std.mem.eql(u8, name, "sqrt")) return sqrt(ctx, args);
        if (std.mem.eql(u8, name, "floor")) return floor(ctx, args);
        if (std.mem.eql(u8, name, "ceil")) return ceil(ctx, args);
        if (std.mem.eql(u8, name, "int_to_str")) return intToStr(ctx, args);
        if (std.mem.eql(u8, name, "float_to_str")) return floatToStr(ctx, args);
        if (std.mem.eql(u8, name, "bool_to_str")) return boolToStr(ctx, args);
        if (std.mem.eql(u8, name, "int_to_float")) return intToFloat(ctx, args);
        if (std.mem.eql(u8, name, "float_to_int")) return floatToInt(ctx, args);
        if (std.mem.eql(u8, name, "array_len")) return arrayLen(ctx, args);
        if (std.mem.eql(u8, name, "array_push")) return arrayPush(ctx, args);
        if (std.mem.eql(u8, name, "array_pop")) return arrayPop(ctx, args);
        if (std.mem.eql(u8, name, "array_slice")) return arraySlice(ctx, args);
        if (std.mem.eql(u8, name, "type_of") or std.mem.eql(u8, name, "typeof")) return typeOf(ctx, args);
        return error.UndefinedFunction;
    }

    /// Print value to stdout (no newline)
    pub fn print(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        for (args) |arg| {
            debugPrintValue(arg);
        }
        return BoxedValue.initNull();
    }

    /// Print value to stdout with newline
    pub fn println(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        for (args) |arg| {
            debugPrintValue(arg);
        }
        std.debug.print("\n", .{});
        return BoxedValue.initNull();
    }

    /// Convert int to string
    pub fn intToStr(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        if (args.len != 1 or args[0].tag != .int) {
            return error.InvalidArguments;
        }
        const str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{args[0].data.int_val});
        try ctx.tracker.trackString(str);
        return BoxedValue.initString(StringRef{
            .ptr = str.ptr,
            .len = str.len,
            .flags = .{ .heap = true },
        });
    }

    /// Convert float to string
    pub fn floatToStr(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        if (args.len != 1 or args[0].tag != .float) {
            return error.InvalidArguments;
        }
        const str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{args[0].data.float_val});
        try ctx.tracker.trackString(str);
        return BoxedValue.initString(StringRef{
            .ptr = str.ptr,
            .len = str.len,
            .flags = .{ .heap = true },
        });
    }

    /// Get string length
    pub fn strLen(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .string) {
            return error.InvalidArguments;
        }
        return BoxedValue.initInt(@intCast(args[0].data.string_val.len));
    }

    /// Concatenate strings
    pub fn strConcat(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        if (args.len != 2 or args[0].tag != .string or args[1].tag != .string) {
            return error.InvalidArguments;
        }
        const result = try ctx.concatStrings(args[0].data.string_val, args[1].data.string_val);
        return BoxedValue.initString(result);
    }

    /// Get substring with half-open range [start, end)
    pub fn strSubstring(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        if (args.len != 3 or args[0].tag != .string or args[1].tag != .int or args[2].tag != .int) {
            return error.InvalidArguments;
        }

        const start_i = args[1].data.int_val;
        const end_i = args[2].data.int_val;
        if (start_i < 0 or end_i < 0) return error.IndexOutOfBounds;

        const source = args[0].data.string_val.toSlice();
        const start: usize = @intCast(start_i);
        const end: usize = @intCast(end_i);
        if (start > source.len or end > source.len or start > end) {
            return error.IndexOutOfBounds;
        }

        const result = try ctx.allocString(source[start..end]);
        return BoxedValue.initString(result);
    }

    /// Split string on a non-empty delimiter and return []str
    pub fn strSplit(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        if (args.len != 2 or args[0].tag != .string or args[1].tag != .string) {
            return error.InvalidArguments;
        }

        const source = args[0].data.string_val.toSlice();
        const delimiter = args[1].data.string_val.toSlice();
        if (delimiter.len == 0) return error.InvalidArguments;

        var part_count: usize = 0;
        var count_it = std.mem.splitSequence(u8, source, delimiter);
        while (count_it.next()) |_| {
            part_count += 1;
        }

        const arr = try ctx.createArray(.string, part_count);
        var it = std.mem.splitSequence(u8, source, delimiter);
        while (it.next()) |part| {
            const owned = try ctx.allocString(part);
            try arr.push(ctx.allocator, BoxedValue.initString(owned));
        }
        return BoxedValue.initArray(arr);
    }

    /// Trim ASCII whitespace from both ends of a string
    pub fn strTrim(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        if (args.len != 1 or args[0].tag != .string) {
            return error.InvalidArguments;
        }

        const trimmed = std.mem.trim(u8, args[0].data.string_val.toSlice(), &std.ascii.whitespace);
        const owned = try ctx.allocString(trimmed);
        return BoxedValue.initString(owned);
    }

    /// Check whether string contains substring
    pub fn strContains(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 2 or args[0].tag != .string or args[1].tag != .string) {
            return error.InvalidArguments;
        }

        const contains = std.mem.indexOf(u8, args[0].data.string_val.toSlice(), args[1].data.string_val.toSlice()) != null;
        return BoxedValue.initBool(contains);
    }

    /// Parse string as base-10 integer
    pub fn strToInt(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .string) {
            return error.InvalidArguments;
        }

        const parsed = std.fmt.parseInt(i64, args[0].data.string_val.toSlice(), 10) catch {
            return error.InvalidArguments;
        };
        return BoxedValue.initInt(parsed);
    }

    /// Parse string as floating-point value
    pub fn strToFloat(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .string) {
            return error.InvalidArguments;
        }

        const parsed = std.fmt.parseFloat(f64, args[0].data.string_val.toSlice()) catch {
            return error.InvalidArguments;
        };
        return BoxedValue.initFloat(parsed);
    }

    /// Get array length
    pub fn arrayLen(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .array) {
            return error.InvalidArguments;
        }
        return BoxedValue.initInt(@intCast(args[0].data.array_val.len));
    }

    /// Push to array
    pub fn arrayPush(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        if (args.len != 2 or args[0].tag != .array) {
            return error.InvalidArguments;
        }
        try args[0].data.array_val.push(ctx.allocator, args[1]);
        return BoxedValue.initNull();
    }

    /// Pop from array
    pub fn arrayPop(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .array) {
            return error.InvalidArguments;
        }
        return args[0].data.array_val.pop();
    }

    /// Return a copy of array[start..end]
    pub fn arraySlice(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        if (args.len != 3 or args[0].tag != .array or args[1].tag != .int or args[2].tag != .int) {
            return error.InvalidArguments;
        }

        const start_i = args[1].data.int_val;
        const end_i = args[2].data.int_val;
        if (start_i < 0 or end_i < 0) return error.IndexOutOfBounds;

        const source = args[0].data.array_val;
        const start: usize = @intCast(start_i);
        const end: usize = @intCast(end_i);

        if (start > source.len or end > source.len or start > end) {
            return error.IndexOutOfBounds;
        }

        const out = try ctx.createArray(source.element_type, end - start);
        for (start..end) |i| {
            try out.push(ctx.allocator, source.data[i]);
        }
        return BoxedValue.initArray(out);
    }

    /// Absolute value
    pub fn abs(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1) return error.InvalidArguments;

        return switch (args[0].tag) {
            .int => BoxedValue.initInt(if (args[0].data.int_val < 0) -args[0].data.int_val else args[0].data.int_val),
            .float => BoxedValue.initFloat(@abs(args[0].data.float_val)),
            else => error.InvalidArguments,
        };
    }

    /// Minimum of two numbers (int,int) or (float,float)
    pub fn min(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 2) return error.InvalidArguments;

        if (args[0].tag == .int and args[1].tag == .int) {
            return BoxedValue.initInt(@min(args[0].data.int_val, args[1].data.int_val));
        }
        if (args[0].tag == .float and args[1].tag == .float) {
            return BoxedValue.initFloat(@min(args[0].data.float_val, args[1].data.float_val));
        }
        return error.InvalidArguments;
    }

    /// Maximum of two numbers (int,int) or (float,float)
    pub fn max(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 2) return error.InvalidArguments;

        if (args[0].tag == .int and args[1].tag == .int) {
            return BoxedValue.initInt(@max(args[0].data.int_val, args[1].data.int_val));
        }
        if (args[0].tag == .float and args[1].tag == .float) {
            return BoxedValue.initFloat(@max(args[0].data.float_val, args[1].data.float_val));
        }
        return error.InvalidArguments;
    }

    /// Square root
    pub fn sqrt(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1) return error.InvalidArguments;

        const val: f64 = switch (args[0].tag) {
            .int => @floatFromInt(args[0].data.int_val),
            .float => args[0].data.float_val,
            else => return error.InvalidArguments,
        };
        return BoxedValue.initFloat(@sqrt(val));
    }

    /// Floor
    pub fn floor(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .float) return error.InvalidArguments;
        return BoxedValue.initFloat(@floor(args[0].data.float_val));
    }

    /// Ceiling
    pub fn ceil(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .float) return error.InvalidArguments;
        return BoxedValue.initFloat(@ceil(args[0].data.float_val));
    }

    /// Convert bool to string
    pub fn boolToStr(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .bool) return error.InvalidArguments;
        const val = if (args[0].data.bool_val) "true" else "false";
        return BoxedValue.initString(StringRef.fromSlice(val));
    }

    /// Convert int to float
    pub fn intToFloat(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .int) return error.InvalidArguments;
        return BoxedValue.initFloat(@floatFromInt(args[0].data.int_val));
    }

    /// Convert float to int (truncate toward zero)
    pub fn floatToInt(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1 or args[0].tag != .float) return error.InvalidArguments;
        return BoxedValue.initInt(@intFromFloat(args[0].data.float_val));
    }

    /// Type check (is)
    pub fn typeOf(ctx: *RuntimeContext, args: []const BoxedValue) !BoxedValue {
        _ = ctx;
        if (args.len != 1) return error.InvalidArguments;
        const type_name = args[0].tag.name();
        return BoxedValue.initString(StringRef.fromSlice(type_name));
    }
};

// ============================================
// Error Handling
// ============================================

pub const RuntimeError = error{
    TypeError,
    IndexOutOfBounds,
    FieldNotFound,
    DivisionByZero,
    StackOverflow,
    StackUnderflow,
    InvalidArguments,
    OutOfMemory,
    UndefinedVariable,
    UndefinedFunction,
};

/// Format a runtime error for display
pub fn formatRuntimeError(err: RuntimeError, writer: anytype) !void {
    const msg = switch (err) {
        error.TypeError => "Type error: incompatible types",
        error.IndexOutOfBounds => "Index out of bounds",
        error.FieldNotFound => "Field not found",
        error.DivisionByZero => "Division by zero",
        error.StackOverflow => "Stack overflow (too much recursion)",
        error.StackUnderflow => "Stack underflow",
        error.InvalidArguments => "Invalid function arguments",
        error.OutOfMemory => "Out of memory",
        error.UndefinedVariable => "Undefined variable",
        error.UndefinedFunction => "Undefined function",
    };
    try writer.writeAll(msg);
}

// ============================================
// Tests
// ============================================

test "BoxedValue basics" {
    const int_val = BoxedValue.initInt(42);
    try std.testing.expectEqual(TypeTag.int, int_val.tag);
    try std.testing.expectEqual(@as(i64, 42), int_val.data.int_val);

    const null_val = BoxedValue.initNull();
    try std.testing.expect(!null_val.isTruthy());
    try std.testing.expect(int_val.isTruthy());
}

test "StringRef basics" {
    const s1 = StringRef.fromSlice("hello");
    const s2 = StringRef.fromSlice("hello");
    const s3 = StringRef.fromSlice("world");

    try std.testing.expect(s1.eql(s2));
    try std.testing.expect(!s1.eql(s3));
}

test "ArrayObj operations" {
    const allocator = std.testing.allocator;

    var arr = try ArrayObj.create(allocator, .int, 4);
    defer arr.destroy(allocator);

    try arr.push(allocator, BoxedValue.initInt(1));
    try arr.push(allocator, BoxedValue.initInt(2));
    try arr.push(allocator, BoxedValue.initInt(3));

    try std.testing.expectEqual(@as(usize, 3), arr.len);

    const val = try arr.get(1);
    try std.testing.expectEqual(@as(i64, 2), val.data.int_val);

    const popped = try arr.pop();
    try std.testing.expectEqual(@as(i64, 3), popped.data.int_val);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
}

test "RuntimeContext string interning" {
    const allocator = std.testing.allocator;

    var ctx = RuntimeContext.init(allocator);
    defer ctx.deinit();

    const s1 = try ctx.internString("hello");
    const s2 = try ctx.internString("hello");
    const s3 = try ctx.internString("world");

    // Same string should return same pointer
    try std.testing.expectEqual(s1.ptr, s2.ptr);
    try std.testing.expect(s1.ptr != s3.ptr);
}

test "Builtins string helpers and parsing" {
    const allocator = std.testing.allocator;

    var ctx = RuntimeContext.init(allocator);
    defer ctx.deinit();

    const trimmed = try Builtins.call(&ctx, "str_trim", &[_]BoxedValue{
        BoxedValue.initString(StringRef.fromSlice("  hello,world  ")),
    });
    try std.testing.expectEqual(TypeTag.string, trimmed.tag);
    try std.testing.expect(std.mem.eql(u8, "hello,world", trimmed.data.string_val.toSlice()));

    const split = try Builtins.call(&ctx, "str_split", &[_]BoxedValue{
        trimmed,
        BoxedValue.initString(StringRef.fromSlice(",")),
    });
    try std.testing.expectEqual(TypeTag.array, split.tag);
    try std.testing.expectEqual(@as(usize, 2), split.data.array_val.len);

    const first = try split.data.array_val.get(0);
    const second = try split.data.array_val.get(1);
    try std.testing.expect(std.mem.eql(u8, "hello", first.data.string_val.toSlice()));
    try std.testing.expect(std.mem.eql(u8, "world", second.data.string_val.toSlice()));

    const parsed_int = try Builtins.call(&ctx, "str_to_int", &[_]BoxedValue{
        BoxedValue.initString(StringRef.fromSlice("123")),
    });
    try std.testing.expectEqual(TypeTag.int, parsed_int.tag);
    try std.testing.expectEqual(@as(i64, 123), parsed_int.data.int_val);

    const parsed_float = try Builtins.call(&ctx, "str_to_float", &[_]BoxedValue{
        BoxedValue.initString(StringRef.fromSlice("3.5")),
    });
    try std.testing.expectEqual(TypeTag.float, parsed_float.tag);
    try std.testing.expectEqual(@as(f64, 3.5), parsed_float.data.float_val);

    const contains = try Builtins.call(&ctx, "str_contains", &[_]BoxedValue{
        BoxedValue.initString(StringRef.fromSlice("alphabet")),
        BoxedValue.initString(StringRef.fromSlice("pha")),
    });
    try std.testing.expectEqual(TypeTag.bool, contains.tag);
    try std.testing.expect(contains.data.bool_val);
}

test "Builtins array helpers" {
    const allocator = std.testing.allocator;

    var ctx = RuntimeContext.init(allocator);
    defer ctx.deinit();

    const arr = try ctx.createArray(.int, 0);
    try arr.push(allocator, BoxedValue.initInt(10));
    try arr.push(allocator, BoxedValue.initInt(20));
    try arr.push(allocator, BoxedValue.initInt(30));

    const slice = try Builtins.call(&ctx, "array_slice", &[_]BoxedValue{
        BoxedValue.initArray(arr),
        BoxedValue.initInt(1),
        BoxedValue.initInt(3),
    });
    try std.testing.expectEqual(TypeTag.array, slice.tag);
    try std.testing.expectEqual(@as(usize, 2), slice.data.array_val.len);

    const slice_first = try slice.data.array_val.get(0);
    const slice_second = try slice.data.array_val.get(1);
    try std.testing.expectEqual(@as(i64, 20), slice_first.data.int_val);
    try std.testing.expectEqual(@as(i64, 30), slice_second.data.int_val);

    const len = try Builtins.call(&ctx, "array_len", &[_]BoxedValue{slice});
    try std.testing.expectEqual(TypeTag.int, len.tag);
    try std.testing.expectEqual(@as(i64, 2), len.data.int_val);

    const popped = try Builtins.call(&ctx, "array_pop", &[_]BoxedValue{slice});
    try std.testing.expectEqual(TypeTag.int, popped.tag);
    try std.testing.expectEqual(@as(i64, 30), popped.data.int_val);
}

test "Builtins dispatcher and numeric conversions" {
    const allocator = std.testing.allocator;

    var ctx = RuntimeContext.init(allocator);
    defer ctx.deinit();

    const as_float = try Builtins.call(&ctx, "int_to_float", &[_]BoxedValue{BoxedValue.initInt(42)});
    try std.testing.expectEqual(TypeTag.float, as_float.tag);
    try std.testing.expectEqual(@as(f64, 42), as_float.data.float_val);

    const as_int = try Builtins.call(&ctx, "float_to_int", &[_]BoxedValue{BoxedValue.initFloat(9.9)});
    try std.testing.expectEqual(TypeTag.int, as_int.tag);
    try std.testing.expectEqual(@as(i64, 9), as_int.data.int_val);

    const bool_str = try Builtins.call(&ctx, "bool_to_str", &[_]BoxedValue{BoxedValue.initBool(true)});
    try std.testing.expectEqual(TypeTag.string, bool_str.tag);
    try std.testing.expect(std.mem.eql(u8, "true", bool_str.data.string_val.toSlice()));

    const min_val = try Builtins.call(&ctx, "min", &[_]BoxedValue{ BoxedValue.initInt(9), BoxedValue.initInt(2) });
    try std.testing.expectEqual(TypeTag.int, min_val.tag);
    try std.testing.expectEqual(@as(i64, 2), min_val.data.int_val);

    const ceil_val = try Builtins.call(&ctx, "ceil", &[_]BoxedValue{BoxedValue.initFloat(2.2)});
    try std.testing.expectEqual(TypeTag.float, ceil_val.tag);
    try std.testing.expectEqual(@as(f64, 3.0), ceil_val.data.float_val);

    try std.testing.expectError(error.UndefinedFunction, Builtins.call(&ctx, "missing_builtin", &[_]BoxedValue{}));
}
