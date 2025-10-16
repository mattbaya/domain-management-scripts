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

# Function to delete a DNS zone
delete_dns_zone() {
    if check_dns_zone; then
        echo "Deleting DNS zone for $DOMAIN..."
        /scripts/killdns "$DOMAIN"
    else
        echo "No DNS zone to delete for $DOMAIN"
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
    
    delete_dns_zone
fi

echo "Cleanup complete for $DOMAIN."
