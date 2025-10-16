#!/bin/bash

# SpamExperts audit script with change monitoring

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="${1:-$SCRIPT_DIR/SpamExpertsDomains.csv}"
EMAIL_TO="service@svaha.com"

# Parse command line options
MONITOR_MODE=false
SEND_EMAIL=false
for arg in "$@"; do
    case $arg in
        --monitor)
            MONITOR_MODE=true
            ;;
        --email)
            SEND_EMAIL=true
            ;;
    esac
done

# Monitoring setup
LAST_STATE_FILE="$SCRIPT_DIR/last-spamexperts-state.txt"

# Counters
total=0
using_spamexperts=0
not_using=0
using_google=0
using_microsoft=0
using_other_service=0

# Output files
timestamp=$(date +%Y%m%d-%H%M%S)
not_using_file="domains-not-using-spamexperts-$timestamp.txt"
google_domains_file="domains-using-google-$timestamp.txt"
microsoft_domains_file="domains-using-microsoft-$timestamp.txt"
other_services_file="domains-using-other-services-$timestamp.txt"
report_file="spamexperts-report-$timestamp.txt"

# Change tracking
declare -A current_state
declare -A previous_state
declare -A changes_detected
changes_found=false

# Load previous state if monitoring
if [[ "$MONITOR_MODE" == "true" && -f "$LAST_STATE_FILE" ]]; then
    while IFS=: read -r domain status; do
        previous_state["$domain"]="$status"
    done < "$LAST_STATE_FILE"
fi

# Clear output files
> "$not_using_file"
> "$google_domains_file"
> "$microsoft_domains_file"
> "$other_services_file"

# Function to detect email service provider
detect_email_service() {
    local mx_records="$1"
    local domain="$2"
    
    if [[ -z "$mx_records" ]]; then
        echo "no_mx"
        return
    fi
    
    # Check for various email service providers
    if echo "$mx_records" | grep -qi "spamexperts"; then
        echo "spamexperts"
    elif echo "$mx_records" | grep -qi "google\|gmail\|googlemail"; then
        echo "google"
    elif echo "$mx_records" | grep -qi "outlook\|hotmail\|live\|microsoft\|office365"; then
        echo "microsoft"
    elif echo "$mx_records" | grep -qi "zoho"; then
        echo "zoho"
    elif echo "$mx_records" | grep -qi "mailgun"; then
        echo "mailgun"
    elif echo "$mx_records" | grep -qi "sendgrid"; then
        echo "sendgrid"
    elif echo "$mx_records" | grep -qi "fastmail"; then
        echo "fastmail"
    elif echo "$mx_records" | grep -qi "protonmail"; then
        echo "protonmail"
    elif echo "$mx_records" | grep -qi "rackspace"; then
        echo "rackspace"
    elif echo "$mx_records" | grep -qi "godaddy"; then
        echo "godaddy"
    elif echo "$mx_records" | grep -qi "1and1\|ionos"; then
        echo "ionos"
    elif echo "$mx_records" | grep -qi "amazon\|aws\|ses"; then
        echo "amazon_ses"
    elif echo "$mx_records" | grep -qi "mailchimp\|mandrill"; then
        echo "mailchimp"
    elif echo "$mx_records" | grep -qi "mimecast"; then
        echo "mimecast"
    elif echo "$mx_records" | grep -qi "barracuda"; then
        echo "barracuda"
    elif echo "$mx_records" | grep -qi "mcafee"; then
        echo "mcafee"
    elif echo "$mx_records" | grep -qi "symantec"; then
        echo "symantec"
    elif echo "$mx_records" | grep -qi "\.${domain}\$\|${domain}\."; then
        echo "self_hosted"
    else
        echo "other"
    fi
}

# Only show header in non-monitor mode
if [[ "$MONITOR_MODE" != "true" ]]; then
    echo "SpamExperts Service Audit - $(date)"
    echo "==================================="
    echo
fi

# Process each line
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    
    # Extract domain (remove quotes, get first field)
    domain=$(echo "$line" | cut -d',' -f1 | sed 's/"//g')
    [[ -z "$domain" ]] && continue
    
    ((total++))
    
    # Check MX records
    mx_records=$(dig +short MX "$domain" 2>/dev/null)
    
    # Detect email service provider
    email_service=$(detect_email_service "$mx_records" "$domain")
    
    # Determine status and categorize
    status=""
    if [[ "$email_service" == "spamexperts" ]]; then
        status="using"
        if [[ "$MONITOR_MODE" != "true" ]]; then
            echo "$total. $domain ... ✓ Using SpamExperts"
        fi
        ((using_spamexperts++))
    else
        status="not_using"
        if [[ "$MONITOR_MODE" != "true" ]]; then
            echo -n "$total. $domain ... ✗ NOT using SpamExperts"
            case "$email_service" in
                "google")
                    echo " (Using Google Workspace)"
                    echo "$domain" >> "$google_domains_file"
                    ((using_google++))
                    ;;
                "microsoft")
                    echo " (Using Microsoft 365/Outlook)"
                    echo "$domain" >> "$microsoft_domains_file"
                    ((using_microsoft++))
                    ;;
                "no_mx")
                    echo " (No MX records)"
                    echo "$domain (No MX records)" >> "$other_services_file"
                    ((using_other_service++))
                    ;;
                "self_hosted")
                    echo " (Self-hosted)"
                    echo "$domain (Self-hosted)" >> "$other_services_file"
                    ((using_other_service++))
                    ;;
                *)
                    echo " (Using $email_service)"
                    echo "$domain ($email_service)" >> "$other_services_file"
                    ((using_other_service++))
                    ;;
            esac
            if [[ -n "$mx_records" ]]; then
                echo "   MX Records: $(echo "$mx_records" | tr '\n' ' ')"
            fi
        else
            # In monitor mode, still categorize for reporting
            case "$email_service" in
                "google") ((using_google++)) ;;
                "microsoft") ((using_microsoft++)) ;;
                *) ((using_other_service++)) ;;
            esac
        fi
        echo "$domain" >> "$not_using_file"
        ((not_using++))
    fi
    
    # Track state for monitoring
    current_state["$domain"]="$status"
    
    # Check for changes if monitoring
    if [[ "$MONITOR_MODE" == "true" ]]; then
        prev_status="${previous_state[$domain]:-}"
        if [[ -n "$prev_status" && "$prev_status" != "$status" ]]; then
            changes_detected["$domain"]="$prev_status -> $status"
            changes_found=true
        fi
    fi
    
    # Small delay
    sleep 0.1
    
