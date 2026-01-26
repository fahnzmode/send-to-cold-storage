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
- Target environment: Windows PowerShell 5.1+ (direct Windows development)
- AWS credentials configured via `~/.aws/credentials` with `cold-storage` profile
- S3 bucket `fahnzmode-cold-storage-archive` exists and is accessible in us-east-2
- Devcontainer disabled - using direct Windows development for agent autonomy

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
