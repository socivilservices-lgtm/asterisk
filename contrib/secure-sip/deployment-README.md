# Secure SIP deployment: SessionTalk -> Kamailio -> Asterisk -> Callcentric

Files in this directory:

| File | Install path |
|---|---|
| `pjsip.conf`, `extensions.conf`, `rtp.conf`, `modules.conf` | `/etc/asterisk/` |
| `kamailio.cfg`, `tls.cfg`, `address.list.example` | `/etc/kamailio/` (`address.list.example` -> `address.list`) |
| `fail2ban-sip.conf` | split into fail2ban `filter.d` + `jail.d` (see file header) |
| `nftables.conf` | `/etc/nftables.conf` |
| `troubleshooting.sh` | anywhere; run as root |

Example values (replace all): Asterisk `203.0.113.50`, Kamailio `203.0.113.51`,
Callcentric number `1777xxxxxxx`, extension `1001`. **No passwords are stored in
these files**; the shipped example password `SecurePass123!` must never be used.

## 1. Prerequisites (Debian 11+/Ubuntu 22.04+)
```bash
apt install asterisk kamailio kamailio-tls-modules nftables fail2ban openssl gettext-base
```
Asterisk built from source requires `libsrtp2-dev` and `libssl-dev` (res_srtp, TLS).

## 2. Secrets and rendering
```bash
export ASTERISK_PUBLIC_IP=203.0.113.50 KAMAILIO_IP=203.0.113.51
export CC_NUMBER=1777xxxxxxx CC_PASSWORD='<callcentric-sip-password>'
export EXT1001_PASSWORD="$(openssl rand -base64 24)"
export SESSIONTALK_NET=198.51.100.0/24 CALLCENTRIC_NET=<callcentric-signaling-net>
envsubst < pjsip.conf > /etc/asterisk/pjsip.conf
chown asterisk:asterisk /etc/asterisk/pjsip.conf; chmod 600 /etc/asterisk/pjsip.conf
cp extensions.conf rtp.conf modules.conf /etc/asterisk/
```
Store the exported values in a vault / root-only env file, not in git.
Digest auth is used (no plaintext on the wire). If a legacy device needs it,
`auth_type=md5` with `md5_cred=` (`echo -n "1001:asterisk:PASS" | md5sum`) avoids storing the plaintext password.

