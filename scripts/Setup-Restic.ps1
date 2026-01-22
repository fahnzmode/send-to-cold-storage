<#
.SYNOPSIS
    Initial setup script for the Cold Storage Archival System.

.DESCRIPTION
    This script performs the initial setup for the cold storage archival system:
    - Checks if restic is installed (installs via winget on Windows if not)
    - Configures AWS credentials if needed
    - Prompts for S3 bucket name and region
    - Creates and securely stores restic repository password
    - Initializes the restic repository
    - Tests the connection
    - Creates config.json and initial tracking database

.PARAMETER ConfigPath
    Path to store the configuration file. Defaults to platform-appropriate location.

.PARAMETER StagingRoot
    Root directory for staging files before archival.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Setup-Restic.ps1

.EXAMPLE
    .\Setup-Restic.ps1 -ConfigPath "D:\ColdStorage\config.json" -StagingRoot "D:\ColdStorage\staging"

.NOTES
    Author: Claude Code
    Requires: PowerShell 5.1+ (Windows) or PowerShell Core 7+ (Linux/macOS)
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$StagingRoot,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Helper Functions

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Get-PlatformDefaults {
    <#
    .SYNOPSIS
        Returns platform-appropriate default paths.
    #>
    if ($IsWindows -or ($PSVersionTable.PSVersion.Major -lt 6)) {
        # Windows (PowerShell 5.1 doesn't have $IsWindows, so check version)
        $isWindowsPlatform = $true
    } else {
        $isWindowsPlatform = $false
    }

    if ($isWindowsPlatform) {
        @{
            IsWindows = $true
            ConfigDir = Join-Path $env:USERPROFILE ".cold-storage"
            ConfigPath = Join-Path $env:USERPROFILE ".cold-storage\config.json"
            PasswordFile = Join-Path $env:USERPROFILE ".cold-storage\.restic-password"
            StagingRoot = "C:\ColdStorageStaging"
            LogDirectory = Join-Path $env:USERPROFILE ".cold-storage\logs"
            AwsCredentialsPath = Join-Path $env:USERPROFILE ".aws\credentials"
        }
    } else {
        # Linux/macOS
        $homeDir = $env:HOME
        @{
            IsWindows = $false
            ConfigDir = Join-Path $homeDir ".cold-storage"
            ConfigPath = Join-Path $homeDir ".cold-storage/config.json"
            PasswordFile = Join-Path $homeDir ".cold-storage/.restic-password"
            StagingRoot = "/tmp/cold-storage-staging"
            LogDirectory = Join-Path $homeDir ".cold-storage/logs"
            AwsCredentialsPath = Join-Path $homeDir ".aws/credentials"
        }
    }
}

function Test-ResticInstalled {
    <#
    .SYNOPSIS
        Check if restic is installed and accessible.
    #>
    try {
        $null = Get-Command restic -ErrorAction Stop
        $version = restic version 2>&1
        Write-Success "restic is installed: $version"
        return $true
    } catch {
        return $false
    }
}

function Install-ResticWindows {
    <#
    .SYNOPSIS
        Install restic via winget on Windows.
    #>
    Write-Step "Installing restic via winget..."

    # Check if winget is available
    try {
        $null = Get-Command winget -ErrorAction Stop
    } catch {
        Write-Error "winget is not available. Please install restic manually:"
        Write-Host "  1. Download from: https://github.com/restic/restic/releases"
        Write-Host "  2. Extract restic.exe to a folder in your PATH"
        Write-Host "  3. Re-run this setup script"
        throw "winget not available"
    }

    try {
        winget install restic.restic --accept-package-agreements --accept-source-agreements
        Write-Success "restic installed successfully"

        # Refresh PATH from registry
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path", "User")

        # Verify restic is now accessible
        $resticCmd = Get-Command restic -ErrorAction SilentlyContinue
        if (-not $resticCmd) {
            # Search common winget installation locations
            $searchPaths = @(
                "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
                "$env:LOCALAPPDATA\Microsoft\WinGet\Links",
                "$env:ProgramFiles\restic",
                "${env:ProgramFiles(x86)}\restic"
            )

            $resticExe = $null
            foreach ($searchPath in $searchPaths) {
                if (Test-Path $searchPath) {
                    $found = Get-ChildItem -Path $searchPath -Recurse -Filter "restic.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($found) {
                        $resticExe = $found.FullName
                        break
                    }
                }
            }

            if ($resticExe) {
                $resticDir = Split-Path $resticExe -Parent
                Write-Host "Found restic at: $resticExe"
                Write-Host "Adding to PATH for this session..."
                $env:Path = "$resticDir;$env:Path"
            } else {
                Write-Warning "restic was installed but not found in PATH."
                Write-Warning "Please close this PowerShell window and open a new one, then run Setup again."
                throw "restic not in PATH after installation"
            }
        }
    } catch {
        Write-Error "Failed to install restic via winget: $_"
        throw
    }
}

