# /root/scripts/domain-management agent notes

## Purpose
This repo is a set of root-run scripts for auditing and managing domains on a cPanel/WHM server.

The most operationally important flow is:
- `./daily-audit.sh` (cron) runs `./domain-audit.sh` to (re)generate today's cache
- `./simple-report.sh` reads that cache and produces the daily email body

## `domain-audit.sh` behavior (high-level)
- Loads cPanel domain->account mappings from `/etc/userdomains` and primary domains from `/var/cpanel/users/*`.
- Normalizes to base domains (subdomains collapse to their registrable base) so WHOIS/cache keys are consistent.
- Audits domains via WHOIS and DNS (A/MX/NS) to classify:
  `active`, `expiring_soon`, `expired`, `unregistered`, `whois_failed`, `registered_no_expiry`.
- Writes outputs under `./reports/` (via `config/audit.conf`):
  - `domain-status-cache-YYYYMMDD.txt` (consumed by `simple-report.sh`)
  - `report-YYYYMMDD-HHMMSS.txt`, `domain-audit-summary-YYYYMMDD-HHMMSS.txt`, and logs

## Cache reliability notes
`domain-audit.sh` runs with `set -euo pipefail`.

Avoid bash arithmetic post-increment/decrement in this repo (`((var++))` / `((var--))`), because with `set -e`
they can terminate the script on the first increment (exit status 1 when the expression evaluates to 0).
Use `((++var))` instead.

To make the daily cron email reliable, `domain-audit.sh`:
- periodically writes cache during the run (`CACHE_SAVE_INTERVAL`, default `25`)
- saves cache on exit (trap) if it has any collected statuses
- skips the invalid `*` entry that can appear in `/etc/userdomains`

## Useful knobs (env vars)
- `CACHE_SAVE_INTERVAL` (default `25`, `0` disables): save cache every N processed domains.
- `DOMAIN_AUDIT_MAX_DOMAINS` (default `0`): stop after N domains (testing/partial runs).

## Quick verification commands
```bash
# run a small test and confirm the cache is created
rm -f reports/domain-status-cache-$(date +%Y%m%d).txt
DOMAIN_AUDIT_MAX_DOMAINS=5 CACHE_SAVE_INTERVAL=1 ./domain-audit.sh
ls -la reports/domain-status-cache-$(date +%Y%m%d).txt

# run the report generator against today's cache
./simple-report.sh | sed -n '1,40p'
```

