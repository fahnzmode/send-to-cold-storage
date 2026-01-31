# Cold Storage Archival System

A PowerShell-based cold storage archival system that archives rarely-accessed files to AWS S3 Glacier Deep Archive via restic, freeing up local disk space while maintaining affordable backup coverage.

## Overview

This system supplements existing Backblaze backup by providing selective cold archival:
- **Keep Backblaze** as primary backup (excellent value at $99/year for 48TB)
- **Add restic + AWS S3 Glacier Deep Archive** for selective cold archival
- **Cost**: ~$1/TB/month for archived data

## Features

- Windows Explorer right-click context menu integration
- Encrypted, deduplicated backups via restic
- JSON tracking database for audit trail
- Search and query archived items
- Restore from Glacier with integrity verification
- Safety mechanisms: verification before deletion, comprehensive logging

## Scripts

| Script | Purpose |
|--------|---------|
| `Setup-Restic.ps1` | Interactive setup - install restic, configure AWS, initialize repository |
| `Setup-Config.ps1` | Non-interactive setup (for automation/multi-PC) |
| `Move-ToColdStorage.ps1` | Stage files for archival (context menu integration) |
| `Archive-Staged.ps1` | Backup staged files to S3 Glacier Deep Archive |
| `Query-ColdStorage.ps1` | Search and browse archived items |
| `Restore-FromColdStorage.ps1` | Restore files from Glacier |
| `Verify-Archives.ps1` | Periodic integrity verification |
| `Install-ContextMenu.ps1` | Install Windows right-click context menu |
| `Create-Shortcuts.ps1` | Create desktop shortcuts for common operations |

## Quick Start

1. **Run setup**:
   ```powershell
   .\scripts\Setup-Restic.ps1
   ```

2. **Install context menu** (optional):
   ```powershell
   .\scripts\Install-ContextMenu.ps1
   # Or merge the generated .reg file: C:\Scripts\ColdStorage\add-context-menu.reg
   ```

3. **Stage files for archival**:
   - Right-click files/folders → Show more options → "Send to Cold Storage", or
   - Run `.\scripts\Move-ToColdStorage.ps1 -Path "C:\path\to\folder"`

4. **Archive staged files**:
   ```powershell
   .\scripts\Archive-Staged.ps1
   ```

5. **Query archives**:
   ```powershell
   .\scripts\Query-ColdStorage.ps1 -Statistics
   .\scripts\Query-ColdStorage.ps1 -Search "*project*"
   ```

## Installation Location

Scripts are deployed to `C:\Scripts\ColdStorage\` by default. Configuration and staging:
- Config: `~\.cold-storage\config.json`
- Password: `~\.cold-storage\.restic-password`
- Staging: `C:\ColdStorageStaging\`
- Tracking DB: `C:\ColdStorageStaging\cold_storage_tracking.json`

## Multi-PC Setup

To archive from multiple PCs to the same S3 repository:

1. **On the first PC**: Run `Setup-Restic.ps1` normally. Save the generated password securely.

2. **On additional PCs**:
   - Copy scripts to `C:\Scripts\ColdStorage\`
   - Copy `~\.cold-storage\` folder (contains config.json and .restic-password)
   - Or run `Setup-Config.ps1` with the same bucket/region, then manually replace the password file with the original
   - Ensure AWS credentials are configured with the `cold-storage` profile

**Important**: All PCs must use the same restic password to access the shared repository. The password is stored in `~\.cold-storage\.restic-password`.

## Automation Ideas

- **Scheduled archiving**: Create a Task Scheduler job to run `Archive-Staged.ps1` daily/weekly
- **Quick archive**: Create a batch script that runs Move + Archive in sequence
- **Desktop shortcut**: Create shortcuts to common operations (Archive, Query, Verify)

## Prerequisites

- Windows 10/11 with **PowerShell Core 7+** (not Windows PowerShell 5.1)
- AWS account with S3 access
- Administrator access (for context menu registry modifications)

To install PowerShell Core: `winget install Microsoft.PowerShell`

## Development Workflow

This project uses **direct Windows development** with Claude Code for maximum autonomy:

- **Claude Code agent** handles: script development, testing, AWS operations, restic commands, file operations
- **User handles only**: initial AWS credential setup, final approval of changes

The devcontainer approach was disabled in favor of this direct workflow to minimize back-and-forth and allow the AI agent to test directly on the target Windows environment.

## Planning Files

Development progress is tracked in:
- `task_plan.md` - Phase-based task planning
- `findings.md` - Research and decisions log
- `progress.md` - Session progress tracking

## Documentation

See `implementation_plan.md` for detailed:
- Component descriptions
- Complete workflow diagrams
- Cost estimates and calculations
- Troubleshooting guide
- Best practices and maintenance

## Cost Estimates

| Archive Size | Monthly Cost |
|--------------|--------------|
| 10 TB | ~$10/month |
| 20 TB | ~$20/month |
| 30 TB | ~$30/month |

Retrieval: ~$0.0025/GB when needed (standard retrieval, 12-48 hours)
