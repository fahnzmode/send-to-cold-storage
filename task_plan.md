# Task Plan: Cold Storage Archival System Implementation

## Goal
Build a PowerShell-based cold storage archival system that allows selective archival of files to AWS S3 Glacier Deep Archive to free up local disk space while maintaining Backblaze as primary backup.

## Context
- User has Backblaze Personal Backup ($99/year) backing up ~48TB across 3 machines
- Need to free up local disk space by archiving rarely-accessed files to S3 Glacier
- Files will remain in Backblaze for 1 year after local deletion (safety net)
- System must verify backups before deleting local files
- Target cost: ~$1/TB/month for archived data

## Phases

### Phase 1: Setup & Configuration
- [ ] Create `Setup-Restic.ps1` script (for Windows deployment)
  - Check if restic is installed, install via winget if not (`winget install restic.restic`)
  - Fallback to manual download if winget unavailable
  - Prompt for AWS credentials (access key, secret key)
  - Prompt for S3 bucket name and region
  - Initialize restic repository
  - Test connection
  - Create config.json file
  - Create initial tracking database
- [ ] Test script logic in devcontainer (basic flow)
- [ ] Document setup process for Windows deployment

### Phase 2: Staging System
- [ ] Create `Move-ToColdStorage.ps1` script
  - Accept file/folder paths as parameters
  - Preserve full directory structure
  - Show confirmation dialog
  - Move items to staging folder
  - Log operations
  - Handle errors gracefully
- [ ] Create Windows registry file for context menu integration
- [ ] Test with small test folder
- [ ] Document usage

### Phase 3: Archival System
- [ ] Create `Archive-Staged.ps1` script
  - Scan staging folder
  - Create restic snapshot
  - Upload to S3 Glacier Deep Archive
  - Verify backup with `restic check`
  - Update tracking database
  - Delete from staging only after verification
  - Show completion notification
  - Log all operations
- [ ] Test archival workflow end-to-end
- [ ] Verify data appears in S3
- [ ] Document archival process

### Phase 4: Query System
- [ ] Create `Query-ColdStorage.ps1` script
  - Interactive search interface
  - Search by path, date, size, status
  - Display formatted results
  - Show archive statistics
  - Export to CSV option
- [ ] Test query functionality
- [ ] Document query capabilities

### Phase 5: Restore System
- [ ] Create `Restore-FromColdStorage.ps1` script
  - Search interface
  - Display item details and restore costs
  - Initiate Glacier retrieval
  - Check retrieval status
  - Download and restore files
  - Verify integrity
  - Update tracking database
- [ ] Test restore workflow
- [ ] Document restore process

### Phase 6: Verification & Documentation
- [ ] Create `Verify-Archives.ps1` (optional integrity checker)
- [ ] Create comprehensive README.md
- [ ] Create troubleshooting guide
- [ ] Test complete workflow with real data
- [ ] Document cost monitoring process

## Key Questions
1. ✓ PowerShell vs Python? → PowerShell (native Windows, simpler for this use case)
2. ✓ How to preserve file paths in staging? → Create full directory structure in staging folder
3. ✓ How to ensure safe deletion? → Verify with restic check before deleting
4. What PowerShell execution policy settings are needed?
5. What IAM permissions are required for S3?
6. How to handle very large files (>100GB)?
7. Should we implement progress bars for long operations?

## Technical Decisions

### Storage Configuration
- **Staging location**: Same drive as source files (instant moves, no extra space)
- **Tracking database**: JSON file (simple, human-readable, easy to backup)
- **Storage class**: S3 Glacier Deep Archive (cheapest, 12-48hr retrieval)
- **Restic repository**: S3 backend with AES-256 encryption

### Script Architecture
- **Language**: PowerShell 5.1+ (native Windows)
- **Error handling**: Try-catch blocks, comprehensive logging
- **User feedback**: Message boxes for notifications, detailed console output
- **Configuration**: Centralized config.json file

### File Paths
- Strip drive letter from staging paths (store relative paths)
- Track original drive in database
- Restore to original or alternate location

### Safety Mechanisms
1. Confirmation dialogs before destructive operations
2. Verification before deletion
3. Comprehensive logging
4. Tracking database for audit trail
5. Backblaze 1-year retention as fallback

## Configuration Files

### config.json
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

