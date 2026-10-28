#!/usr/bin/env bash
# Diagnostics for the secure SIP stack. Run as root. No secrets are printed.
ASTERISK_HOST="${ASTERISK_HOST:-203.0.113.50}"
KAMAILIO_HOST="${KAMAILIO_HOST:-203.0.113.51}"
TLS_PORT=5061

section() { printf '\n=== %s ===\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

section "Asterisk registrations / endpoints"
if have asterisk; then
  asterisk -rx "pjsip show registrations"
  asterisk -rx "pjsip show endpoints"
  asterisk -rx "pjsip show transports"
else echo "asterisk not installed"; fi

section "TLS handshake (Asterisk)"
if have openssl; then
  echo | openssl s_client -connect "${ASTERISK_HOST}:${TLS_PORT}" -tls1_2 2>/dev/null \
    | grep -E "Protocol|Cipher|Verify return|subject=|issuer=" || echo "TLS handshake failed"
  echo "--- TLS 1.1 must be refused:"
  echo | openssl s_client -connect "${ASTERISK_HOST}:${TLS_PORT}" -tls1_1 2>&1 | grep -qi "handshake failure\|no protocols\|alert" \
    && echo "OK: TLS1.1 rejected" || echo "WARNING: TLS1.1 may be accepted"
fi

section "TLS handshake (Kamailio)"
have openssl && echo | openssl s_client -connect "${KAMAILIO_HOST}:${TLS_PORT}" -tls1_2 2>/dev/null \
  | grep -E "Protocol|Cipher|Verify return" || true

section "Kamailio status"
have kamctl && { kamctl stats shmem; kamctl stats tm; kamctl ul show 2>/dev/null | head -n 20; }

section "SRTP verification (enable 'pjsip set logger on' and look for a=crypto in SDP)"
have asterisk && asterisk -rx "rtp set debug off" >/dev/null

section "Recent SIP security events"
tail -n 30 /var/log/asterisk/security.log 2>/dev/null

section "CDR (last 20)"
tail -n 20 /var/log/asterisk/cdr-csv/Master.csv 2>/dev/null

section "Fail2ban"
have fail2ban-client && fail2ban-client status asterisk-sip

section "Firewall rules"
have nft && nft list ruleset | head -n 80

section "Listening sockets"
ss -lntup | grep -E ":5060|:5061" || true

section "Short SIP capture (10s, TLS payload is encrypted by design)"
if have tcpdump; then timeout 10 tcpdump -nn -c 50 "port 5060 or port 5061" 2>/dev/null; fi
