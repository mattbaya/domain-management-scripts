#!/bin/bash

set -euo pipefail

# SpamExperts MX Record Update Script
# Verifies and updates MX records for domains to use SpamExperts service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${2:-$SCRIPT_DIR/config/spamexperts.conf}"
CSV_FILE="${1:-$SCRIPT_DIR/SpamExpertsDomains.csv}"

# Check if CSV file is provided
if [[ -z "$1" ]]; then
    echo "Usage: $0 <spamexperts_domains.csv> [config_file]"
    echo "  spamexperts_domains.csv: Path to the SpamExperts domains CSV file"
    echo "  config_file: Optional path to configuration file (default: config/spamexperts.conf)"
    exit 1
fi

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found at $CONFIG_FILE"
    exit 1
fi

# Verify CSV file exists
if [[ ! -f "$CSV_FILE" ]]; then
    echo "Error: CSV file not found at $CSV_FILE"
    exit 1
fi

# Create log directory
mkdir -p "$LOG_DIR"

# Initialize tracking arrays
declare -A domains_processed
declare -A domains_updated
declare -A domains_errors

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Extract domain from CSV line
extract_domain() {
    local line="$1"
    # Remove quotes and extract first field (domain name)
    echo "$line" | cut -d',' -f1 | sed 's/"//g'
}

# Check current MX records for domain
check_current_mx() {
    local domain="$1"
    local current_mx
    
    if current_mx=$(dig +short MX "$domain" 2>/dev/null); then
        echo "$current_mx"
    else
        echo ""
    fi
}

# Check if domain has correct SpamExperts MX records
has_correct_mx() {
    local domain="$1"
    local current_mx
    current_mx=$(check_current_mx "$domain")
    
    # Check if all required MX records are present
    local all_present=true
    for required_mx in "${SPAMEXPERTS_MX_RECORDS[@]}"; do
        local priority=$(echo "$required_mx" | awk '{print $1}')
        local mx_host=$(echo "$required_mx" | awk '{print $2}')
        
        # Check if this MX record exists in current records
        if ! echo "$current_mx" | grep -q "$priority $mx_host"; then
            all_present=false
            break
        fi
    done
    
    echo "$all_present"
}

# Find DNS zone file for domain
find_zone_file() {
    local domain="$1"
    local zone_file="/var/named/$domain.db"
    
    if [[ -f "$zone_file" ]]; then
        echo "$zone_file"
    else
        echo ""
    fi
}

# Backup DNS zone file
backup_zone_file() {
    local zone_file="$1"
    local backup_file="${zone_file}.backup-$(date +%Y%m%d-%H%M%S)"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would backup $zone_file to $backup_file"
        return 0
    fi
    
    if cp "$zone_file" "$backup_file"; then
        log "INFO" "Backed up zone file to $backup_file"
        return 0
    else
        log "ERROR" "Failed to backup zone file $zone_file"
        return 1
    fi
}

# Update MX records in DNS zone file
update_mx_records() {
    local domain="$1"
    local zone_file="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY RUN] Would update MX records for $domain in $zone_file"
        return 0
    fi
    
    log "INFO" "Updating MX records for $domain"
    
    # Create backup first
    if ! backup_zone_file "$zone_file"; then
        return 1
    fi
    
    # Create temporary file for modifications
    local temp_file=$(mktemp)
    
    # Remove existing MX records and add new ones
    {
        # Copy everything except MX records
        grep -v "IN[[:space:]]*MX" "$zone_file" || true
        
        # Add SpamExperts MX records
        for mx_record in "${SPAMEXPERTS_MX_RECORDS[@]}"; do
            local priority=$(echo "$mx_record" | awk '{print $1}')
            local mx_host=$(echo "$mx_record" | awk '{print $2}')
            echo "$MX_TTL    IN      MX      $priority $mx_host"
        done
    } > "$temp_file"
    
    # Increment serial number
    awk '
    /;Serial Number/ {
        match($0, /[0-9]+/)
        serial_start = RSTART
        serial_end = RLENGTH
        serial_number = substr($0, serial_start, serial_end)
        new_serial = serial_number + 1
        printf "%s%d ;Serial Number\n", substr($0, 1, serial_start - 1), new_serial
        next
    }
    { print }
    ' "$temp_file" > "${temp_file}.serial"
    
    # Replace original file
    if mv "${temp_file}.serial" "$zone_file"; then
        # Set proper permissions
        if [[ "$SET_PERMISSIONS" == "true" ]]; then
            chown "$OWNER:$GROUP" "$zone_file"
            chmod "$PERMISSIONS" "$zone_file"
        fi
        
        # Sync to cluster if configured
        if [[ "$SYNC_TO_CLUSTER" == "true" ]]; then
            if /scripts/dnscluster synczone "$domain" >/dev/null 2>&1; then
                log "INFO" "Successfully synced $domain to cluster"
            else
                log "WARNING" "Failed to sync $domain to cluster"
            fi
        fi
        
        log "INFO" "Successfully updated MX records for $domain"
        rm -f "$temp_file"
        return 0
    else
        log "ERROR" "Failed to update zone file for $domain"
        rm -f "$temp_file" "${temp_file}.serial"
        return 1
    fi
}

