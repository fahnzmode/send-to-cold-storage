<#
.SYNOPSIS
    Create desktop shortcuts for cold storage operations.
.DESCRIPTION
    Creates Windows desktop shortcuts that open PowerShell with -NoExit
    so you can see results and run follow-up commands.
.EXAMPLE
    .\Create-Shortcuts.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ScriptPath = "C:\Scripts\ColdStorage",

    [Parameter()]
    [string]$ShortcutLocation = [Environment]::GetFolderPath("Desktop")
)

$ErrorActionPreference = "Stop"

function New-Shortcut {
    param(
        [string]$Name,
        [string]$Script,
        [string]$Arguments = "",
        [string]$Description
    )

    $shortcutPath = Join-Path $ShortcutLocation "$Name.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)

    $scriptFullPath = Join-Path $ScriptPath $Script
    $pwshArgs = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$scriptFullPath`""
    if ($Arguments) {
        $pwshArgs += " $Arguments"
    }

    $shortcut.TargetPath = "pwsh.exe"
    $shortcut.Arguments = $pwshArgs
    $shortcut.WorkingDirectory = $ScriptPath
    $shortcut.Description = $Description
    $shortcut.IconLocation = "shell32.dll,145"  # Archive icon
    $shortcut.Save()

    Write-Host "Created: $shortcutPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Creating Cold Storage Shortcuts      " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Script path: $ScriptPath"
Write-Host "Shortcut location: $ShortcutLocation"
Write-Host ""

# Verify script path exists
if (-not (Test-Path $ScriptPath)) {
    Write-Host "Warning: Script path does not exist: $ScriptPath" -ForegroundColor Yellow
    Write-Host "Shortcuts will be created but won't work until scripts are installed." -ForegroundColor Yellow
    Write-Host ""
}

# Create shortcuts
New-Shortcut -Name "Cold Storage - Archive" `
    -Script "Archive-Staged.ps1" `
    -Description "Archive staged files to S3 Glacier"

New-Shortcut -Name "Cold Storage - Statistics" `
    -Script "Query-ColdStorage.ps1" `
    -Arguments "-Statistics" `
    -Description "View cold storage statistics"

New-Shortcut -Name "Cold Storage - Verify" `
    -Script "Verify-Archives.ps1" `
    -Description "Verify archive integrity"

New-Shortcut -Name "Cold Storage - List Snapshots" `
    -Script "Restore-FromColdStorage.ps1" `
    -Arguments "-ListSnapshots" `
    -Description "List available snapshots"

Write-Host ""
Write-Host "Done! Shortcuts created on desktop." -ForegroundColor Green
Write-Host ""
Write-Host "Tip: The PowerShell window stays open after running so you can" -ForegroundColor Cyan
Write-Host "     see results and run additional commands." -ForegroundColor Cyan
Write-Host ""