## 3. TLS certificates
Lab (self-signed):
```bash
mkdir -p /etc/asterisk/keys /etc/kamailio/tls
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout /etc/asterisk/keys/asterisk.key -out /etc/asterisk/keys/asterisk.crt \
  -subj "/CN=sip.example.com" -addext "subjectAltName=DNS:sip.example.com,IP:203.0.113.50"
cp /etc/asterisk/keys/asterisk.crt /etc/asterisk/keys/ca.crt
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout /etc/kamailio/tls/kamailio.key -out /etc/kamailio/tls/kamailio.crt \
  -subj "/CN=proxy.example.com" -addext "subjectAltName=DNS:proxy.example.com,IP:203.0.113.51"
cp /etc/kamailio/tls/kamailio.crt /etc/kamailio/tls/ca.crt
chown asterisk: /etc/asterisk/keys/*; chmod 600 /etc/asterisk/keys/*.key
chown kamailio: /etc/kamailio/tls/*;  chmod 600 /etc/kamailio/tls/*.key
```
Production: use a CA-signed certificate (e.g. Let's Encrypt via `certbot certonly`) and point
`cert_file`/`priv_key_file`/`certificate`/`private_key` at the issued files; set `ca_list` to the system bundle.

## 4. Caller ID, DIDs, voicemail
Caller ID is never taken from the client. Provision only numbers verified on your Callcentric account:
```bash
asterisk -rx 'database put cid 1001 1777xxxxxxx'
asterisk -rx 'database put cidname 1001 "My Company"'
asterisk -rx 'database put did 1777xxxxxxx 1001'
```
Add a mailbox to `/etc/asterisk/voicemail.conf`: `[default]` / `1001 => <PIN>,Ext 1001,,`.
CDR: enable `cdr_custom`/`cdr_csv` output on an encrypted filesystem (LUKS) for at-rest protection;
`logger.conf` should log only `notice,warning,error,security` and rotate (`logrotate`).
Emergency (911) uses the isolated `[emergency]` context. Register an E911 address with Callcentric before use.

## 5. Kamailio
Replace `203.0.113.50/51` in `kamailio.cfg`, copy `address.list.example` to `address.list` and add
group-1 entries for SessionTalk and Callcentric networks, then:
```bash
cp kamailio.cfg tls.cfg /etc/kamailio/
kamailio -c -f /etc/kamailio/kamailio.cfg && systemctl restart kamailio
```
The proxy is transaction-stateful only (`tm` for relay; no registrar DB), so it can be run as
multiple identical instances behind DNS SRV for HA.

## 6. Firewall and fail2ban
```bash
cp nftables.conf /etc/nftables.conf   # edit the define lines first!
nft -c -f /etc/nftables.conf && systemctl enable --now nftables
```
Keep an out-of-band console session when applying. Install the fail2ban filter and jail from `fail2ban-sip.conf`
and enable the security log in `/etc/asterisk/logger.conf`: `security_log => security`.

## 7. SessionTalk settings
Server `sip.example.com`, port 5061, transport **TLS**, username `1001`, strong password,
SRTP **SDES/mandatory**, codecs G.711 only, keep-alive on, STUN off.

## 8. Testing
```bash
sudo ./troubleshooting.sh all
asterisk -rx 'pjsip show registrations'      # callcentric -> Registered
asterisk -rx 'pjsip show endpoint 1001'
kamctl stats; kamctl dlg show
openssl s_client -connect 203.0.113.50:5061 -tls1_2 </dev/null
openssl s_client -connect 203.0.113.50:5061 -tls1_1 </dev/null   # must fail
```
Call flows (`asterisk -rx 'pjsip set logger on'`):

* **Outbound**: `1001 INVITE (TLS, SDP m=audio RTP/SAVP, a=crypto) -> Kamailio -> Asterisk 401 -> authed INVITE -> From rewritten to verified CID -> INVITE to callcentric.com (SDES) -> 100/180/200 -> ACK -> BYE`.
* **Inbound**: `callcentric INVITE <DID> -> identified by IP -> dialplan [from-trunk] looks up did/<DID> -> PJSIP/1001 rings (or Voicemail if no contacts)`.
* **Internal**: `1001 INVITE 1002 -> endpoint auth -> Dial(PJSIP/1002) -> Voicemail on no answer`.

SRTP check: SDP carries `RTP/SAVP` with `a=crypto:`; `pjsip show endpoint 1001` shows `media_encryption : sdes`.
A call from a client without SRTP to 1001 is rejected (`media_encryption_optimistic=no`).

Caller ID override test (must be blocked): from 1001 dial out while sending a spoofed `From`/`P-Asserted-Identity`
header; the trunk INVITE must still show `From: <sip:1777xxxxxxx@callcentric.com>` (set from `DB(cid/...)`).
Callcentric also rejects unverified numbers.

## 9. Troubleshooting
| Symptom | Check |
|---|---|
| Trunk not registered | `pjsip show registrations`; credentials, outbound UDP 5060 allowed, `CALLCENTRIC_NET` |
| TLS handshake fails | cert paths/permissions, `openssl s_client`, SessionTalk trusts CA |
| One-way audio | `external_media_address`, RTP 10000-20000 open, `rtp_symmetric`/`force_rport` |
| 403 from Kamailio | `address.list` / ACL route, `xlog` in syslog |
| Banned unexpectedly | `fail2ban-client status asterisk-sip`; `fail2ban-client set asterisk-sip unbanip <ip>` |
| Hung calls | session timers (`timers_sess_expires=1800`), `kamctl dlg show` |

## 10. Failover / redundancy
Run two Kamailio instances (same config) published via DNS SRV; add a second Callcentric registration
or a secondary Asterisk with keepalived VIP. Back up `/var/lib/asterisk/astdb.sqlite3` (caller ID/DID data).

## 11. Security audit checklist
```bash
sudo ./troubleshooting.sh audit
nft list ruleset; fail2ban-client status
grep -RnE 'password=' /etc/asterisk/pjsip.conf     # only rendered secrets, mode 600
ls -l /etc/asterisk/keys /etc/kamailio/tls          # keys 600
asterisk -rx 'pjsip show endpoints'                 # no unexpected endpoints
```
Rotate credentials and certificates regularly; apply OS and Asterisk/Kamailio security updates.
