#!/bin/bash

# Define file paths
DOMAIN_LIST="${1:-/root/domain_list.txt}"
MISSING_EXPIRATION_REPORT="${2:-/root/missing_expiration_report.txt}"
USERDOMAINS="/etc/userdomains"

# Configuration
WHOIS_TIMEOUT=${WHOIS_TIMEOUT:-30}
RATE_LIMIT_DELAY=${RATE_LIMIT_DELAY:-2}

# Function to extract expiration date using multiple patterns
extract_expiration_date() {
    local whois_output="$1"
    local date=""
    
    # Array of common expiration date patterns (order matters - most specific first)
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
    
    # Try each pattern until we find a match
    for pattern in "${patterns[@]}"; do
        date=$(echo "$whois_output" | grep -i "^[[:space:]]*$pattern" | head -1 | cut -d: -f2- | xargs)
        if [[ -n "$date" ]]; then
            # Clean up the date string - remove timezone info and keep only date part
            date=$(echo "$date" | cut -d'T' -f1 | cut -d' ' -f1-3)
            echo "$date"
            return 0
        fi
    done
    
    # Fallback: try a more general pattern
    date=$(echo "$whois_output" | grep -i -E "(expir|renewal)" | grep -i "date" | head -1 | awk -F: '{print $2}' | xargs | cut -d'T' -f1)
    echo "$date"
}

# Prepare the domain list file
echo "Fetching domains from server configurations..." > "$DOMAIN_LIST"

# Function to fetch domains from cPanel DNS zones
fetch_from_dns_zones() {
    echo "Fetching domains from cPanel DNS zones..."
    if [[ -d "/var/named" ]]; then
        for zone_file in /var/named/*.db; do
            [[ -f "$zone_file" ]] || continue
            grep -oP '^\S+(?=\s+IN\s+SOA)' "$zone_file" 2>/dev/null >> "$DOMAIN_LIST" || true
        done
    fi
}

# Function to fetch domains from cPanel userdata
fetch_from_cpanel_userdata() {
    echo "Fetching domains from cPanel userdata..."
    if [[ -d "/var/cpanel/users" ]]; then
        find /var/cpanel/users -maxdepth 1 -type f -exec grep -h "DNS=" {} \; 2>/dev/null | cut -d= -f2 >> "$DOMAIN_LIST" || true
    fi
}

# Function to fetch addon and parked domains
fetch_from_addon_domains() {
    echo "Fetching addon and parked domains..."
    if [[ -f "$USERDOMAINS" ]]; then
        awk -F: '{print $1}' "$USERDOMAINS" >> "$DOMAIN_LIST" 2>/dev/null || true
    fi
}

# Run all discovery functions
fetch_from_dns_zones
fetch_from_cpanel_userdata
fetch_from_addon_domains

# Filter for primary domains (e.g., "baya.net") and remove duplicates
grep -E '^[a-zA-Z0-9-]+\.[a-zA-Z]{2,}$' "$DOMAIN_LIST" | sort -u > "$DOMAIN_LIST.tmp"
mv "$DOMAIN_LIST.tmp" "$DOMAIN_LIST"
echo "Primary domains have been collected into $DOMAIN_LIST."

# Prepare/clear the missing expiration report file
echo "Primary domains with missing expiration dates and associated usernames:" > "$MISSING_EXPIRATION_REPORT"

# Check each domain's WHOIS record for missing expiration date
while IFS= read -r domain; do
    # Validate domain format
    if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Skipping invalid domain format: $domain"
        continue
    fi

    echo "Checking $domain..."
    
    # Get the username associated with the domain
    username=$(grep -m1 "^${domain}:" "$USERDOMAINS" 2>/dev/null | awk '{print $2}' || echo "unknown")

    # Determine the TLD of the domain
    TLD=$(echo "${domain}" | rev | cut -d'.' -f1 | rev | tr '[A-Z]' '[a-z]')

    # Query the appropriate WHOIS server for the TLD with timeout
    WHOIS_SERVER=$(timeout "$WHOIS_TIMEOUT" whois -h "whois.iana.org" "${TLD}" 2>/dev/null | grep 'whois:' | awk '{print $2}' | head -1)
    
    if [[ -z "$WHOIS_SERVER" ]]; then
        echo "Could not determine WHOIS server for TLD: $TLD"
        WHOIS_OUTPUT=$(timeout "$WHOIS_TIMEOUT" whois "$domain" 2>/dev/null || echo "")
    else
        WHOIS_OUTPUT=$(timeout "$WHOIS_TIMEOUT" whois -h "$WHOIS_SERVER" "$domain" 2>/dev/null || echo "")
    fi

    # Extract the expiration date using improved parsing
    EXPIRATION_DATE=$(extract_expiration_date "$WHOIS_OUTPUT")

    # Add domain to the report if expiration date is missing
    if [[ -z "$EXPIRATION_DATE" ]]; then
        echo "$domain (User: $username)" >> "$MISSING_EXPIRATION_REPORT"
    fi
    
    # Rate limiting
    sleep "$RATE_LIMIT_DELAY"
done < "$DOMAIN_LIST"

echo "Domains with missing expiration dates have been listed in $MISSING_EXPIRATION_REPORT."
echo "Total domains checked: $(wc -l < "$DOMAIN_LIST")"
echo "Domains with missing expiration: $(grep -c "User:" "$MISSING_EXPIRATION_REPORT" 2>/dev/null || echo 0)"
