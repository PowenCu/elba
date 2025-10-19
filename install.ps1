# Elba Installation Script for Windows PowerShell

Write-Host "🚀 Elba Programming Language Installation" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Check for Zig
try {
    $zigVersion = zig version
    Write-Host "✓ Zig found: $zigVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ Zig is not installed!" -ForegroundColor Red
    Write-Host "Please install Zig 0.15.2 or later from https://ziglang.org/download/" -ForegroundColor Yellow
    exit 1
}

# Build Elba
Write-Host ""
Write-Host "Building Elba..." -ForegroundColor Yellow
zig build

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "✓ Build successful!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Elba has been installed to: .\zig-out\bin\elba.exe" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To use Elba, you can:" -ForegroundColor White
    Write-Host "  1. Run directly: .\zig-out\bin\elba.exe program.elba"
    Write-Host "  2. Add to PATH in System Environment Variables"
    Write-Host ""
    Write-Host "Quick test:" -ForegroundColor Yellow
    Write-Host "  .\zig-out\bin\elba.exe examples\hello_world.elba"
    Write-Host ""
    Write-Host "Start REPL:" -ForegroundColor Yellow
    Write-Host "  .\zig-out\bin\elba.exe repl"
    Write-Host ""
    Write-Host "Get help:" -ForegroundColor Yellow
    Write-Host "  .\zig-out\bin\elba.exe --help"
    Write-Host ""
    Write-Host "Happy coding! 🎉" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "❌ Build failed!" -ForegroundColor Red
    Write-Host "Please check the error messages above." -ForegroundColor Yellow
    exit 1
}
