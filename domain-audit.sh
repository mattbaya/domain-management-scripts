#!/bin/bash

set -euo pipefail

# Domain Audit and Cleanup Script
# Scans all domains to identify expired, unregistered, or externally pointed domains
# Performs automated cleanup based on domain status and account configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config/audit.conf}"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found at $CONFIG_FILE"
    echo "Please create the configuration file or specify a different path."
    exit 1
fi

# Create log directory
mkdir -p "$LOG_DIR"

# Initialize arrays for tracking
declare -A domain_status
declare -A domain_accounts
declare -A account_domains
declare -A primary_domains
declare -A actions_taken

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"
    echo "$log_line" >> "$LOG_FILE"
    echo "$log_line" >&2
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

# Get domain status via WHOIS
get_domain_status() {
    local domain="$1"
    local status="unknown"
    
    log "INFO" "Checking WHOIS for domain: $domain"
    
    local whois_output
    if ! whois_output=$(timeout "$WHOIS_TIMEOUT" whois "$domain" 2>/dev/null); then
        status="whois_failed"
    elif echo "$whois_output" | grep -Eqi "no match|not found|domain not found|no data found"; then
        status="unregistered"
    else
        local expiration_date
        expiration_date=$(extract_expiration_date "$whois_output")
        
        if [[ -n "$expiration_date" ]]; then
            status=$(is_domain_expired "$domain" "$expiration_date")
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
    
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        local domain=$(echo "$line" | awk '{print $1}' | sed 's/:$//')
        local username=$(echo "$line" | awk '{print $2}')
        
        [[ -z "$domain" || -z "$username" ]] && continue
        
        domain_accounts["$domain"]="$username"
        
        # Build account -> domains mapping
        if [[ -n "${account_domains[$username]:-}" ]]; then
            account_domains["$username"]+=" $domain"
        else
            account_domains["$username"]="$domain"
        fi
    done < "/etc/userdomains"
    
    # Identify primary domains for each account
    for username in "${!account_domains[@]}"; do
        if [[ -f "/var/cpanel/users/$username" ]]; then
            local primary_domain
            primary_domain=$(grep "^DNS=" "/var/cpanel/users/$username" 2>/dev/null | cut -d= -f2 || echo "")
            if [[ -n "$primary_domain" ]]; then
                primary_domains["$username"]="$primary_domain"
            fi
        fi
    done
    
    domain_count=${#domain_accounts[@]}
    account_count=${#account_domains[@]}
    log "INFO" "Loaded $domain_count domains across $account_count accounts"
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
    
    # Get domain registration status
    local registration_status
    registration_status=$(get_domain_status "$domain")
    domain_status["$domain"]="$registration_status"
    
    log "INFO" "Domain $domain: status=$registration_status"
    
    # Handle based on status
    case "$registration_status" in
        "unregistered")
            if [[ "$is_primary" == "true" ]]; then
                # Primary domain is unregistered
                local other_domains
                other_domains=$(echo "${account_domains[$username]}" | tr ' ' '\n' | grep -v "^$domain$" || echo "")
                
                if [[ -z "$other_domains" ]]; then
                    # No other domains - suspend account
                    suspend_account "$username" "Primary domain unregistered: $domain"
                else
                    # Has other domains - suggest primary domain change
                    local new_primary
                    new_primary=$(echo "$other_domains" | head -1)
                    change_primary_domain "$username" "$domain" "$new_primary"
                fi
            else
                # Addon/parked domain is unregistered - remove it
                remove_addon_parked_domain "$domain" "$username"
            fi
            ;;
            
        "expired")
            # Similar handling to unregistered, but log differently
            log "WARNING" "Domain $domain has expired"
            if [[ "$is_primary" == "true" ]]; then
                local other_domains
                other_domains=$(echo "${account_domains[$username]}" | tr ' ' '\n' | grep -v "^$domain$" || echo "")
                
                if [[ -z "$other_domains" ]]; then
                    suspend_account "$username" "Primary domain expired: $domain"
                else
                    local new_primary
                    new_primary=$(echo "$other_domains" | head -1)
                    change_primary_domain "$username" "$domain" "$new_primary"
                fi
            else
                remove_addon_parked_domain "$domain" "$username"
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
                        remove_addon_parked_domain "$domain" "$username"
                    else
                        log "WARNING" "Primary domain $domain has no connection to our services"
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
    
    for status in "${domain_status[@]}"; do
        case "$status" in
            "active") ((active_count++)) ;;
            "unregistered") ((unregistered_count++)) ;;
            "expired") ((expired_count++)) ;;
            "whois_failed") ((failed_count++)) ;;
            "external") ((external_count++)) ;;
        esac
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

# Main execution
main() {
    log "INFO" "Starting domain audit (DRY_RUN: $DRY_RUN)"
    
    if [[ "$REQUIRE_CONFIRMATION" == "true" && "$DRY_RUN" == "false" ]]; then
        echo "WARNING: This script will make live changes to your server!"
        echo "This includes potentially suspending accounts and removing domains."
        echo "Are you sure you want to continue? (type 'yes' to confirm)"
        read -r confirmation
        if [[ "$confirmation" != "yes" ]]; then
            log "INFO" "Operation cancelled by user"
            exit 0
        fi
    fi
    
    load_domain_data
    
    log "INFO" "Starting domain audits..."
    for domain in "${!domain_accounts[@]}"; do
        audit_domain "$domain"
    done
    
    generate_report
    generate_summary_report
    
    log "INFO" "Domain audit completed"
    echo "Report: $REPORT_FILE"
    echo "Log: $LOG_FILE"
}

# Run main function
main "$@"