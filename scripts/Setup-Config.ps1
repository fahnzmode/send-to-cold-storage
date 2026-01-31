<#
.SYNOPSIS
    Non-interactive setup script for cold storage configuration.
.DESCRIPTION
    Creates config files and directories. Pass bucket and region as parameters.
    Used for autonomous setup where interactive prompts aren't possible.
.PARAMETER Bucket
    S3 bucket name for cold storage archive.
.PARAMETER Region
    AWS region where the bucket is located.
.PARAMETER AwsProfile
    AWS profile name to use. Defaults to 'cold-storage'.
.EXAMPLE
    .\Setup-Config.ps1 -Bucket "my-cold-storage-bucket" -Region "us-east-1"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Bucket,

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [Parameter()]
    [string]$AwsProfile = "cold-storage"
)

$ErrorActionPreference = "Stop"

# Find restic executable dynamically
$resticExe = $env:RESTIC_EXE
if (-not $resticExe) {
    $resticExe = (Get-Command 'restic' -ErrorAction SilentlyContinue)?.Source
}
if (-not $resticExe) {
    # Search common winget installation locations
    $searchPaths = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    )
    foreach ($searchPath in $searchPaths) {
        if (Test-Path $searchPath) {
            $found = Get-ChildItem -Path $searchPath -Recurse -Filter "restic*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $resticExe = $found.FullName
                break
            }
        }
    }
}
if (-not $resticExe) {
    throw "Restic executable not found. Install restic (winget install restic.restic) or set RESTIC_EXE environment variable."
}
$configDir = Join-Path $env:USERPROFILE '.cold-storage'
$configPath = Join-Path $configDir 'config.json'
$passwordFile = Join-Path $configDir '.restic-password'
$logDir = Join-Path $configDir 'logs'
$stagingRoot = 'C:\ColdStorageStaging'
$resticRepo = "s3:s3.$Region.amazonaws.com/$Bucket"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Cold Storage Setup (Non-Interactive) " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Create directories
Write-Host "Creating directories..."
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
Write-Host "  Config: $configDir" -ForegroundColor Green
Write-Host "  Logs: $logDir" -ForegroundColor Green
Write-Host "  Staging: $stagingRoot" -ForegroundColor Green

# Generate a fresh password (delete old one if exists to ensure clean start)
Write-Host ""
Write-Host "Setting up restic password..."
if (Test-Path $passwordFile) {
    Remove-Item -Path $passwordFile -Force
    Write-Host "  Removed old password file" -ForegroundColor Yellow
}
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$password = [Convert]::ToBase64String($bytes)
$password | Out-File -FilePath $passwordFile -Encoding UTF8 -NoNewline
Write-Host "  Password saved to: $passwordFile" -ForegroundColor Green
Write-Host ""
Write-Host "  !! IMPORTANT: SAVE THIS PASSWORD !!" -ForegroundColor Yellow
Write-Host "  $password" -ForegroundColor White
Write-Host ""

# Create config.json
Write-Host "Creating config.json..."
$config = @{
    version = '1.0'
    created = (Get-Date).ToString('o')
    aws_profile = $AwsProfile
    aws_region = $Region
    s3_bucket = $Bucket
    restic_repository = $resticRepo
    restic_password_file = $passwordFile
    restic_executable = $resticExe
    staging_root = $stagingRoot
    tracking_database = Join-Path $stagingRoot 'cold_storage_tracking.json'
    log_directory = $logDir
}
$config | ConvertTo-Json -Depth 10 | Out-File -FilePath $configPath -Encoding UTF8
Write-Host "  Config saved to: $configPath" -ForegroundColor Green

# Create tracking database
$trackingDb = Join-Path $stagingRoot 'cold_storage_tracking.json'
if (-not (Test-Path $trackingDb)) {
    Write-Host "Creating tracking database..."
    $db = @{
        version = '1.0'
        created = (Get-Date).ToString('o')
        archives = @()
        statistics = @{
            total_archived_bytes = 0
            total_items = 0
            last_archive_date = $null
            estimated_monthly_cost_usd = 0.0
        }
    }
    $db | ConvertTo-Json -Depth 10 | Out-File -FilePath $trackingDb -Encoding UTF8
    Write-Host "  Database: $trackingDb" -ForegroundColor Green
} else {
    Write-Host "  Tracking database exists: $trackingDb" -ForegroundColor Green
}

# Initialize restic repository
Write-Host ""
Write-Host "Initializing restic repository..."
Write-Host "  Repository: $resticRepo"

$env:AWS_PROFILE = $AwsProfile
$env:RESTIC_REPOSITORY = $resticRepo
$env:RESTIC_PASSWORD_FILE = $passwordFile

# Check if repo already exists
$ErrorActionPreference = "SilentlyContinue"
$checkResult = & $resticExe snapshots 2>&1
$checkExitCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"

if ($checkExitCode -eq 0) {
    Write-Host "  Repository already initialized" -ForegroundColor Green
} else {
    # Initialize
    Write-Host "  Repository does not exist, initializing..."
    $initResult = & $resticExe init 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Failed to initialize: $initResult" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Repository initialized successfully" -ForegroundColor Green
}

# Test connection
Write-Host ""
Write-Host "Testing repository connection..."
$snapshots = & $resticExe snapshots --json 2>&1
if ($LASTEXITCODE -eq 0) {
    $snapshotList = $snapshots | ConvertFrom-Json
    $count = if ($snapshotList) { @($snapshotList).Count } else { 0 }
    Write-Host "  Connection successful. $count snapshot(s) in repository." -ForegroundColor Green
} else {
    Write-Host "  Connection test failed: $snapshots" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Setup Complete!                      " -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Configuration: $configPath"
Write-Host "Staging root: $stagingRoot"
Write-Host ""