done < "$CSV_FILE" 2>/dev/null

# Calculate savings
savings_monthly=$(echo "$not_using * 1.23" | bc -l 2>/dev/null || echo "0")
savings_yearly=$(echo "$savings_monthly * 12" | bc -l 2>/dev/null || echo "0")

# Generate report (always needed for email functionality)
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
    echo "EMAIL SERVICE BREAKDOWN:"
    echo "- SpamExperts: $using_spamexperts domains"
    echo "- Google Workspace: $using_google domains"
    echo "- Microsoft 365/Outlook: $using_microsoft domains"  
    echo "- Other services: $using_other_service domains"
    echo
    echo "POTENTIAL SAVINGS:"
    echo "Monthly: \$$savings_monthly"
    echo "Yearly: \$$savings_yearly"
    echo
    if [[ $not_using -gt 0 ]]; then
        echo "DOMAINS NOT USING SPAMEXPERTS:"
        cat "$not_using_file"
        echo
        
        if [[ $using_google -gt 0 ]]; then
            echo "DOMAINS USING GOOGLE WORKSPACE:"
            cat "$google_domains_file"
            echo
        fi
        
        if [[ $using_microsoft -gt 0 ]]; then
            echo "DOMAINS USING MICROSOFT 365/OUTLOOK:"
            cat "$microsoft_domains_file"
            echo
        fi
        
        if [[ $using_other_service -gt 0 ]]; then
            echo "DOMAINS USING OTHER EMAIL SERVICES:"
            cat "$other_services_file"
            echo
        fi
        
        echo "💰 You can save \$$savings_monthly/month by removing these $not_using domains!"
    else
        echo "✅ All domains are properly using SpamExperts."
    fi
} > "$report_file"

# Save current state for future monitoring
if [[ "$MONITOR_MODE" == "true" ]]; then
    > "$LAST_STATE_FILE"
    for domain in "${!current_state[@]}"; do
        echo "$domain:${current_state[$domain]}" >> "$LAST_STATE_FILE"
    done
fi

# Email logic
send_email_report() {
    local email_subject="SpamExperts Audit Report - $(date +%Y-%m-%d)"
    local email_body
    
    if [[ "$MONITOR_MODE" == "true" && "$changes_found" == "true" ]]; then
        email_subject="[ALERT] SpamExperts Status Changes Detected"
        email_body="SpamExperts Status Changes Detected!
=====================================

Changes found:
"
        for domain in "${!changes_detected[@]}"; do
            email_body+="$domain: ${changes_detected[$domain]}
"
        done
        
        email_body+="

Current Summary:
- Total domains: $total
- Using SpamExperts: $using_spamexperts
- NOT using SpamExperts: $not_using
- Potential monthly savings: \$$savings_monthly

Server: $(hostname -f)
Date: $(date)

Full report available at: $report_file"
        
    elif [[ "$MONITOR_MODE" != "true" ]]; then
        # Regular report mode
        email_body=$(cat "$report_file")
    else
        # Monitor mode but no changes
        return 0
    fi
    
    if command -v mail >/dev/null 2>&1; then
        echo "$email_body" | mail -s "$email_subject" "$EMAIL_TO"
        echo "Email sent to $EMAIL_TO"
    else
        echo "Mail command not available - no email sent"
    fi
}

# Output results based on mode
if [[ "$MONITOR_MODE" == "true" ]]; then
    # Monitor mode - only show changes
    if [[ "$changes_found" == "true" ]]; then
        echo "SpamExperts status changes detected!"
        for domain in "${!changes_detected[@]}"; do
            echo "  $domain: ${changes_detected[$domain]}"
        done
        send_email_report
    else
        echo "No changes detected in SpamExperts usage."
    fi
else
    # Regular audit mode - show full report
    echo
    echo "AUDIT COMPLETE!"
    echo "==============="
    cat "$report_file"
    
    if [[ "$SEND_EMAIL" == "true" ]]; then
        echo
        send_email_report
    fi
    
    echo
    echo "Files created:"
    echo "- Report: $report_file"
    echo "- Domains not using SpamExperts: $not_using_file"
    if [[ $using_google -gt 0 ]]; then
        echo "- Domains using Google Workspace: $google_domains_file"
    fi
    if [[ $using_microsoft -gt 0 ]]; then
        echo "- Domains using Microsoft 365: $microsoft_domains_file"
    fi
    if [[ $using_other_service -gt 0 ]]; then
        echo "- Domains using other services: $other_services_file"
    fi
fi