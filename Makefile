# Makefile for Elba Programming Language
# Transitioning from Zig to C

CC = gcc
CFLAGS = -Wall -Wextra -std=c11 -g -O2
LDFLAGS = 
LIBS = -lm 

# LLVM configuration (optional)
LLVM_CONFIG = llvm-config
LLVM_CFLAGS = $(shell $(LLVM_CONFIG) --cflags 2>/dev/null || echo "")
LLVM_LDFLAGS = $(shell $(LLVM_CONFIG) --ldflags 2>/dev/null || echo "")
LLVM_LIBS = $(shell $(LLVM_CONFIG) --libs core executionengine mcjit native 2>/dev/null || echo "")

# Directories
SRC_DIR = src
BUILD_DIR = build
BIN_DIR = bin
OBJ_DIR = $(BUILD_DIR)/obj

# Source files (will be populated as we convert from Zig to C)
C_SOURCES = \
	$(SRC_DIR)/main.c \
	$(SRC_DIR)/common.c \
	$(SRC_DIR)/frontend/lexer.c \
	$(SRC_DIR)/frontend/ast.c \
	$(SRC_DIR)/frontend/parser.c \
	$(SRC_DIR)/frontend/typechecker.c \
	$(SRC_DIR)/backend/interpreter.c \
	$(SRC_DIR)/backend/ir.c \
	$(SRC_DIR)/backend/ir_gen.c \
	$(SRC_DIR)/backend/ir_optimizer.c \
	$(SRC_DIR)/backend/ir_interp.c \
	$(SRC_DIR)/utils/error_reporter.c 

# Object files
OBJECTS = $(C_SOURCES:$(SRC_DIR)/%.c=$(OBJ_DIR)/%.o)

# Output executable
TARGET = $(BIN_DIR)/elba

# Phony targets
.PHONY: all clean directories run test

all: directories $(TARGET)

directories:
	@mkdir -p $(BIN_DIR)
	@mkdir -p $(OBJ_DIR)
	@mkdir -p $(OBJ_DIR)/frontend
	@mkdir -p $(OBJ_DIR)/backend
	@mkdir -p $(OBJ_DIR)/codegen
	@mkdir -p $(OBJ_DIR)/utils

$(TARGET): $(OBJECTS)
	$(CC) $(OBJECTS) -o $(TARGET) $(LDFLAGS) $(LIBS) $(LLVM_LDFLAGS) $(LLVM_LIBS)
	@echo "Build complete: $(TARGET)"

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c
	$(CC) $(CFLAGS) $(LLVM_CFLAGS) -c $< -o $@

clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)

run: $(TARGET)
	$(TARGET)

test: $(TARGET)
	@echo "Running tests..."
	@# Add test commands here

# Help target
help:
	@echo "Elba C Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all       - Build the elba executable (default)"
	@echo "  clean     - Remove build artifacts"
	@echo "  run       - Build and run elba"
	@echo "  test      - Build and run tests"
	@echo "  help      - Show this help message"
