# Findings & Decisions

## Requirements
- PowerShell-based cold storage archival system for Windows
- Right-click context menu integration for staging files
- Use restic + AWS S3 Glacier Deep Archive for backup
- JSON tracking database for audit trail
- Must verify backups before deleting local files
- Cross-platform development (Linux devcontainer) with Windows deployment

## Research Findings
- restic 0.17.3 installed and working in devcontainer
- restic supports S3 backend natively with AWS_PROFILE environment variable
- PowerShell Core 7.5.4 available for development; target is Windows PowerShell 5.1+
- AWS credentials configured via `~/.aws/credentials` with `cold-storage` profile
- S3 bucket `fahnzmode-cold-storage-archive` exists and is accessible in us-east-2

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| AWS credentials file with named profile | Cross-platform (Linux/Windows), standard approach, restic supports it natively |
| Profile name: `cold-storage` | Descriptive, easy to remember |
| Parameterized paths in scripts | Allows testing in Linux devcontainer with different paths than Windows deployment |
| Scripts in `scripts/` directory | Clean project organization; deploy to `C:\Scripts\` on Windows |
| JSON config file | Human-readable, easy to edit, sufficient for this use case |
| Platform detection in scripts | Use `$IsWindows` / `$IsLinux` to set appropriate default paths |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| (none yet) | |

## Resources
- Restic docs: https://restic.readthedocs.io/
- Restic S3 backend: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#amazon-s3
- AWS S3 Glacier pricing: https://aws.amazon.com/s3/pricing/
- Project implementation plan: implementation_plan.md
- Task breakdown: task_plan.md

## Configuration Values
```
AWS_PROFILE: cold-storage
S3_BUCKET: fahnzmode-cold-storage-archive
AWS_REGION: us-east-2
RESTIC_REPO: s3:s3.us-east-2.amazonaws.com/fahnzmode-cold-storage-archive
```

## Visual/Browser Findings
- (none - no web browsing performed yet)

---
*Update this file after every 2 view/browser/search operations*
