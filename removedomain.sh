#!/bin/bash

# Check if a domain argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

DOMAIN="$1"
USERDOMAINS="/etc/userdomains"

# Function to check for the domain in user domains
find_user_for_domain() {
    grep -m1 "^$DOMAIN:" "$USERDOMAINS" | awk -F: '{print $2}' | xargs
}

# Function to check if a DNS zone exists
check_dns_zone() {
    if [ -f "/var/named/$DOMAIN.db" ]; then
        echo "DNS zone found for $DOMAIN"
        return 0
    else
        echo "No DNS zone found for $DOMAIN"
        return 1
    fi
}

# Function to perform WHOIS lookup and check domain status
check_domain_registration() {
    local domain="$1"
    local timeout=30
    
    echo "Checking domain registration status..."
    
    # Perform WHOIS lookup with timeout
    local whois_output
    if ! whois_output=$(timeout "$timeout" whois "$domain" 2>/dev/null); then
        echo "Warning: WHOIS lookup failed or timed out for $domain"
        return 1
    fi
    
    # Check if domain is registered (not expired or available)
    if echo "$whois_output" | grep -qi -E "(no match|not found|available|no data found|no entries found|status: free)"; then
        echo "Domain $domain appears to be unregistered or expired"
        return 1
    fi
    
    # Extract expiration date
    local expiration_date
    local patterns=(
        "Registry Expiry Date:"
        "Expiration Date:"
        "Expires:"
        "Valid Until:"
        "paid-till:"
        "Expiry Date:"
        "expire:"
    )
    
    for pattern in "${patterns[@]}"; do
        expiration_date=$(echo "$whois_output" | grep -i "$pattern" | head -1 | awk -F: '{print $2}' | xargs)
        [[ -n "$expiration_date" ]] && break
    done
    
    if [[ -n "$expiration_date" ]]; then
        echo "Domain expires: $expiration_date"
    else
        echo "Could not determine expiration date"
    fi
    
    return 0
}

# Function to check DNS pointing
check_dns_pointing() {
    local domain="$1"
    
    echo "Checking where $domain is currently pointed..."
    
    # Check A record
    local a_record=$(dig +short A "$domain" 2>/dev/null | head -1)
    if [[ -n "$a_record" ]]; then
        echo "A record points to: $a_record"
    else
        echo "No A record found"
    fi
    
    # Check NS records
    echo "Name servers:"
    local ns_records=$(dig +short NS "$domain" 2>/dev/null)
    if [[ -n "$ns_records" ]]; then
        echo "$ns_records" | while read -r ns; do
            echo "  $ns"
        done
    else
        echo "  No NS records found"
    fi
    
    # Check MX records
    local mx_records=$(dig +short MX "$domain" 2>/dev/null)
    if [[ -n "$mx_records" ]]; then
        echo "MX records:"
        echo "$mx_records" | while read -r mx; do
            echo "  $mx"
        done
    fi
}

# Function to prompt for removal confirmation
confirm_removal() {
    local domain="$1"
    local user="$2"
    
    echo ""
    echo "=========================================="
    echo "DOMAIN REMOVAL CONFIRMATION"
    echo "=========================================="
    echo "Domain: $domain"
    echo "cPanel User: $user"
    echo ""
    echo "WARNING: This will:"
    echo "  - Remove the domain from cPanel user '$user'"
    echo "  - Delete DNS zone and backup to user's home directory"
    echo "  - Remove domain from cluster DNS servers"
    echo ""
    
    while true; do
        read -p "Are you sure you want to remove this domain? (yes/no): " confirmation
        case "$confirmation" in
            yes|YES|y|Y)
                echo "Proceeding with domain removal..."
                return 0
                ;;
            no|NO|n|N)
                echo "Domain removal cancelled by user"
                return 1
                ;;
            *)
                echo "Please answer 'yes' or 'no'"
                ;;
        esac
    done
}

# Function to backup DNS zone before deletion
backup_dns_zone() {
    local user_dir="$1"
    local zone_file="/var/named/$DOMAIN.db"
    
    if [ -f "$zone_file" ]; then
        local backup_dir="$user_dir/dns_backups"
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local backup_file="$backup_dir/${DOMAIN}_${timestamp}.db"
        
        mkdir -p "$backup_dir"
        if cp "$zone_file" "$backup_file"; then
            echo "DNS zone backed up to: $backup_file"
            return 0
        else
            echo "Warning: Failed to backup DNS zone"
            return 1
        fi
    else
        echo "No DNS zone file to backup"
        return 1
    fi
}

# Function to delete a DNS zone
delete_dns_zone() {
    local user_home="$1"
    
    if check_dns_zone; then
        if [ -n "$user_home" ]; then
            backup_dns_zone "$user_home"
        fi
        echo "Deleting DNS zone for $DOMAIN..."
        /scripts/killdns "$DOMAIN"
    else
        echo "No DNS zone to delete for $DOMAIN"
    fi
}

# Function to check if domain is primary domain for user
is_primary_domain() {
    local user="$1"
    local domain="$2"
    local primary_domain=$(uapi --user="$user" DomainInfo primary_domain 2>/dev/null | grep 'primary_domain:' | awk -F': ' '{print $2}' | xargs)
    [ "$domain" = "$primary_domain" ]
}

