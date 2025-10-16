#!/bin/bash

# Input file containing /etc/userdomains content
USERDOMAINS_FILE="${1:-/etc/userdomains}"

# Output file for domain status and expiration dates
OUTPUT_FILE="${2:-domain_status_with_expiration.txt}"

# Configuration variables
WHOIS_TIMEOUT=${WHOIS_TIMEOUT:-30}
DELAY_SECONDS=${DELAY_SECONDS:-2}

# Clear the output file at the start
> "$OUTPUT_FILE"

# Array to track processed domains
declare -A processed_domains

# Function to extract the base domain from a full domain
extract_base_domain() {
    echo "$1" | awk -F. '{ 
        if (NF > 2) {
            # Handle subdomains by extracting the last two segments (e.g., www.baya.net -> baya.net)
            print $(NF-1)"."$NF
        } else {
            # Direct domain without subdomain
            print $0
        }
    }'
}

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

# Loop through each domain and username pair in the input file
while IFS= read -r line; do
    # Extract domain and username
    domain=$(echo "$line" | awk '{print $1}')
    username=$(echo "$line" | awk '{print $2}')

    # Get the base domain (e.g., from www.baya.net -> baya.net)
    base_domain=$(extract_base_domain "$domain")

    # Validate domain format
    if [[ ! "$base_domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Invalid domain format: $base_domain" >> "$OUTPUT_FILE"
        continue
    fi

    # Avoid duplicates by checking if the base domain is already processed
    if [[ -n "${processed_domains[$base_domain]}" ]]; then
        continue
    fi
    processed_domains[$base_domain]=1

    # Perform WHOIS lookup
    echo "Checking $base_domain..."
    if ! whois_output=$(timeout "$WHOIS_TIMEOUT" whois "$base_domain" 2>/dev/null); then
        echo "WHOIS query failed for $base_domain ($username)" >> "$OUTPUT_FILE"
        continue
    fi

    # Check if WHOIS returned any output
    if [[ -z "$whois_output" ]]; then
        echo "No WHOIS data for $base_domain ($username)" >> "$OUTPUT_FILE"
        echo "No WHOIS data for $base_domain ($username)"
        continue
    fi

    # Extract expiration date using improved parsing
    expiration_date=$(extract_expiration_date "$whois_output")

    # Check if the domain is unregistered
    if echo "$whois_output" | grep -Eqi "no match|not found|domain not found"; then
        echo "Unregistered: $base_domain ($username)" >> "$OUTPUT_FILE"
        echo "Unregistered: $base_domain ($username)"
    else
        # Log the registered domain with its expiration date
        if [[ -n "$expiration_date" ]]; then
            echo "Registered: $base_domain ($username) - Expiration Date: $expiration_date" >> "$OUTPUT_FILE"
            echo "Registered: $base_domain ($username) - Expiration Date: $expiration_date"
        else
            echo "Registered: $base_domain ($username) - Expiration Date: Not Found" >> "$OUTPUT_FILE"
            echo "Registered: $base_domain ($username) - Expiration Date: Not Found"
        fi
    fi

    # Add a delay to avoid WHOIS throttling
    sleep "$DELAY_SECONDS"  # Wait before the next query
done < "$USERDOMAINS_FILE"

# Final output message
echo "Script completed. Domain statuses with expiration dates are saved in $OUTPUT_FILE."
