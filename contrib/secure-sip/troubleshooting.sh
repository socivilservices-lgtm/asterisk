#!/usr/bin/env bash
# Verification helper for the Asterisk + Kamailio secure SIP stack.
# Usage: ./troubleshooting.sh [tls|reg|trace|srtp|audit|all]
set -u
ASTERISK_HOST="${ASTERISK_HOST:-127.0.0.1}"
KAMAILIO_HOST="${KAMAILIO_HOST:-127.0.0.1}"
TLS_PORT="${TLS_PORT:-5061}"
ok()   { printf '[ OK ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

check_tls() {
  have openssl || { fail "openssl not installed"; return; }
  for h in "$ASTERISK_HOST" "$KAMAILIO_HOST"; do
    echo "== TLS handshake $h:$TLS_PORT =="
    out=$(echo | timeout 10 openssl s_client -connect "$h:$TLS_PORT" -tls1_2 2>&1)
    if grep -q "Protocol *: TLSv1.[23]" <<<"$out"; then ok "TLS 1.2+ negotiated on $h"; else fail "TLS handshake failed on $h"; fi
    if echo | timeout 10 openssl s_client -connect "$h:$TLS_PORT" -tls1_1 >/dev/null 2>&1; then
      fail "$h accepts TLS 1.1 or lower"; else ok "$h rejects TLS < 1.2"; fi
    echo | timeout 10 openssl s_client -connect "$h:$TLS_PORT" 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null
  done
}

check_reg() {
  have asterisk || { fail "asterisk CLI not found"; return; }
  asterisk -rx "pjsip show registrations"
  asterisk -rx "pjsip show endpoints"
  asterisk -rx "pjsip show contacts"
  asterisk -rx "pjsip show transports"
  have kamctl && { kamctl stats; kamctl dlg show 2>/dev/null | head -20; }
}

check_trace() {
  have asterisk && { asterisk -rx "pjsip set logger on"; echo "PJSIP logger on; run 'asterisk -rvvv' and place a call. Disable: asterisk -rx 'pjsip set logger off'"; }
  have ngrep && echo "TLS is encrypted on the wire; capture decrypted SIP only on the loopback UDP leg: ngrep -d any -W byline port 5060"
}

check_srtp() {
  have asterisk || { fail "asterisk CLI not found"; return; }
  asterisk -rx "pjsip show endpoint 1001" | grep -i "media_encryption" || fail "media_encryption not found"
  asterisk -rx "pjsip show endpoint callcentric" | grep -i "media_encryption"
  echo "During a call, 'core show channels verbose' and SDP should contain 'RTP/SAVP' and 'a=crypto:'."
  asterisk -rx "pjsip set logger on" >/dev/null
}

check_audit() {
  echo "== Firewall =="; have nft && nft list ruleset 2>/dev/null | head -40
  echo "== Listening sockets =="; ss -tulpn 2>/dev/null | grep -E ':(5060|5061)\b'
  echo "== fail2ban =="; have fail2ban-client && fail2ban-client status asterisk-sip
  echo "== Key permissions =="; ls -l /etc/asterisk/keys /etc/kamailio/tls 2>/dev/null
  echo "== Default credentials check =="
  grep -RnE 'SecurePass123!|YOUR_PASSWORD' /etc/asterisk /etc/kamailio 2>/dev/null && fail "default password found" || ok "no default passwords found"
  echo "== Caller ID DB =="; have asterisk && asterisk -rx "database show cid"
  have kamctl && { echo "== Kamailio config check =="; kamailio -c -f /etc/kamailio/kamailio.cfg 2>&1 | tail -3; }
}

case "${1:-all}" in
  tls) check_tls;; reg) check_reg;; trace) check_trace;; srtp) check_srtp;; audit) check_audit;;
  all) check_tls; check_reg; check_srtp; check_audit;;
  *) echo "usage: $0 [tls|reg|trace|srtp|audit|all]"; exit 2;;
esac
