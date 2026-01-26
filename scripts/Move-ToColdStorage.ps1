<#
.SYNOPSIS
    Move files/folders to cold storage staging area.

.DESCRIPTION
    This script moves selected files or folders to the staging area while preserving
    the original directory structure. This is the first step in the archival process.

    Files are moved (not copied) to save disk space. The staging area preserves the
    full path structure so files can be restored to their original locations.

.PARAMETER Paths
    One or more file or folder paths to stage for archival.

.PARAMETER ConfigPath
    Path to the configuration file. If not specified, uses default location.

.PARAMETER NoConfirm
    Skip confirmation prompt.

.EXAMPLE
    .\Move-ToColdStorage.ps1 -Paths "D:\Projects\OldProject"

.EXAMPLE
    .\Move-ToColdStorage.ps1 -Paths "D:\Videos\2013", "D:\Videos\2014" -NoConfirm

.EXAMPLE
    # Called from Windows context menu:
    .\Move-ToColdStorage.ps1 -Paths "%1"

.NOTES
    Author: Claude Code
    This script is designed to be called from Windows Explorer context menu.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Paths,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [switch]$NoConfirm
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

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    return $config
}

function Get-RelativePath {
    <#
    .SYNOPSIS
        Get the path relative to the drive root (strips drive letter on Windows).
    #>
    param([string]$FullPath)

    $defaults = Get-PlatformDefaults

    if ($defaults.IsWindows) {
        # Remove drive letter (e.g., "C:\Users\..." -> "Users\...")
        if ($FullPath -match '^[A-Za-z]:(.+)$') {
            return $Matches[1].TrimStart('\', '/')
        }
    } else {
        # Remove leading slash for Linux paths
        return $FullPath.TrimStart('/')
    }

    return $FullPath
}

function Get-DriveLetter {
    <#
    .SYNOPSIS
        Extract drive letter from a Windows path.
    #>
    param([string]$Path)

    if ($Path -match '^([A-Za-z]):') {
        return $Matches[1].ToUpper()
    }
    return $null
}

function Get-ItemDetails {
    <#
    .SYNOPSIS
        Get size and file count for a file or folder.
    #>
    param([string]$Path)

    if (Test-Path $Path -PathType Leaf) {
        $item = Get-Item $Path
        return @{
            SizeBytes = $item.Length
            FileCount = 1
            IsFile = $true
        }
    } else {
        $items = Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue
        $totalSize = ($items | Measure-Object -Property Length -Sum).Sum
        return @{
            SizeBytes = if ($totalSize) { $totalSize } else { 0 }
            FileCount = $items.Count
            IsFile = $false
        }
    }
}

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

function Show-Confirmation {
    <#
    .SYNOPSIS
        Show confirmation dialog (console or GUI based on platform).
    #>
    param(
        [string]$Title,
        [string]$Message,
        [bool]$IsWindows
    )

    if ($IsWindows -and -not $env:WT_SESSION -and -not $env:TERM) {
        # Running in Windows without a proper terminal - use message box
        Add-Type -AssemblyName System.Windows.Forms
        $result = [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        return $result -eq [System.Windows.Forms.DialogResult]::Yes
    } else {
        # Console-based confirmation
        Write-Host ""
        Write-Host $Title -ForegroundColor Cyan
        Write-Host $Message
        Write-Host ""
        $response = Read-Host "Continue? [y/N]"
        return $response -eq "y" -or $response -eq "Y"
    }
}

function Move-ToStaging {
    <#
    .SYNOPSIS
        Move a file or folder to the staging area, preserving path structure.
    #>
    param(
        [string]$SourcePath,
        [string]$StagingRoot,
        [string]$LogFile
    )

    $relativePath = Get-RelativePath -FullPath $SourcePath
    $destinationPath = Join-Path $StagingRoot $relativePath

    # Create parent directory structure
    $destParent = Split-Path $destinationPath -Parent
    if (-not (Test-Path $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        Write-Log "Created directory: $destParent" -LogFile $LogFile
    }

    # Check if destination already exists
    if (Test-Path $destinationPath) {
        Write-Log "Destination already exists: $destinationPath" -Level "WARN" -LogFile $LogFile
        throw "Destination already exists: $destinationPath"
    }

    # Move the item
    Move-Item -Path $SourcePath -Destination $destinationPath -Force
    Write-Log "Moved: $SourcePath -> $destinationPath" -Level "SUCCESS" -LogFile $LogFile

    return $destinationPath
}

function Update-TrackingDatabase {
    <#
    .SYNOPSIS
        Add a staged item to the tracking database.
    #>
    param(
        [string]$TrackingDbPath,
        [string]$OriginalPath,
        [string]$StagedPath,
        [long]$SizeBytes,
        [int]$FileCount
    )

    $db = Get-Content $TrackingDbPath -Raw | ConvertFrom-Json

    # Convert archives to a modifiable list if it's an array
    if ($db.archives -is [array]) {
        $archives = [System.Collections.ArrayList]@($db.archives)
    } else {
        $archives = [System.Collections.ArrayList]@()
    }

    $entry = @{
        id = [guid]::NewGuid().ToString()
        original_path = $OriginalPath
        staged_path = $StagedPath
        staged_date = (Get-Date).ToString("o")
        archived_date = $null
        restic_snapshot_id = $null
        size_bytes = $SizeBytes
        file_count = $FileCount
        deleted_date = $null
        status = "staged"
        notes = ""
    }

    $null = $archives.Add($entry)
    $db.archives = $archives.ToArray()

    $db | ConvertTo-Json -Depth 10 | Out-File -FilePath $TrackingDbPath -Encoding UTF8

    return $entry.id
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
    try {
        $config = Get-Configuration -ConfigPath $ConfigPath
    } catch {
        Write-Host "ERROR: $_" -ForegroundColor Red
        if ($defaults.IsWindows) {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "Cold Storage - Configuration Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
        exit 1
    }

    $stagingRoot = $config.staging_root
    $trackingDb = $config.tracking_database
    $logDir = $config.log_directory

    # Setup logging
    $logFile = Join-Path $logDir "staging_$(Get-Date -Format 'yyyyMMdd').log"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Write-Log "=== Staging operation started ===" -LogFile $logFile
    Write-Log "Paths to stage: $($Paths -join ', ')" -LogFile $logFile

    # Validate paths
    $validPaths = @()
    $totalSize = 0
    $totalFiles = 0

    foreach ($path in $Paths) {
        # Clean up the path (remove quotes if present)
        $cleanPath = $path.Trim('"', "'", ' ')

        if (-not (Test-Path $cleanPath)) {
            Write-Log "Path not found: $cleanPath" -Level "WARN" -LogFile $logFile
            continue
        }

        $details = Get-ItemDetails -Path $cleanPath
        $validPaths += @{
            Path = $cleanPath
            SizeBytes = $details.SizeBytes
            FileCount = $details.FileCount
            IsFile = $details.IsFile
        }
        $totalSize += $details.SizeBytes
        $totalFiles += $details.FileCount
    }

    if ($validPaths.Count -eq 0) {
        $msg = "No valid paths to stage."
        Write-Log $msg -Level "ERROR" -LogFile $logFile
        if ($defaults.IsWindows) {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show(
                $msg,
                "Cold Storage - Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
        exit 1
    }

    # Build confirmation message
    $itemList = ($validPaths | ForEach-Object {
        $type = if ($_.IsFile) { "File" } else { "Folder" }
        "  - $($_.Path) ($type, $(Format-FileSize $_.SizeBytes), $($_.FileCount) files)"
    }) -join "`n"

    $confirmMessage = @"
The following items will be MOVED to staging:

$itemList

Total: $(Format-FileSize $totalSize), $totalFiles files

Staging location: $stagingRoot

Items will be moved (not copied) to free up disk space immediately.
After archival, they will be backed up to S3 Glacier Deep Archive.
"@

    # Show confirmation
    if (-not $NoConfirm) {
        $confirmed = Show-Confirmation -Title "Move to Cold Storage Staging" -Message $confirmMessage -IsWindows $defaults.IsWindows
        if (-not $confirmed) {
            Write-Log "Operation cancelled by user" -LogFile $logFile
            exit 0
        }
    }

    # Move items to staging
    $movedCount = 0
    $errorCount = 0
    $movedPaths = @()

    foreach ($item in $validPaths) {
        try {
            Write-Host "Moving: $($item.Path)..." -NoNewline
            $stagedPath = Move-ToStaging -SourcePath $item.Path -StagingRoot $stagingRoot -LogFile $logFile

            # Update tracking database
            $entryId = Update-TrackingDatabase `
                -TrackingDbPath $trackingDb `
                -OriginalPath $item.Path `
                -StagedPath $stagedPath `
                -SizeBytes $item.SizeBytes `
                -FileCount $item.FileCount

            Write-Host " Done (ID: $entryId)" -ForegroundColor Green
            $movedPaths += @{
                Original = $item.Path
                Staged = $stagedPath
                Id = $entryId
            }
            $movedCount++
        } catch {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Log "Failed to move $($item.Path): $_" -Level "ERROR" -LogFile $logFile
            $errorCount++
        }
    }

    # Summary
    Write-Host ""
    Write-Log "=== Staging operation complete ===" -LogFile $logFile
    Write-Log "Moved: $movedCount, Errors: $errorCount" -LogFile $logFile

    $summaryMessage = @"
Staging complete!

Moved: $movedCount item(s)
Errors: $errorCount

Total size staged: $(Format-FileSize $totalSize)

Next step: Run Archive-Staged.ps1 to backup staged files to S3 Glacier.
"@

    if ($defaults.IsWindows -and -not $env:WT_SESSION -and -not $env:TERM) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            $summaryMessage,
            "Cold Storage - Staging Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } else {
        Write-Host ""
        Write-Host $summaryMessage -ForegroundColor Cyan
    }

    return $movedPaths
}

# Run main function
try {
    $result = Main
    exit 0
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}

#endregion
