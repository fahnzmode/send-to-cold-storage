<#
.SYNOPSIS
    Verify integrity of cold storage archives.

.DESCRIPTION
    This script performs integrity verification of the restic repository
    and checks consistency between the tracking database and actual backups.

.PARAMETER Full
    Perform full verification including reading all data (slow but thorough).

.PARAMETER Quick
    Quick verification - only check repository structure (default).

.PARAMETER CheckDatabase
    Verify tracking database consistency with restic snapshots.

.PARAMETER ConfigPath
    Path to the configuration file.

.EXAMPLE
    .\Verify-Archives.ps1

.EXAMPLE
    .\Verify-Archives.ps1 -Full

.EXAMPLE
    .\Verify-Archives.ps1 -CheckDatabase

.NOTES
    Author: Claude Code
    Recommendation: Run monthly with -Quick, quarterly with -Full
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Full,

    [Parameter()]
    [switch]$Quick,

    [Parameter()]
    [switch]$CheckDatabase,

    [Parameter()]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Helper Functions

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$LogFile
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    if ($LogFile) {
        Add-Content -Path $LogFile -Value $logLine
    }

    switch ($Level) {
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
        "WARN"  { Write-Host $logLine -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logLine -ForegroundColor Green }
        default { Write-Host $logLine }
    }
}

function Get-PlatformDefaults {
    # Requires PowerShell Core 7+
    if ($IsWindows) {
        @{
            IsWindows = $true
            ConfigPath = Join-Path $env:USERPROFILE ".cold-storage\config.json"
        }
    } else {
        @{
            IsWindows = $false
            ConfigPath = Join-Path $env:HOME ".cold-storage/config.json"
        }
    }
}

function Get-Configuration {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        throw "Configuration file not found: $ConfigPath`nRun Setup-Restic.ps1 first."
    }

    Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Set-ResticEnvironment {
    param($Config)

    $env:AWS_PROFILE = $Config.aws_profile
    $env:RESTIC_REPOSITORY = $Config.restic_repository
    $env:RESTIC_PASSWORD_FILE = $Config.restic_password_file

    # Set script-level restic path
    $script:ResticExe = if ($Config.restic_executable) { $Config.restic_executable } else { "restic" }
}

function Get-TrackingDatabase {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Tracking database not found: $Path"
    }

    Get-Content $Path -Raw | ConvertFrom-Json
}

function Test-ResticRepository {
    <#
    .SYNOPSIS
        Verify restic repository integrity.
    #>
    param([bool]$ReadData = $false)

    $args = @("check")

    if ($ReadData) {
        $args += "--read-data"
        Write-Host "Running full verification (this may take a while)..." -ForegroundColor Yellow
    } else {
        Write-Host "Running quick verification..." -ForegroundColor Cyan
    }

    $startTime = Get-Date
    $output = & $script:ResticExe @args 2>&1
    $duration = (Get-Date) - $startTime

    if ($LASTEXITCODE -eq 0) {
        return @{
            Success = $true
            Duration = $duration
            Output = $output
        }
    } else {
        return @{
            Success = $false
            Duration = $duration
            Output = $output
            Error = $output
        }
    }
}

function Get-ResticSnapshots {
    $output = & $script:ResticExe snapshots --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list snapshots: $output"
    }

    $result = $output | ConvertFrom-Json
    return @($result | Where-Object { $_ })
}

function Test-DatabaseConsistency {
    <#
    .SYNOPSIS
        Check consistency between tracking database and restic snapshots.
    #>
    param(
        $Database,
        $Snapshots
    )

    $issues = @()
    $snapshotIds = @($Snapshots | Where-Object { $_ } | ForEach-Object { $_.short_id, $_.id } | Where-Object { $_ })

    # Check each archived item has a valid snapshot
    $archivedItems = @($Database.archives | Where-Object { $_.status -in @("archived", "archived_and_deleted") })

    foreach ($item in $archivedItems) {
        if (-not $item.restic_snapshot_id) {
            $issues += @{
                Type = "WARN"
                Message = "Archived item missing snapshot ID: $($item.original_path)"
                ItemId = $item.id
            }
            continue
        }

        $found = $snapshotIds | Where-Object { $item.restic_snapshot_id -like "$_*" -or $_ -like "$($item.restic_snapshot_id)*" }
        if (-not $found) {
            $issues += @{
                Type = "ERROR"
                Message = "Snapshot not found in repository: $($item.restic_snapshot_id) for $($item.original_path)"
                ItemId = $item.id
            }
        }
    }

    # Check for orphaned snapshots (in restic but not in database)
    $dbSnapshotIds = $archivedItems | ForEach-Object { $_.restic_snapshot_id } | Where-Object { $_ }

    foreach ($snap in $Snapshots) {
        $found = $dbSnapshotIds | Where-Object { $snap.short_id -like "$_*" -or $snap.id -like "$_*" -or $_ -like "$($snap.short_id)*" }
        if (-not $found) {
            $issues += @{
                Type = "INFO"
                Message = "Snapshot in repository but not in tracking database: $($snap.short_id) from $($snap.time)"
                SnapshotId = $snap.short_id
            }
        }
    }

    return $issues
}