# Process a single domain
process_domain() {
    local domain="$1"
    
    log "INFO" "Processing domain: $domain"
    domains_processed["$domain"]=1
    
    # Check if domain has correct MX records
    local has_correct
    has_correct=$(has_correct_mx "$domain")
    
    if [[ "$has_correct" == "true" ]]; then
        log "INFO" "Domain $domain already has correct SpamExperts MX records"
        return 0
    fi
    
    # Find DNS zone file
    local zone_file
    zone_file=$(find_zone_file "$domain")
    
    if [[ -z "$zone_file" ]]; then
        log "WARNING" "No DNS zone file found for $domain - may be hosted elsewhere"
        domains_errors["$domain"]="no_zone_file"
        return 1
    fi
    
    # Show current MX records
    local current_mx
    current_mx=$(check_current_mx "$domain")
    if [[ -n "$current_mx" ]]; then
        log "INFO" "Current MX records for $domain:"
        echo "$current_mx" | while read -r line; do
            log "INFO" "  $line"
        done
    else
        log "INFO" "No current MX records found for $domain"
    fi
    
    # Update MX records
    if update_mx_records "$domain" "$zone_file"; then
        domains_updated["$domain"]=1
        log "INFO" "Successfully updated MX records for $domain"
    else
        domains_errors["$domain"]="update_failed"
        log "ERROR" "Failed to update MX records for $domain"
        return 1
    fi
}

# Generate report
generate_report() {
    log "INFO" "Generating SpamExperts MX update report..."
    
    {
        echo "SpamExperts MX Records Update Report"
        echo "Generated: $(date)"
        echo "Server: $(hostname -f)"
        echo "Mode: $([ "$DRY_RUN" == "true" ] && echo "DRY RUN" || echo "LIVE")"
        echo "=========================================="
        echo
        
        echo "REQUIRED MX RECORDS:"
        for mx_record in "${SPAMEXPERTS_MX_RECORDS[@]}"; do
            local priority=$(echo "$mx_record" | awk '{print $1}')
            local mx_host=$(echo "$mx_record" | awk '{print $2}')
            echo "$MX_TTL    IN      MX      $priority $mx_host"
        done
        echo
        
        echo "PROCESSING SUMMARY:"
        echo "Total domains processed: ${#domains_processed[@]}"
        echo "Domains updated: ${#domains_updated[@]}"
        echo "Domains with errors: ${#domains_errors[@]}"
        echo
        
        if [[ ${#domains_updated[@]} -gt 0 ]]; then
            echo "DOMAINS UPDATED:"
            for domain in "${!domains_updated[@]}"; do
                echo "  $domain"
            done
            echo
        fi
        
        if [[ ${#domains_errors[@]} -gt 0 ]]; then
            echo "DOMAINS WITH ERRORS:"
            for domain in "${!domains_errors[@]}"; do
                echo "  $domain: ${domains_errors[$domain]}"
            done
            echo
        fi
        
        echo "See detailed log at: $LOG_FILE"
        
    } > "$REPORT_FILE"
    
    log "INFO" "Report generated: $REPORT_FILE"
}

# Main execution
main() {
    log "INFO" "Starting SpamExperts MX records update (DRY_RUN: $DRY_RUN)"
    
    if [[ "$REQUIRE_CONFIRMATION" == "true" && "$DRY_RUN" == "false" ]]; then
        echo "WARNING: This script will modify DNS zone files!"
        echo "This will update MX records for domains to use SpamExperts."
        echo "Are you sure you want to continue? (type 'yes' to confirm)"
        read -r confirmation
        if [[ "$confirmation" != "yes" ]]; then
            log "INFO" "Operation cancelled by user"
            exit 0
        fi
    fi
    
    log "INFO" "Processing domains from: $CSV_FILE"
    
    # Read and process CSV file
    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue
        
        # Extract domain from CSV line
        local domain
        domain=$(extract_domain "$line")
        
        # Skip if domain is empty
        [[ -z "$domain" ]] && continue
        
        # Process the domain
        process_domain "$domain"
        
        # Small delay to avoid overwhelming the system
        sleep 0.5
        
    done < "$CSV_FILE"
    
    generate_report
    
    log "INFO" "SpamExperts MX update completed"
    echo "Report: $REPORT_FILE"
    echo "Log: $LOG_FILE"
    
    if [[ ${#domains_updated[@]} -gt 0 ]]; then
        echo "Updated ${#domains_updated[@]} domains with SpamExperts MX records"
    fi
    
    if [[ ${#domains_errors[@]} -gt 0 ]]; then
        echo "WARNING: ${#domains_errors[@]} domains had errors - check the log"
    fi
}

# Run main function
main "$@"