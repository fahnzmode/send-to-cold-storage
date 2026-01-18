# Cold Storage Archival System - Implementation Plan

## Project Overview

### Goal
Implement a cold storage archival system to free up local disk space while maintaining affordable backup coverage. This supplements existing Backblaze backup rather than replacing it.

### Current Setup
- **Backblaze Personal Backup**: $99/year per computer (unlimited storage)
  - Backing up 2 personal computers
  - Backing up media server with ~30TB movies/TV and ~18TB projects
  - Grandfathered into 1-year retention for deleted files
- **Total data**: ~48TB across 3 machines
- **Problem**: Running out of local disk space

### Solution Architecture
- **Keep Backblaze** as primary backup (excellent value at $99/year for 48TB)
- **Add restic + AWS S3 Glacier Deep Archive** for selective cold archival
- **Use case**: Archive rarely-accessed files to S3, delete locally to free space
- **Safety net**: Files remain in Backblaze for 1 year after local deletion
- **Cost**: ~$1/TB/month for what you archive (only pay for what you store)

---

## System Components

### 1. Staging System
**Purpose**: Safely prepare files for archival with path preservation

**Key Features**:
- Windows Explorer context menu integration
- Right-click any file(s)/folder(s) → "Move to Cold Storage Staging"
- Preserves full directory structure in staging area
- Confirmation dialog before moving
- Operation logging

