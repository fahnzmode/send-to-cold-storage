# Findings & Decisions

## Requirements
- PowerShell-based cold storage archival system for Windows
- Right-click context menu integration for staging files
- Use restic + AWS S3 Glacier Deep Archive for backup
- JSON tracking database for audit trail
- Must verify backups before deleting local files
- Direct Windows development for maximum agent autonomy

## Research Findings
- restic supports S3 backend natively with AWS_PROFILE environment variable
- Target environment: PowerShell Core 7+ (not Windows PowerShell 5.1)
- AWS credentials configured via `~/.aws/credentials` with `cold-storage` profile
- S3 bucket configured per-install (not hardcoded in repo)
- Devcontainer disabled - using direct Windows development for agent autonomy
- Windows 11 modern context menu requires COM DLL; classic menu via registry is simpler

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| AWS credentials file with named profile | Standard approach, restic supports it natively |
| Profile name: `cold-storage` | Descriptive, easy to remember |
| Scripts in `scripts/` directory | Clean project organization; deploy to `C:\Scripts\` on Windows |
| JSON config file | Human-readable, easy to edit, sufficient for this use case |
| Direct Windows development | Maximum agent autonomy, eliminates cross-platform issues |
| PowerShell Core 7+ (not 5.1) | Actively developed, modern features, user preference |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| `$IsWindows` not available in PowerShell 5.1 | Target PowerShell Core 7+ only |
| restic not in PATH after winget install | Store full path in config, use `restic_executable` |
| winget installs restic as `restic_0.18.1_windows_amd64.exe` | Search for `restic*.exe` pattern |
| Interactive scripts hang in non-interactive contexts | Created `Setup-Config.ps1` with mandatory params |
| PowerShell array/null handling edge cases | Wrap with `@()` and add null checks |

## Resources
- Restic docs: https://restic.readthedocs.io/
- Restic S3 backend: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#amazon-s3
- AWS S3 Glacier pricing: https://aws.amazon.com/s3/pricing/
- Project implementation plan: implementation_plan.md
- Task breakdown: task_plan.md

## Configuration Values
```
AWS_PROFILE: cold-storage (default, configurable)
S3_BUCKET: (configured per-install via Setup-Restic.ps1 or Setup-Config.ps1)
AWS_REGION: (configured per-install)
RESTIC_REPO: s3:s3.<region>.amazonaws.com/<bucket>
Scripts: C:\Scripts\ColdStorage\
Config: ~\.cold-storage\config.json
Password: ~\.cold-storage\.restic-password
Staging: C:\ColdStorageStaging\
```

## Visual/Browser Findings
- (none - no web browsing performed yet)

---
*Update this file after every 2 view/browser/search operations*
