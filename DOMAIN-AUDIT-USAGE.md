# Domain Audit Script Usage Guide

## Overview

The `domain-audit.sh` script performs comprehensive analysis of all domains on your cPanel server to identify:

- Recently expired domains
- Unregistered domains  
- Domains pointing to other servers
- Domains where you no longer provide services

Based on findings, it can automatically:
- Remove unregistered addon/parked domains
- Suspend accounts with unregistered primary domains (when no other domains exist)
- Suggest primary domain changes (requires manual action)
- Send email notifications for important actions

## Initial Setup

### 1. Configure Server Details

Edit `config/audit.conf` and update:

```bash
# Your server's hostname and IPs
SERVER_HOSTNAME="$(hostname -f)"
SERVER_IPS=(
    "162.247.79.106"  # Replace with your actual server IPs
    "192.168.1.100"   # Add additional IPs as needed
)

# Your mail server patterns
MX_PATTERNS=(
    "mail.yourdomain.com"     # Replace with your mail server
    "$(hostname -f)"
)

# Your nameservers
NS_PATTERNS=(
    "ns1.yourdomain.com"      # Replace with your nameservers
    "ns2.yourdomain.com"
)
```

### 2. Set Email Notifications

```bash
NOTIFICATION_EMAIL="service@svaha.com"  # Update if needed
```

### 3. Create Log Directory

```bash
mkdir -p /var/log/domain-audit
```

## Safety Features

### Dry Run Mode (Default)
```bash
DRY_RUN=true  # Default - no actual changes made
```

The script runs in dry-run mode by default. It will:
- Analyze all domains
- Log what actions it WOULD take
- Generate reports
- NOT make any actual changes

### Confirmation Required
```bash
REQUIRE_CONFIRMATION=true
```

When running in live mode, the script requires explicit confirmation before proceeding.

## Usage Examples

### 1. Initial Audit (Dry Run)
```bash
./domain-audit.sh
```

This performs a complete audit without making changes. Review the report before proceeding.

### 2. Live Run with Default Config
```bash
# First, edit config/audit.conf and set DRY_RUN=false
./domain-audit.sh
```

### 3. Custom Configuration
```bash
./domain-audit.sh /path/to/custom/audit.conf
```

## Understanding the Output

### Log Files
- **Main Log**: `/var/log/domain-audit/audit-YYYYMMDD-HHMMSS.log`
- **Report**: `/var/log/domain-audit/report-YYYYMMDD-HHMMSS.txt`

### Domain Status Classifications

| Status | Meaning | Action Taken |
|--------|---------|--------------|
| `unregistered` | Domain is not registered | Remove if addon/parked, suspend/change primary if main domain |
| `expired` | Domain registration has expired | Same as unregistered |
| `registered` | Domain is actively registered | Check if points to your server |
| `expiring_soon` | Domain expires within 30 days | Log warning, check server pointing |
| `registered_no_expiry` | Registered but expiry date not found | Check server pointing |
| `whois_failed` | WHOIS lookup failed | Manual investigation needed |

### Actions Taken

| Action | Description |
|--------|-------------|
| `removed_addon` | Addon domain removed from account |
| `removed_parked` | Parked domain removed from account |
| `suspended` | Account suspended due to unregistered primary domain |
| `primary_change_needed` | Manual primary domain change required |

## Domain Decision Logic

### For Unregistered/Expired Domains:

#### If Addon/Parked Domain:
- **Action**: Automatically removed
- **Rationale**: No point keeping unregistered addon domains

#### If Primary Domain:
- **Has Other Domains**: Suggests changing primary to another domain (manual action required)
- **No Other Domains**: Account suspended and notification sent

### For Registered Domains Pointing Elsewhere:

#### Domain points to other server:
1. Check if you handle MX (mail) records
2. Check if you are authoritative DNS server
3. If neither: Remove addon/parked domains
4. If either: Keep domain (you still provide services)

## Manual Actions Required

The script intentionally requires manual intervention for:

### 1. Primary Domain Changes
When an account's primary domain is unregistered but other domains exist, the script will:
- Send email notification
- Log the recommended change
- **NOT** automatically change the primary domain (for safety)

**Manual Steps**:
1. Log into WHM
2. Go to Account Functions → Change Primary Domain
3. Select the account and new primary domain

### 2. Complex Account Issues
Some situations require human judgment:
- Multiple expired domains in one account
- Domains with complex DNS setups
- Accounts with custom configurations

## Email Notifications

You'll receive emails for:
- Account suspensions
- Required primary domain changes
- Failed operations requiring attention

Email format:
```
Subject: [Domain Audit] Account Suspended: username
Body: Details about the action taken and reason
```

## Best Practices

### 1. Start with Dry Run
```bash
# Always start with dry run
DRY_RUN=true ./domain-audit.sh
```

### 2. Review Reports Carefully
- Check `/var/log/domain-audit/report-*.txt`
- Verify the proposed actions make sense
- Look for any unexpected results

### 3. Run During Maintenance Windows
- The script can take time with many domains
- WHOIS lookups may be rate-limited
- Schedule during low-traffic periods

### 4. Monitor Email Notifications
- Set up proper email delivery for service@svaha.com
- Check spam folders for notifications
- Act promptly on primary domain change requests

### 5. Regular Audits
```bash
# Monthly audit recommended
0 2 1 * * /root/scripts/domain-management/domain-audit.sh
```

## Troubleshooting

### Common Issues:

1. **WHOIS Timeouts**
   - Increase `WHOIS_TIMEOUT` in config
   - Add delay between lookups

2. **DNS Resolution Failures**
   - Check DNS server configuration
   - Verify network connectivity

3. **Permission Errors**
   - Run as root
   - Check file permissions on /etc/userdomains

4. **Email Not Sending**
   - Verify mail command availability
   - Check mail server configuration
   - Test with: `echo "test" | mail -s "test" service@svaha.com`

### Log Analysis:
```bash
# Find all suspended accounts
grep "suspended" /var/log/domain-audit/audit-*.log

# Find domains pointing elsewhere
grep "points elsewhere" /var/log/domain-audit/audit-*.log

# Find failed operations
grep "ERROR" /var/log/domain-audit/audit-*.log
```

## Recovery Procedures

### Undoing Account Suspensions:
```bash
# If you need to unsuspend an account
/scripts/unsuspendacct username
```

### Restoring Removed Domains:
Removed addon/parked domains would need to be re-added through cPanel if restoration is needed.

### Emergency Stop:
If the script is running and you need to stop it:
```bash
# Find the process
ps aux | grep domain-audit
# Kill it
kill <PID>
```

This script provides powerful automation but requires careful configuration and monitoring. Always test thoroughly in dry-run mode before enabling live operations.