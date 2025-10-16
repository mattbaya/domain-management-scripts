#!/bin/bash

# Input file containing /etc/userdomains content
USERDOMAINS_FILE="${1:-/etc/userdomains}"

# Output file for domain list
OUTPUT_FILE="${2:-domains.txt}"

# Check if input file exists
if [[ ! -f "$USERDOMAINS_FILE" ]]; then
    echo "Error: Input file $USERDOMAINS_FILE not found" >&2
    exit 1
fi

# Clear the output file at the start
> "$OUTPUT_FILE"

# Array to track processed domains for efficient duplicate detection
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

# Loop through each domain and username pair in the input file
while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Extract domain and username
    domain=$(echo "$line" | awk '{print $1}')
    username=$(echo "$line" | awk '{print $2}')
    
    # Skip if domain is empty
    [[ -z "$domain" ]] && continue

    # Get the base domain (e.g., from www.baya.net -> baya.net)
    base_domain=$(extract_base_domain "$domain")
    
    # Validate domain format
    if [[ ! "$base_domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Warning: Skipping invalid domain format: $base_domain" >&2
        continue
    fi

    # Avoid duplicates using associative array (much more efficient)
    if [[ -n "${processed_domains[$base_domain]}" ]]; then
        continue
    fi
    processed_domains[$base_domain]=1

    echo "$base_domain" >> "$OUTPUT_FILE"
done < "$USERDOMAINS_FILE"

# Final summary
echo "Domain extraction completed."
echo "Total unique domains extracted: $(wc -l < "$OUTPUT_FILE")"
echo "Domains saved to: $OUTPUT_FILE"