**Staging Location**: `S:\move_to_cold_storage\`

**Example**:
- Original: `S:\Projects, Video\2013 Dance Recital\`
- Staged: `S:\move_to_cold_storage\Projects, Video\2013 Dance Recital\`

**Configuration**:
- Staging root should be on same drive as source files (instant moves)
- Can be changed in script configuration if needed

### 2. Archival System (restic + S3)
**Purpose**: Backup staged files to AWS S3 Glacier Deep Archive

**Key Features**:
- Scans staging folder for items ready to archive
- Uses restic to create encrypted, deduplicated backups
- Uploads directly to S3 Glacier Deep Archive storage class
- Verifies backup integrity after completion
- Only deletes local/staged files after verification passes

**Restic Configuration**:
- Repository: S3 bucket with Glacier Deep Archive
- Encryption: AES-256 (restic built-in)
- Retention: Keep all snapshots (manual cleanup if needed later)
- Deduplication: Automatic (saves storage costs for similar files)

**S3 Configuration**:
- Storage class: Glacier Deep Archive
- Retrieval time: 12-48 hours
- Cost: ~$1/TB/month storage, ~$0.02/GB retrieval
- No lifecycle policies needed (upload directly to Deep Archive)

### 3. Tracking Database
**Purpose**: Maintain searchable record of all archived items

**Format**: JSON file (can migrate to SQLite later if needed)

**Location**: `S:\move_to_cold_storage\cold_storage_tracking.json`

**Schema**:
```json
{
  "archives": [
    {
      "id": "unique-id-123",
      "original_path": "S:\\Projects, Video\\2013 Dance Recital",
      "staged_date": "2024-12-28T10:30:00",
      "archived_date": "2024-12-28T11:45:00",
      "restic_snapshot_id": "a1b2c3d4e5f6",
      "size_bytes": 15728640000,
      "file_count": 245,
      "deleted_date": "2024-12-28T12:00:00",
      "status": "archived_and_deleted",
      "notes": "Dance recital footage",
      "checksum": "sha256-hash-here"
    }
  ],
  "statistics": {
    "total_archived_bytes": 15728640000,
    "total_items": 1,
    "last_archive_date": "2024-12-28T11:45:00",
    "estimated_monthly_cost": 15.0
  }
}
```

**Status Values**:
- `staged`: Moved to staging, not yet archived
- `archiving`: Currently being backed up
- `archived`: Backed up but not yet deleted from staging
- `archived_and_deleted`: Fully complete
- `failed`: Archive attempt failed

### 4. Query System
**Purpose**: Search and browse archived items

**Features**:
- Search by path, filename, date range
- Filter by size, file type, status
- View archive statistics (total size, cost estimates)
- List all archived items with details
- Export search results

### 5. Restore System
**Purpose**: Retrieve files from Glacier Deep Archive

**Features**:
- Search for items to restore
- Initiate Glacier retrieval request
- Monitor retrieval status
- Download and restore to original or alternate path
- Update tracking database with restore events
- Handle partial restores (specific files from folder)

**Restoration Process**:
1. Search for archived item
2. Initiate Glacier retrieval (12-48 hour wait)
3. Receive notification when available
4. Download from S3
5. Restore to specified location
6. Verify integrity

---

## Complete Workflow

### Phase 1: Manual Selection & Staging
1. User identifies folders/files for archival
2. Right-click → "Move to Cold Storage Staging"
3. Confirmation dialog appears
4. User confirms → items moved to staging with path preservation
5. Operation logged to `staging_log.txt`

### Phase 2: Archival
1. User runs `Archive-Staged.ps1` (can be manual or scheduled)
2. Script scans staging folder
3. Creates restic snapshot of all staged items
4. Uploads to S3 Glacier Deep Archive
5. Verifies backup with `restic check`
6. Updates tracking database with metadata
7. Only if verification passes: deletes from staging
8. Sends completion notification

### Phase 3: Tracking & Query
1. All operations recorded in tracking database
2. User can query archived items anytime
3. View statistics and cost estimates
4. Audit what's been archived

### Phase 4: Restore (When Needed)
1. User searches for archived item
2. Initiates Glacier retrieval
3. Waits 12-48 hours for retrieval
4. Downloads and restores to desired location
5. Verifies integrity after restore

---

## Scripts to Implement

### 1. Move-ToColdStorage.ps1
**Purpose**: Context menu integration for moving items to staging

**Functionality**:
- Accept file/folder paths as command-line arguments
- Handle single or multiple selections
- Preserve full directory structure in staging
- Show confirmation dialog with list of items
- Create parent directories as needed
- Check for existing items to prevent overwrites
- Move (not copy) items to staging
- Log all operations
- Show success/failure notification

**Context Menu Integration**:
- Add to right-click menu for files
- Add to right-click menu for folders
- Support multiple selections

### 2. Setup-Restic.ps1
**Purpose**: Initial setup and configuration

**Functionality**:
- Check if restic is installed (install if needed via chocolatey)
- Prompt for AWS credentials (access key, secret key)
- Prompt for S3 bucket name and region
- Prompt for restic repository password (store securely)
- Initialize restic repository with S3 backend
- Test connection and credentials
- Create initial tracking database file
- Save configuration for other scripts

**Configuration File** (`config.json`):
```json
{
  "staging_root": "S:\\move_to_cold_storage",
  "tracking_db": "S:\\move_to_cold_storage\\cold_storage_tracking.json",
  "restic_repo": "s3:s3.amazonaws.com/your-bucket-name",
  "restic_password_file": "C:\\Scripts\\.restic-password",
  "aws_region": "us-east-1",
  "log_directory": "S:\\move_to_cold_storage\\logs"
}
```

### 3. Archive-Staged.ps1
**Purpose**: Main archival workflow

**Functionality**:
- Read configuration
- Scan staging folder for items
- Display summary of what will be archived
- Prompt for optional notes/description
- Create restic snapshot with descriptive tag
- Monitor progress and show status
- Verify backup integrity
- Update tracking database for each item
- Delete from staging only after verification
- Calculate and log storage costs
- Send completion notification with summary
- Handle errors gracefully (log and continue)

**Safety Checks**:
- Verify restic repository is accessible
- Confirm S3 credentials are valid
- Check sufficient S3 storage quota
- Verify staging items exist before archiving
- Double-check before deletion

### 4. Query-ColdStorage.ps1
**Purpose**: Search and browse archived items

**Functionality**:
- Interactive menu system
- Search options:
  - By path/filename (wildcards supported)
  - By date range
  - By size range
  - By status
  - By restic snapshot ID
- Display results in formatted table
- Show detailed info for selected item
- View archive statistics:
  - Total items archived
  - Total size
  - Estimated monthly cost
  - Date range of archives
- Export results to CSV
- Open containing folder (if not deleted)

**Example Queries**:
```
Find all items with "2013" in path
Find items larger than 10GB
Find items archived in last 30 days
Find items in "Projects, Video" folder
```

### 5. Restore-FromColdStorage.ps1
**Purpose**: Restore files from Glacier

**Functionality**:
- Search interface to find archived items
- Display item details and estimated restore time/cost
- Options:
  - Restore to original location
  - Restore to alternate location
  - Restore specific files from folder (if possible)
- Initiate Glacier retrieval request
- Save retrieval request ID
- Check retrieval status
- Download when ready
- Restore to specified location
- Verify integrity after restore
- Update tracking database with restore event
- Option to keep in cold storage or remove

**Restoration Options**:
- Standard retrieval: 12-48 hours, cheapest
- Expedited retrieval: 1-5 minutes, expensive (if needed urgently)

### 6. Verify-Archives.ps1 (Optional but Recommended)
**Purpose**: Periodic integrity verification

**Functionality**:
- Run `restic check` on repository
- Verify random sample of archived items
- Check tracking database consistency
- Report any issues
- Can be scheduled monthly

---

## Development Environment

### Devcontainer Configuration
This project uses a devcontainer for autonomous development with Claude Code. The container includes:

**Installed Tools:**
- PowerShell Core (latest) - For script development and testing
- AWS CLI (latest) - For S3 integration testing
- Restic (v0.17.3) - For backup tool testing
- Node.js LTS - For Claude Code CLI
- Git - For version control

**VS Code Extensions:**
- ms-vscode.powershell - PowerShell language support
- amazonwebservices.aws-toolkit-vscode - AWS integration
- editorconfig.editorconfig - Code formatting

**Container Configuration:**
- User: root (for autonomous operations)
- Memory: 4GB limit
- CPUs: 2 cores
- Security: Restricted capabilities with no-new-privileges

### Development vs Deployment

**Important Distinction:**
- **Development**: Scripts are written and tested in Linux devcontainer
- **Deployment**: Scripts run on Windows 10/11 with PowerShell 5.1+

**Hybrid Development Workflow:**

**Phase 1: Devcontainer Development (~80% of work)**
- Autonomous agent develops PowerShell script logic
- Tests basic functionality:
  - File operations (create, move, delete)
  - AWS CLI commands (S3 operations)
  - Restic commands (backup, verify, restore)
  - JSON parsing and manipulation
  - Error handling and logging
- Validates PowerShell syntax and best practices
- Creates comprehensive documentation

**Phase 2: Windows Testing (~20% of work)**
- Manual testing on Windows system:
  - Registry modifications (context menu integration)
  - Drive letter handling (C:\, S:\, etc.)
  - Windows-specific path separators (backslashes)
  - Windows PowerShell 5.1 compatibility
  - WinGet installation process
  - Actual staging and archival workflow
  - Message box dialogs and Windows UI

**Phase 3: Iteration**
- Report Windows-specific issues to agent
- Agent fixes in devcontainer
- Re-test on Windows
- Repeat until fully functional

**What CAN be tested in devcontainer:**
- ✅ Script logic and control flow
- ✅ AWS S3 operations
- ✅ Restic backup/restore operations
- ✅ JSON file manipulation
- ✅ Error handling
- ✅ PowerShell syntax validation

**What CANNOT be tested in devcontainer:**
- ❌ Windows Registry operations
- ❌ Windows drive letters (C:\, S:\)
- ❌ Windows path separators
- ❌ Context menu integration
- ❌ Windows message boxes
- ❌ PowerShell 5.1 specific behavior
- ❌ WinGet package installation

**Cross-platform Considerations:**
- PowerShell Core in devcontainer for development
- Windows PowerShell 5.1+ on target system
- Path handling must account for Windows (backslashes, drive letters)
- Registry operations are Windows-only (cannot be tested in container)
- Final testing must be performed on actual Windows system

**Testing Strategy:**
1. Develop logic in devcontainer with PowerShell Core
2. Test basic functionality (file operations, AWS CLI, restic)
3. Deploy to Windows test environment
4. Test Windows-specific features (registry, context menu, drive paths)
5. Report issues back to agent for fixes
6. Iterate until complete

---

## Installation & Setup Guide

### Prerequisites
1. Windows 10/11 with PowerShell 5.1+
2. WinGet package manager (built into Windows 11, available via Microsoft Store App Installer on Windows 10)
3. AWS account with S3 access
4. Sufficient AWS permissions (S3 read/write, Glacier)
5. Administrator access to install software and modify registry

### Step 1: Install Required Software

**Check WinGet Availability:**
```powershell
# Check if WinGet is installed
winget --version