function Test-AwsCredentials {
    <#
    .SYNOPSIS
        Check if AWS credentials are configured for the specified profile.
    #>
    param([string]$AwsProfileName = "cold-storage")

    try {
        $env:AWS_PROFILE = $AwsProfileName
        $identity = aws sts get-caller-identity 2>&1
        if ($LASTEXITCODE -eq 0) {
            $parsed = $identity | ConvertFrom-Json
            Write-Success "AWS credentials valid for profile '$AwsProfileName'"
            Write-Host "  Account: $($parsed.Account)"
            Write-Host "  User: $($parsed.Arn)"
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Initialize-AwsCredentials {
    <#
    .SYNOPSIS
        Prompt user to configure AWS credentials.
    #>
    param([string]$AwsProfileName = "cold-storage")

    Write-Step "Configuring AWS credentials for profile '$AwsProfileName'..."
    Write-Host "You'll need your AWS Access Key ID and Secret Access Key."
    Write-Host "These should be for a user with S3 access to your cold storage bucket."
    Write-Host ""

    $accessKey = Read-Host "AWS Access Key ID"
    $secretKey = Read-Host "AWS Secret Access Key" -AsSecureString

    $region = ""
    while ([string]::IsNullOrWhiteSpace($region)) {
        $region = Read-Host "AWS Region (e.g., us-east-1, us-west-2, eu-west-1)"
        if ([string]::IsNullOrWhiteSpace($region)) {
            Write-Host "Region is required." -ForegroundColor Yellow
        }
    }

    # Convert SecureString to plain text for aws configure
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretKey)
    $secretKeyPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

    try {
        # Use aws configure to set up the profile
        $env:AWS_ACCESS_KEY_ID = $accessKey
        $env:AWS_SECRET_ACCESS_KEY = $secretKeyPlain
        $env:AWS_DEFAULT_REGION = $region

        aws configure set aws_access_key_id $accessKey --profile $AwsProfileName
        aws configure set aws_secret_access_key $secretKeyPlain --profile $AwsProfileName
        aws configure set region $region --profile $AwsProfileName

        # Clear sensitive data
        $secretKeyPlain = $null
        Remove-Variable secretKeyPlain -ErrorAction SilentlyContinue

        Write-Success "AWS credentials configured for profile '$AwsProfileName'"
        return $true
    } catch {
        Write-Error "Failed to configure AWS credentials: $_"
        return $false
    } finally {
        # Clear environment variables
        Remove-Item Env:AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
        Remove-Item Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
    }
}

function New-ResticPassword {
    <#
    .SYNOPSIS
        Generate or prompt for restic repository password and save securely.
    #>
    param([string]$ResticKeyFile)

    Write-Step "Setting up restic repository password..."
    Write-Host "This password encrypts your backups. Store it safely - you cannot recover data without it!"
    Write-Host ""

    $choice = Read-Host "Generate random password (G) or enter your own (E)? [G/E]"

    if ($choice -eq "G" -or $choice -eq "g" -or [string]::IsNullOrWhiteSpace($choice)) {
        # Generate a random password
        $bytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        $password = [Convert]::ToBase64String($bytes)
        Write-Host ""
        Write-Host "Generated password (SAVE THIS SOMEWHERE SAFE):" -ForegroundColor Yellow
        Write-Host $password -ForegroundColor White
        Write-Host ""
    } else {
        $securePassword = Read-Host "Enter restic repository password" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }

    # Save to password file
    $passwordDir = Split-Path $ResticKeyFile -Parent
    if (-not (Test-Path $passwordDir)) {
        New-Item -ItemType Directory -Path $passwordDir -Force | Out-Null
    }

    $password | Out-File -FilePath $ResticKeyFile -Encoding UTF8 -NoNewline

    # Set restrictive permissions
    $defaults = Get-PlatformDefaults
    if ($defaults.IsWindows) {
        # Windows: Remove inheritance and set owner-only access
        $acl = Get-Acl $ResticKeyFile
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $env:USERNAME, "FullControl", "Allow"
        )
        $acl.SetAccessRule($rule)
        Set-Acl $ResticKeyFile $acl
    } else {
        # Linux/macOS: chmod 600
        chmod 600 $ResticKeyFile
    }

    Write-Success "Password saved to: $ResticKeyFile"
    return $password
}

function Initialize-ResticRepository {
    <#
    .SYNOPSIS
        Initialize the restic repository on S3.
    #>
    param(
        [string]$Repository,
        [string]$ResticKeyFile,
        [string]$AwsProfile
    )

    Write-Step "Initializing restic repository..."
    Write-Host "Repository: $Repository"

    $env:AWS_PROFILE = $AwsProfile
    $env:RESTIC_REPOSITORY = $Repository
    $env:RESTIC_PASSWORD_FILE = $ResticKeyFile

    # Check if repository already exists
    $null = restic snapshots 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Repository already initialized"
        return $true
    }

    # Initialize new repository
    try {
        $initResult = restic init 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to initialize repository: $initResult"
            return $false
        }
        Write-Success "Repository initialized successfully"
        return $true
    } catch {
        Write-Error "Failed to initialize repository: $_"
        return $false
    }
}

