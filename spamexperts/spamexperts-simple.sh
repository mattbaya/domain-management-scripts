#!/bin/bash

# Simplified SpamExperts audit script

CSV_FILE="SpamExpertsDomains.csv"
EMAIL_TO="service@svaha.com"

# Counters
total=0
using_spamexperts=0
not_using=0

# Output files
timestamp=$(date +%Y%m%d-%H%M%S)
not_using_file="domains-not-using-spamexperts-$timestamp.txt"
report_file="spamexperts-report-$timestamp.txt"

# Clear output files
> "$not_using_file"

echo "SpamExperts Service Audit - $(date)"
echo "==================================="
echo

# Process each line
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    
    # Extract domain (remove quotes, get first field)
    domain=$(echo "$line" | cut -d',' -f1 | sed 's/"//g')
    [[ -z "$domain" ]] && continue
    
    ((total++))
    echo -n "$total. $domain ... "
    
    # Check MX records
    mx_records=$(dig +short MX "$domain" 2>/dev/null)
    
    if [[ -n "$mx_records" ]] && echo "$mx_records" | grep -q "spamexperts"; then
        echo "✓ Using SpamExperts"
        ((using_spamexperts++))
    else
        echo "✗ NOT using SpamExperts"
        echo "$domain" >> "$not_using_file"
        ((not_using++))
        if [[ -n "$mx_records" ]]; then
            echo "   Current MX: $(echo "$mx_records" | head -1)"
        fi
    fi
    
    # Small delay
    sleep 0.1
    
done < "$CSV_FILE"

# Calculate savings
savings_monthly=$(echo "$not_using * 1.23" | bc -l 2>/dev/null || echo "0")
savings_yearly=$(echo "$savings_monthly * 12" | bc -l 2>/dev/null || echo "0")

# Generate report
{
    echo "SpamExperts Audit Report"
    echo "======================="
    echo "Date: $(date)"
    echo "Server: $(hostname -f)"
    echo
    echo "SUMMARY:"
    echo "Total domains checked: $total"
    echo "Using SpamExperts: $using_spamexperts"
    echo "NOT using SpamExperts: $not_using"
    echo
    echo "POTENTIAL SAVINGS:"
    echo "Monthly: \$$savings_monthly"
    echo "Yearly: \$$savings_yearly"
    echo
    if [[ $not_using -gt 0 ]]; then
        echo "DOMAINS NOT USING SPAMEXPERTS:"
        cat "$not_using_file"
        echo
        echo "💰 You can save \$$savings_monthly/month by removing these $not_using domains!"
    else
        echo "✅ All domains are properly using SpamExperts."
    fi
} > "$report_file"

echo
echo "AUDIT COMPLETE!"
echo "==============="
cat "$report_file"

# Send email if mail is available
if command -v mail >/dev/null 2>&1; then
    echo
    echo "Sending email report to $EMAIL_TO..."
    cat "$report_file" | mail -s "SpamExperts Audit Report - $(date +%Y-%m-%d)" "$EMAIL_TO"
    echo "Email sent!"
else
    echo "Mail command not available - no email sent"
fi

echo
echo "Files created:"
echo "- Report: $report_file"
echo "- Domains not using SpamExperts: $not_using_file"