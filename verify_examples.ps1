# Verify every example against the AST interpreter and compiled backends.

param(
    [Switch]$SkipNative,
    [String]$Filter = "*.elba"
)

$ErrorActionPreference = "Stop"
$elbaExe = Join-Path $PSScriptRoot "zig-out\bin\elba.exe"
$examplesDir = Join-Path $PSScriptRoot "examples"

if (!(Test-Path -LiteralPath $elbaExe)) {
    Write-Host "Elba executable not found. Run 'zig build' first." -ForegroundColor Red
    exit 1
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) ("elba-example-verification-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workDir | Out-Null

function Invoke-Captured {
    param([String]$Command, [String[]]$Arguments)

    # Elba currently writes program output through stderr. Windows PowerShell
    # wraps native stderr records and would stop here under the script-wide
    # ErrorActionPreference, so capture native output in Continue mode.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& $Command @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord]) {
                $_.Exception.Message
            } else {
                $_.ToString()
            }
        })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Test-SameOutput {
    param([String[]]$Expected, [String[]]$Actual)
    return (($Expected -join "`n") -ceq ($Actual -join "`n"))
}

$failed = 0

try {
    $examples = Get-ChildItem -LiteralPath $examplesDir -Filter $Filter | Sort-Object Name
    foreach ($example in $examples) {
        Write-Host -NoNewline ("{0,-28}" -f $example.Name)

        $ast = Invoke-Captured $elbaExe @("--no-bindings", $example.FullName)
        if ($ast.ExitCode -ne 0) {
            Write-Host " AST failed" -ForegroundColor Red
            $failed++
            continue
        }

        $ir = Invoke-Captured $elbaExe @("--compile", "--run-ir", "--no-bindings", $example.FullName)
        if ($ir.ExitCode -ne 0 -or !(Test-SameOutput -Expected $ast.Output -Actual $ir.Output)) {
            Write-Host " IR differs" -ForegroundColor Red
            $failed++
            continue
        }

        if ($SkipNative) {
            Write-Host " AST/IR OK" -ForegroundColor Green
            continue
        }

        $cBase = Join-Path $workDir ($example.BaseName + "-c")
        $cCompile = Invoke-Captured $elbaExe @("--compile", "--compile-c", "--no-bindings", "-o", $cBase, $example.FullName)
        $cExe = $cBase + ".exe"
        if ($cCompile.ExitCode -ne 0 -or !(Test-Path -LiteralPath $cExe)) {
            Write-Host " C compile failed" -ForegroundColor Red
            $failed++
            continue
        }
        $cRun = Invoke-Captured $cExe @()
        if ($cRun.ExitCode -ne 0 -or !(Test-SameOutput -Expected $ast.Output -Actual $cRun.Output)) {
            Write-Host " C differs" -ForegroundColor Red
            $failed++
            continue
        }

        $llvmBase = Join-Path $workDir ($example.BaseName + "-llvm")
        $llvmCompile = Invoke-Captured $elbaExe @("--compile", "--compile-llvm", "--no-bindings", "-o", $llvmBase, $example.FullName)
        $llvmExe = $llvmBase + ".exe"
        if ($llvmCompile.ExitCode -ne 0 -or !(Test-Path -LiteralPath $llvmExe)) {
            Write-Host " LLVM compile failed" -ForegroundColor Red
            $failed++
            continue
        }
        $llvmRun = Invoke-Captured $llvmExe @()
        if ($llvmRun.ExitCode -ne 0 -or !(Test-SameOutput -Expected $ast.Output -Actual $llvmRun.Output)) {
            Write-Host " LLVM differs" -ForegroundColor Red
            $failed++
            continue
        }

        Write-Host " AST/IR/C/LLVM OK" -ForegroundColor Green
    }
} finally {
    $resolvedWorkDir = [IO.Path]::GetFullPath($workDir)
    $resolvedTempDir = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedWorkDir.StartsWith($resolvedTempDir, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failed -gt 0) {
    Write-Host "$failed example(s) failed verification." -ForegroundColor Red
    exit 1
}

Write-Host "All examples produced identical output." -ForegroundColor Green
