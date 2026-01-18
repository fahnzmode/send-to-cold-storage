<#
.SYNOPSIS
    Query and search archived items in cold storage.

.DESCRIPTION
    This script provides an interface to search and browse items that have been
    archived to S3 Glacier Deep Archive. It queries the local tracking database.

.PARAMETER Search
    Search string to filter by path (supports wildcards).

.PARAMETER Status
    Filter by status: staged, archived, archived_and_deleted, failed, all

.PARAMETER MinSize
    Minimum size filter (e.g., "1GB", "500MB")

.PARAMETER MaxSize
    Maximum size filter (e.g., "10GB", "1TB")

.PARAMETER Since
    Show items archived since this date (e.g., "2024-01-01", "30 days ago")

.PARAMETER Before
    Show items archived before this date.

.PARAMETER Statistics
    Show archive statistics only.

.PARAMETER ExportCsv
    Export results to CSV file.

.PARAMETER ConfigPath
    Path to the configuration file.

.EXAMPLE
    .\Query-ColdStorage.ps1

.EXAMPLE
    .\Query-ColdStorage.ps1 -Search "*2013*"

.EXAMPLE
    .\Query-ColdStorage.ps1 -Status archived_and_deleted -MinSize 1GB

.EXAMPLE
    .\Query-ColdStorage.ps1 -Statistics

.EXAMPLE
    .\Query-ColdStorage.ps1 -ExportCsv "C:\Reports\archived_items.csv"

.NOTES
    Author: Claude Code
#>

