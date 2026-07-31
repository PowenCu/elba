const std = @import("std");

pub const Error = error{
    IntegerOverflow,
    DivisionByZero,
    NegativeExponent,
};

pub fn add(left: i64, right: i64) Error!i64 {
    return std.math.add(i64, left, right) catch error.IntegerOverflow;
}

pub fn sub(left: i64, right: i64) Error!i64 {
    return std.math.sub(i64, left, right) catch error.IntegerOverflow;
}

pub fn mul(left: i64, right: i64) Error!i64 {
    return std.math.mul(i64, left, right) catch error.IntegerOverflow;
}

pub fn div(left: i64, right: i64) Error!i64 {
    if (right == 0) return error.DivisionByZero;
    if (left == std.math.minInt(i64) and right == -1) return error.IntegerOverflow;
    return @divTrunc(left, right);
}

pub fn mod(left: i64, right: i64) Error!i64 {
    if (right == 0) return error.DivisionByZero;
    if (left == std.math.minInt(i64) and right == -1) return error.IntegerOverflow;
    return @mod(left, right);
}

pub fn neg(value: i64) Error!i64 {
    return sub(0, value);
}

pub fn pow(base_value: i64, exponent_value: i64) Error!i64 {
    if (exponent_value < 0) return error.NegativeExponent;

    var base = base_value;
    var exponent: u64 = @intCast(exponent_value);
    var result: i64 = 1;
    while (exponent != 0) : (exponent >>= 1) {
        if (exponent & 1 != 0) result = try mul(result, base);
        if (exponent > 1) base = try mul(base, base);
    }
    return result;
}

test "checked integer arithmetic" {
    try std.testing.expectEqual(@as(i64, 42), try add(40, 2));
    try std.testing.expectEqual(@as(i64, 81), try pow(3, 4));
    try std.testing.expectError(error.IntegerOverflow, add(std.math.maxInt(i64), 1));
    try std.testing.expectError(error.IntegerOverflow, neg(std.math.minInt(i64)));
    try std.testing.expectError(error.DivisionByZero, div(1, 0));
    try std.testing.expectError(error.NegativeExponent, pow(2, -1));
}
