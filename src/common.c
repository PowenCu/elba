#include "common.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Arena allocator implementation
Arena* arena_create(size_t initial_capacity) {
    Arena* arena = (Arena*)malloc(sizeof(Arena));
    if (!arena) return NULL;
    
    arena->data = malloc(initial_capacity);
    if (!arena->data) {
        free(arena);
        return NULL;
    }
    
    arena->size = 0;
    arena->capacity = initial_capacity;
    return arena;
}

void* arena_alloc(Arena* arena, size_t size) {
    if (arena->size + size > arena->capacity) {
        size_t new_capacity = arena->capacity * 2;
        while (new_capacity < arena->size + size) {
            new_capacity *= 2;
        }
        
        void* new_data = realloc(arena->data, new_capacity);
        if (!new_data) return NULL;
        
        arena->data = new_data;
        arena->capacity = new_capacity;
    }
    
    void* ptr = (char*)arena->data + arena->size;
    arena->size += size;
    return ptr;
}

void arena_free(Arena* arena) {
    if (arena) {
        free(arena->data);
        free(arena);
    }
}

// Dynamic array implementation
DynamicArray* dyn_array_create(size_t item_size) {
    DynamicArray* array = (DynamicArray*)malloc(sizeof(DynamicArray));
    if (!array) return NULL;
    
    array->items = NULL;
    array->length = 0;
    array->capacity = 0;
    array->item_size = item_size;
    return array;
}

void dyn_array_append(DynamicArray* array, const void* item) {
    if (array->length >= array->capacity) {
        size_t new_capacity = array->capacity == 0 ? 8 : array->capacity * 2;
        void* new_items = realloc(array->items, new_capacity * array->item_size);
        if (!new_items) {
            fprintf(stderr, "Out of memory in dyn_array_append\n");
            exit(1);
        }
        array->items = new_items;
        array->capacity = new_capacity;
    }
    
    void* dest = (char*)array->items + (array->length * array->item_size);
    memcpy(dest, item, array->item_size);
    array->length++;
}

void* dyn_array_get(DynamicArray* array, size_t index) {
    if (index >= array->length) return NULL;
    return (char*)array->items + (index * array->item_size);
}

void dyn_array_free(DynamicArray* array) {
    if (array) {
        free(array->items);
        free(array);
    }
}

// String slice implementation
Slice slice_from_cstr(const char* str) {
    Slice s;
    s.data = str;
    s.length = strlen(str);
    return s;
}

Slice slice_from_ptr_len(const char* ptr, size_t len) {
    Slice s;
    s.data = ptr;
    s.length = len;
    return s;
}

bool slice_equals(Slice a, Slice b) {
    if (a.length != b.length) return false;
    return memcmp(a.data, b.data, a.length) == 0;
}

int slice_compare(Slice a, Slice b) {
    size_t min_len = a.length < b.length ? a.length : b.length;
    int cmp = memcmp(a.data, b.data, min_len);
    if (cmp != 0) return cmp;
    if (a.length < b.length) return -1;
    if (a.length > b.length) return 1;
    return 0;
}

// Error handling implementation
Error error_ok(void) {
    Error err;
    err.code = ERR_OK;
    err.message = NULL;
    return err;
}

Error error_new(ErrorCode code, const char* message) {
    Error err;
    err.code = code;
    err.message = message;
    return err;
}

bool error_is_ok(Error err) {
    return err.code == ERR_OK;
}