[CmdletBinding(DefaultParameterSetName = "Query")]
param(
    [Parameter(ParameterSetName = "Query")]
    [string]$Search,

    [Parameter(ParameterSetName = "Query")]
    [ValidateSet("staged", "archived", "archived_and_deleted", "failed", "all")]
    [string]$Status = "all",

    [Parameter(ParameterSetName = "Query")]
    [string]$MinSize,

    [Parameter(ParameterSetName = "Query")]
    [string]$MaxSize,

    [Parameter(ParameterSetName = "Query")]
    [string]$Since,

    [Parameter(ParameterSetName = "Query")]
    [string]$Before,

    [Parameter(ParameterSetName = "Query")]
    [string]$ExportCsv,

    [Parameter(ParameterSetName = "Stats")]
    [switch]$Statistics,

    [Parameter()]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Helper Functions

function Get-PlatformDefaults {
    if ($IsWindows -or ($PSVersionTable.PSVersion.Major -lt 6)) {
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

function ConvertTo-Bytes {
    <#
    .SYNOPSIS
        Convert size string to bytes (e.g., "1GB" -> 1073741824)
    #>
    param([string]$SizeString)

    if ([string]::IsNullOrWhiteSpace($SizeString)) {
        return $null
    }

    $SizeString = $SizeString.Trim().ToUpper()

    if ($SizeString -match '^(\d+(?:\.\d+)?)\s*(TB|GB|MB|KB|B)?$') {
        $value = [double]$Matches[1]
        $unit = if ($Matches[2]) { $Matches[2] } else { "B" }

        switch ($unit) {
            "TB" { return [long]($value * 1TB) }
            "GB" { return [long]($value * 1GB) }
            "MB" { return [long]($value * 1MB) }
            "KB" { return [long]($value * 1KB) }
            "B"  { return [long]$value }
        }
    }

    throw "Invalid size format: $SizeString. Use format like '1GB', '500MB', '1.5TB'"
}

function Get-TrackingDatabase {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Tracking database not found: $Path"
    }

    Get-Content $Path -Raw | ConvertFrom-Json
}

function Show-Statistics {
    <#
    .SYNOPSIS
        Display archive statistics.
    #>
    param($Database)

    $stats = $Database.statistics
    $archives = @($Database.archives)

    $statusCounts = $archives | Group-Object -Property status | ForEach-Object {
        @{ $_.Name = $_.Count }
    }

    $stagedCount = @($archives | Where-Object { $_.status -eq "staged" }).Count
    $archivedCount = @($archives | Where-Object { $_.status -eq "archived" }).Count
    $deletedCount = @($archives | Where-Object { $_.status -eq "archived_and_deleted" }).Count
    $failedCount = @($archives | Where-Object { $_.status -eq "failed" }).Count

    $stagedItems = @($archives | Where-Object { $_.status -eq "staged" })
    $stagedSize = 0
    if ($stagedItems.Count -gt 0) {
        $stagedSize = ($stagedItems | Measure-Object -Property size_bytes -Sum).Sum
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Cold Storage Statistics              " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Database created: $($Database.created)"
    Write-Host "Database version: $($Database.version)"
    Write-Host ""
    Write-Host "--- Item Counts ---" -ForegroundColor Yellow
    Write-Host "Total items tracked: $($archives.Count)"
    Write-Host "  Staged (pending): $stagedCount"
    Write-Host "  Archived (kept):  $archivedCount"
    Write-Host "  Archived+Deleted: $deletedCount"
    Write-Host "  Failed:           $failedCount"
    Write-Host ""
    Write-Host "--- Storage ---" -ForegroundColor Yellow
    Write-Host "Total archived: $(Format-FileSize $stats.total_archived_bytes)"
    Write-Host "Currently staged: $(Format-FileSize $stagedSize)"
    Write-Host ""
    Write-Host "--- Cost Estimate ---" -ForegroundColor Yellow
    Write-Host "Monthly storage cost: `$$($stats.estimated_monthly_cost_usd) USD"
    Write-Host "(Based on S3 Glacier Deep Archive at ~`$1/TB/month)"
    Write-Host ""
    if ($stats.last_archive_date) {
        Write-Host "Last archive date: $($stats.last_archive_date)"
    }
    Write-Host ""
}

function Search-Archives {
    <#
    .SYNOPSIS
        Search and filter archived items.
    #>
    param(
        [array]$Archives,
        [string]$Search,
        [string]$Status,
        [Nullable[long]]$MinSizeBytes,
        [Nullable[long]]$MaxSizeBytes,
        [Nullable[datetime]]$SinceDate,
        [Nullable[datetime]]$BeforeDate
    )

    $results = $Archives

    # Filter by status
    if ($Status -ne "all") {
        $results = $results | Where-Object { $_.status -eq $Status }
    }

    # Filter by search term
    if ($Search) {
        $results = $results | Where-Object {
            $_.original_path -like $Search -or
            $_.staged_path -like $Search -or
            $_.notes -like $Search
        }
    }

    # Filter by size
    if ($MinSizeBytes) {
        $results = $results | Where-Object { $_.size_bytes -ge $MinSizeBytes }
    }
    if ($MaxSizeBytes) {
        $results = $results | Where-Object { $_.size_bytes -le $MaxSizeBytes }
    }

    # Filter by date
    if ($SinceDate) {
        $results = $results | Where-Object {
            $date = if ($_.archived_date) { [datetime]$_.archived_date } else { [datetime]$_.staged_date }
            $date -ge $SinceDate
        }
    }
    if ($BeforeDate) {
        $results = $results | Where-Object {
            $date = if ($_.archived_date) { [datetime]$_.archived_date } else { [datetime]$_.staged_date }
            $date -le $BeforeDate
        }
    }

    return $results
}

function Show-Results {
    <#
    .SYNOPSIS
        Display search results in a formatted table.
    #>
    param([array]$Results)

    if ($Results.Count -eq 0) {
        Write-Host "No items found matching the criteria." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Found $($Results.Count) item(s):" -ForegroundColor Cyan
    Write-Host ""

    $i = 1
    foreach ($item in $Results) {
        $statusColor = switch ($item.status) {
            "staged" { "Yellow" }
            "archived" { "Green" }
            "archived_and_deleted" { "Cyan" }
            "failed" { "Red" }
            default { "White" }
        }

        Write-Host "[$i] " -NoNewline -ForegroundColor DarkGray
        Write-Host $item.original_path -ForegroundColor White
        Write-Host "    Status: " -NoNewline
        Write-Host $item.status -ForegroundColor $statusColor
        Write-Host "    Size: $(Format-FileSize $item.size_bytes), Files: $($item.file_count)"

        if ($item.archived_date) {
            Write-Host "    Archived: $($item.archived_date)"
        } else {
            Write-Host "    Staged: $($item.staged_date)"
        }

        if ($item.restic_snapshot_id) {
            Write-Host "    Snapshot: $($item.restic_snapshot_id)" -ForegroundColor DarkGray
        }

        if ($item.notes) {
            Write-Host "    Notes: $($item.notes)" -ForegroundColor DarkGray
        }

        Write-Host "    ID: $($item.id)" -ForegroundColor DarkGray
        Write-Host ""
        $i++
    }
}

function Export-ToCsv {
    <#
    .SYNOPSIS
        Export results to CSV file.
    #>
    param(
        [array]$Results,
        [string]$Path
    )

    $exportData = $Results | ForEach-Object {
        [PSCustomObject]@{
            ID = $_.id
            OriginalPath = $_.original_path
            StagedPath = $_.staged_path
            Status = $_.status
            SizeBytes = $_.size_bytes
            SizeFormatted = Format-FileSize $_.size_bytes
            FileCount = $_.file_count
            StagedDate = $_.staged_date
            ArchivedDate = $_.archived_date
            DeletedDate = $_.deleted_date
            SnapshotId = $_.restic_snapshot_id
            Notes = $_.notes
        }
    }

    $exportData | Export-Csv -Path $Path -NoTypeInformation
    Write-Host "Exported $($Results.Count) items to: $Path" -ForegroundColor Green
}

function Show-InteractiveMenu {
    <#
    .SYNOPSIS
        Show interactive menu for querying.
    #>
    param($Database)

    while ($true) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  Cold Storage Query Menu              " -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Show all archived items"
        Write-Host "2. Show staged items (pending archival)"
        Write-Host "3. Search by path"
        Write-Host "4. Show statistics"
        Write-Host "5. Show large items (>1GB)"
        Write-Host "6. Export all to CSV"
        Write-Host "Q. Quit"
        Write-Host ""

        $choice = Read-Host "Select option"

        switch ($choice.ToUpper()) {
            "1" {
                $results = $Database.archives | Where-Object { $_.status -in @("archived", "archived_and_deleted") }
                Show-Results -Results $results
            }
            "2" {
                $results = $Database.archives | Where-Object { $_.status -eq "staged" }
                Show-Results -Results $results
            }
            "3" {
                $searchTerm = Read-Host "Enter search term (supports wildcards like *2013*)"
                $results = Search-Archives -Archives $Database.archives -Search $searchTerm -Status "all"
                Show-Results -Results $results
            }
            "4" {
                Show-Statistics -Database $Database
            }
            "5" {
                $results = Search-Archives -Archives $Database.archives -Status "all" -MinSizeBytes 1GB
                Show-Results -Results ($results | Sort-Object -Property size_bytes -Descending)
            }
            "6" {
                $exportPath = Read-Host "Export path (default: cold_storage_export.csv)"
                if ([string]::IsNullOrWhiteSpace($exportPath)) {
                    $exportPath = "cold_storage_export.csv"
                }
                Export-ToCsv -Results $Database.archives -Path $exportPath
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

    # Load tracking database
    $db = Get-TrackingDatabase -Path $config.tracking_database

    # Statistics mode
    if ($Statistics) {
        Show-Statistics -Database $db
        return
    }

    # Parse size filters
    $minSizeBytes = $null
    $maxSizeBytes = $null
    if ($MinSize) {
        $minSizeBytes = ConvertTo-Bytes $MinSize
    }
    if ($MaxSize) {
        $maxSizeBytes = ConvertTo-Bytes $MaxSize
    }

    # Parse date filters
    $sinceDate = $null
    $beforeDate = $null
    if ($Since) {
        $sinceDate = [datetime]::Parse($Since)
    }
    if ($Before) {
        $beforeDate = [datetime]::Parse($Before)
    }

    # If no search parameters, show interactive menu
    if (-not $Search -and $Status -eq "all" -and -not $MinSize -and -not $MaxSize -and -not $Since -and -not $Before -and -not $ExportCsv) {
        Show-InteractiveMenu -Database $db
        return
    }

    # Search with provided parameters
    $results = Search-Archives `
        -Archives $db.archives `
        -Search $Search `
        -Status $Status `
        -MinSizeBytes $minSizeBytes `
        -MaxSizeBytes $maxSizeBytes `
        -SinceDate $sinceDate `
        -BeforeDate $beforeDate

    # Export or display
    if ($ExportCsv) {
        Export-ToCsv -Results $results -Path $ExportCsv
    } else {
        Show-Results -Results $results
    }
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