# If not installed on Windows 10, install App Installer from Microsoft Store
# On Windows 11, WinGet comes pre-installed
```

**Install restic via WinGet:**
```powershell
# Install restic
winget install restic.restic

# Verify installation
restic version
```

**Alternative: Manual Installation (if WinGet unavailable):**
1. Download latest restic release from https://github.com/restic/restic/releases
2. Extract `restic.exe` to `C:\Program Files\restic\`
3. Add to PATH environment variable

### Step 2: AWS Setup

1. Create S3 bucket for cold storage
   - Name: `your-cold-storage-bucket`
   - Region: Choose closest to you
   - Disable versioning (restic handles this)
   - Block public access (security)

2. Create IAM user for restic
   - Create user: `restic-cold-storage`
   - Attach policy:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "s3:ListBucket",
           "s3:GetBucketLocation",
           "s3:ListBucketMultipartUploads"
         ],
         "Resource": "arn:aws:s3:::your-cold-storage-bucket"
       },
       {
         "Effect": "Allow",
         "Action": [
           "s3:PutObject",
           "s3:GetObject",
           "s3:DeleteObject",
           "s3:ListMultipartUploadParts",
           "s3:AbortMultipartUpload"
         ],
         "Resource": "arn:aws:s3:::your-cold-storage-bucket/*"
       }
     ]
   }
   ```
   - Save access key and secret key

