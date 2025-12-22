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
    grep -m1 "^$DOMAIN:" "$USERDOMAINS" | awk -F: '{print $2}'
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
    local primary_domain=$(uapi --user="$user" DomainInfo main_domain | grep -E "data:|result:" | awk -F': ' '{print $2}' | tr -d '"' | head -1)
    [ "$domain" = "$primary_domain" ]
}

# Function to get active secondary domains for user
get_active_domains() {
    local user="$1"
    local domains=()
    
    # Get addon domains
    local addon_domains=$(uapi --user="$user" DomainInfo list_addon_domains 2>/dev/null | grep -E "domain:" | awk -F': ' '{print $2}' | tr -d '"')
    
    # Get parked domains  
    local parked_domains=$(uapi --user="$user" DomainInfo list_parked_domains 2>/dev/null | grep -E "domain:" | awk -F': ' '{print $2}' | tr -d '"')
    
    # Combine all domains except the one being removed
    for domain in $addon_domains $parked_domains; do
        if [ "$domain" != "$DOMAIN" ] && [ -n "$domain" ]; then
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
    
    # First convert the new primary from addon to main domain
    if uapi --user="$user" DomainInfo main_domain_builtin domain="$new_primary" 2>/dev/null; then
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
USER=$(find_user_for_domain)

if [ -z "$USER" ]; then
    echo "Domain $DOMAIN is not associated with any cPanel user. Checking further..."
    remove_orphaned_domain
    delete_dns_zone
else
    echo "Domain $DOMAIN found under user $USER. Attempting to remove..."
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
    
    # Remove domain (addon or parked)
    if uapi --user="$USER" DomainInfo remove_addon_domain domain="$DOMAIN" 2>/dev/null; then
        echo "Successfully removed addon domain"
    else
        echo "Addon domain removal failed or domain was not an addon"
    fi
    
    if uapi --user="$USER" DomainInfo remove_parked_domain domain="$DOMAIN" 2>/dev/null; then
        echo "Successfully removed parked domain"
    else
        echo "Parked domain removal failed or domain was not parked"
    fi
    
    delete_dns_zone "$USER_HOME"
fi

echo "Cleanup complete for $DOMAIN."