### tracking database schema (cold_storage_tracking.json)
```json
{
  "archives": [
    {
      "id": "unique-id",
      "original_path": "S:\\path\\to\\folder",
      "staged_date": "ISO-8601",
      "archived_date": "ISO-8601",
      "restic_snapshot_id": "snapshot-id",
      "size_bytes": 12345,
      "file_count": 100,
      "deleted_date": "ISO-8601",
      "status": "archived_and_deleted",
      "notes": "user notes"
    }
  ],
  "statistics": {
    "total_archived_bytes": 12345,
    "total_items": 1,
    "last_archive_date": "ISO-8601"
  }
}
```

## Decisions Made
- Using PowerShell over Python for native Windows integration
- Staging folder on same drive as source (instant moves)
- JSON tracking database (simple, human-readable)
- Context menu integration via Windows Registry
- Verification required before any deletion
- All scripts in C:\Scripts\ directory
- Staging area at S:\move_to_cold_storage\

## Errors Encountered
(None yet - track as implementation proceeds)

## Dependencies & Prerequisites
- Windows 10/11 with PowerShell 5.1+ (target deployment environment)
- WinGet package manager (built into Windows 11, available on Windows 10 via App Installer)
- AWS account with S3 access
- Administrator access (for registry modifications on Windows)
- Restic binary (installed via winget or manual download on Windows)

**Development Environment:**
- Devcontainer with PowerShell Core, AWS CLI, and restic
- Claude Code CLI for autonomous agent development
- Git for version control

**Note**: Scripts are developed in Linux devcontainer but designed to run on Windows. Final testing must be done on target Windows system.

## Testing Strategy
1. Install and configure with minimal AWS credentials
2. Test with small folder (~100MB, 10 files)
3. Verify staging preserves paths
4. Verify archival creates S3 objects
5. Verify restore retrieves correct files
6. Test error handling (bad credentials, network failure)
7. Test with larger folder (~5GB) before production use

## Success Criteria
- [ ] All 5 core scripts implemented and tested
- [ ] Context menu integration working
- [ ] Can successfully archive, query, and restore files
- [ ] Tracking database maintains accurate records
- [ ] All operations logged for debugging
- [ ] Documentation complete and clear
- [ ] Tested with real data (10+ TB archived)

## Status
**Currently in Phase 1: Setup & Configuration**
- ✅ Development environment configured (devcontainer with PowerShell, AWS CLI, restic)
- ✅ Project repository created and initialized
- ✅ Planning documents created (task_plan.md, IMPLEMENTATION_REFERENCE.md)
- Ready to begin implementation of Setup-Restic.ps1 script
- All prerequisites documented and understood

## Notes for Implementation

### Development Workflow (Hybrid Approach)

**Phase 1: Devcontainer Development (Autonomous)**
- Develop PowerShell script logic and structure
- Test basic functionality: file operations, AWS CLI, restic commands
- Validate PowerShell syntax and best practices
- Create comprehensive error handling
- Document script usage and parameters

**Phase 2: Windows Testing (Manual)**
- Deploy scripts to Windows test environment
- Test Windows-specific features:
  - Registry modifications (context menu)
  - Drive letter and path handling (C:\, S:\, etc.)
  - Windows PowerShell 5.1 compatibility
  - Actual file staging and archival workflow
  - WinGet installation process
- Report issues back for iteration

**Phase 3: Iteration**
- Agent fixes issues based on Windows test feedback
- Repeat cycle until fully functional

### Development Guidelines
- **Development environment**: Linux devcontainer with restic pre-installed
- **Deployment target**: Windows 10/11 where scripts will actually run
- Scripts will use WinGet to install restic on Windows (built into Windows 11, available via App Installer on Windows 10)
- Fallback to manual download if WinGet unavailable
- **Agent focus**: ~80% of functionality can be developed/tested in container (logic, AWS, restic)
- **Manual testing required**: Windows-specific features (registry, drive letters, context menus)
- Start with Setup-Restic.ps1 to get foundation working
- Test each script thoroughly before moving to next phase
- Use comprehensive error handling in all scripts
- Include inline comments for maintainability
- Follow PowerShell best practices (approved verbs, parameter validation)
- Show progress for long-running operations
- Make scripts user-friendly with clear prompts and feedback

## Reference Documentation
See comprehensive implementation plan document for:
- Detailed component descriptions
- Complete workflow diagrams
- Cost estimates and calculations
- Troubleshooting guide
- Best practices and maintenance

## Cost Tracking
Track AWS costs monthly:
- Storage: ~$1/TB/month
- Retrieval: ~$0.0025/GB (if needed)
- Target: Archive 10-20TB initially (~$10-20/month)
