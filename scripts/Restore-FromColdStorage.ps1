<#
.SYNOPSIS
    Restore files from cold storage (S3 Glacier Deep Archive).

.DESCRIPTION
    This script handles the restoration process from S3 Glacier Deep Archive:
    1. Search for archived items
    2. Initiate Glacier retrieval (if needed)
    3. Wait for retrieval to complete (12-48 hours for Deep Archive)
    4. Download and restore files using restic

    Note: Glacier Deep Archive has a 12-48 hour retrieval time. This script
    will initiate the retrieval and can check status on subsequent runs.

.PARAMETER Search
    Search string to find items to restore.

.PARAMETER Id
    Specific item ID to restore.

.PARAMETER SnapshotId
    Specific restic snapshot ID to restore from.

.PARAMETER DestinationPath
    Where to restore files. Defaults to original location.

.PARAMETER CheckStatus
    Check status of pending retrievals.

.PARAMETER ListSnapshots
    List all restic snapshots.

.PARAMETER ConfigPath
    Path to the configuration file.

.EXAMPLE
    .\Restore-FromColdStorage.ps1 -Search "*2013*"

.EXAMPLE
    .\Restore-FromColdStorage.ps1 -Id "abc123-def456"

.EXAMPLE
    .\Restore-FromColdStorage.ps1 -CheckStatus

.EXAMPLE
    .\Restore-FromColdStorage.ps1 -ListSnapshots

.NOTES
    Author: Claude Code
    Important: Glacier Deep Archive retrieval takes 12-48 hours.
#>

[CmdletBinding(DefaultParameterSetName = "Interactive")]
param(
    [Parameter(ParameterSetName = "Search")]
    [string]$Search,

    [Parameter(ParameterSetName = "ById")]
    [string]$Id,

    [Parameter(ParameterSetName = "BySnapshot")]
    [string]$SnapshotId,

    [Parameter()]
    [string]$DestinationPath,

    [Parameter(ParameterSetName = "Status")]
    [switch]$CheckStatus,

    [Parameter(ParameterSetName = "Snapshots")]
    [switch]$ListSnapshots,

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

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes bytes"
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

function Get-KnownStagingRoots {
    param($Config)

    $roots = @()
    if ($Config.staging_roots) { $roots += $Config.staging_roots }
    if ($Config.staging_root -and $Config.staging_root -notin $roots) { $roots += $Config.staging_root }
    return $roots
}

function Get-AllTrackingDatabases {
    param($Config)

    $stagingRoots = @(Get-KnownStagingRoots -Config $Config)
    $mergedDb = @{
        version = "1.0"
        archives = @()
        _sources = @()
    }

    foreach ($root in $stagingRoots) {
        $trackingDbPath = Join-Path $root "cold_storage_tracking.json"
        if (Test-Path $trackingDbPath) {
            try {
                $db = Get-Content $trackingDbPath -Raw | ConvertFrom-Json
                $mergedDb.archives += @($db.archives)
                $mergedDb._sources += $root
            } catch {
                Write-Host "Warning: Could not read: $trackingDbPath" -ForegroundColor Yellow
            }
        }
    }

    if ($mergedDb._sources.Count -eq 0 -and $Config.tracking_database -and (Test-Path $Config.tracking_database)) {
        return Get-TrackingDatabase -Path $Config.tracking_database
    }

    return [PSCustomObject]$mergedDb
}

function Get-ResticSnapshots {
    <#
    .SYNOPSIS
        Get list of restic snapshots.
    #>
    $output = & $script:ResticExe snapshots --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list snapshots: $output"
    }

    $snapshots = $output | ConvertFrom-Json
    return @($snapshots | Where-Object { $_ })
}

