#!/usr/bin/env powershell
# Benchmark runner for Elba - measures execution time of examples

param(
    [String]$Filter = "*.elba",
    [Switch]$Verbose
)

$examplesDir = "examples"
$elbaExe = ".\zig-out\bin\elba.exe"

# Check if elba executable exists
if (!(Test-Path $elbaExe)) {
    Write-Host "Error: Elba executable not found at $elbaExe" -ForegroundColor Red
    exit 1
}

# Get all example files
$exampleFiles = Get-ChildItem $examplesDir -Filter $Filter -Recurse | Where-Object { $_.Name -ne ".*" }

if ($exampleFiles.Count -eq 0) {
    Write-Host "No example files found matching pattern $Filter in $examplesDir" -ForegroundColor Yellow
    exit 0
}

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Elba Performance Benchmark" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Testing $($exampleFiles.Count) example file(s)" -ForegroundColor Green
Write-Host ""

$totalTime = 0
$results = @()

foreach ($file in $exampleFiles) {
    $name = $file.Name
    Write-Host -NoNewline "Benchmarking $name ... "
    
    try {
        # Measure execution time (3 runs, take average)
        $times = @()
        for ($i = 0; $i -lt 3; $i++) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $output = & $elbaExe $file.FullName 2>&1 | Out-Null
            $sw.Stop()
            $times += $sw.ElapsedMilliseconds
        }
        
        $avgTime = ($times | Measure-Object -Average).Average
        $totalTime += $avgTime
        
        Write-Host "$([Math]::Round($avgTime, 2))ms" -ForegroundColor Green
        $results += @{
            Name = $name
            Time = $avgTime
        }
    } catch {
        Write-Host "ERROR" -ForegroundColor Red
        if ($Verbose) {
            Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkRed
        }
    }
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Benchmark Results (avg of 3 runs):" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Sort by time (slowest first)
$results | Sort-Object Time -Descending | ForEach-Object {
    Write-Host "$($_.Name): $([Math]::Round($_.Time, 2))ms" -ForegroundColor Green
}

Write-Host ""
Write-Host "Total time: $([Math]::Round($totalTime, 2))ms" -ForegroundColor Cyan
Write-Host "Average time: $([Math]::Round($totalTime / $results.Count, 2))ms" -ForegroundColor Cyan
