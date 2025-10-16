# Domain Management Scripts

A collection of bash scripts for managing domains, DNS zones, and WHOIS lookups in cPanel environments.

## Scripts Overview

### 1. `check_domains.sh`
**Purpose**: Checks domain registration status and expiration dates via WHOIS lookups.

**Usage**:
```bash
./check_domains.sh [userdomains_file] [output_file]
```

**Features**:
- Processes domains from `/etc/userdomains` by default
- Extracts base domains from subdomains
- Performs WHOIS lookups with timeout protection
- Identifies unregistered domains
- Enhanced expiration date extraction with multiple pattern matching
- Rate limiting to prevent WHOIS server throttling
- Duplicate domain detection

**Output**: Text file with domain status and expiration information

### 2. `expiredcheck.sh`
**Purpose**: Discovers all domains on a cPanel server and identifies those with missing expiration dates.

**Usage**:
```bash
./expiredcheck.sh [domain_list_file] [missing_expiration_report]
```

**Features**:
- Automatic domain discovery from multiple sources:
  - cPanel DNS zones (`/var/named/*.db`)
  - cPanel userdata (`/var/cpanel/users`)
  - User domains file (`/etc/userdomains`)
- Primary domain filtering (excludes subdomains)
- TLD-specific WHOIS server detection
- Enhanced expiration date parsing with multiple pattern matching
- Missing expiration date reporting
- Rate limiting and timeout protection

**Output**: 
- Domain list file with unique primary domains
- Report of domains missing expiration dates

### 3. `make-domain-list.sh`
**Purpose**: Extracts unique base domains from the userdomains file.

**Usage**:
```bash
./make-domain-list.sh [userdomains_file] [output_file]
```

**Features**:
- Efficient duplicate detection using associative arrays
- Base domain extraction from subdomains
- Domain format validation
- Error handling for missing files
- Summary statistics

**Output**: Clean list of unique domains

### 4. `removedomain.sh`
**Purpose**: Comprehensive domain removal from cPanel system.

**Usage**:
```bash
./removedomain.sh <domain>
```

**Features**:
- Identifies domain ownership via `/etc/userdomains`
- Removes addon and parked domains via cPanel API
- Deletes DNS zones using cPanel scripts
- Handles orphaned domain references
- Comprehensive cleanup process

**Requirements**: Must be run as root on cPanel server

### 5. `updateDNS.sh`
**Purpose**: Updates DNS zone files with new IP addresses and syncs changes.

**Usage**:
```bash
./updateDNS.sh <dns_zone_file> [config_file]
```

**Features**:
- Configurable IP address replacement via configuration file
- Removal of specified IP addresses from SPF records
- Automatic serial number incrementing
- Optional DNS cluster synchronization
- Configurable file permissions and ownership
- Fallback to default values if config file is missing

**Configuration**: Uses `config/dns-update.conf` by default, or specify custom config file

### 6. `domain-audit.sh` ⭐ **ENHANCED**
**Purpose**: Comprehensive domain audit and cleanup automation for expired, unregistered, and externally-pointed domains.

**Usage**:
```bash
./domain-audit.sh [config_file]
```

**Features**:
- **Domain Status Analysis**: Detects expired, unregistered, and externally-pointed domains
- **Service Connection Checking**: Verifies MX and DNS server relationships for external domains
- **Automated Cleanup**: Removes unregistered addon/parked domains
- **Account Management**: Suspends accounts with unregistered primary domains (when no alternatives exist)
- **Primary Domain Migration**: Suggests primary domain changes for accounts with alternatives
- **Email Notifications**: Sends alerts to service@svaha.com for important actions
- **Safety Features**: Dry-run mode, confirmation prompts, comprehensive logging
- **Detailed Reporting**: Generates audit reports and action logs in `./reports/` directory
- **📧 Automatic Summary Reports**: Generates and emails statistical summaries with key findings
- **📊 Domain Statistics**: Categorizes domains by status with percentage breakdowns
- **🎯 Key Findings Lists**: Highlights top active, unregistered, and expired domains

**Configuration**: Uses `config/audit.conf` for server settings, email, and safety options

**⚠️ Important**: Always run in dry-run mode first! See `DOMAIN-AUDIT-USAGE.md` for detailed setup and usage instructions.

