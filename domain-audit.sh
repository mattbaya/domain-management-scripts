#!/bin/bash

set -euo pipefail

# Domain Audit and Cleanup Script
#
# What it does:
# - Loads cPanel domain->account mappings from `/etc/userdomains` and primary domains
#   from `/var/cpanel/users/*` (normalizes to base domains for consistent WHOIS/cache keys).
# - Audits each domain:
#   - WHOIS registration status (active/expiring_soon/expired/unregistered/whois_failed/registered_no_expiry)
#   - DNS posture (A record points here? NS/MX handled here?) to flag "external"/"DNS-only" candidates.
# - Actions (LIVE mode only):
#   - Removes addon/parked domains via `uapi` when safe.
#   - Suspends accounts via `/scripts/suspendacct` when the PRIMARY domain is unregistered/expired and
#     there are no alternative domains.
#   - Primary domain changes are intentionally NOT automated; the script emails/logs a manual request.
#
# Outputs (under `$LOG_DIR`, usually `./reports/` via `config/audit.conf`):
# - `domain-status-cache-YYYYMMDD.txt` (consumed by `./simple-report.sh` and `./daily-audit.sh`)
# - `report-YYYYMMDD-HHMMSS.txt` and `domain-audit-summary-YYYYMMDD-HHMMSS.txt`
#
# Tuning (env vars):
# - `CACHE_SAVE_INTERVAL` (default 25): periodically writes cache during the run (0 disables).
# - `DOMAIN_AUDIT_MAX_DOMAINS` (default 0): stop after N domains (useful for testing).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for interactive flag
INTERACTIVE_MODE=false
if [[ "${1:-}" == "--interactive" ]]; then
    INTERACTIVE_MODE=true
    CONFIG_FILE="${2:-$SCRIPT_DIR/config/audit.conf}"
    # Interactive mode implies live mode
    FORCE_LIVE_MODE=true
else
    CONFIG_FILE="${1:-$SCRIPT_DIR/config/audit.conf}"
    FORCE_LIVE_MODE=false
fi

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found at $CONFIG_FILE"
    echo "Please create the configuration file or specify a different path."
    exit 1
fi

# Override DRY_RUN if interactive mode is specified
if [[ "$FORCE_LIVE_MODE" == "true" ]]; then
    DRY_RUN=false
    echo "🚶 Interactive mode enabled - setting LIVE mode (DRY_RUN=false)"
    echo "   You'll be prompted individually for each problematic domain"
fi

# Create log directory
mkdir -p "$LOG_DIR"

# With `set -e`, arithmetic like `((var++))` can abort the script because it
# returns status 1 when the expression evaluates to 0. We avoid that pattern
# below and also periodically write cache so cron runs have something to report.
CACHE_SAVE_INTERVAL="${CACHE_SAVE_INTERVAL:-25}"  # domains between cache writes (0 disables)
DOMAIN_AUDIT_MAX_DOMAINS="${DOMAIN_AUDIT_MAX_DOMAINS:-0}"  # 0 disables; useful for testing/partial runs

# Initialize arrays for tracking
declare -A domain_status
declare -A domain_accounts
declare -A account_domains
declare -A primary_domains
declare -A actions_taken

on_exit_save_cache() {
    # Best-effort: make sure we leave a cache behind even on early exit.
    # Avoid failing the script from inside the trap.
    if [[ ${#domain_status[@]} -gt 0 ]]; then
        save_domain_cache >/dev/null 2>&1 || true
    fi
}

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"
    echo "$log_line" >> "$LOG_FILE"
    echo "$log_line" >&2
}

# Extract base domain from subdomain for WHOIS queries
extract_base_domain() {
    local domain="$1"
    
    # Handle special multi-part TLDs first
    if [[ "$domain" =~ \.(co\.uk|org\.uk|ac\.uk|gov\.uk|net\.uk)$ ]]; then
        echo "$domain" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}'
    elif [[ "$domain" =~ \.(com\.au|net\.au|org\.au|edu\.au|gov\.au)$ ]]; then
        echo "$domain" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}'
    elif [[ "$domain" =~ \.(edu\.cn|com\.cn|net\.cn|org\.cn|gov\.cn)$ ]]; then
        echo "$domain" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}'
    else
        # Standard TLD - extract last two segments
        echo "$domain" | awk -F. '{ 
            if (NF > 2) {
                print $(NF-1)"."$NF
            } else {
                print $0
            }
        }'
    fi
}

# Enhanced expiration date extraction function
extract_expiration_date() {
    local whois_output="$1"
    local date=""
    
    local patterns=(
        "Registry Expiry Date:"
        "Registrar Registration Expiration Date:"
        "Expiration Date:"
        "Expiry Date:"
        "Expires:"
        "Valid Until:"
        "paid-till:"
        "Expiration Time:"
        "Registry Expiration:"
        "Domain Expiration Date:"
        "expire:"
        "renewal date:"
        "Renewal Date:"
        "Expires On:"
        "Record expires on"
    )
    
    for pattern in "${patterns[@]}"; do
        date=$(echo "$whois_output" | grep -i "^[[:space:]]*$pattern" | head -1 | cut -d: -f2- | xargs)
        if [[ -n "$date" ]]; then
            date=$(echo "$date" | cut -d'T' -f1 | cut -d' ' -f1-3)
            echo "$date"
            return 0
        fi
    done
    
    date=$(echo "$whois_output" | grep -i -E "(expir|renewal)" | grep -i "date" | head -1 | awk -F: '{print $2}' | xargs | cut -d'T' -f1)
    echo "$date"
}

# Check if domain is expired
is_domain_expired() {
    local domain="$1"
    local expiration_date="$2"
    
    if [[ -z "$expiration_date" ]]; then
        echo "unknown"
        return 1
    fi
    
    # Convert expiration date to timestamp
    local exp_timestamp
    if ! exp_timestamp=$(date -d "$expiration_date" +%s 2>/dev/null); then
        echo "unknown"
        return 1
    fi
    
    local current_timestamp=$(date +%s)
    local days_diff=$(( (exp_timestamp - current_timestamp) / 86400 ))
    
    if [[ $days_diff -lt 0 ]]; then
        echo "expired"
        return 0
    elif [[ $days_diff -lt 30 ]]; then
        echo "expiring_soon"
        return 0
    else
        echo "active"
        return 1
    fi
}

# Check if domain points to this server
check_domain_dns() {
    local domain="$1"
    local points_here=false
    
    # Check A records
    local a_records
    if a_records=$(timeout "$DNS_TIMEOUT" dig +short A "$domain" 2>/dev/null); then
        for server_ip in "${SERVER_IPS[@]}"; do
            if echo "$a_records" | grep -q "$server_ip"; then
                points_here=true
                break
            fi
        done
    fi
    
    echo "$points_here"
}

# Check if we handle MX for this domain
check_mx_records() {
    local domain="$1"
    local handles_mx=false
    
    local mx_records
    if mx_records=$(timeout "$DNS_TIMEOUT" dig +short MX "$domain" 2>/dev/null); then
        for mx_pattern in "${MX_PATTERNS[@]}"; do
            if echo "$mx_records" | grep -q "$mx_pattern"; then
                handles_mx=true
                break
            fi
        done
    fi
    
    echo "$handles_mx"
}

