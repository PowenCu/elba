# Test runner for Elba programming language
# Runs all test files and reports results

param(
    [Switch]$Verbose,
    [Switch]$StopOnError,
    [String]$Filter = "*.elba"
)

$testDir = "tests"
$elbaExe = ".\zig-out\bin\elba.exe"
$passed = 0
$expectedRejected = 0
$failed = 0
$skipped = 0
$testErrors = @()


# Check if elba executable exists
if (!(Test-Path $elbaExe)) {
    Write-Host "Error: Elba executable not found at $elbaExe" -ForegroundColor Red
    Write-Host "Please run 'zig build' first"
    exit 1
}

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

# Get all test files
$testFiles = Get-ChildItem $testDir -Filter $Filter -Recurse | Where-Object { $_.Name -match '^test_.*\.elba$' -or $_.Name -match '^comprehensive_test\.elba$' }
$expectedFailureFiles = Get-ChildItem $testDir -Filter $Filter -Recurse | Where-Object { $_.Name -match '^expect_fail_.*\.elba$' }

if ($testFiles.Count -eq 0) {
    Write-Host "No test files found matching pattern $Filter in $testDir" -ForegroundColor Yellow
    exit 0
}

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Elba Test Suite" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Found $($testFiles.Count) positive and $($expectedFailureFiles.Count) expected-failure test file(s)" -ForegroundColor Green
Write-Host ""

foreach ($testFile in $testFiles) {
    $testName = $testFile.Name
    $relativePath = $testFile.FullName | Resolve-Path -Relative
    
    Write-Host -NoNewline "Running $testName ... "
    
    try {
        $ast = Invoke-Captured $elbaExe @("--no-bindings", $testFile.FullName)
        $ir = if ($ast.ExitCode -eq 0) {
            Invoke-Captured $elbaExe @("--compile", "--run-ir", "--no-bindings", $testFile.FullName)
        } else {
            $null
        }
        
        if ($ast.ExitCode -eq 0 -and $ir.ExitCode -eq 0 -and (($ast.Output -join "`n") -ceq ($ir.Output -join "`n"))) {
            Write-Host "PASSED" -ForegroundColor Green
            $passed++
            
            if ($Verbose) {
                Write-Host "  Output: $($ast.Output)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "FAILED (AST/IR mismatch or nonzero exit)" -ForegroundColor Red
            $failed++
            $testErrors += @{
                Test = $testName
                Path = $relativePath
                Output = "AST: $($ast.Output) IR: $($ir.Output)"
                ExitCode = if ($ast.ExitCode -ne 0) { $ast.ExitCode } else { $ir.ExitCode }
            }
            
            if ($StopOnError) {
                Write-Host ""
                Write-Host "Stopping on first error (use -StopOnError:$false to continue)" -ForegroundColor Yellow
                break
            }
        }
    } catch {
        Write-Host "ERROR" -ForegroundColor Red
        $failed++
        $testErrors += @{
            Test = $testName
            Path = $relativePath
            Output = $_.Exception.Message
            ExitCode = -1
        }
        
        if ($StopOnError) {
            Write-Host ""
            Write-Host "Stopping on first error" -ForegroundColor Yellow
            break
        }
    }
}

foreach ($testFile in $expectedFailureFiles) {
    $testName = $testFile.Name
    $relativePath = $testFile.FullName | Resolve-Path -Relative

    Write-Host -NoNewline "Rejecting $testName ... "

    try {
        $output = & $elbaExe $testFile.FullName 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-Host "PASSED" -ForegroundColor Green
            $expectedRejected++

            if ($Verbose) {
                Write-Host "  Diagnostic: $output" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "FAILED (program was accepted)" -ForegroundColor Red
            $failed++
            $testErrors += @{
                Test = $testName
                Path = $relativePath
                Output = $output
                ExitCode = $exitCode
            }

            if ($StopOnError) {
                Write-Host ""
                Write-Host "Stopping on first error" -ForegroundColor Yellow
                break
            }
        }
    } catch {
        Write-Host "ERROR" -ForegroundColor Red
        $failed++
        $testErrors += @{
            Test = $testName
            Path = $relativePath
            Output = $_.Exception.Message
            ExitCode = -1
        }

        if ($StopOnError) {
            Write-Host ""
            Write-Host "Stopping on first error" -ForegroundColor Yellow
            break
        }
    }
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Test Results:" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Expected failures rejected: $expectedRejected" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "Skipped: $skipped" -ForegroundColor Yellow

if ($testErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "Failures:" -ForegroundColor Red
    foreach ($err in $testErrors) {
        Write-Host "  - $($err.Test)" -ForegroundColor Red
        if ($Verbose) {
            Write-Host "    Path: $($err.Path)"
            Write-Host "    Output: $($err.Output)"
        }
    }
}

# Exit with appropriate code
if ($failed -eq 0) {
    Write-Host ""
    Write-Host "All tests passed!" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host "$failed test(s) failed" -ForegroundColor Red
    exit 1
}
