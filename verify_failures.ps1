# Verify that every expected-failure fixture is rejected or fails at runtime
# through the AST interpreter, IR interpreter, generated C, and LLVM.

param(
    [String]$Filter = "expect_fail_*.elba",
    [Switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"
$elbaExe = Join-Path $PSScriptRoot "zig-out\bin\elba.exe"
$testsDir = Join-Path $PSScriptRoot "tests"

if (!(Test-Path -LiteralPath $elbaExe)) {
    Write-Host "Elba executable not found. Run 'zig build' first." -ForegroundColor Red
    exit 1
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) ("elba-failure-verification-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workDir | Out-Null

function Invoke-Captured {
    param([String]$Command, [String[]]$Arguments)

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

function Show-FailureOutput {
    param([String]$Backend, $Result)
    if ($VerboseOutput) {
        Write-Host "`n  $Backend output:" -ForegroundColor DarkGray
        $Result.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

$failed = 0
$verified = 0

try {
    $fixtures = Get-ChildItem -LiteralPath $testsDir -Filter $Filter | Sort-Object Name
    foreach ($fixture in $fixtures) {
        Write-Host -NoNewline ("{0,-42}" -f $fixture.Name)

        $ast = Invoke-Captured $elbaExe @("--no-bindings", $fixture.FullName)
        if ($ast.ExitCode -eq 0) {
            Write-Host " AST accepted" -ForegroundColor Red
            $failed++
            continue
        }
        Show-FailureOutput "AST" $ast

        $ir = Invoke-Captured $elbaExe @("--compile", "--run-ir", "--no-bindings", $fixture.FullName)
        if ($ir.ExitCode -eq 0) {
            Write-Host " IR accepted" -ForegroundColor Red
            $failed++
            continue
        }
        Show-FailureOutput "IR" $ir

        $cBase = Join-Path $workDir ($fixture.BaseName + "-c")
        $cCompile = Invoke-Captured $elbaExe @("--compile", "--compile-c", "--no-bindings", "-o", $cBase, $fixture.FullName)
        if ($cCompile.ExitCode -eq 0) {
            $cExe = $cBase + ".exe"
            if (!(Test-Path -LiteralPath $cExe)) {
                Write-Host " C executable missing" -ForegroundColor Red
                $failed++
                continue
            }
            $cRun = Invoke-Captured $cExe @()
            if ($cRun.ExitCode -eq 0) {
                Write-Host " C accepted" -ForegroundColor Red
                $failed++
                continue
            }
            Show-FailureOutput "C" $cRun
        } else {
            Show-FailureOutput "C compile" $cCompile
        }

        $llvmBase = Join-Path $workDir ($fixture.BaseName + "-llvm")
        $llvmCompile = Invoke-Captured $elbaExe @("--compile", "--compile-llvm", "--no-bindings", "-o", $llvmBase, $fixture.FullName)
        if ($llvmCompile.ExitCode -eq 0) {
            $llvmExe = $llvmBase + ".exe"
            if (!(Test-Path -LiteralPath $llvmExe)) {
                Write-Host " LLVM executable missing" -ForegroundColor Red
                $failed++
                continue
            }
            $llvmRun = Invoke-Captured $llvmExe @()
            if ($llvmRun.ExitCode -eq 0) {
                Write-Host " LLVM accepted" -ForegroundColor Red
                $failed++
                continue
            }
            Show-FailureOutput "LLVM" $llvmRun
        } else {
            Show-FailureOutput "LLVM compile" $llvmCompile
        }

        Write-Host " AST/IR/C/LLVM rejected" -ForegroundColor Green
        $verified++
    }
} finally {
    $resolvedWorkDir = [IO.Path]::GetFullPath($workDir)
    $resolvedTempDir = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedWorkDir.StartsWith($resolvedTempDir, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failed -gt 0) {
    Write-Host "$failed expected-failure fixture(s) were accepted." -ForegroundColor Red
    exit 1
}

Write-Host "All $verified expected-failure fixtures were rejected by every backend." -ForegroundColor Green
exit 0