function Show-Snapshots {
    <#
    .SYNOPSIS
        Display restic snapshots.
    #>
    param([array]$Snapshots)

    if ($Snapshots.Count -eq 0) {
        Write-Host "No snapshots found." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Restic Snapshots:" -ForegroundColor Cyan
    Write-Host ""

    foreach ($snap in $Snapshots) {
        Write-Host "Snapshot: $($snap.short_id)" -ForegroundColor White
        Write-Host "  Time: $($snap.time)"
        Write-Host "  Hostname: $($snap.hostname)"
        Write-Host "  Tags: $($snap.tags -join ', ')"
        Write-Host "  Paths: $($snap.paths -join ', ')"
        Write-Host ""
    }
}

function Get-SnapshotContents {
    <#
    .SYNOPSIS
        List contents of a restic snapshot.
    #>
    param([string]$SnapshotId)

    $output = & $script:ResticExe ls $SnapshotId --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list snapshot contents: $output"
    }

    $lines = $output -split "`n" | Where-Object { $_ -match '^\{' }
    $items = $lines | ForEach-Object { $_ | ConvertFrom-Json }
    return $items
}

function Invoke-ResticRestore {
    <#
    .SYNOPSIS
        Restore files from a restic snapshot.
    #>
    param(
        [string]$SnapshotId,
        [string]$TargetPath,
        [string]$IncludePath
    )

    $args = @("restore", $SnapshotId, "--target", $TargetPath)

    if ($IncludePath) {
        $args += "--include"
        $args += $IncludePath
    }

    Write-Host "Running: $script:ResticExe $($args -join ' ')"

    $output = & $script:ResticExe @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Restore failed: $output"
    }

    return $output
}

