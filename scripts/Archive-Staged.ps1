<#
.SYNOPSIS
    Archive staged files to S3 Glacier Deep Archive using restic.

.DESCRIPTION
    This script performs the archival workflow:
    1. Scans the staging folder for items to archive
    2. Creates a restic snapshot
    3. Verifies the backup integrity
    4. Updates the tracking database
    5. Optionally deletes staged files after verification

.PARAMETER ConfigPath
    Path to the configuration file. If not specified, uses default location.

.PARAMETER Tag
    Optional tag for the restic snapshot.

.PARAMETER Notes
    Optional notes to add to the tracking database entries.

.PARAMETER NoDelete
    Skip deletion of staged files after successful archival.

.PARAMETER DryRun
    Show what would be archived without actually archiving.

.EXAMPLE
    .\Archive-Staged.ps1

.EXAMPLE
    .\Archive-Staged.ps1 -Tag "2024-videos" -Notes "Old video projects from 2024"

.EXAMPLE
    .\Archive-Staged.ps1 -NoDelete -DryRun

.NOTES
    Author: Claude Code
    Requires: restic, AWS CLI, configured cold-storage profile
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Tag,

    [Parameter()]
    [string]$Notes,

    [Parameter()]
    [switch]$NoDelete,

    [Parameter()]
    [switch]$DryRun
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

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

function Get-StagedItems {
    <#
    .SYNOPSIS
        Get list of items in staging folder and their tracking info.
    #>
    param(
        [string]$StagingRoot,
        [string]$TrackingDbPath
    )

    $db = Get-Content $TrackingDbPath -Raw | ConvertFrom-Json
    $stagedEntries = $db.archives | Where-Object { $_.status -eq "staged" }

    $results = @()
    foreach ($entry in $stagedEntries) {
        if (Test-Path $entry.staged_path) {
            $results += $entry
        }
    }

    return $results
}

function Set-ResticEnvironment {
    <#
    .SYNOPSIS
        Set environment variables for restic.
    #>
    param($Config)

    $env:AWS_PROFILE = $Config.aws_profile
    $env:RESTIC_REPOSITORY = $Config.restic_repository
    $env:RESTIC_PASSWORD_FILE = $Config.restic_password_file

    # Set script-level restic path
    $script:ResticExe = if ($Config.restic_executable) { $Config.restic_executable } else { "restic" }
}

function Invoke-ResticBackup {
    <#
    .SYNOPSIS
        Run restic backup on the staging folder.
    #>
    param(
        [string]$StagingRoot,
        [string]$Tag
    )

    $args = @("backup", $StagingRoot, "--json")

    if ($Tag) {
        $args += "--tag"
        $args += $Tag
    }

    # Add timestamp tag
    $args += "--tag"
    $args += "archive-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    Write-Host "Running: $script:ResticExe $($args -join ' ')"

    $output = & $script:ResticExe @args 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "restic backup failed: $output"
    }

    # Parse JSON output to get snapshot ID
    $lines = $output -split "`n"
    foreach ($line in $lines) {
        if ($line -match '"snapshot_id"') {
            try {
                $json = $line | ConvertFrom-Json
                if ($json.snapshot_id) {
                    return $json.snapshot_id
                }
            } catch {
                # Continue looking
            }
        }
    }

    # If we can't parse the snapshot ID from output, get the latest
    $snapshots = & $script:ResticExe snapshots --json --latest 1 2>&1 | ConvertFrom-Json
    if ($snapshots -and $snapshots.Count -gt 0) {
        return $snapshots[0].id
    }

    throw "Could not determine snapshot ID after backup"
}

function Test-ResticBackup {
    <#
    .SYNOPSIS
        Verify the restic repository integrity.
    #>
    param([string]$SnapshotId)

    Write-Host "Verifying backup integrity..."

    # Quick check - verify repository structure
    $result = & $script:ResticExe check 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Repository check output: $result" -ForegroundColor Yellow
        return $false
    }

    # Verify the specific snapshot exists
    $snapshots = & $script:ResticExe snapshots --json 2>&1 | ConvertFrom-Json
    $found = $snapshots | Where-Object { $_.id -like "$SnapshotId*" -or $_.short_id -eq $SnapshotId }

    if (-not $found) {
        Write-Host "Snapshot $SnapshotId not found in repository" -ForegroundColor Red
        return $false
    }

    return $true
}

