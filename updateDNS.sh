#!/bin/bash

# Check if the file argument is provided
if [[ -z "$1" ]]; then
    echo "Usage: $0 <dns_file> [config_file]"
    echo "  dns_file: Path to the DNS zone file to update"
    echo "  config_file: Optional path to configuration file (default: config/dns-update.conf)"
    exit 1
fi

# Define the DNS file to update
DNS_FILE="$1"

# Extract the domain name by removing the `.db` extension
DOMAIN_NAME=$(basename "$DNS_FILE" .db)

# Configuration file handling
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${2:-$SCRIPT_DIR/config/dns-update.conf}"

# Load configuration if file exists
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "Warning: Configuration file not found at $CONFIG_FILE"
    echo "Using default values..."
    
    # Default values (fallback)
    OLD_IP="173.230.249.203"
    NEW_IP="162.247.79.106"
    REMOVE_IPS=(
        "+ip4:173.230.249.246"
        "+ip4:68.171.210.250"
    )
    SYNC_TO_CLUSTER=true
    SET_PERMISSIONS=true
    OWNER="named"
    GROUP="named"
    PERMISSIONS="600"
fi

# Validate required configuration
if [[ -z "$OLD_IP" || -z "$NEW_IP" ]]; then
    echo "Error: OLD_IP and NEW_IP must be configured"
    exit 1
fi

# Ensure the file exists
if [[ ! -f "$DNS_FILE" ]]; then
    echo "Error: File '$DNS_FILE' not found."
    exit 1
fi

echo "Processing $DNS_FILE for domain $DOMAIN_NAME..."

# Replace all occurrences of the old IP with the new IP
echo "Replacing $OLD_IP with $NEW_IP..."
sed -i "s/\+ip4:$OLD_IP/\+ip4:$NEW_IP/g" "$DNS_FILE"
sed -i "s/$OLD_IP/$NEW_IP/g" "$DNS_FILE"

# Remove the specified IP addresses from REMOVE_IPS array
if [[ ${#REMOVE_IPS[@]:-0} -gt 0 ]]; then
    echo "Removing specified IP addresses..."
    for remove_ip in "${REMOVE_IPS[@]}"; do
        echo "  Removing: $remove_ip"
        # Escape special characters for sed
        escaped_ip=$(printf '%s\n' "$remove_ip" | sed 's/[[\.*^$()+?{|]/\\&/g')
        sed -i "/$escaped_ip/d" "$DNS_FILE"
    done
fi

# Increment the Serial Number while preserving leading spaces
awk '
/;Serial Number/ {
    match($0, /[0-9]+/)
    serial_start = RSTART
    serial_end = RLENGTH
    serial_number = substr($0, serial_start, serial_end)
    new_serial = serial_number + 1
    # Preserve indentation
    printf "%s%d ;Serial Number\n", substr($0, 1, serial_start - 1), new_serial
    next
}
{ print }
' "$DNS_FILE" > temp_file && mv temp_file "$DNS_FILE"

# Set proper ownership and permissions if configured
if [[ "$SET_PERMISSIONS" == "true" ]]; then
    echo "Setting file ownership to $OWNER:$GROUP and permissions to $PERMISSIONS..."
    chown "$OWNER:$GROUP" "$DNS_FILE"
    chmod "$PERMISSIONS" "$DNS_FILE"
fi

# Sync the DNS changes to the cluster if configured
if [[ "$SYNC_TO_CLUSTER" == "true" ]]; then
    echo "Syncing DNS changes for domain: $DOMAIN_NAME..."
    if /scripts/dnscluster synczone "$DOMAIN_NAME"; then
        echo "Successfully synced $DOMAIN_NAME to cluster"
    else
        echo "Warning: Failed to sync $DOMAIN_NAME to cluster"
    fi
fi

echo "DNS update completed for $DNS_FILE"