**Recent Fixes** (2025-10-15):
- ✅ Fixed report location (now uses `./reports/` instead of `/var/log/`)
- ✅ Fixed domain parsing (removed trailing colons)
- ✅ Fixed domain counting (now correctly shows 681 domains across 258 accounts)
- ✅ Cleaned up logging (eliminated duplicate/mixed log entries)
- ✅ Enhanced with automatic summary generation and email delivery

## SpamExperts Management (`spamexperts/`)

### 7. `spamexperts-audit.sh` ⭐ **NEW**
**Purpose**: Audit domains in SpamExperts service to identify cost savings and email service providers.

**Usage**:
```bash
./spamexperts-audit.sh [csv_file] [--email] [--monitor]
```

**Features**:
- **Email Service Detection**: Identifies Google Workspace, Microsoft 365, and 15+ other email providers
- **Cost Analysis**: Calculates potential savings from unused SpamExperts domains
- **Change Monitoring**: Tracks changes over time and alerts only when changes occur
- **Detailed Categorization**: Separate reports for each email service provider
- **Automated Cleanup Recommendations**: Lists domains that can be removed to save money
- **Multiple Output Modes**: Regular audit, email reports, or silent monitoring

### 8. `setup-spamexperts-monitoring.sh`
**Purpose**: Setup automated daily monitoring for SpamExperts service changes.

**Usage**:
```bash
./setup-spamexperts-monitoring.sh
```

**Features**:
- **Automated Setup**: Creates cron job for daily monitoring at 2 AM
- **Change-Only Notifications**: Only sends emails when domain status changes
- **Email Testing**: Verifies email delivery during setup
- **Baseline Creation**: Establishes current state for future change detection

## Configuration Files

### DNS Update Configuration (`config/dns-update.conf`)
Configure IP address mappings and behavior for `updateDNS.sh`:

```bash
# Primary IP replacement
OLD_IP="173.230.249.203"
NEW_IP="162.247.79.106"

# IP addresses to remove from SPF records  
REMOVE_IPS=(
    "+ip4:173.230.249.246"
    "+ip4:68.171.210.250"
)

# Operational settings
SYNC_TO_CLUSTER=true
SET_PERMISSIONS=true
OWNER="named"
GROUP="named" 
PERMISSIONS="600"
```

### Domain Audit Configuration (`config/audit.conf`)
Configure server details and behavior for `domain-audit.sh`:

```bash
# Email notifications
NOTIFICATION_EMAIL="service@svaha.com"

# Server identification (update these!)
SERVER_IPS=("162.247.79.106")
MX_PATTERNS=("mail.yourdomain.com")
NS_PATTERNS=("ns1.yourdomain.com" "ns2.yourdomain.com")

# Safety settings
DRY_RUN=true  # Set to false for live operations
REQUIRE_CONFIRMATION=true
MAX_SUSPENSIONS_PER_RUN=10
```

## Environment Variables

Several scripts support configuration via environment variables:

- `WHOIS_TIMEOUT`: Timeout for WHOIS queries (default: 30 seconds)
- `DELAY_SECONDS`: Rate limiting delay (default: 2 seconds)
- `RATE_LIMIT_DELAY`: Alternative rate limiting variable (default: 2 seconds)

## Prerequisites

- cPanel/WHM server environment
- Root access for domain removal and DNS operations
- Standard Unix utilities: `whois`, `awk`, `sed`, `grep`
- cPanel command-line tools: `/scripts/killdns`, `/scripts/updateuserdomains`, `/scripts/dnscluster`

## Security Considerations

- Scripts require elevated privileges for DNS and domain operations
- WHOIS queries may be rate-limited by external servers
- DNS changes are automatically synced to cluster members
- File permissions are enforced on DNS zone files

## Common Usage Patterns

1. **Domain Audit**:
   ```bash
   ./make-domain-list.sh
   ./check_domains.sh
   ./expiredcheck.sh
   ```

2. **Domain Cleanup**:
   ```bash
   ./removedomain.sh unwanted-domain.com
   ```

3. **DNS Migration**:
   ```bash
   for file in /var/named/*.db; do
       ./updateDNS.sh "$file"
   done
   ```

## Error Handling

All scripts include:
- Input validation
- File existence checks
- Timeout protection for external queries
- Graceful handling of missing data
- Informative error messages

## Limitations

- WHOIS parsing may occasionally fail for TLDs with highly non-standard formats
- Domain discovery depends on standard cPanel file locations
- Scripts assume cPanel/WHM environment
- DNS update configuration requires manual setup for new environments