# Check if we are authoritative DNS for this domain
check_ns_records() {
    local domain="$1"
    local is_authoritative=false
    
    local ns_records
    if ns_records=$(timeout "$DNS_TIMEOUT" dig +short NS "$domain" 2>/dev/null); then
        for ns_pattern in "${NS_PATTERNS[@]}"; do
            if echo "$ns_records" | grep -q "$ns_pattern"; then
                is_authoritative=true
                break
            fi
        done
    fi
    
    echo "$is_authoritative"
}

# Check email usage for a domain
check_email_usage() {
    local domain="$1"
    local username="$2"
    
    # Initialize usage stats
    local mailbox_count=0
    local unread_count=0
    local recent_activity=false
    local forwarding_active=false
    local total_size=0
    
    # Check for mailboxes under this domain
    if [[ -d "/home/$username/mail/$domain" ]]; then
        # Count mailboxes
        mailbox_count=$(find "/home/$username/mail/$domain" -type d -name "cur" 2>/dev/null | wc -l)
        
        # Count unread messages across all mailboxes
        unread_count=$(find "/home/$username/mail/$domain" -path "*/new/*" -type f 2>/dev/null | wc -l)
        
        # Calculate total mailbox size
        if [[ $mailbox_count -gt 0 ]]; then
            total_size=$(du -sb "/home/$username/mail/$domain" 2>/dev/null | awk '{print $1}')
            [[ -z "$total_size" ]] && total_size=0
        fi
    fi
    
    # Check recent mail activity in logs (last 30 days)
    local thirty_days_ago=$(date -d "30 days ago" "+%b %d")
    if [[ -f "/var/log/maillog" ]]; then
        # Check for recent POP/IMAP/webmail connections for this domain
        if grep -q "$domain" /var/log/maillog 2>/dev/null && \
           grep "$domain" /var/log/maillog 2>/dev/null | \
           awk -v date="$thirty_days_ago" '$0 >= date' | \
           grep -q -E "(pop3|imap|webmail|dovecot)" 2>/dev/null; then
            recent_activity=true
        fi
    fi
    
    # Check for email forwarding rules
    local external_forwards=0
    local internal_forwards=0
    
    # Check main user forwarding
    if [[ -f "/home/$username/.forward" ]]; then
        if grep -q "@" "/home/$username/.forward" 2>/dev/null; then
            forwarding_active=true
            # Count external vs internal forwards
            while read -r forward_addr; do
                if [[ "$forward_addr" =~ @.*\.(com|org|net|edu|gov) ]] && [[ ! "$forward_addr" =~ @.*$(hostname -d) ]]; then
                    ((++external_forwards))
                else
                    ((++internal_forwards))
                fi
            done < "/home/$username/.forward"
        fi
    fi
    
    # Check domain-specific forwarding in cPanel
    local email_accounts=0
    if [[ -f "/home/$username/etc/$domain/passwd" ]]; then
        # Domain has email accounts configured
        email_accounts=$(wc -l < "/home/$username/etc/$domain/passwd" 2>/dev/null)
        [[ -z "$email_accounts" ]] && email_accounts=0
        
        # Check for individual email account forwards
        if [[ -d "/home/$username/etc/$domain" ]]; then
            local forward_files=("/home/$username/etc/$domain"/*.forward)
            if [[ -e "${forward_files[0]}" ]]; then
                for forward_file in "${forward_files[@]}"; do
                    [[ ! -f "$forward_file" ]] && continue
                    while read -r forward_addr; do
                        [[ -z "$forward_addr" || "$forward_addr" =~ ^[[:space:]]*# ]] && continue
                        if [[ "$forward_addr" =~ @.*\.(com|org|net|edu|gov) ]] && [[ ! "$forward_addr" =~ @.*$(hostname -d) ]]; then
                            ((++external_forwards))
                        else
                            ((++internal_forwards))
                        fi
                    done < "$forward_file"
                done
            fi
        fi
    fi
    
    # Output results as a structured string
    echo "mailboxes:$mailbox_count|unread:$unread_count|size:$total_size|recent:$recent_activity|forwarding:$forwarding_active|accounts:${email_accounts:-0}|ext_forwards:$external_forwards|int_forwards:$internal_forwards"
}

# Parse email usage results 
parse_email_usage() {
    local usage_string="$1"
    local field="$2"
    
    echo "$usage_string" | sed 's/|/\n/g' | grep "^$field:" | cut -d: -f2
}

# Get domain status via WHOIS
get_domain_status() {
    local domain="$1"
    local status="unknown"
    
    # Extract base domain for WHOIS query (subdomains don't have WHOIS records)
    local base_domain
    base_domain=$(extract_base_domain "$domain")
    
    # Only log the actual domain being queried if it's different
    if [[ "$domain" != "$base_domain" ]]; then
        log "INFO" "Checking WHOIS for domain: $domain (querying base domain: $base_domain)"
    else
        log "INFO" "Checking WHOIS for domain: $domain"
    fi
    
    local whois_output
    if ! whois_output=$(timeout "$WHOIS_TIMEOUT" whois "$base_domain" 2>/dev/null); then
        status="whois_failed"
    elif echo "$whois_output" | grep -Eqi "no match|not found|domain not found|no data found"; then
        status="unregistered"
    else
        local expiration_date
        expiration_date=$(extract_expiration_date "$whois_output")
        
        if [[ -n "$expiration_date" ]]; then
            status=$(is_domain_expired "$base_domain" "$expiration_date")
            if [[ "$status" == "unknown" ]]; then
                status="registered"
            fi
        else
            status="registered_no_expiry"
        fi
    fi
    
    echo "$status"
}

# Load domain and account information
load_domain_data() {
    log "INFO" "Loading domain and account data..."
    
    # Read userdomains file
    if [[ ! -f "/etc/userdomains" ]]; then
        log "ERROR" "/etc/userdomains not found"
        exit 1
    fi
    
    declare -A seen_base_domains  # Track base domains we've already processed
    
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        local domain=$(echo "$line" | awk '{print $1}' | sed 's/:$//')
        local username=$(echo "$line" | awk '{print $2}')
        
        [[ -z "$domain" || -z "$username" ]] && continue
        [[ "$domain" == "*" ]] && continue
        
        # Extract base domain to match our cleaned cache
        local base_domain
        base_domain=$(extract_base_domain "$domain")
        
        # Only process each base domain once (avoid duplicates from subdomains)
        if [[ -z "${seen_base_domains[$base_domain]:-}" ]]; then
            seen_base_domains["$base_domain"]="$username"
            domain_accounts["$base_domain"]="$username"
            
            # Build account -> domains mapping using base domains
            if [[ -n "${account_domains[$username]:-}" ]]; then
                account_domains["$username"]+=" $base_domain"
            else
                account_domains["$username"]="$base_domain"
            fi
        fi
    done < "/etc/userdomains"
    
    # Identify primary domains for each account
    for username in "${!account_domains[@]}"; do
        if [[ -f "/var/cpanel/users/$username" ]]; then
            local primary_domain
            primary_domain=$(grep "^DNS=" "/var/cpanel/users/$username" 2>/dev/null | cut -d= -f2 || echo "")
            if [[ -n "$primary_domain" ]]; then
                # Convert primary domain to base domain to match our processing
                local base_primary
                base_primary=$(extract_base_domain "$primary_domain")
                primary_domains["$username"]="$base_primary"
            fi
        fi
    done
    
    domain_count=${#domain_accounts[@]}
    account_count=${#account_domains[@]}
    log "INFO" "Loaded $domain_count domains across $account_count accounts"
}

# Cache management functions
save_domain_cache() {
    local cache_file="$LOG_DIR/domain-status-cache-$(date +%Y%m%d).txt"
    log "INFO" "Saving domain status cache to $cache_file"
    
    {
        echo "# Domain Status Cache - Generated $(date)"
        echo "# Format: domain:status:timestamp:is_primary"
        for domain in "${!domain_status[@]}"; do
            local username="${domain_accounts[$domain]}"
            local is_primary="false"
            if [[ "${primary_domains[$username]:-}" == "$domain" ]]; then
                is_primary="true"
            fi
            echo "$domain:${domain_status[$domain]}:$(date +%s):$is_primary"
        done | sort
    } > "$cache_file"
    
    log "INFO" "Cache saved with ${#domain_status[@]} domain statuses"
}

load_domain_cache() {
    local cache_file="$LOG_DIR/domain-status-cache-$(date +%Y%m%d).txt"
    local max_age_hours=24
    local loaded_count=0
    
    if [[ ! -f "$cache_file" ]]; then
        log "INFO" "No cache file found for today: $cache_file"
        return 1
    fi
    
    # Check cache age
    local cache_age=$(( ($(date +%s) - $(stat -c %Y "$cache_file")) / 3600 ))
    if [[ $cache_age -gt $max_age_hours ]]; then
        log "INFO" "Cache file is $cache_age hours old (max: $max_age_hours), ignoring"
        return 1
    fi
    
    log "INFO" "Loading domain status cache from $cache_file (age: $cache_age hours)"
    
    # Load cached domain statuses
    while IFS=':' read -r domain status timestamp is_primary; do
        # Skip comments and empty lines
        [[ -z "$domain" || "$domain" =~ ^[[:space:]]*# ]] && continue
        
        # Validate the cached domain exists in current domain list
        if [[ -n "${domain_accounts[$domain]:-}" ]]; then
            domain_status["$domain"]="$status"
            ((++loaded_count))
        fi
    done < "$cache_file"
    
    log "INFO" "Loaded $loaded_count domain statuses from cache"
    return 0
}

check_cache_coverage() {
    local total_domains=${#domain_accounts[@]}
    local cached_domains=${#domain_status[@]}
    local coverage_percent=0
    
    if [[ $total_domains -gt 0 ]]; then
        coverage_percent=$(( cached_domains * 100 / total_domains ))
    fi
    
    log "INFO" "Cache coverage: $cached_domains/$total_domains domains ($coverage_percent%)"
    
    # Return success if we have good cache coverage (80% or more)
    [[ $coverage_percent -ge 80 ]]
}

# Send email notification
send_notification() {
    local subject="$1"
    local body="$2"
    
    if command -v mail >/dev/null 2>&1; then
        echo "$body" | mail -s "$MAIL_SUBJECT_PREFIX $subject" "$NOTIFICATION_EMAIL"
        log "INFO" "Email notification sent to $NOTIFICATION_EMAIL"
    else
        log "WARNING" "Mail command not available, notification not sent"
        log "INFO" "Notification would have been: $subject"
    fi
}

# Remove addon or parked domain
remove_addon_parked_domain() {
    local domain="$1"
    local username="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would remove addon/parked domain: $domain (user: $username)"
        return 0
    fi
    
    log "INFO" "Removing addon/parked domain: $domain (user: $username)"
    
    # Try removing as addon domain
    if uapi --user="$username" DomainInfo remove_addon_domain domain="$domain" >/dev/null 2>&1; then
        log "INFO" "Successfully removed addon domain: $domain"
        actions_taken["$domain"]="removed_addon"
        return 0
    fi
    
    # Try removing as parked domain
    if uapi --user="$username" DomainInfo remove_parked_domain domain="$domain" >/dev/null 2>&1; then
        log "INFO" "Successfully removed parked domain: $domain"
        actions_taken["$domain"]="removed_parked"
        return 0
    fi
    
    log "WARNING" "Failed to remove domain $domain - may not be addon/parked"
    return 1
}

# Suspend account
suspend_account() {
    local username="$1"
    local reason="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would suspend account: $username (reason: $reason)"
        return 0
    fi
    
    log "INFO" "Suspending account: $username (reason: $reason)"
    
    if /scripts/suspendacct "$username" "$reason" >/dev/null 2>&1; then
        log "INFO" "Successfully suspended account: $username"
        actions_taken["account_$username"]="suspended"
        
        # Send notification
        local subject="Account Suspended: $username"
        local body="Account $username has been suspended due to: $reason

Primary domain status: $reason
Date: $(date)
Server: $(hostname -f)"
        
        send_notification "$subject" "$body"
        return 0
    else
        log "ERROR" "Failed to suspend account: $username"
        return 1
    fi
}

# Change primary domain for account
change_primary_domain() {
    local username="$1"
    local old_primary="$2"
    local new_primary="$3"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would change primary domain for $username: $old_primary -> $new_primary"
        return 0
    fi
    
    log "INFO" "Changing primary domain for $username: $old_primary -> $new_primary"
    
    # This is a complex operation that may require cPanel API calls
    # For safety, we'll log the action but not implement the actual change
    log "WARNING" "Primary domain change requires manual intervention for safety"
    log "INFO" "Manual action required: Change primary domain for $username from $old_primary to $new_primary"
    
    actions_taken["account_$username"]="primary_change_needed"
    
    # Send notification for manual action
    local subject="Manual Action Required: Primary Domain Change"
    local body="Account $username requires primary domain change:
    
Old primary (unregistered): $old_primary
Suggested new primary: $new_primary
Account domains: ${account_domains[$username]}

Please manually change the primary domain through WHM.
Date: $(date)
Server: $(hostname -f)"
    
    send_notification "$subject" "$body"
}

# Interactive confirmation for domain action with real-time verification
confirm_domain_action() {
    local domain="$1"
    local action="$2"
    local username="$3"
    local status="$4"
    
    if [[ "$INTERACTIVE_MODE" == "true" && "$DRY_RUN" == "false" ]]; then
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔍 DOMAIN VERIFICATION: $domain (account: $username)"
        echo "📊 Cached status: $status"
        echo "🎯 Proposed action: $action"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  Using cached status (skipping real-time WHOIS for speed)"
        echo
        
        local whois_output
        local current_status="unknown"
        
        if whois_output=$(timeout "$WHOIS_TIMEOUT" whois "$base_domain" 2>/dev/null); then
            if echo "$whois_output" | grep -Eqi "no match|not found|domain not found|no data found"; then
                current_status="🔴 UNREGISTERED"
                echo "   ❌ Domain appears to be UNREGISTERED"
            else
                current_status="🟢 REGISTERED"
                echo "   ✅ Domain is REGISTERED"
                
                # Extract and show expiration date
                local expiration_date
                expiration_date=$(extract_expiration_date "$whois_output")
                if [[ -n "$expiration_date" ]]; then
                    echo "   📅 Expires: $expiration_date"
                    
                    # Check if expired or expiring soon
                    local exp_status
                    exp_status=$(is_domain_expired "$base_domain" "$expiration_date")
                    case "$exp_status" in
                        "expired") echo "   ⚠️  Domain has EXPIRED" ;;
                        "expiring_soon") echo "   ⚠️  Domain expires within 30 days" ;;
                        "active") echo "   ✅ Domain expiration is current" ;;
                    esac
                else
                    echo "   📅 Expiration: Not found in WHOIS"
                fi
                
                # Show registrar if available
                local registrar
                registrar=$(echo "$whois_output" | grep -i "registrar:" | head -1 | cut -d: -f2- | xargs)
                [[ -n "$registrar" ]] && echo "   🏢 Registrar: $registrar"
            fi
        else
            current_status="❓ WHOIS FAILED"
            echo "   ❌ WHOIS query failed (timeout or error)"
        fi
        
        echo
        echo "🌐 DNS & MX RECORD CHECK:"
        echo "   ────────────────────────────────────────"
        
        # Check A records
        echo "   🔗 A Records:"
        local a_records
        local points_here=false
        if a_records=$(timeout "$DNS_TIMEOUT" dig +short A "$domain" 2>/dev/null); then
            if [[ -n "$a_records" ]]; then
                echo "$a_records" | while read -r ip; do
                    [[ -z "$ip" ]] && continue
                    local points_to_us=""
                    for server_ip in "${SERVER_IPS[@]}"; do
                        if [[ "$ip" == "$server_ip" ]]; then
                            points_to_us=" ← THIS SERVER"
                            points_here=true
                            break
                        fi
                    done
                    echo "      • $ip$points_to_us"
                done
                # Store result for later use
                if echo "$a_records" | grep -q "$(echo "${SERVER_IPS[@]}" | tr ' ' '|')"; then
                    points_here=true
                fi
            else
                echo "      • No A records found"
            fi
        else
            echo "      • DNS query failed"
        fi
        
        # Check MX records
        echo "   📧 MX Records:"
        local mx_records
        local handles_mx=false
        if mx_records=$(timeout "$DNS_TIMEOUT" dig +short MX "$domain" 2>/dev/null); then
            if [[ -n "$mx_records" ]]; then
                echo "$mx_records" | while read -r priority server; do
                    [[ -z "$server" ]] && continue
                    local our_mx=""
                    for mx_pattern in "${MX_PATTERNS[@]}"; do
                        if echo "$server" | grep -q "$mx_pattern"; then
                            our_mx=" ← OUR MAIL SERVER"
                            handles_mx=true
                            break
                        fi
                    done
                    echo "      • $priority $server$our_mx"
                done
                # Store result for later use
                for mx_pattern in "${MX_PATTERNS[@]}"; do
                    if echo "$mx_records" | grep -q "$mx_pattern"; then
                        handles_mx=true
                        break
                    fi
                done
                
                # If we handle MX, check email usage
                if [[ "$handles_mx" == "true" ]]; then
                    echo "   📊 Email Usage Analysis:"
                    local email_usage
                    email_usage=$(check_email_usage "$domain" "$username")
                    
                    local mailbox_count unread_count total_size recent_activity forwarding_active email_accounts external_forwards internal_forwards
                    mailbox_count=$(parse_email_usage "$email_usage" "mailboxes")
                    unread_count=$(parse_email_usage "$email_usage" "unread")
                    total_size=$(parse_email_usage "$email_usage" "size")
                    recent_activity=$(parse_email_usage "$email_usage" "recent")
                    forwarding_active=$(parse_email_usage "$email_usage" "forwarding")
                    email_accounts=$(parse_email_usage "$email_usage" "accounts")
                    external_forwards=$(parse_email_usage "$email_usage" "ext_forwards")
                    internal_forwards=$(parse_email_usage "$email_usage" "int_forwards")
                    
                    echo "      • Email accounts: $email_accounts"
                    echo "      • Active mailboxes: $mailbox_count"
                    echo "      • Unread messages: $unread_count"
                    if [[ $total_size -gt 0 ]]; then
                        local size_mb=$((total_size / 1024 / 1024))
                        echo "      • Total mailbox size: ${size_mb}MB"
                    fi
                    
                    # Show forwarding information
                    if [[ "$forwarding_active" == "true" ]]; then
                        if [[ $external_forwards -gt 0 ]]; then
                            echo "      • 📨 External forwards: $external_forwards (forwarding TO external domains)"
                        fi
                        if [[ $internal_forwards -gt 0 ]]; then
                            echo "      • 🔄 Internal forwards: $internal_forwards (forwarding within our server)"
                        fi
                    fi
                    
                    if [[ "$recent_activity" == "true" ]]; then
                        echo "      • Recent activity: ✅ Yes (last 30 days)"
                    else
                        echo "      • Recent activity: ❌ No activity found"
                    fi
                    
                    # Email usage recommendations
                    if [[ $external_forwards -gt 0 && $mailbox_count -eq 0 && "$recent_activity" == "false" ]]; then
                        echo "      ⚠️  WARNING: Only forwarding externally, no local email usage"
                        echo "         Consider disabling email services to save resources"
                    elif [[ $email_accounts -gt 0 && $unread_count -eq 0 && "$recent_activity" == "false" ]]; then
                        echo "      ⚠️  INFO: Email accounts configured but no recent usage"
                    fi
                    
                    # Determine if email is actually being used
                    if [[ $email_accounts -eq 0 && $mailbox_count -eq 0 && "$recent_activity" == "false" && "$forwarding_active" == "false" ]]; then
                        echo "      ⚠️  EMAIL APPEARS UNUSED - MX points here but no activity detected"
                    elif [[ "$recent_activity" == "false" && $unread_count -eq 0 && "$forwarding_active" == "false" ]]; then
                        echo "      ⚠️  EMAIL MAY BE UNUSED - No recent activity or unread mail"
                    fi
                fi
            else
                echo "      • No MX records found"
            fi
        else
            echo "      • DNS query failed"
        fi
        
        # Check NS records
        echo "   🌍 Name Servers:"
        local ns_records
        local is_authoritative=false
        if ns_records=$(timeout "$DNS_TIMEOUT" dig +short NS "$domain" 2>/dev/null); then
            if [[ -n "$ns_records" ]]; then
                echo "$ns_records" | while read -r ns; do
                    [[ -z "$ns" ]] && continue
                    local our_ns=""
                    for ns_pattern in "${NS_PATTERNS[@]}"; do
                        if echo "$ns" | grep -q "$ns_pattern"; then
                            our_ns=" ← OUR DNS"
                            is_authoritative=true
                            break
                        fi
                    done
                    echo "      • $ns$our_ns"
                done
                # Store result for later use  
                for ns_pattern in "${NS_PATTERNS[@]}"; do
                    if echo "$ns_records" | grep -q "$ns_pattern"; then
                        is_authoritative=true
                        break
                    fi
                done
            else
                echo "      • No NS records found"
            fi
        else
            echo "      • DNS query failed"
        fi
        
        echo
        echo "📋 SUMMARY:"
        echo "   • WHOIS Status: $current_status"
        if [[ "$points_here" == "true" ]]; then
            echo "   • DNS: ✅ Points to our server"
        else
            echo "   • DNS: ❌ Points elsewhere or not found"
        fi
        if [[ "$handles_mx" == "true" ]]; then
            echo "   • Email: ✅ We handle mail"
        else
            echo "   • Email: ❌ Mail handled elsewhere or not configured"
        fi
        if [[ "$is_authoritative" == "true" ]]; then
            echo "   • Name Servers: ✅ We are authoritative"
        else
            echo "   • Name Servers: ❌ Handled elsewhere"
        fi
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        read -p "After reviewing the above information, proceed with: $action? [y/N/s(kip all)/q(uit)]: " -r response
        
        case "$response" in
            [Yy]|[Yy][Ee][Ss])
                return 0  # Proceed with action
                ;;
            [Ss]|[Ss][Kk][Ii][Pp])
                echo "⏩ Skipping all remaining interactive prompts"
                INTERACTIVE_MODE=false
                return 0  # Proceed and disable interactive mode
                ;;
            [Qq]|[Qq][Uu][Ii][Tt])
                echo "🛑 Audit stopped by user"
                exit 0
                ;;
            *)
                echo "⏭️  Skipping $domain"
                return 1  # Skip this action
                ;;
        esac
    fi
    
    return 0  # Always proceed if not in interactive mode
}

# Main audit function
audit_domain() {
    local domain="$1"
    local username="${domain_accounts[$domain]}"
    local is_primary=false
    
    # Check if this is a primary domain
    if [[ "${primary_domains[$username]:-}" == "$domain" ]]; then
        is_primary=true
    fi
    
    log "INFO" "Auditing domain: $domain (user: $username, primary: $is_primary)"
    
    # Get domain registration status (use cached if available)
    local registration_status
    if [[ -n "${domain_status[$domain]:-}" ]]; then
        registration_status="${domain_status[$domain]}"
        log "INFO" "Domain $domain: status=$registration_status (cached)"
    else
        registration_status=$(get_domain_status "$domain")
        domain_status["$domain"]="$registration_status"
        log "INFO" "Domain $domain: status=$registration_status"
    fi
    
    # Handle based on status
    case "$registration_status" in
        "unregistered")
            if [[ "$is_primary" == "true" ]]; then
                # Primary domain is unregistered
                local other_domains
                other_domains=$(echo "${account_domains[$username]}" | tr ' ' '\n' | grep -v "^$domain$" || echo "")
                
                if [[ -z "$other_domains" ]]; then
                    # No other domains - suspend account
                    if confirm_domain_action "$domain" "SUSPEND account '$username' (no other domains)" "$username" "$registration_status"; then
                        suspend_account "$username" "Primary domain unregistered: $domain"
                    fi
                else
                    # Has other domains - suggest primary domain change
                    local new_primary
                    new_primary=$(echo "$other_domains" | head -1)
                    if confirm_domain_action "$domain" "CHANGE primary domain from '$domain' to '$new_primary'" "$username" "$registration_status"; then
                        change_primary_domain "$username" "$domain" "$new_primary"
                    fi
                fi
            else
                # Addon/parked domain is unregistered - remove it
                if confirm_domain_action "$domain" "REMOVE addon/parked domain from account" "$username" "$registration_status"; then
                    remove_addon_parked_domain "$domain" "$username"
                fi
            fi
            ;;
            
        "expired")
            # Similar handling to unregistered, but log differently
            log "WARNING" "Domain $domain has expired"
            if [[ "$is_primary" == "true" ]]; then
                local other_domains
                other_domains=$(echo "${account_domains[$username]}" | tr ' ' '\n' | grep -v "^$domain$" || echo "")
                
                if [[ -z "$other_domains" ]]; then
                    if confirm_domain_action "$domain" "SUSPEND account '$username' (expired primary domain)" "$username" "$registration_status"; then
                        suspend_account "$username" "Primary domain expired: $domain"
                    fi
                else
                    local new_primary
                    new_primary=$(echo "$other_domains" | head -1)
                    if confirm_domain_action "$domain" "CHANGE primary domain from '$domain' to '$new_primary'" "$username" "$registration_status"; then
                        change_primary_domain "$username" "$domain" "$new_primary"
                    fi
                fi
            else
                if confirm_domain_action "$domain" "REMOVE expired addon/parked domain from account" "$username" "$registration_status"; then
                    remove_addon_parked_domain "$domain" "$username"
                fi
            fi
            ;;
            
        "registered"|"registered_no_expiry"|"expiring_soon")
            # Domain is registered, check if it points elsewhere
            local points_here
            points_here=$(check_domain_dns "$domain")
            
            if [[ "$points_here" == "false" ]]; then
                # Domain points elsewhere, check our services
                local handles_mx handles_dns
                handles_mx=$(check_mx_records "$domain")
                handles_dns=$(check_ns_records "$domain")
                
                log "INFO" "Domain $domain points elsewhere (MX: $handles_mx, DNS: $handles_dns)"
                
                if [[ "$handles_mx" == "false" && "$handles_dns" == "false" ]]; then
                    # We have no connection to this domain
                    if [[ "$is_primary" == "false" ]]; then
                        if confirm_domain_action "$domain" "REMOVE external domain (no connection to our services)" "$username" "$registration_status"; then
                            remove_addon_parked_domain "$domain" "$username"
                        fi
                    else
                        log "WARNING" "Primary domain $domain has no connection to our services"
                    fi
                elif [[ "$handles_mx" == "false" && "$handles_dns" == "true" ]]; then
                    # DNS-only candidate: We provide DNS but they host elsewhere and handle their own email
                    log "INFO" "DNS-only candidate: $domain (user: $username) - hosting and email elsewhere, we provide DNS only"
                    actions_taken["dns_only_$domain"]="dns_only_candidate"
                    
                    # For non-primary domains, offer to remove and suggest moving DNS to registrar
                    if [[ "$is_primary" == "false" ]]; then
                        if confirm_domain_action "$domain" "REMOVE DNS-only domain (suggest moving DNS to registrar)" "$username" "$registration_status"; then
                            remove_addon_parked_domain "$domain" "$username"
                        fi
                    else
                        log "WARNING" "Primary domain $domain is DNS-only - consider moving DNS to registrar"
                    fi
                fi
            fi
            ;;
    esac
    
    # Rate limiting
    sleep "$RATE_LIMIT_DELAY"
}

# Generate report
generate_report() {
    log "INFO" "Generating audit report..."
    
    {
        echo "Domain Audit Report"
        echo "Generated: $(date)"
        echo "Server: $(hostname -f)"
        echo "Mode: $([ "$DRY_RUN" == "true" ] && echo "DRY RUN" || echo "LIVE")"
        echo "=========================================="
        echo
        
        echo "DOMAIN STATUS SUMMARY:"
        for domain in "${!domain_status[@]}"; do
            echo "$domain: ${domain_status[$domain]} (${domain_accounts[$domain]})"
        done | sort
        echo
        
        echo "ACTIONS TAKEN:"
        action_count=0
        if [[ -v actions_taken ]]; then
            action_count=${#actions_taken[@]}
        fi
        if [[ $action_count -eq 0 ]]; then
            echo "No actions taken."
        else
            for item in "${!actions_taken[@]}"; do
                echo "$item: ${actions_taken[$item]}"
            done | sort
        fi
        echo
        
        echo "See detailed log at: $LOG_FILE"
        
    } > "$REPORT_FILE"
    
    log "INFO" "Report generated: $REPORT_FILE"
}

# Generate summary report and email it
generate_summary_report() {
    local summary_file="$LOG_DIR/domain-audit-summary-$(date +%Y%m%d-%H%M%S).txt"
    
    # Count domain statuses
    local total_domains=${#domain_status[@]}
    local active_count=0
    local unregistered_count=0
    local expired_count=0
    local failed_count=0
    local external_count=0
    local dns_only_count=0
    
    for status in "${domain_status[@]}"; do
        case "$status" in
            "active") ((++active_count)) ;;
            "unregistered") ((++unregistered_count)) ;;
            "expired") ((++expired_count)) ;;
            "whois_failed") ((++failed_count)) ;;
            "external") ((++external_count)) ;;
        esac
    done
    
    # Count DNS-only candidates from actions taken
    for action_key in "${!actions_taken[@]}"; do
        if [[ "$action_key" =~ ^dns_only_ && "${actions_taken[$action_key]}" == "dns_only_candidate" ]]; then
            ((++dns_only_count))
        fi
    done
    
    # Generate summary report
    {
        echo "Domain Audit Summary Report"
        echo "Generated: $(date)"
        echo "Server: $(hostname -f)"
        echo "Mode: $([ "$DRY_RUN" == "true" ] && echo "DRY RUN" || echo "LIVE")"
        echo "=========================================="
        echo
        echo "AUDIT RESULTS ($total_domains domains processed):"
        echo "• Active domains: $active_count ($(( active_count * 100 / total_domains || 0 ))%)"
        echo "• Unregistered domains: $unregistered_count ($(( unregistered_count * 100 / total_domains || 0 ))%)"
        echo "• Expired domains: $expired_count ($(( expired_count * 100 / total_domains || 0 ))%)"
        echo "• External domains: $external_count ($(( external_count * 100 / total_domains || 0 ))%)"
        echo "• DNS-only candidates: $dns_only_count ($(( dns_only_count * 100 / total_domains || 0 ))%)"
        echo "• WHOIS failed: $failed_count ($(( failed_count * 100 / total_domains || 0 ))%)"
        echo
        
        if [[ $active_count -gt 0 ]]; then
            echo "ACTIVE DOMAINS:"
            for domain in "${!domain_status[@]}"; do
                if [[ "${domain_status[$domain]}" == "active" ]]; then
                    echo "- $domain (user: ${domain_accounts[$domain]})"
                fi
            done | sort | head -10
            [[ $active_count -gt 10 ]] && echo "... and $(( active_count - 10 )) more"
            echo
        fi
        
        if [[ $unregistered_count -gt 0 ]]; then
            echo "UNREGISTERED DOMAINS:"
            for domain in "${!domain_status[@]}"; do
                if [[ "${domain_status[$domain]}" == "unregistered" ]]; then
                    echo "- $domain (user: ${domain_accounts[$domain]})"
                fi
            done | sort | head -10
            [[ $unregistered_count -gt 10 ]] && echo "... and $(( unregistered_count - 10 )) more"
            echo
        fi
        
        if [[ $expired_count -gt 0 ]]; then
            echo "EXPIRED DOMAINS:"
            for domain in "${!domain_status[@]}"; do
                if [[ "${domain_status[$domain]}" == "expired" ]]; then
                    echo "- $domain (user: ${domain_accounts[$domain]})"
                fi
            done | sort | head -10
            [[ $expired_count -gt 10 ]] && echo "... and $(( expired_count - 10 )) more"
            echo
        fi
        
        if [[ $dns_only_count -gt 0 ]]; then
            echo "DNS-ONLY CANDIDATES (hosting & email elsewhere):"
            for action_key in "${!actions_taken[@]}"; do
                if [[ "$action_key" =~ ^dns_only_(.+) && "${actions_taken[$action_key]}" == "dns_only_candidate" ]]; then
                    local domain="${action_key#dns_only_}"
                    echo "- $domain (user: ${domain_accounts[$domain]}) - Consider moving DNS to registrar"
                fi
            done | sort | head -10
            [[ $dns_only_count -gt 10 ]] && echo "... and $(( dns_only_count - 10 )) more"
            echo
        fi
        
        echo "ACTIONS TAKEN:"
        local action_count=0
        if [[ -v actions_taken ]]; then
            action_count=${#actions_taken[@]}
        fi
        if [[ $action_count -eq 0 ]]; then
            echo "No actions taken."
        else
            for item in "${!actions_taken[@]}"; do
                echo "- $item: ${actions_taken[$item]}"
            done | sort
        fi
        echo
        
        echo "=========================================="
        echo "Full detailed report: $REPORT_FILE"
        echo "Full log file: $LOG_FILE"
        
    } > "$summary_file"
    
    log "INFO" "Summary report generated: $summary_file"
    
    # Email the summary report
    if [[ -n "$NOTIFICATION_EMAIL" ]]; then
        local subject="$MAIL_SUBJECT_PREFIX Domain Audit Complete - $total_domains domains processed"
        if cat "$summary_file" | mail -s "$subject" "$NOTIFICATION_EMAIL"; then
            log "INFO" "Summary report emailed to $NOTIFICATION_EMAIL"
        else
            log "ERROR" "Failed to email summary report to $NOTIFICATION_EMAIL"
        fi
    fi
}

# Generate preview of actions that will be taken in live mode
generate_action_preview() {
    # Check if we have domain data loaded
    if [[ ${#domain_status[@]} -eq 0 ]]; then
        echo "⚠️  No domain status data available - cannot generate preview"
        echo "   Run a dry run first to see what actions would be taken"
        return 1
    fi
    
    local preview_actions=()
    local suspension_count=0
    local removal_count=0
    local primary_change_count=0
    
    echo "📋 PREVIEW OF ACTIONS TO BE TAKEN:"
    echo "=================================="
    
    for domain in "${!domain_status[@]}"; do
        local status="${domain_status[$domain]}"
        local username="${domain_accounts[$domain]}"
        local is_primary=false
        
        if [[ "${primary_domains[$username]:-}" == "$domain" ]]; then
            is_primary=true
        fi
        
        case "$status" in
            "unregistered"|"expired")
                if [[ "$is_primary" == "true" ]]; then
                    # Check if account has other domains
                    local other_domains
                    other_domains=$(echo "${account_domains[$username]}" | tr ' ' '\n' | grep -v "^$domain$" | head -1)
                    
                    if [[ -z "$other_domains" ]]; then
                        preview_actions+=("🚫 SUSPEND account '$username' (primary domain $domain is $status)")
                        ((++suspension_count))
                    else
                        preview_actions+=("🔄 CHANGE primary domain for '$username' from $domain to $other_domains")
                        ((++primary_change_count))
                    fi
                else
                    preview_actions+=("🗑️  REMOVE addon/parked domain '$domain' from account '$username'")
                    ((++removal_count))
                fi
                ;;
        esac
    done
    
    # Show summary counts
    echo "📊 ACTION SUMMARY:"
    echo "• Account suspensions: $suspension_count"
    echo "• Domain removals: $removal_count" 
    echo "• Primary domain changes: $primary_change_count"
    echo "• Total actions: $((suspension_count + removal_count + primary_change_count))"
    echo
    
    if [[ ${#preview_actions[@]} -eq 0 ]]; then
        echo "✅ No actions required - all domains are in good standing"
        return 0
    fi
    
    echo "📝 DETAILED ACTIONS:"
    for action in "${preview_actions[@]}"; do
        echo "   $action"
    done | head -20
    
    if [[ ${#preview_actions[@]} -gt 20 ]]; then
        echo "   ... and $((${#preview_actions[@]} - 20)) more actions"
    fi
}

# Main execution
main() {
    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        echo "🚶 Interactive mode enabled - no batch confirmation needed"
        echo "   You'll review each problematic domain individually with detailed verification"
        echo "   Options for each domain: [y]es, [N]o (default), [s]kip all prompts, [q]uit"
        echo
    fi
    
    log "INFO" "Starting domain audit (DRY_RUN: $DRY_RUN, INTERACTIVE: $INTERACTIVE_MODE)"
    trap on_exit_save_cache EXIT INT TERM
    
    load_domain_data
    
    # Try to load cached results first  
    local using_cache=false
    local need_audit=true
    
    if load_domain_cache && check_cache_coverage; then
        using_cache=true
        log "INFO" "Using cached domain statuses (good coverage)"
        
        # Show preview and get confirmation for live mode when using cache
        if [[ "$REQUIRE_CONFIRMATION" == "true" && "$DRY_RUN" == "false" ]]; then
            if [[ "$INTERACTIVE_MODE" == "false" ]]; then
                # Batch confirmation mode
            echo
            echo "WARNING: This script will make live changes to your server!"
            echo "This includes potentially suspending accounts and removing domains."
            echo
            echo "ℹ️  Using cached domain status data from today"
            echo
            
            # Show preview of actions that will be taken
            echo "Generating preview of actions..."
            
            # Simple preview - count problematic domains from cache
            local cache_file="$LOG_DIR/domain-status-cache-$(date +%Y%m%d).txt"
            local unregistered_count=0
            local expired_count=0  
            local expiring_count=0
            
            if [[ -f "$cache_file" ]]; then
                unregistered_count=$(grep -c ":unregistered:" "$cache_file" 2>/dev/null || echo "0")
                unregistered_count=${unregistered_count//[^0-9]/}  # Remove non-numeric chars
                [[ -z "$unregistered_count" ]] && unregistered_count=0
                
                expired_count=$(grep -c ":expired:" "$cache_file" 2>/dev/null || echo "0")
                expired_count=${expired_count//[^0-9]/}  # Remove non-numeric chars
                [[ -z "$expired_count" ]] && expired_count=0
                
                expiring_count=$(grep -c ":expiring_soon:" "$cache_file" 2>/dev/null || echo "0")
                expiring_count=${expiring_count//[^0-9]/}  # Remove non-numeric chars
                [[ -z "$expiring_count" ]] && expiring_count=0
            fi
            
            echo "📋 PREVIEW OF ACTIONS TO BE TAKEN:"
            echo "=================================="
            echo "📊 ACTION SUMMARY:"
            echo "• Unregistered domains to remove: $unregistered_count"
            echo "• Expired domains to process: $expired_count"  
            echo "• Expiring soon (≤30 days): $expiring_count"
            
            # Calculate total safely
            local total_actions=0
            total_actions=$((unregistered_count + expired_count))
            echo "• Total domains requiring action: $total_actions"
            echo
            
            if [[ $total_actions -gt 0 ]]; then
                echo "📝 DOMAINS TO BE PROCESSED:"
                echo
                
                # Show unregistered domains
                if [[ $unregistered_count -gt 0 ]]; then
                    echo "🗑️  UNREGISTERED DOMAINS ($unregistered_count total):"
                    grep ":unregistered:" "$cache_file" 2>/dev/null | while IFS=: read -r domain status timestamp primary; do
                        # Get account for this domain
                        local account="${domain_accounts[$domain]:-unknown}"
                        echo "   • $domain (account: $account)"
                    done
                    echo
                fi
                
                # Show expired domains  
                if [[ $expired_count -gt 0 ]]; then
                    echo "⏰ EXPIRED DOMAINS ($expired_count total):"
                    grep ":expired:" "$cache_file" 2>/dev/null | while IFS=: read -r domain status timestamp primary; do
                        # Get account for this domain
                        local account="${domain_accounts[$domain]:-unknown}"
                        echo "   • $domain (account: $account)"
                    done
                    echo
                fi
                
                echo "⚠️  ACTIONS THAT WILL BE TAKEN:"
                echo "   - Unregistered addon/parked domains will be REMOVED"
                echo "   - Accounts with unregistered primary domains will be SUSPENDED"
                echo "   - Expired domains will be processed similarly"
            else
                echo "✅ No problematic domains found - all domains are in good standing"
            fi
            echo
            
            echo "Are you sure you want to continue? (type 'yes' to confirm)"
            read -r confirmation
            if [[ "$confirmation" != "yes" ]]; then
                log "INFO" "Operation cancelled by user"
                exit 0
            fi
            
            # Process actions using cached data
            log "INFO" "Starting LIVE domain audit with cached statuses"
            
            # Create sorted array of domains for consistent ordering and progress tracking
            local sorted_domains=()
            while IFS= read -r domain; do
                sorted_domains+=("$domain")
            done < <(printf '%s\n' "${!domain_accounts[@]}" | sort)
            
            local total_domains=${#sorted_domains[@]}
            local current_count=0
            
            for domain in "${sorted_domains[@]}"; do
                ((++current_count))
                echo "🔍 [$current_count/$total_domains] Processing: $domain"
                audit_domain "$domain"
                if [[ "$CACHE_SAVE_INTERVAL" != "0" ]] && (( current_count % CACHE_SAVE_INTERVAL == 0 )); then
                    save_domain_cache
                fi
                if [[ "$DOMAIN_AUDIT_MAX_DOMAINS" != "0" && $current_count -ge $DOMAIN_AUDIT_MAX_DOMAINS ]]; then
                    log "INFO" "DOMAIN_AUDIT_MAX_DOMAINS reached ($DOMAIN_AUDIT_MAX_DOMAINS); stopping early"
                    break
                fi
            done
            need_audit=false
            else
                # Interactive mode - process domains immediately without batch confirmation
                log "INFO" "Starting LIVE domain audit with cached statuses (interactive)"
                
                # Create sorted array of domains for consistent ordering and progress tracking
                # In interactive mode, only process domains with problematic statuses
                local sorted_domains=()
                local problematic_statuses="unregistered|expired|whois_failed|expiring_soon|registered_no_expiry"
                
                while IFS= read -r domain; do
                    # Skip invalid domains like "*"
                    [[ "$domain" == "*" || -z "$domain" ]] && continue
                    
                    # In interactive mode, only include domains with problematic statuses
                    local domain_status_value="${domain_status[$domain]:-unknown}"
                    if echo "$domain_status_value" | grep -Eq "($problematic_statuses)"; then
                        sorted_domains+=("$domain")
                    fi
                done < <(printf '%s\n' "${!domain_accounts[@]}" | sort)
                
                local total_domains=${#sorted_domains[@]}
                local current_count=0
                
                if [[ $total_domains -eq 0 ]]; then
                    echo "✅ No problematic domains found in cache - all domains appear healthy!"
                    echo "📊 Total domains checked: ${#domain_accounts[@]}"
                else
                    echo "🔍 Found $total_domains problematic domains that need review"
                    echo
                    echo "DEBUG: About to start for loop"
                    
                    for domain in "${sorted_domains[@]}"; do
                        echo "DEBUG: In loop, processing $domain"
                        ((++current_count))
                        echo "🔍 [$current_count/$total_domains] Processing: $domain"
                        audit_domain "$domain"
                        if [[ "$CACHE_SAVE_INTERVAL" != "0" ]] && (( current_count % CACHE_SAVE_INTERVAL == 0 )); then
                            save_domain_cache
                        fi
                        if [[ "$DOMAIN_AUDIT_MAX_DOMAINS" != "0" && $current_count -ge $DOMAIN_AUDIT_MAX_DOMAINS ]]; then
                            log "INFO" "DOMAIN_AUDIT_MAX_DOMAINS reached ($DOMAIN_AUDIT_MAX_DOMAINS); stopping early"
                            break
                        fi
                    done
                fi
                need_audit=false
            fi
        fi
    fi
    
    # If not using cache or confirmation was disabled, do fresh audit
    if [[ "$need_audit" == "true" ]]; then
        log "INFO" "Starting domain audits..."
        
        # Create sorted array of domains for consistent ordering and progress tracking
        local sorted_domains=()
        while IFS= read -r domain; do
            sorted_domains+=("$domain")
        done < <(printf '%s\n' "${!domain_accounts[@]}" | sort)
        
        local total_domains=${#sorted_domains[@]}
        local current_count=0
        
        for domain in "${sorted_domains[@]}"; do
            ((++current_count))
            echo "🔍 [$current_count/$total_domains] Processing: $domain"
            audit_domain "$domain"
            if [[ "$CACHE_SAVE_INTERVAL" != "0" ]] && (( current_count % CACHE_SAVE_INTERVAL == 0 )); then
                save_domain_cache
            fi
            if [[ "$DOMAIN_AUDIT_MAX_DOMAINS" != "0" && $current_count -ge $DOMAIN_AUDIT_MAX_DOMAINS ]]; then
                log "INFO" "DOMAIN_AUDIT_MAX_DOMAINS reached ($DOMAIN_AUDIT_MAX_DOMAINS); stopping early"
                break
            fi
        done
        
        # Save cache after completing domain audits
        save_domain_cache
    fi
    
    generate_report
    generate_summary_report
    
    log "INFO" "Domain audit completed"
    echo "Report: $REPORT_FILE"
    echo "Log: $LOG_FILE"
    
    # Interactive prompts for manual dry runs
    if [[ "$DRY_RUN" == "true" && -t 0 && -t 1 ]]; then
        echo
        echo "=========================================="
        echo "DRY RUN COMPLETED"
        echo "=========================================="
        
        # Show quick summary
        local total_domains=${#domain_status[@]}
        local active_count=0
        local expired_count=0
        local unregistered_count=0
        local expiring_count=0
        
        for status in "${domain_status[@]}"; do
            case "$status" in
                "active") ((++active_count)) ;;
                "expired") ((++expired_count)) ;;
                "unregistered") ((++unregistered_count)) ;;
                "expiring_soon") ((++expiring_count)) ;;
            esac
        done
        
        echo "Quick Summary:"
        echo "• Total domains: $total_domains"
        echo "• Active: $active_count"
        echo "• Expiring soon (≤30 days): $expiring_count"
        echo "• Expired: $expired_count"
        echo "• Unregistered: $unregistered_count"
        echo
        
        if [[ $using_cache == "true" ]]; then
            echo "ℹ️  Results loaded from today's cache (no new WHOIS queries needed)"
        else
            echo "💾 Results cached for fast re-runs today"
        fi
        echo
        
        echo "Next Steps:"
        echo "1) Review the emailed summary report"
        echo "2) Check detailed report: $REPORT_FILE"
        echo "3) Run live mode to perform actions"
        echo
        
        read -p "Do you want to run in LIVE mode now? (y/N): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo
            echo "⚠️  SWITCHING TO LIVE MODE ⚠️"
            echo "This will perform actual changes to domains and accounts!"
            read -p "Are you absolutely sure? (type 'YES' to confirm): " -r
            if [[ $REPLY == "YES" ]]; then
                log "INFO" "User confirmed live mode execution"
                
                # Clear domain status cache to force re-evaluation with live actions
                unset domain_status
                declare -A domain_status
                
                # Set to live mode
                DRY_RUN=false
                
                echo "Running in LIVE mode..."
                log "INFO" "Starting LIVE domain audit with cached statuses"
                
                # Re-run audit logic but with actions enabled
                # Create sorted array of domains for consistent ordering and progress tracking
                local sorted_domains=()
                while IFS= read -r domain; do
                    sorted_domains+=("$domain")
                done < <(printf '%s\n' "${!domain_accounts[@]}" | sort)
                
                local total_domains=${#sorted_domains[@]}
                local current_count=0
                
                for domain in "${sorted_domains[@]}"; do
                    ((++current_count))
                    echo "🔍 [$current_count/$total_domains] Processing: $domain"
                    audit_domain "$domain"
                    if [[ "$CACHE_SAVE_INTERVAL" != "0" ]] && (( current_count % CACHE_SAVE_INTERVAL == 0 )); then
                        save_domain_cache
                    fi
                    if [[ "$DOMAIN_AUDIT_MAX_DOMAINS" != "0" && $current_count -ge $DOMAIN_AUDIT_MAX_DOMAINS ]]; then
                        log "INFO" "DOMAIN_AUDIT_MAX_DOMAINS reached ($DOMAIN_AUDIT_MAX_DOMAINS); stopping early"
                        break
                    fi
                done
                
                generate_report
                generate_summary_report
                
                echo "✅ LIVE mode completed!"
                echo "📧 Summary emailed to $NOTIFICATION_EMAIL"
            else
                echo "Live mode cancelled."
                echo "To run live mode later: edit config/audit.conf and set DRY_RUN=false"
            fi
        else
            echo "To run live mode later:"
            echo "• Edit config/audit.conf and set DRY_RUN=false"
            echo "• Run: ./domain-audit.sh"
            echo "• Or re-run this script and choose 'y' when prompted"
        fi
    fi
}

# Run main function
main "$@"