function Test-ResticConnection {
    <#
    .SYNOPSIS
        Test the restic repository connection.
    #>
    param(
        [string]$Repository,
        [string]$ResticKeyFile,
        [string]$AwsProfile
    )

    Write-Step "Testing restic repository connection..."

    $env:AWS_PROFILE = $AwsProfile
    $env:RESTIC_REPOSITORY = $Repository
    $env:RESTIC_PASSWORD_FILE = $ResticKeyFile

    try {
        $result = restic snapshots --json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $snapshots = $result | ConvertFrom-Json
            Write-Success "Connection successful. Repository has $($snapshots.Count) snapshot(s)."
            return $true
        } else {
            Write-Error "Connection test failed: $result"
            return $false
        }
    } catch {
        Write-Error "Connection test failed: $_"
        return $false
    }
}

function New-TrackingDatabase {
    <#
    .SYNOPSIS
        Create the initial tracking database JSON file.
    #>
    param([string]$Path)

    $database = @{
        version = "1.0"
        created = (Get-Date).ToString("o")
        archives = @()
        statistics = @{
            total_archived_bytes = 0
            total_items = 0
            last_archive_date = $null
            estimated_monthly_cost_usd = 0.0
        }
    }

    $dbDir = Split-Path $Path -Parent
    if (-not (Test-Path $dbDir)) {
        New-Item -ItemType Directory -Path $dbDir -Force | Out-Null
    }

    $database | ConvertTo-Json -Depth 10 | Out-File -FilePath $Path -Encoding UTF8
    Write-Success "Tracking database created: $Path"
}

function New-Configuration {
    <#
    .SYNOPSIS
        Create the configuration file.
    #>
    param(
        [string]$ConfigPath,
        [hashtable]$Config
    )

    $configDir = Split-Path $ConfigPath -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $Config | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigPath -Encoding UTF8
    Write-Success "Configuration saved: $ConfigPath"
}

#endregion

#region Main Script