function Update-TrackingDatabaseArchived {
    <#
    .SYNOPSIS
        Update tracking database entries to archived status.
    #>
    param(
        [string]$TrackingDbPath,
        [array]$EntryIds,
        [string]$SnapshotId,
        [string]$Notes,
        [bool]$Deleted
    )

    $db = Get-Content $TrackingDbPath -Raw | ConvertFrom-Json
    $now = (Get-Date).ToString("o")

    foreach ($id in $EntryIds) {
        $entry = $db.archives | Where-Object { $_.id -eq $id }
        if ($entry) {
            $entry.archived_date = $now
            $entry.restic_snapshot_id = $SnapshotId
            if ($Deleted) {
                $entry.deleted_date = $now
                $entry.status = "archived_and_deleted"
            } else {
                $entry.status = "archived"
            }
            if ($Notes) {
                $entry.notes = $Notes
            }
        }
    }

    # Update statistics
    $archivedItems = $db.archives | Where-Object { $_.status -in @("archived", "archived_and_deleted") }
    $totalBytes = ($archivedItems | Measure-Object -Property size_bytes -Sum).Sum
    if (-not $totalBytes) { $totalBytes = 0 }

    $db.statistics.total_archived_bytes = $totalBytes
    $db.statistics.total_items = $archivedItems.Count
    $db.statistics.last_archive_date = $now
    # Glacier Deep Archive cost: ~$0.00099/GB/month = ~$1/TB/month
    $db.statistics.estimated_monthly_cost_usd = [math]::Round($totalBytes / 1TB * 1.0, 2)

    $db | ConvertTo-Json -Depth 10 | Out-File -FilePath $TrackingDbPath -Encoding UTF8
}

function Remove-StagedItems {
    <#
    .SYNOPSIS
        Delete staged items after successful archival.
    #>
    param(
        [array]$Entries,
        [string]$LogFile
    )

    foreach ($entry in $Entries) {
        if (Test-Path $entry.staged_path) {
            try {
                Remove-Item -Path $entry.staged_path -Recurse -Force
                Write-Log "Deleted: $($entry.staged_path)" -Level "SUCCESS" -LogFile $LogFile
            } catch {
                Write-Log "Failed to delete: $($entry.staged_path) - $_" -Level "ERROR" -LogFile $LogFile
            }
        }
    }

    # Clean up empty directories in staging root
    # (Walk up from deleted items and remove empty parents)
}

