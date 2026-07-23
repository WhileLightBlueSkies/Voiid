# TURN Setup (coturn, bare metal)

Deploying the relay that `GET /calls/turn` hands out credentials for.

Files referenced here live in [`deploy/turn/`](../deploy/turn/):
`turnserver.conf`, `voiid-turn.service`, `docker-compose.yml`.

---

## Why TURN matters

A WebRTC call prefers to go **peer-to-peer**: media flows device→device and never
touches our infrastructure. STUN is usually enough to arrange that — each side
discovers its public address and they connect directly.

But **roughly 10–20% of calls cannot go P2P**. Symmetric NAT (common on mobile
carriers), corporate firewalls that block inbound UDP, double NAT, and restrictive
guest Wi-Fi all defeat hole-punching. For those calls the only options are a relay
or a failed call. Without TURN, one call in six or so simply *never connects*, and
it fails on exactly the networks users can't do anything about.

TURN relays **encrypted** media. VOIID media is SRTP with keys derived end-to-end
on the devices (`e2e-core`) — the relay forwards opaque packets it cannot decrypt.
It does observe IP addresses and traffic timing, which is why logging is kept
minimal in `turnserver.conf`.

---

## 1. Install coturn

```bash
sudo apt update
sudo apt install -y coturn
```

Debian/Ubuntu ship a stock `coturn.service`. Disable it — we run our own unit, and
two instances will fight over the same ports:

```bash
sudo systemctl disable --now coturn
```

## 2. Generate the shared secret

The REST scheme is only as strong as this secret. Generate it, never hand-pick it:

```bash
openssl rand -hex 32
```

Put the value in **two places, byte-identical**:

1. `static-auth-secret=` in `/etc/turnserver.conf`
2. `VOIID_TURN_STATIC_AUTH_SECRET` in the API environment

If they differ, `GET /calls/turn` returns credentials that coturn rejects with
`401` and **every relayed call fails** — while STUN-only calls keep working, so
the symptom looks like "calls work at home, fail on mobile data".

Lock the file down (it is a shared secret):

```bash
sudo chown root:turnserver /etc/turnserver.conf
sudo chmod 640 /etc/turnserver.conf
```

## 3. Install the config

```bash
sudo cp deploy/turn/turnserver.conf /etc/turnserver.conf
sudo mkdir -p /var/log/turnserver && sudo chown turnserver:turnserver /var/log/turnserver
```

Then edit `/etc/turnserver.conf` and set:

- `realm` / `server-name` → your TURN hostname (e.g. `turn.voiid.app`)
- `static-auth-secret` → the value from step 2
- `cert` / `pkey` → your certificate paths (step 4)
- `external-ip` → **only if the host is behind NAT** (step 5)

## 4. TLS certificate (Let's Encrypt)

TURNS on 443 is the whole point of this deployment, and it needs a real cert.

```bash
sudo apt install -y certbot
sudo certbot certonly --standalone -d turn.voiid.app
```