function Main {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Cold Storage Archival System Setup   " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $defaults = Get-PlatformDefaults

    # Use parameter values or defaults
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $defaults.ConfigPath
    }
    if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
        $StagingRoot = $defaults.StagingRoot
    }

    Write-Host "Platform: $(if ($defaults.IsWindows) { 'Windows' } else { 'Linux/macOS' })"
    Write-Host "Config path: $ConfigPath"
    Write-Host "Staging root: $StagingRoot"
    Write-Host ""

    # Step 1: Check/install restic
    Write-Step "Checking restic installation..."
    if (-not (Test-ResticInstalled)) {
        if ($defaults.IsWindows) {
            Install-ResticWindows
        } else {
            Write-Error "restic is not installed. Please install it using your package manager:"
            Write-Host "  Ubuntu/Debian: sudo apt install restic"
            Write-Host "  macOS: brew install restic"
            Write-Host "  Or download from: https://github.com/restic/restic/releases"
            throw "restic not installed"
        }
    }

    # Step 2: Check/configure AWS credentials
    Write-Step "Checking AWS credentials..."
    $awsProfile = "cold-storage"
    if (-not (Test-AwsCredentials -AwsProfileName $awsProfile)) {
        Write-Warning "AWS credentials not configured for profile '$awsProfile'"
        if (-not (Initialize-AwsCredentials -AwsProfileName $awsProfile)) {
            throw "Failed to configure AWS credentials"
        }
    }

    # Step 3: Get S3 bucket configuration
    Write-Step "Configuring S3 bucket..."

    $bucket = ""
    while ([string]::IsNullOrWhiteSpace($bucket)) {
        $bucket = Read-Host "S3 bucket name"
        if ([string]::IsNullOrWhiteSpace($bucket)) {
            Write-Host "Bucket name is required." -ForegroundColor Yellow
        }
    }

    $region = ""
    while ([string]::IsNullOrWhiteSpace($region)) {
        $region = Read-Host "AWS region (e.g., us-east-1, us-west-2, eu-west-1)"
        if ([string]::IsNullOrWhiteSpace($region)) {
            Write-Host "Region is required." -ForegroundColor Yellow
        }
    }

    # Construct the restic repository URL
    $resticRepo = "s3:s3.$region.amazonaws.com/$bucket"
    Write-Host "Restic repository: $resticRepo"

    # Step 4: Set up restic password
    $passwordFile = $defaults.PasswordFile
    if (Test-Path $passwordFile) {
        Write-Host ""
        $useExisting = Read-Host "Password file already exists at $passwordFile. Use it? [Y/n]"
        if ($useExisting -eq "n" -or $useExisting -eq "N") {
            $null = New-ResticPassword -ResticKeyFile $passwordFile
        } else {
            Write-Success "Using existing password file"
        }
    } else {
        $null = New-ResticPassword -ResticKeyFile $passwordFile
    }

    # Step 5: Initialize restic repository
    if (-not (Initialize-ResticRepository -Repository $resticRepo -ResticKeyFile $passwordFile -AwsProfile $awsProfile)) {
        throw "Failed to initialize restic repository"
    }

    # Step 6: Test connection
    if (-not (Test-ResticConnection -Repository $resticRepo -ResticKeyFile $passwordFile -AwsProfile $awsProfile)) {
        throw "Failed to connect to restic repository"
    }

    # Step 7: Create staging directory
    Write-Step "Creating staging directory..."
    if (-not (Test-Path $StagingRoot)) {
        New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
        Write-Success "Created staging directory: $StagingRoot"
    } else {
        Write-Success "Staging directory exists: $StagingRoot"
    }

    # Create logs directory
    $logDir = $defaults.LogDirectory
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Write-Success "Created log directory: $logDir"
    }

    # Step 8: Create tracking database
    Write-Step "Creating tracking database..."
    $trackingDbPath = Join-Path $StagingRoot "cold_storage_tracking.json"
    if (-not (Test-Path $trackingDbPath)) {
        New-TrackingDatabase -Path $trackingDbPath
    } else {
        Write-Success "Tracking database exists: $trackingDbPath"
    }

    # Step 9: Save configuration
    Write-Step "Saving configuration..."
    $config = @{
        version = "1.0"
        created = (Get-Date).ToString("o")
        aws_profile = $awsProfile
        aws_region = $region
        s3_bucket = $bucket
        restic_repository = $resticRepo
        restic_password_file = $passwordFile
        staging_root = $StagingRoot
        tracking_database = $trackingDbPath
        log_directory = $logDir
    }
    New-Configuration -ConfigPath $ConfigPath -Config $config

    # Done!
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Setup Complete!                      " -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Configuration saved to: $ConfigPath"
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Use Move-ToColdStorage.ps1 to stage files for archival"
    Write-Host "  2. Run Archive-Staged.ps1 to backup staged files to S3"
    Write-Host "  3. Use Query-ColdStorage.ps1 to search archived items"
    Write-Host "  4. Use Restore-FromColdStorage.ps1 to retrieve files"
    Write-Host ""

    if ($defaults.IsWindows) {
        Write-Host "To add context menu integration, run:"
        Write-Host "  .\Install-ContextMenu.ps1"
        Write-Host ""
    }

    return $config
}

# Run main function
try {
    $result = Main
    exit 0
} catch {
    Write-Error "Setup failed: $_"
    exit 1
}

#endregion