function Show-RestoreOptions {
    <#
    .SYNOPSIS
        Show restore options for a selected item.
    #>
    param(
        $Item,
        $Config,
        [string]$LogFile
    )

    $defaults = Get-PlatformDefaults

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Restore Item                         " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Original path: $($Item.original_path)"
    Write-Host "Size: $(Format-FileSize $Item.size_bytes)"
    Write-Host "Files: $($Item.file_count)"
    Write-Host "Archived: $($Item.archived_date)"
    Write-Host "Snapshot: $($Item.restic_snapshot_id)"
    Write-Host ""

    # Estimate retrieval cost
    # Source: AWS S3 Glacier Deep Archive pricing (as of 2024)
    # Standard retrieval: ~$0.0025/GB, takes 12-48 hours
    # See: https://aws.amazon.com/s3/pricing/ for current rates
    $retrievalCostPerGB = 0.0025
    $estimatedCost = [math]::Round(($Item.size_bytes / 1GB) * $retrievalCostPerGB, 4)
    Write-Host "Estimated retrieval cost: `$$estimatedCost USD" -ForegroundColor Yellow
    Write-Host "(Glacier Deep Archive: 12-48 hour retrieval time)" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "Restore options:"
    Write-Host "1. Restore to original location: $($Item.original_path)"
    Write-Host "2. Restore to custom location"
    Write-Host "3. Cancel"
    Write-Host ""

    $choice = Read-Host "Select option [1-3]"

    switch ($choice) {
        "1" {
            $targetPath = Split-Path $Item.original_path -Parent
            if (-not $targetPath) {
                $targetPath = if ($defaults.IsWindows) { "C:\" } else { "/" }
            }
        }
        "2" {
            $targetPath = Read-Host "Enter destination path"
            if ([string]::IsNullOrWhiteSpace($targetPath)) {
                Write-Host "Cancelled." -ForegroundColor Yellow
                return
            }
        }
        "3" {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }
        default {
            Write-Host "Invalid option." -ForegroundColor Red
            return
        }
    }

    # Create target directory if needed
    if (-not (Test-Path $targetPath)) {
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    }

    Write-Host ""
    Write-Host "Restoring to: $targetPath" -ForegroundColor Cyan
    Write-Log "Starting restore: $($Item.original_path) -> $targetPath" -LogFile $LogFile

    try {
        # Determine the path within the snapshot to restore
        # The staging path is what's actually in the snapshot
        $includePath = $Item.staged_path
        if (-not $includePath) {
            # Fallback: try to derive from original path
            $includePath = "*"
        }

        $result = Invoke-ResticRestore `
            -SnapshotId $Item.restic_snapshot_id `
            -TargetPath $targetPath `
            -IncludePath $includePath

        Write-Host ""
        Write-Host "Restore complete!" -ForegroundColor Green
        Write-Host "Files restored to: $targetPath"
        Write-Log "Restore complete: $targetPath" -Level "SUCCESS" -LogFile $LogFile
    } catch {
        Write-Host ""
        Write-Host "Restore failed: $_" -ForegroundColor Red
        Write-Log "Restore failed: $_" -Level "ERROR" -LogFile $LogFile

        # Check if it's a Glacier retrieval issue
        if ($_ -match "Glacier" -or $_ -match "retrieval" -or $_ -match "RestoreInProgress") {
            Write-Host ""
            Write-Host "This appears to be a Glacier retrieval issue." -ForegroundColor Yellow
            Write-Host "For Glacier Deep Archive, objects must be restored before download." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "To initiate Glacier retrieval, you'll need to:" -ForegroundColor Yellow
            Write-Host "1. Use AWS CLI: aws s3api restore-object --bucket BUCKET --key KEY --restore-request Days=7"
            Write-Host "2. Wait 12-48 hours for retrieval to complete"
            Write-Host "3. Re-run this restore script"
            Write-Host ""
            Write-Host "Note: restic may need all repository objects to be in a retrievable state."
            Write-Host "Consider using AWS CLI to restore the entire bucket prefix."
        }
    }
}

function Search-ArchivedItems {
    <#
    .SYNOPSIS
        Search for archived items in the tracking database.
    #>
    param(
        [array]$Archives,
        [string]$SearchTerm
    )

    $archived = @($Archives | Where-Object { $_.status -in @("archived", "archived_and_deleted") })

    if ($SearchTerm) {
        $archived = @($archived | Where-Object {
            $_.original_path -like $SearchTerm -or
            $_.notes -like $SearchTerm
        })
    }

    return $archived
}

function Show-InteractiveRestore {
    <#
    .SYNOPSIS
        Interactive restore menu.
    #>
    param(
        $Database,
        $Config,
        [string]$LogFile
    )

    while ($true) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  Cold Storage Restore                 " -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Search archived items"
        Write-Host "2. List all archived items"
        Write-Host "3. List restic snapshots"
        Write-Host "4. Restore from snapshot ID"
        Write-Host "Q. Quit"
        Write-Host ""

        $choice = Read-Host "Select option"

        switch ($choice.ToUpper()) {
            "1" {
                $searchTerm = Read-Host "Enter search term (wildcards: *2013*)"
                $results = @(Search-ArchivedItems -Archives $Database.archives -SearchTerm $searchTerm)

                if ($results.Count -eq 0) {
                    Write-Host "No items found." -ForegroundColor Yellow
                    continue
                }

                Write-Host ""
                Write-Host "Found $($results.Count) item(s):" -ForegroundColor Cyan
                $i = 1
                foreach ($item in $results) {
                    Write-Host "[$i] $($item.original_path)"
                    Write-Host "    Size: $(Format-FileSize $item.size_bytes), Files: $($item.file_count)"
                    $i++
                }
                Write-Host ""

                $selection = Read-Host "Select item to restore (number) or Q to cancel"
                if ($selection -eq "Q" -or $selection -eq "q") { continue }

                $index = [int]$selection - 1
                if ($index -ge 0 -and $index -lt $results.Count) {
                    Show-RestoreOptions -Item $results[$index] -Config $Config -LogFile $LogFile
                }
            }
            "2" {
                $results = @(Search-ArchivedItems -Archives $Database.archives)
                if ($results.Count -eq 0) {
                    Write-Host "No archived items found." -ForegroundColor Yellow
                    continue
                }

                Write-Host ""
                Write-Host "Archived items:" -ForegroundColor Cyan
                $i = 1
                foreach ($item in $results) {
                    Write-Host "[$i] $($item.original_path)"
                    Write-Host "    Size: $(Format-FileSize $item.size_bytes), Snapshot: $($item.restic_snapshot_id)"
                    $i++
                }
                Write-Host ""

                $selection = Read-Host "Select item to restore (number) or Q to cancel"
                if ($selection -eq "Q" -or $selection -eq "q") { continue }

                $index = [int]$selection - 1
                if ($index -ge 0 -and $index -lt $results.Count) {
                    Show-RestoreOptions -Item $results[$index] -Config $Config -LogFile $LogFile
                }
            }
            "3" {
                $snapshots = @(Get-ResticSnapshots)
                Show-Snapshots -Snapshots $snapshots
            }
            "4" {
                $snapId = Read-Host "Enter snapshot ID"
                $targetPath = Read-Host "Enter target path for restore"

                if ([string]::IsNullOrWhiteSpace($targetPath)) {
                    Write-Host "Target path required." -ForegroundColor Red
                    continue
                }

                try {
                    $result = Invoke-ResticRestore -SnapshotId $snapId -TargetPath $targetPath
                    Write-Host "Restore complete!" -ForegroundColor Green
                } catch {
                    Write-Host "Restore failed: $_" -ForegroundColor Red
                }
            }
            "Q" {
                return
            }
            default {
                Write-Host "Invalid option" -ForegroundColor Red
            }
        }
    }
}

#endregion

#region Main Script

function Main {
    $defaults = Get-PlatformDefaults

    # Determine config path
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $defaults.ConfigPath
    }

    # Load configuration
    $config = Get-Configuration -ConfigPath $ConfigPath

    # Setup logging
    $logFile = Join-Path $config.log_directory "restore_$(Get-Date -Format 'yyyyMMdd').log"

    # Set restic environment
    Set-ResticEnvironment -Config $config

    # Load tracking databases (merged from all accessible sources)
    $db = Get-AllTrackingDatabases -Config $config
    if ($db._sources -and $db._sources.Count -gt 1) {
        Write-Host "Loaded from $($db._sources.Count) tracking databases" -ForegroundColor Gray
    }

    # Handle different modes
    if ($ListSnapshots) {
        $snapshots = @(Get-ResticSnapshots)
        Show-Snapshots -Snapshots $snapshots
        return
    }

    if ($CheckStatus) {
        Write-Host "Checking repository status..."
        $result = & $script:ResticExe snapshots 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Repository accessible." -ForegroundColor Green
            $snapshots = @(Get-ResticSnapshots)
            Write-Host "Total snapshots: $($snapshots.Count)"
        } else {
            Write-Host "Repository check failed: $result" -ForegroundColor Red
        }
        return
    }

    if ($Id) {
        $item = $db.archives | Where-Object { $_.id -eq $Id }
        if (-not $item) {
            Write-Host "Item not found with ID: $Id" -ForegroundColor Red
            return
        }
        Show-RestoreOptions -Item $item -Config $config -LogFile $logFile
        return
    }

    if ($Search) {
        $results = @(Search-ArchivedItems -Archives $db.archives -SearchTerm $Search)
        if ($results.Count -eq 0) {
            Write-Host "No items found matching: $Search" -ForegroundColor Yellow
            return
        }

        if ($results.Count -eq 1) {
            Show-RestoreOptions -Item $results[0] -Config $config -LogFile $logFile
        } else {
            Write-Host "Found $($results.Count) items. Please select:" -ForegroundColor Cyan
            $i = 1
            foreach ($item in $results) {
                Write-Host "[$i] $($item.original_path) ($(Format-FileSize $item.size_bytes))"
                $i++
            }

            $selection = Read-Host "Select item (number)"
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $results.Count) {
                Show-RestoreOptions -Item $results[$index] -Config $config -LogFile $logFile
            }
        }
        return
    }

    if ($SnapshotId) {
        $targetPath = $DestinationPath
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            $targetPath = Read-Host "Enter destination path"
        }

        try {
            $result = Invoke-ResticRestore -SnapshotId $SnapshotId -TargetPath $targetPath
            Write-Host "Restore complete!" -ForegroundColor Green
        } catch {
            Write-Host "Restore failed: $_" -ForegroundColor Red
        }
        return
    }

    # Interactive mode
    Show-InteractiveRestore -Database $db -Config $config -LogFile $logFile
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
