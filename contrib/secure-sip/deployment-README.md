# Secure SIP deployment: SessionTalk -> Kamailio -> Asterisk -> Callcentric

Files in this directory are templates. Replace every `CHANGE_ME_*`, `1777XXXXXXX`,
`203.0.113.50` (Asterisk) and `203.0.113.51` (Kamailio). Never commit real credentials.
Caller ID is fixed in the dialplan to a number you own and have verified in the
Callcentric portal; it is not user-settable.

| File | Destination |
|---|---|
| pjsip.conf, extensions.conf, rtp.conf, modules.conf | /etc/asterisk/ |
| kamailio.cfg, tls.cfg, address.list.example (as address.list) | /etc/kamailio/ |
| fail2ban-sip.conf | split into filter.d and jail.d (see header) |
| nftables.conf | /etc/nftables.conf |
| troubleshooting.sh | run as root |

## 1. Packages (Debian 11+/Ubuntu 22.04+)
    apt install asterisk kamailio kamailio-tls-modules nftables fail2ban openssl

## 2. TLS certificates
Lab (self-signed):

    openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
      -keyout asterisk.key -out asterisk.crt -subj "/CN=sip.example.com" \
      -addext "subjectAltName=DNS:sip.example.com,IP:203.0.113.50"
    install -m 0640 -o asterisk asterisk.key asterisk.crt /etc/asterisk/keys/

Repeat for Kamailio into `/etc/kamailio/certs/` (owner `kamailio`, key mode 0640).
Production: use a CA-signed certificate (e.g. Let's Encrypt `certbot certonly`), point
`cert_file`/`priv_key_file` and `tls.cfg` at the fullchain/key, and set `ca_list`
to the system CA bundle. Self-signed certs require importing the cert in SessionTalk.

## 3. Credentials
Digest hash for extension 1001 (no plaintext in config):

    echo -n "1001:asterisk:YOUR_PASSWORD" | md5sum

Put the hash in `md5_cred`. Put the Callcentric password in `callcentric-auth`
(Asterisk needs it in plaintext to register; protect with `chmod 640`).

## 4. Voicemail / CDR
Add to `/etc/asterisk/voicemail.conf`: `[default]` `1001 => <PIN>,Mobile 1001,<email>`.
CDR is written by `cdr_csv`; rotate via logrotate and keep `/var/log/asterisk` readable
by fail2ban. In `logger.conf` enable `security` and `full` logs; do not log SIP
with `pjsip set logger` in production because it may expose credentials.

## 5. Services
    nft -c -f /etc/nftables.conf && cp nftables.conf /etc/nftables.conf && systemctl enable --now nftables
    kamailio -c -f /etc/kamailio/kamailio.cfg && systemctl restart kamailio
    systemctl restart asterisk fail2ban

Edit the Callcentric IP set in `nftables.conf` and `address.list` first.

## 6. SessionTalk settings
Server: your Kamailio host; port 5061; transport TLS; SRTP: SDES/mandatory;
username `1001`; codecs G.711; keep-alive on; session timer 600 s.

## 7. Verification
    asterisk -rx "pjsip show registrations"      # callcentric Registered
    asterisk -rx "pjsip show endpoints"          # 1001 Avail
    kamctl ul show; kamctl stats
    openssl s_client -connect 203.0.113.51:5061 -tls1_2
    ./troubleshooting.sh

* TLS: protocol must be TLSv1.2+; `-tls1_1` must fail.
* SRTP: temporarily run `pjsip set logger on`; the SDP must contain `RTP/SAVP` and `a=crypto:`.
* Outbound: dial 10 digits from 1001; the INVITE to Callcentric carries From/PAI of
  the configured number regardless of what the client sent.
* Inbound: Callcentric -> `from-trunk` -> Dial 1001, else voicemail.
* Internal: extension to extension through `from-internal` (the dialplan checks the endpoint).
* Caller ID test: set a different display name/number in the client; confirm the
  trunk INVITE still shows the verified number.

## 8. Call flows (abridged)
Outbound: `INVITE sip:1NXXNXXXXXX@callcentric.com` (TLS) -> 407 challenge -> INVITE with
Authorization -> 100/180/200 -> ACK -> SRTP. Inbound: Callcentric INVITE -> Asterisk
identifies by `callcentric-id` -> 200 or voicemail. Internal: INVITE 1001 -> Kamailio -> Asterisk.

## 9. Failover / redundancy
Run a second Kamailio and add it to `address.list`, nftables and DNS SRV; add a second
`registration` for a backup Callcentric server; use keepalived for a floating IP.

## 10. Troubleshooting
* 403 at Kamailio: source missing from `address.list` group 1.
* 488 on trunk: provider does not accept SRTP; verify support before changing `media_encryption`.
* One-way audio: confirm RTP 10000-20000 open, `external_media_address` correct.
* Registration fails: check `pjsip show registrations`, firewall, and credentials.
* Banned yourself: `fail2ban-client set asterisk-sip unbanip <ip>`.
Fail2ban: 5 failures in 10 minutes bans for 1 hour. Emergency (911) calls bypass all other routing rules, but
verify the provider's E911 registration and address.