function Show-Summary {
    <#
    .SYNOPSIS
        Display archival summary.
    #>
    param(
        [array]$Entries,
        [string]$SnapshotId,
        [bool]$Deleted
    )

    $totalSize = ($Entries | Measure-Object -Property size_bytes -Sum).Sum
    $totalFiles = ($Entries | Measure-Object -Property file_count -Sum).Sum
    $monthlyCost = [math]::Round($totalSize / 1TB * 1.0, 2)

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Archival Complete!                   " -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Snapshot ID: $SnapshotId"
    Write-Host "Items archived: $($Entries.Count)"
    Write-Host "Total files: $totalFiles"
    Write-Host "Total size: $(Format-FileSize $totalSize)"
    Write-Host "Estimated monthly cost: `$$monthlyCost"
    Write-Host ""
    if ($Deleted) {
        Write-Host "Staged files have been deleted." -ForegroundColor Yellow
    } else {
        Write-Host "Staged files have been kept (use -NoDelete was specified or delete manually)." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "View archived items: .\Query-ColdStorage.ps1"
    Write-Host "Restore items: .\Restore-FromColdStorage.ps1"
    Write-Host ""
}

#endregion

#region Main Script

function Main {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Cold Storage Archive                 " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $defaults = Get-PlatformDefaults

    # Determine config path
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $defaults.ConfigPath
    }

    # Load configuration
    $config = Get-Configuration -ConfigPath $ConfigPath
    Write-Host "Configuration loaded from: $ConfigPath"
    Write-Host "Repository: $($config.restic_repository)"
    Write-Host ""

    # Setup logging
    $logFile = Join-Path $config.log_directory "archive_$(Get-Date -Format 'yyyyMMdd').log"
    Write-Log "=== Archive operation started ===" -LogFile $logFile

    # Set restic environment
    Set-ResticEnvironment -Config $config

    # Get staged items
    Write-Host "Scanning staging folder..."
    $stagedItems = Get-StagedItems -StagingRoot $config.staging_root -TrackingDbPath $config.tracking_database

    if ($stagedItems.Count -eq 0) {
        Write-Host "No items to archive in staging folder." -ForegroundColor Yellow
        Write-Log "No items to archive" -LogFile $logFile
        return
    }

    # Display items to be archived
    $totalSize = ($stagedItems | Measure-Object -Property size_bytes -Sum).Sum
    $totalFiles = ($stagedItems | Measure-Object -Property file_count -Sum).Sum

    Write-Host ""
    Write-Host "Items to archive:" -ForegroundColor Cyan
    foreach ($item in $stagedItems) {
        Write-Host "  - $($item.original_path)"
        Write-Host "    Staged: $($item.staged_path)"
        Write-Host "    Size: $(Format-FileSize $item.size_bytes), Files: $($item.file_count)"
    }
    Write-Host ""
    Write-Host "Total: $($stagedItems.Count) items, $(Format-FileSize $totalSize), $totalFiles files"
    Write-Host ""

    if ($DryRun) {
        Write-Host "[DRY RUN] Would archive the above items. No changes made." -ForegroundColor Yellow
        return
    }

    # Confirm
    $response = Read-Host "Proceed with archival? [y/N]"
    if ($response -ne "y" -and $response -ne "Y") {
        Write-Host "Archival cancelled."
        Write-Log "Archival cancelled by user" -LogFile $logFile
        return
    }

    # Perform backup
    Write-Host ""
    Write-Host "Creating restic backup..." -ForegroundColor Cyan
    Write-Log "Starting restic backup" -LogFile $logFile

    try {
        $snapshotId = Invoke-ResticBackup -StagingRoot $config.staging_root -Tag $Tag
        Write-Log "Backup complete. Snapshot: $snapshotId" -Level "SUCCESS" -LogFile $logFile
        Write-Host "Backup complete. Snapshot: $snapshotId" -ForegroundColor Green
    } catch {
        Write-Log "Backup failed: $_" -Level "ERROR" -LogFile $logFile
        throw "Backup failed: $_"
    }

    # Verify backup
    Write-Host ""
    Write-Host "Verifying backup..." -ForegroundColor Cyan
    Write-Log "Verifying backup" -LogFile $logFile

    $verified = Test-ResticBackup -SnapshotId $snapshotId
    if (-not $verified) {
        Write-Log "Verification FAILED - not deleting staged files" -Level "ERROR" -LogFile $logFile
        Write-Host "VERIFICATION FAILED!" -ForegroundColor Red
        Write-Host "Staged files have NOT been deleted." -ForegroundColor Yellow
        Write-Host "Please investigate and re-run the archive."
        throw "Backup verification failed"
    }

    Write-Log "Verification passed" -Level "SUCCESS" -LogFile $logFile
    Write-Host "Verification passed!" -ForegroundColor Green

    # Update tracking database
    Write-Host ""
    Write-Host "Updating tracking database..." -ForegroundColor Cyan
    $entryIds = $stagedItems | ForEach-Object { $_.id }
    $shouldDelete = -not $NoDelete

    Update-TrackingDatabaseArchived `
        -TrackingDbPath $config.tracking_database `
        -EntryIds $entryIds `
        -SnapshotId $snapshotId `
        -Notes $Notes `
        -Deleted $shouldDelete

    Write-Log "Tracking database updated" -Level "SUCCESS" -LogFile $logFile

    # Delete staged files if verification passed and -NoDelete not specified
    if ($shouldDelete) {
        Write-Host ""
        Write-Host "Deleting staged files..." -ForegroundColor Cyan
        Remove-StagedItems -Entries $stagedItems -LogFile $logFile
    }

    # Show summary
    Show-Summary -Entries $stagedItems -SnapshotId $snapshotId -Deleted $shouldDelete

    Write-Log "=== Archive operation complete ===" -LogFile $logFile
}

# Run main function
try {
    Main
    exit 0
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}

#endregion
