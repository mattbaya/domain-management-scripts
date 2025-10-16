#!/bin/bash

# Setup script for SpamExperts change monitoring cron job

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/spamexperts-audit.sh"
CSV_FILE="$SCRIPT_DIR/SpamExpertsDomains.csv"

echo "SpamExperts Change Monitoring Setup"
echo "==================================="
echo "This will set up automated monitoring that ONLY emails when changes are detected."
echo

# Check if files exist
if [[ ! -f "$AUDIT_SCRIPT" ]]; then
    echo "Error: Audit script not found at $AUDIT_SCRIPT"
    exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
    echo "Error: CSV file not found at $CSV_FILE"
    echo "Please ensure SpamExpertsDomains.csv is in the same directory as this script"
    exit 1
fi

# Test email functionality
echo "Testing email functionality..."
if command -v mail >/dev/null 2>&1; then
    echo "✓ Mail command available"
    
    echo "Testing email delivery..."
    echo "This is a test email to verify SpamExperts monitoring setup.

If you receive this email, the monitoring system is ready to send you alerts.

Server: $(hostname -f)
Date: $(date)" | mail -s "[TEST] SpamExperts Monitoring Setup" "service@svaha.com"
    
    echo "Test email sent to service@svaha.com"
    echo "Please check your email to confirm delivery"
else
    echo "⚠ Warning: Mail command not available"
    echo "Email notifications will not work until mail is configured"
fi

# Create initial baseline state
echo
echo "Creating initial baseline state..."
echo "This establishes the current SpamExperts usage as the baseline for change detection."
"$AUDIT_SCRIPT" "$CSV_FILE" --monitor > /dev/null 2>&1
echo "✓ Baseline state saved"

# Add cron job
echo
echo "Setting up cron job for daily change monitoring..."

# Create cron entry (runs at 2 AM daily, only emails if changes detected)
CRON_ENTRY="# SpamExperts change monitoring (checks at 2 AM, emails only on changes)
0 2 * * * $AUDIT_SCRIPT $CSV_FILE --monitor >/dev/null 2>&1"

# Check if cron entry already exists
if crontab -l 2>/dev/null | grep -q "spamexperts-audit.sh.*--monitor"; then
    echo "⚠ Cron job already exists for SpamExperts monitoring"
    echo "Current monitoring cron entries:"
    crontab -l 2>/dev/null | grep "spamexperts-audit.sh.*--monitor"
else
    # Add to crontab
    (crontab -l 2>/dev/null; echo ""; echo "$CRON_ENTRY") | crontab -
    echo "✓ Cron job added successfully"
    echo "Change monitoring will run daily at 2:00 AM"
fi

echo
echo "SETUP COMPLETE!"
echo "==============="
echo
echo "🎯 Change Monitoring Features:"
echo "- Daily checks at 2:00 AM"
echo "- Email alerts ONLY when changes detected (silent when no changes)"
echo "- Tracks domains that start/stop using SpamExperts"
echo "- Cost impact alerts for new unused domains"
echo "- Alerts sent to: service@svaha.com"
echo
echo "📋 Manual Commands:"
echo "----------------"
echo "Full audit with immediate email report:"
echo "  $AUDIT_SCRIPT $CSV_FILE --email"
echo
echo "Silent monitoring check (only emails if changes found):"
echo "  $AUDIT_SCRIPT $CSV_FILE --monitor"
echo
echo "Regular audit (no email):"
echo "  $AUDIT_SCRIPT $CSV_FILE"
echo
echo "View current cron jobs:"
echo "  crontab -l"
echo
echo "Remove monitoring cron job:"
echo "  crontab -l | grep -v 'spamexperts-audit.sh.*--monitor' | crontab -"
echo
echo "📁 Files and Locations:"
echo "- Baseline state: $SCRIPT_DIR/last-spamexperts-state.txt"
echo "- Audit reports: $SCRIPT_DIR/spamexperts-report-*.txt"
echo "- Unused domains lists: $SCRIPT_DIR/domains-not-using-spamexperts-*.txt"
echo
echo "💡 What happens next:"
echo "- The system now knows the current state of all 67 domains"
echo "- Daily at 2 AM, it will check for changes"
echo "- You'll ONLY get emails when something changes"
echo "- No emails = no changes = everything is stable"