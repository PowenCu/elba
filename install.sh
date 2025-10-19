#!/bin/bash
# Elba Installation Script for Unix/Linux/macOS

set -e

echo "🚀 Elba Programming Language Installation"
echo "=========================================="
echo ""

# Check for Zig
if ! command -v zig &> /dev/null; then
    echo "❌ Zig is not installed!"
    echo "Please install Zig 0.15.2 or later from https://ziglang.org/download/"
    exit 1
fi

echo "✓ Zig found: $(zig version)"

# Build Elba
echo ""
echo "Building Elba..."
zig build

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Build successful!"
    echo ""
    echo "Elba has been installed to: ./zig-out/bin/elba"
    echo ""
    echo "To use Elba, you can:"
    echo "  1. Run directly: ./zig-out/bin/elba program.elba"
    echo "  2. Add to PATH: export PATH=\$PATH:$(pwd)/zig-out/bin"
    echo "  3. Create an alias: alias elba='$(pwd)/zig-out/bin/elba'"
    echo ""
    echo "Quick test:"
    echo "  ./zig-out/bin/elba examples/hello_world.elba"
    echo ""
    echo "Start REPL:"
    echo "  ./zig-out/bin/elba repl"
    echo ""
    echo "Get help:"
    echo "  ./zig-out/bin/elba --help"
    echo ""
    echo "Happy coding! 🎉"
else
    echo ""
    echo "❌ Build failed!"
    echo "Please check the error messages above."
    exit 1
fi
