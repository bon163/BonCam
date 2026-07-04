param(
    [switch]$Release
)

$ErrorActionPreference = 'Stop'

function Write-Step($message) {
    Write-Host "`n==> $message" -ForegroundColor Cyan
}

$workspaceRoot = Split-Path -Parent $PSScriptRoot
Set-Location $workspaceRoot

Write-Step 'Checking for Rust toolchain'
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Host 'Cargo was not found in PATH.' -ForegroundColor Red
    Write-Host 'Install Rust from https://rustup.rs/ and then reopen PowerShell.' -ForegroundColor Yellow
    exit 1
}

Write-Step 'Rust version'
cargo --version

$buildArgs = @('run', '-p', 'windows-host')
if ($Release) {
    $buildArgs += "--release"
}

Write-Step 'Starting Windows host'
Write-Host 'The host will listen on TCP 41000, TCP 41001, and TCP 41003.' -ForegroundColor Green
Write-Host 'Keep this window open while testing from the iPhone.' -ForegroundColor Green
& cargo @buildArgs