`--standalone` binds :80 briefly, so open port 80 for the duration (or use a DNS
challenge if you can't).

**coturn runs as `turnserver`, not root, and certbot's private key is `root:root
0600` by default** — coturn will fail to start reading it. Grant access and
reload on renewal with a deploy hook:

```bash
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/voiid-turn.sh >/dev/null <<'EOF'
#!/bin/sh
set -e
chgrp -R turnserver /etc/letsencrypt/live /etc/letsencrypt/archive
chmod -R g+rX /etc/letsencrypt/live /etc/letsencrypt/archive
systemctl reload voiid-turn || systemctl restart voiid-turn
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/voiid-turn.sh
sudo /etc/letsencrypt/renewal-hooks/deploy/voiid-turn.sh
```

Certificates expire every 90 days. Without that hook, calls break silently three
months after launch.

Also generate DH params for the `dh2066` directive:

```bash
sudo openssl dhparam -out /etc/turnserver-dhparam.pem 2066
```

## 5. `external-ip` for NAT'd hosts

On AWS / GCP / Azure / most VPS providers the machine has a **private** address on
its interface and a **public** address mapped 1:1. coturn binds what it sees and
would advertise the private one — producing candidates no client can route, so
allocations succeed and then no media ever flows.

Check whether they differ:

```bash
ip -4 addr show          # private / bound address
curl -s https://api.ipify.org; echo   # public address
```

If they differ, set:

```
external-ip=203.0.113.10/10.0.0.5
```

(public/private). If the public IP is bound directly to the interface, leave
`external-ip` commented out entirely.

## 6. Firewall

Open **all** of these — a missing relay range is the most common failure:

| Port | Proto | Purpose |
|---|---|---|
| 3478 | UDP | STUN/TURN (primary path) |
| 3478 | TCP | STUN/TURN where UDP is blocked |
| 5349 | TCP | TURNS (TLS) |
| 5349 | UDP | TURN over DTLS |
| 443 | TCP | **TURNS on 443** — survives restrictive networks |
| 49152–65535 | UDP | relay media range (`min-port`/`max-port`) |

```bash
sudo ufw allow 3478/udp
sudo ufw allow 3478/tcp
sudo ufw allow 5349/tcp
sudo ufw allow 5349/udp
sudo ufw allow 443/tcp
sudo ufw allow 49152:65535/udp
```

On a cloud provider you must open the same ports in the **security group** as
well — the host firewall alone is not enough.

> Port 443 matters more than it looks. Corporate, hotel, and some mobile networks
> block 3478/5349 outright but never block 443, and TURNS over TCP/443 is
> indistinguishable from ordinary HTTPS. It is the last-resort path that rescues
> calls on the most locked-down networks.

## 7. Start it

```bash
sudo cp deploy/turn/voiid-turn.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now voiid-turn
systemctl status voiid-turn
```

## 8. Point the API at it

In the API environment (see `backend/api/.env.example`):

```bash
VOIID_TURN_URLS=turn:turn.voiid.app:3478?transport=udp,turn:turn.voiid.app:3478?transport=tcp,turns:turn.voiid.app:5349?transport=tcp,turns:turn.voiid.app:443?transport=tcp
VOIID_TURN_STATIC_AUTH_SECRET=<same secret as step 2>
VOIID_TURN_TTL_SECONDS=3600
```

Order matters — clients try them in sequence, so cheap UDP first and the
`turns:...:443?transport=tcp` fallback last.

Note: if `VOIID_TURN_CLOUDFLARE_KEY_ID` and `VOIID_TURN_CLOUDFLARE_API_TOKEN` are
set, the API prefers Cloudflare's managed TURN and **ignores** these vars. Unset
them to use your own relay.

---

## Verifying it works

### a. Is it listening?

```bash
sudo ss -lnup | grep turnserver
sudo ss -lntp | grep turnserver     # expect 3478, 5349, 443
```

### b. `turnutils_uclient` (direct relay test)

Compute a credential the same way the API does:

```bash
SECRET='<your static-auth-secret>'
USER="$(( $(date +%s) + 3600 )):testuser"
PASS=$(printf '%s' "$USER" | openssl dgst -sha1 -hmac "$SECRET" -binary | base64)
echo "user=$USER pass=$PASS"

# UDP relay on 3478
turnutils_uclient -v -u "$USER" -w "$PASS" turn.voiid.app -p 3478

# TLS on 443 (the important one)
turnutils_uclient -v -S -u "$USER" -w "$PASS" turn.voiid.app -p 443
```

Success looks like `allocate sent`, `allocate response received: success`, and a
round-trip test that completes. `401` here almost always means the secret does
not match; a hang means a firewall is blocking the relay port range.

### c. Trickle ICE (end-to-end, as a real client sees it)

This validates the *whole* chain including the API.

1. Get live credentials from the API:
   ```bash
   curl -s -H "Authorization: Bearer <jwt>" https://api.voiid.app/calls/turn | jq
   ```
   Confirm `"turn_configured": true`.
2. Open <https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/>
3. Remove the default server. Add each TURN URL with the `username` and
   `credential` from the response.
4. Click **Gather candidates**.

You need at least one candidate of type **`relay`**. `srflx` only means STUN
works but the relay does not — that is exactly the 10–20% of calls that will
fail. Test the `turns:...:443` entry separately; it is the one that matters on
restricted networks.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `401` from coturn | secret mismatch between `turnserver.conf` and `VOIID_TURN_STATIC_AUTH_SECRET`, or clock skew (run NTP — the username embeds an expiry timestamp) |
| Allocation succeeds, no media | relay UDP range 49152–65535 not open, or `external-ip` unset on a NAT'd host |
| coturn won't start | cannot read the Let's Encrypt private key (see step 4), or the stock `coturn.service` still holds the ports |
| No `relay` candidate in Trickle ICE | firewall, or the client is using the Cloudflare path instead |
| Works on Wi-Fi, fails on mobile | the `turns:...:443?transport=tcp` URL is missing from `VOIID_TURN_URLS` |
