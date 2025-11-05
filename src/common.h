#ifndef ELBA_COMMON_H
#define ELBA_COMMON_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// Memory allocator wrapper
typedef struct {
    void* data;
    size_t size;
    size_t capacity;
} Arena;

Arena* arena_create(size_t initial_capacity);
void* arena_alloc(Arena* arena, size_t size);
void arena_free(Arena* arena);

// Dynamic array (similar to Zig's ArrayList)
typedef struct {
    void* items;
    size_t length;
    size_t capacity;
    size_t item_size;
} DynamicArray;

DynamicArray* dyn_array_create(size_t item_size);
void dyn_array_append(DynamicArray* array, const void* item);
void* dyn_array_get(DynamicArray* array, size_t index);
void dyn_array_free(DynamicArray* array);

// String slice (pointer + length)
typedef struct {
    const char* data;
    size_t length;
} Slice;

Slice slice_from_cstr(const char* str);
Slice slice_from_ptr_len(const char* ptr, size_t len);
bool slice_equals(Slice a, Slice b);
int slice_compare(Slice a, Slice b);

// Error handling
typedef enum {
    ERR_OK = 0,
    ERR_OUT_OF_MEMORY,
    ERR_FILE_NOT_FOUND,
    ERR_IO_ERROR,
    ERR_PARSE_ERROR,
    ERR_TYPE_ERROR,
    ERR_RUNTIME_ERROR,
    ERR_INVALID_ARGUMENT,
} ErrorCode;

typedef struct {
    ErrorCode code;
    const char* message;
} Error;

Error error_ok(void);
Error error_new(ErrorCode code, const char* message);
bool error_is_ok(Error err);

#endif // ELBA_COMMON_H