# Function to get active secondary domains for user
get_active_domains() {
    local user="$1"
    local domains=()
    
    # Get all domains and filter out primary and current domain
    local all_domains=$(uapi --user="$user" DomainInfo list_domains 2>/dev/null | grep 'domain:' | awk -F': ' '{print $2}' | xargs)
    local primary=$(uapi --user="$user" DomainInfo primary_domain 2>/dev/null | grep 'primary_domain:' | awk -F': ' '{print $2}' | xargs)
    
    # Combine all domains except primary and the one being removed
    for domain in $all_domains; do
        if [ "$domain" != "$DOMAIN" ] && [ "$domain" != "$primary" ] && [ -n "$domain" ]; then
            domains+=("$domain")
        fi
    done
    
    echo "${domains[@]}"
}

# Function to prompt user for primary domain change
prompt_primary_change() {
    local user="$1"
    local current_primary="$2"
    local available_domains=("$@")
    # Remove first two arguments (user and current_primary)
    available_domains=("${available_domains[@]:2}")
    
    echo "WARNING: $current_primary is the primary domain for user $user"
    echo "Available secondary domains to promote to primary:"
    
    local count=1
    for domain in "${available_domains[@]}"; do
        echo "  $count) $domain"
        ((count++))
    done
    
    echo "  0) Cancel operation"
    echo
    read -p "Select a domain to promote to primary (0 to cancel): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#available_domains[@]}" ]; then
        local selected_domain="${available_domains[$((choice-1))]}"
        echo "$selected_domain"
        return 0
    else
        echo "Operation cancelled"
        return 1
    fi
}

# Function to change primary domain
change_primary_domain() {
    local user="$1"
    local new_primary="$2"
    
    echo "Changing primary domain for user $user to $new_primary..."
    
    # Use WHM API to change primary domain
    if whmapi1 domainuserdata domain="$new_primary" action=park 2>/dev/null >/dev/null; then
        echo "Successfully changed primary domain to $new_primary"
        return 0
    else
        echo "Error: Failed to change primary domain"
        return 1
    fi
}

# Function to remove orphaned domains
remove_orphaned_domain() {
    echo "Removing orphaned references for $DOMAIN..."
    escaped_domain=$(printf '%s\n' "$DOMAIN" | sed 's/[[\.*^$()+?{|]/\\&/g')
    sed -i "/^$escaped_domain:/d" "$USERDOMAINS"
    if /scripts/updateuserdomains; then
        echo "Successfully updated user domains"
    else
        echo "Warning: Failed to update user domains"
    fi
}

# Main execution
echo "Starting domain removal process for: $DOMAIN"
echo "================================================"

# First, check if domain is registered and where it points
if check_domain_registration "$DOMAIN"; then
    echo ""
    check_dns_pointing "$DOMAIN"
    echo ""
fi

USER=$(find_user_for_domain)

if [ -z "$USER" ]; then
    echo "Domain $DOMAIN is not associated with any cPanel user."
    
    # Still prompt for confirmation even for orphaned domains
    if ! confirm_removal "$DOMAIN" "none (orphaned)"; then
        exit 0
    fi
    
    echo "Checking further..."
    remove_orphaned_domain
    delete_dns_zone
else
    echo "Domain $DOMAIN found under user $USER."
    
    # Prompt for confirmation before proceeding
    if ! confirm_removal "$DOMAIN" "$USER"; then
        exit 0
    fi
    
    USER_HOME="/home/$USER"
    
    # Check if this is the primary domain
    if is_primary_domain "$USER" "$DOMAIN"; then
        echo "Domain $DOMAIN is the primary domain for user $USER"
        
        # Get available secondary domains
        secondary_domains=($(get_active_domains "$USER"))
        
        if [ ${#secondary_domains[@]} -gt 0 ]; then
            # Prompt user to select new primary domain
            new_primary=$(prompt_primary_change "$USER" "$DOMAIN" "${secondary_domains[@]}")
            
            if [ $? -eq 0 ] && [ -n "$new_primary" ]; then
                # Change primary domain
                if change_primary_domain "$USER" "$new_primary"; then
                    echo "Primary domain successfully changed. Proceeding with removal of $DOMAIN"
                else
                    echo "Error: Could not change primary domain. Aborting removal."
                    exit 1
                fi
            else
                echo "Operation cancelled by user. Domain $DOMAIN was not removed."
                exit 0
            fi
        else
            echo "Error: No secondary domains available to promote to primary."
            echo "Cannot remove primary domain $DOMAIN without a replacement."
            exit 1
        fi
    fi
    
    # Remove domain using WHM API
    if whmapi1 delete_domain domain="$DOMAIN" 2>/dev/null | grep -q 'status: 1'; then
        echo "Successfully removed domain from cPanel"
    else
        echo "Domain removal completed (may not have been in cPanel system)"
    fi
    
    delete_dns_zone "$USER_HOME"
fi

echo "Cleanup complete for $DOMAIN."
