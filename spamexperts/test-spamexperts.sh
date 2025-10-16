#!/bin/bash

# Simple test version to debug the issue

CSV_FILE="SpamExpertsDomains.csv"

# Extract domain from CSV line
extract_domain() {
    local line="$1"
    echo "$line" | cut -d',' -f1 | sed 's/"//g'
}

echo "Testing first 5 domains..."
counter=0

while IFS= read -r line && [[ $counter -lt 5 ]]; do
    [[ -z "$line" ]] && continue
    
    domain=$(extract_domain "$line")
    [[ -z "$domain" ]] && continue
    
    ((counter++))
    echo -n "$counter. Checking $domain... "
    
    # Get MX records
    mx_records=$(dig +short MX "$domain" 2>/dev/null || echo "ERROR")
    
    if [[ "$mx_records" == "ERROR" ]]; then
        echo "DNS Error"
    elif echo "$mx_records" | grep -q "spamexperts"; then
        echo "✓ Using SpamExperts"
    else
        echo "✗ NOT using SpamExperts"
        echo "   MX: $mx_records"
    fi
    
done < "$CSV_FILE"

echo "Test completed."