function Show-VerificationReport {
    <#
    .SYNOPSIS
        Display verification results.
    #>
    param(
        $RepoCheck,
        $DbIssues,
        $SnapshotCount,
        [string]$LogFile
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Verification Report                  " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Repository check results
    Write-Host "--- Repository Integrity ---" -ForegroundColor Yellow
    if ($RepoCheck.Success) {
        Write-Host "Status: PASSED" -ForegroundColor Green
        Write-Log "Repository check passed" -Level "SUCCESS" -LogFile $LogFile
    } else {
        Write-Host "Status: FAILED" -ForegroundColor Red
        Write-Host "Error: $($RepoCheck.Error)" -ForegroundColor Red
        Write-Log "Repository check failed: $($RepoCheck.Error)" -Level "ERROR" -LogFile $LogFile
    }
    Write-Host "Duration: $($RepoCheck.Duration.ToString('mm\:ss'))"
    Write-Host "Snapshots in repository: $SnapshotCount"
    Write-Host ""

    # Database consistency results
    if ($DbIssues -ne $null) {
        Write-Host "--- Database Consistency ---" -ForegroundColor Yellow

        $errors = @($DbIssues | Where-Object { $_.Type -eq "ERROR" })
        $warnings = @($DbIssues | Where-Object { $_.Type -eq "WARN" })
        $info = @($DbIssues | Where-Object { $_.Type -eq "INFO" })

        if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
            Write-Host "Status: PASSED" -ForegroundColor Green
            Write-Log "Database consistency check passed" -Level "SUCCESS" -LogFile $LogFile
        } else {
            Write-Host "Status: ISSUES FOUND" -ForegroundColor Yellow
        }

        Write-Host "Errors: $($errors.Count)"
        Write-Host "Warnings: $($warnings.Count)"
        Write-Host "Info: $($info.Count)"
        Write-Host ""

        if ($errors.Count -gt 0) {
            Write-Host "Errors:" -ForegroundColor Red
            foreach ($err in $errors) {
                Write-Host "  - $($err.Message)" -ForegroundColor Red
                Write-Log $err.Message -Level "ERROR" -LogFile $LogFile
            }
            Write-Host ""
        }

        if ($warnings.Count -gt 0) {
            Write-Host "Warnings:" -ForegroundColor Yellow
            foreach ($warn in $warnings) {
                Write-Host "  - $($warn.Message)" -ForegroundColor Yellow
                Write-Log $warn.Message -Level "WARN" -LogFile $LogFile
            }
            Write-Host ""
        }

        if ($info.Count -gt 0 -and $info.Count -le 10) {
            Write-Host "Info:" -ForegroundColor DarkGray
            foreach ($i in $info) {
                Write-Host "  - $($i.Message)" -ForegroundColor DarkGray
            }
            Write-Host ""
        } elseif ($info.Count -gt 10) {
            Write-Host "Info: $($info.Count) informational messages (not shown)" -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    # Overall status
    Write-Host "--- Overall Status ---" -ForegroundColor Yellow
    $overallPassed = $RepoCheck.Success
    if ($DbIssues -ne $null) {
        $errorCount = @($DbIssues | Where-Object { $_.Type -eq "ERROR" }).Count
        $overallPassed = $overallPassed -and ($errorCount -eq 0)
    }

    if ($overallPassed) {
        Write-Host "VERIFICATION PASSED" -ForegroundColor Green
        Write-Log "Overall verification passed" -Level "SUCCESS" -LogFile $LogFile
    } else {
        Write-Host "VERIFICATION FAILED - Please investigate issues above" -ForegroundColor Red
        Write-Log "Overall verification failed" -Level "ERROR" -LogFile $LogFile
    }
    Write-Host ""
}

#endregion

#region Main Script

function Main {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Cold Storage Archive Verification    " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $defaults = Get-PlatformDefaults

    # Determine config path
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $defaults.ConfigPath
    }

    # Load configuration
    $config = Get-Configuration -ConfigPath $ConfigPath
    Write-Host "Configuration: $ConfigPath"
    Write-Host "Repository: $($config.restic_repository)"
    Write-Host ""

    # Setup logging
    $logFile = Join-Path $config.log_directory "verify_$(Get-Date -Format 'yyyyMMdd').log"
    Write-Log "=== Verification started ===" -LogFile $logFile

    # Set restic environment
    Set-ResticEnvironment -Config $config

    # Determine verification mode
    $readData = $Full -and -not $Quick

    # Run repository check
    $repoCheck = Test-ResticRepository -ReadData $readData

    # Get snapshots
    $snapshots = @()
    try {
        $snapshots = @(Get-ResticSnapshots)
    } catch {
        Write-Host "Warning: Could not list snapshots: $_" -ForegroundColor Yellow
    }

    # Run database consistency check if requested or by default
    $dbIssues = $null
    if ($CheckDatabase -or (-not $Full -and -not $Quick)) {
        try {
            $db = Get-TrackingDatabase -Path $config.tracking_database
            $dbIssues = Test-DatabaseConsistency -Database $db -Snapshots $snapshots
        } catch {
            Write-Host "Warning: Could not check database consistency: $_" -ForegroundColor Yellow
        }
    }

    # Show report
    Show-VerificationReport `
        -RepoCheck $repoCheck `
        -DbIssues $dbIssues `
        -SnapshotCount $snapshots.Count `
        -LogFile $logFile

    Write-Log "=== Verification complete ===" -LogFile $logFile

    # Return exit code
    if ($repoCheck.Success) {
        return 0
    } else {
        return 1
    }
}

# Run main function
try {
    $exitCode = Main
    exit $exitCode
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}

#endregion