3. Configure storage class
   - Create lifecycle rule (optional, or upload directly to Deep Archive)
   - Or configure restic to upload directly to Deep Archive

### Step 3: Create Scripts Directory

```powershell
New-Item -ItemType Directory -Path "C:\Scripts" -Force
New-Item -ItemType Directory -Path "S:\move_to_cold_storage" -Force
New-Item -ItemType Directory -Path "S:\move_to_cold_storage\logs" -Force
```

### Step 4: Install Scripts

1. Save all PowerShell scripts to `C:\Scripts\`
2. Run setup script:
   ```powershell
   cd C:\Scripts
   .\Setup-Restic.ps1
   ```
3. Follow prompts to configure AWS credentials and repository

### Step 5: Install Context Menu Integration

1. Create registry file `add-context-menu.reg` (provided by Setup-Restic.ps1)
2. Right-click → Merge
3. Confirm UAC prompt
4. Context menu item now available

### Step 6: Test with Small Folder

1. Create test folder: `S:\test-archive\small-test\`
2. Add a few small files (< 1GB total)
3. Right-click → "Move to Cold Storage Staging"
4. Run: `.\Archive-Staged.ps1`
5. Verify in AWS console that files appear
6. Test query: `.\Query-ColdStorage.ps1`
7. Test restore: `.\Restore-FromColdStorage.ps1`

### Step 7: Begin Regular Use

Once tested successfully:
1. Identify larger folders for archival
2. Move to staging via context menu
3. Run archival script (can schedule if desired)
4. Monitor tracking database and AWS billing

---

## Cost Estimates

### Storage Costs (AWS S3 Glacier Deep Archive)
- **$0.00099/GB/month** (~$1/TB/month)
- Examples:
  - 10TB archived: ~$10/month
  - 20TB archived: ~$20/month
  - 30TB archived: ~$30/month

### Retrieval Costs (when needed)
- **Standard retrieval**: $0.0025/GB + $0.02/request
  - Example: Restore 100GB = $0.25 + $0.02 = $0.27
- **Bulk retrieval**: $0.00025/GB (48 hours)
  - Example: Restore 100GB = $0.025

### Request Costs
- **PUT requests**: $0.05 per 1,000 requests
- **GET requests**: $0.0004 per 1,000 requests
- Generally negligible for this use case

### Total Cost Example
Archiving 15TB:
- Monthly storage: $15/month ($180/year)
- Initial upload: ~$1-2 one-time
- Occasional restores: Variable, typically < $5/year
- **Total: ~$185-200/year for 15TB archived**

Combined with Backblaze ($99/year), total backup costs: **~$285-300/year**

---

## Safety Mechanisms

### Multiple Verification Layers
1. **Confirmation dialog** before moving to staging
2. **Restic verification** after backup (`restic check`)
3. **Tracking database** records all operations
4. **Backblaze retention** keeps files for 1 year after deletion
5. **Logging** of all operations for audit trail

### Error Handling
- Scripts check for errors at each step
- Failed operations logged but don't stop entire process
- Notifications include error details
- Staging files not deleted if verification fails
- Database records failure status

### Recovery Options
- **Within 1 year**: Restore from Backblaze (fast, free)
- **After 1 year**: Restore from Glacier (12-48 hours, ~$0.0025/GB)
- **Database corruption**: Can rebuild from restic repository metadata

---

## Maintenance & Best Practices

### Regular Tasks
- **Monthly**: Review archive statistics and costs
- **Quarterly**: Run `Verify-Archives.ps1` to check integrity
- **Annually**: Review what's archived, delete if no longer needed

### Best Practices
1. Start with smaller, less critical folders to gain confidence
2. Always verify first backup before archiving large amounts
3. Keep tracking database backed up (it's small but critical)
4. Document any custom notes in tracking database
5. Monitor AWS billing regularly
6. Test restoration process periodically
7. Keep restic password secure and backed up separately

### Monitoring
- Review `staging_log.txt` periodically
- Check AWS S3 console for unexpected costs
- Verify tracking database stays synchronized
- Monitor local disk space freed

### Scaling Considerations
- Tracking database is JSON (fine for 1000s of items)
- For 10,000+ items, consider migrating to SQLite
- Large archives (>5TB single snapshot) may take hours
- Consider splitting very large folders into batches

---

## Future Enhancements (Optional)

### Automation Options
- Schedule `Archive-Staged.ps1` to run weekly
- Auto-archive based on last access date
- Email/SMS notifications on completion
- Dashboard web interface for tracking

### Advanced Features
- Integration with Windows Search to flag archived items
- Preview files before restore (if metadata available)
- Differential archival (only changed files)
- Compression analysis and reporting
- Cost optimization recommendations

### Integration Ideas
- Mount restic repository as virtual drive (when needed)
- Integrate with media server software
- API for programmatic access
- Mobile app for monitoring

---

## Troubleshooting

### Common Issues

**Restic can't connect to S3**:
- Verify AWS credentials in config
- Check S3 bucket name and region
- Ensure IAM permissions are correct
- Test with: `restic -r s3:... snapshots`

**Files not appearing in staging**:
- Check staging root path in config
- Verify source drive letter matches
- Review `staging_log.txt` for errors
- Ensure sufficient permissions

**Verification fails**:
- Run `restic check --read-data` for detailed check
- May indicate S3 upload issue
- Check AWS console for partial uploads
- Do not delete staged files until resolved

**Context menu not appearing**:
- Verify registry entries are correct
- Check script path in registry
- Ensure PowerShell execution policy allows scripts
- Try logging out and back in

**High AWS costs**:
- Check for unintended retrievals
- Verify storage class is Deep Archive
- Review request counts (should be low)
- Use AWS Cost Explorer for details

---

## Support & Documentation

### Restic Documentation
- Official docs: https://restic.readthedocs.io/
- AWS S3 backend: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#amazon-s3

### AWS Documentation
- S3 Glacier Deep Archive: https://aws.amazon.com/s3/storage-classes/glacier/
- S3 Pricing: https://aws.amazon.com/s3/pricing/

### Script Documentation
- Each script includes inline comments
- Use `-Help` parameter for usage info
- Example: `Get-Help .\Archive-Staged.ps1 -Detailed`

---

## Implementation Checklist

- [ ] Install Chocolatey
- [ ] Install restic
- [ ] Create AWS S3 bucket
- [ ] Create IAM user and save credentials
- [ ] Create scripts directory structure
- [ ] Implement `Setup-Restic.ps1`
- [ ] Implement `Move-ToColdStorage.ps1`
- [ ] Create and merge registry file
- [ ] Implement `Archive-Staged.ps1`
- [ ] Implement `Query-ColdStorage.ps1`
- [ ] Implement `Restore-FromColdStorage.ps1`
- [ ] Implement `Verify-Archives.ps1` (optional)
- [ ] Test with small folder
- [ ] Document custom configuration
- [ ] Begin archiving real data
- [ ] Set up monitoring/alerts
- [ ] Schedule verification checks

---

## Notes for AI Implementation Assistant

This plan provides complete context for implementing a cold storage archival system. Key implementation priorities:

1. **Start with Setup-Restic.ps1** - gets the foundation working
2. **Then Move-ToColdStorage.ps1** - enables user to stage files
3. **Then Archive-Staged.ps1** - core archival functionality
4. **Query and Restore** can be added after core workflow is tested

All scripts should:
- Include comprehensive error handling
- Log operations for debugging
- Show progress for long operations
- Provide clear user feedback
- Follow PowerShell best practices
- Include inline documentation

The user is comfortable with programming and technical concepts, so implementation can be sophisticated but should remain maintainable.
