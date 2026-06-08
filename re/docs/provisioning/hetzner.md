# Hetzner Provisioning Guide — Immo (newprojects.ma)

> **Audience:** the solo developer, following along by hand in the Hetzner Cloud
> Console. This is a **manual runbook** — nothing here is automated, and no API
> calls are made on your behalf. Work top-to-bottom; each section is idempotent
> enough that you can stop and resume.
>
> **Scope:** provision one Hetzner Cloud VPS + Hetzner Object Storage to host the
> Phoenix admin/API app **co-located with self-hosted PostgreSQL 16**, per
> **[ADR 00-5 — Database Operations](../decisions/00-5-db-ops.md)** (self-host on
> Hetzner; Neon as the pre-approved escape hatch).
>
> **Bead:** `super-lth` (1.2 Provision Hetzner) · **Related:** `super-8mu` (E6 6.4
> backups bucket), `super-pv4` (secrets/env), `super-rivd` (15.3 production
> Postgres), `super-y3a5` (14.3 backups + restore drills).

---

## 0. Architecture recap (why this shape)

- The **public site is static Astro served from Cloudflare's edge** (ADR 00-4);
  **public read traffic never hits this server**. Postgres serves only the
  authenticated admin panel, Oban queues, and the rebuild/search pipeline.
- Therefore: **one small VPS, co-located app + DB at launch**, split to a
  dedicated DB box later if load warrants (ADR 00-5 "Growth" topology).
- **Postgres is never publicly exposed** — bound to localhost (single-box) or the
  private network (when split). The only inbound ports are SSH, HTTP, HTTPS.
- **Backups go to Hetzner Object Storage (EU)** via pgBackRest (continuous WAL)
  plus a nightly `pg_dump` portable logical dump (keeps the Neon escape hatch a
  `pg_restore` away).

```
                Cloudflare edge (static Astro + R2 media/tiles)
                              │  (public traffic stops here)
   ┌──────────────────────────┴───────────────────────────┐
   │  Hetzner VPS (Nuremberg/Falkenstein, Ubuntu 24.04)    │
   │                                                       │
   │   Caddy :80/:443 ──► Phoenix :4000 (localhost)        │
   │                          │                            │
   │                     PostgreSQL 16 (localhost:5432)    │
   │                          │                            │
   └──────────────────────────┼───────────────────────────┘
                              │ pgBackRest WAL + nightly pg_dump
                              ▼
              Hetzner Object Storage (EU)  ── backups bucket
```

---

## 1. Account & project setup

1. Sign in at **<https://console.hetzner.cloud>** (Hetzner **Cloud** Console — not
   Robot, which is for dedicated/bare-metal).
2. Create a **Project** named `immo-prod` (keeps resources, firewalls, and keys
   scoped). Use a separate project later for staging if needed.
3. Under **Security → API Tokens**: only create a token if you later automate with
   Terraform/`hcloud` CLI. **For this manual run you do not need one** — leave it
   for `super-pv4`.

---

## 2. SSH key setup (do this before creating the server)

On your **local machine** (skip if you already have a key you want to use):

```bash
# Modern, recommended key type
ssh-keygen -t ed25519 -C "immo-prod-deploy" -f ~/.ssh/immo_prod_ed25519
# Set a passphrase when prompted (recommended).
cat ~/.ssh/immo_prod_ed25519.pub   # copy this PUBLIC key
```

In the Console: **Security → SSH Keys → Add SSH Key** → paste the **public** key,
name it `immo-prod-deploy`. This key gets injected into the server at create time,
so you never need password login.

Add a convenience host entry to `~/.ssh/config` (fill the IP in after §3):

```sshconfig
Host immo-prod
    HostName <SERVER_IP>
    User deploy            # created in §5; use 'root' for the very first login
    IdentityFile ~/.ssh/immo_prod_ed25519
    IdentitiesOnly yes
```

---

## 3. Provision the VPS

**Console → Servers → Add Server.**

| Field | Choice | Why |
|---|---|---|
| **Location** | **Nuremberg** (or **Falkenstein**) | Hetzner's German DCs are the **lowest-latency EU region to Morocco**; both are fine — pick one and keep Object Storage in the **same** region. |
| **Image** | **Ubuntu 24.04 LTS** | Current LTS; supported to 2029; matches this guide's apt commands. |
| **Type** | **CX22** (2 vCPU / 4 GB / 40 GB, ~€4–6/mo) to start; **CPX31** (4 vCPU / 8 GB, ~€13–15/mo) if you want headroom for app + Postgres + builds | ADR 00-5 launch topology = co-located app + DB on one small box. CX22 is enough for low-QPS launch; size up in-place later with no rebuild. |
| **Networking** | **IPv4 + IPv6** enabled | Public reachability for Caddy/LetsEncrypt. |
| **SSH keys** | select **`immo-prod-deploy`** | Password login stays off from minute one. |
| **Volumes** | (optional now) add a **Hetzner Volume** for `/var/lib/postgresql` if you want DB data on durable, separately-snapshottable storage | ADR 00-5: data directory on **durable host storage**, never an ephemeral layer. Recommended once you split the DB box; optional at single-box launch. |
| **Firewall** | attach the firewall from §6 (create it first, or attach after) | Defense in depth alongside UFW. |
| **Backups** | enable Hetzner's automated **server snapshots** (~20% surcharge) | Convenient *secondary* DR layer — **not** the primary (pgBackRest is). |
| **Name** | `immo-prod-app` | |

Create the server, note its **public IPv4**, and put it in `~/.ssh/config`.

First login (as root, one time):

```bash
ssh root@<SERVER_IP>
apt update && apt -y upgrade
```

---

## 4. Object Storage (backups buckets)

**Console → Object Storage** (S3-compatible, EU). Create in the **same region** as
the VPS (Nuremberg or Falkenstein) so backup writes are local and fast.

1. **Create bucket** `immo-db-backups` — pgBackRest WAL archive + nightly
   `pg_dump`. (`super-8mu`)
2. **Create bucket** `immo-general-backups` — config, secrets-vault exports,
   uploaded-media safety copies, anything non-DB.
3. **Generate S3 credentials:** Object Storage → **Credentials / Access Keys** →
   create a key pair. You'll get:
   - **Access Key ID**
   - **Secret Access Key**
   - **Endpoint**, e.g. `https://nbg1.your-objectstorage.com` (region-specific)
   Store these in your secrets manager (`super-pv4`) — they are written into the
   pgBackRest config in §8. **Never commit them.**
4. **Lifecycle / retention:** set a lifecycle rule on `immo-db-backups` to expire
   objects older than your retention window (e.g. 30 days of WAL + dumps;
   pgBackRest's own retention in §8 is the primary control — the bucket rule is a
   backstop). Keep versioning **off** for WAL (pgBackRest manages its own history).

> **Note:** Hetzner Object Storage is S3-compatible, so the same config also works
> against **Cloudflare R2** ($0 egress) if you ever want a restore-cheap secondary
> per ADR 00-5's Notes.

---

## 5. Create a non-root sudo user

Still as root:

```bash
adduser deploy                       # set a strong password (used only for sudo)
usermod -aG sudo deploy

# Give the new user your SSH key
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
```

Open a **second terminal** and confirm `ssh deploy@<SERVER_IP>` works **before**
locking down root in §7 (so you don't lock yourself out). Update `~/.ssh/config`
`User` to `deploy`.

---

## 6. Hetzner Cloud Firewall (network-edge layer)

**Console → Firewalls → Create Firewall** `immo-prod-fw`, attach to
`immo-prod-app`. This is the cloud-edge filter; UFW (§7) is the host filter —
run both.

**Inbound rules (allow):**

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | TCP | your home/office IP (or `0.0.0.0/0` if you roam — fail2ban + key-only login mitigate) | SSH |
| 80 | TCP | `0.0.0.0/0`, `::/0` | HTTP → Caddy (LetsEncrypt challenge + redirect) |
| 443 | TCP | `0.0.0.0/0`, `::/0` | HTTPS → Caddy → Phoenix |

**Everything else inbound is denied** (Hetzner firewalls default-deny inbound).
Outbound is allowed by default — leave it. **Do not** open 5432 (Postgres) or 4000
(Phoenix); both stay on localhost.

---

## 7. Server hardening checklist

All commands as `deploy` with `sudo`.

### 7.1 UFW host firewall

```bash
sudo apt -y install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
```

Phoenix (`:4000`) and Postgres (`:5432`) are **never** opened — they bind to
`127.0.0.1` and Caddy reverse-proxies to Phoenix locally.

### 7.2 fail2ban (SSH brute-force protection)

```bash
sudo apt -y install fail2ban
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[sshd]
enabled  = true
port     = ssh
maxretry = 4
findtime = 10m
bantime  = 1h
EOF
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

### 7.3 Automatic security updates

```bash
sudo apt -y install unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades   # choose "Yes"
# Confirm security origin is enabled:
grep -A3 'Allowed-Origins' /etc/apt/apt.conf.d/50unattended-upgrades
```

For automatic reboots after kernel updates (pick a quiet hour):

```bash
sudo tee /etc/apt/apt.conf.d/51immo-reboot >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
```

### 7.4 SSH lockdown (do this LAST, after confirming key login as `deploy`)

Edit `/etc/ssh/sshd_config` (or drop a file in `/etc/ssh/sshd_config.d/`):

```bash
sudo tee /etc/ssh/sshd_config.d/10-immo-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
EOF
sudo sshd -t                 # validate config BEFORE restarting
sudo systemctl restart ssh
```

> ⚠️ Keep your existing session open and test a **new** `ssh deploy@immo-prod`
> login in a separate terminal before closing anything.

---

## 8. PostgreSQL 16 (self-hosted, per ADR 00-5)

### 8.1 Install from the official PGDG repo (pinned major version)

```bash
sudo apt -y install curl ca-certificates
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
. /etc/os-release
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt update
sudo apt -y install postgresql-16
```

> **Pin the major version** (`postgresql-16`, not `postgresql`) so an apt upgrade
> never silently jumps majors — upgrades are scheduled/rehearsed (ADR 00-5
> guardrail #4).

### 8.2 Localhost-only binding (guardrail #3 — no public exposure)

Edit `/etc/postgresql/16/main/postgresql.conf`:

```conf
listen_addresses = 'localhost'   # single-box launch. When DB is split to its
                                 # own box, bind to the PRIVATE network IP only.
```

`/etc/postgresql/16/main/pg_hba.conf` — keep local + loopback only:

```conf
local   all   all                       peer
host    all   all   127.0.0.1/32        scram-sha-256
host    all   all   ::1/128             scram-sha-256
```

Set `password_encryption = scram-sha-256` in `postgresql.conf`, then:

```bash
sudo systemctl restart postgresql
```

### 8.3 Create the app role & database

```bash
sudo -u postgres psql <<'SQL'
CREATE ROLE immo_app WITH LOGIN PASSWORD 'CHANGE_ME_USE_SECRETS_MANAGER';
CREATE DATABASE immo_prod OWNER immo_app;
ALTER ROLE immo_app SET search_path = public;
SQL
```

The connection string (`postgresql://immo_app:...@localhost:5432/immo_prod`) lives
as a **single env/secret value** (`super-pv4`) so the Neon escape hatch is a config
change, not a code change (ADR 00-5 follow-ups).

### 8.4 Monitoring & slow-query logging (guardrail #5)

In `postgresql.conf`:

```conf
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
log_min_duration_statement = 500   # log queries slower than 500ms
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
```

```bash
sudo systemctl restart postgresql
sudo -u postgres psql -d immo_prod -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

Wire disk-space, WAL, and connection metrics into E14 observability
(LiveDashboard + a Postgres exporter/alerts) — alert on **disk > 80%** and on
**backup-not-completed** (§8.6).

### 8.5 pgBackRest — continuous WAL archiving to Object Storage (`super-y3a5`)

```bash
sudo apt -y install pgbackrest
sudo install -d -o postgres -g postgres /var/log/pgbackrest /var/lib/pgbackrest
```

`/etc/pgbackrest/pgbackrest.conf` (fill S3 values from §4 — keep this file
`chmod 640`, owned by `postgres`):

```ini
[global]
repo1-type=s3
repo1-s3-endpoint=nbg1.your-objectstorage.com
repo1-s3-bucket=immo-db-backups
repo1-s3-region=eu-central
repo1-s3-key=<ACCESS_KEY_ID>
repo1-s3-key-secret=<SECRET_ACCESS_KEY>
repo1-s3-uri-style=path
repo1-path=/pgbackrest
repo1-retention-full=4
start-fast=y
process-max=2
log-level-console=info
log-level-file=detail

[immo]
pg1-path=/var/lib/postgresql/16/main
```

Point Postgres at pgBackRest for archiving — in `postgresql.conf`:

```conf
archive_mode = on
archive_command = 'pgbackrest --stanza=immo archive-push %p'
wal_level = replica
max_wal_senders = 3
```

```bash
sudo systemctl restart postgresql
sudo -u postgres pgbackrest --stanza=immo stanza-create
sudo -u postgres pgbackrest --stanza=immo check          # verify WAL archiving works
sudo -u postgres pgbackrest --stanza=immo --type=full backup
```

### 8.6 Backup schedule (WAL continuous + nightly dump)

WAL is archived **continuously** via `archive_command` (RPO ≈ seconds–minutes).
Add scheduled full/diff backups + a portable nightly `pg_dump` (the escape-hatch
layer). As the `postgres` user's crontab (`sudo -u postgres crontab -e`):

```cron
# Weekly full + daily differential pgBackRest backups
30 2 * * 0   pgbackrest --stanza=immo --type=full backup
30 2 * * 1-6 pgbackrest --stanza=immo --type=diff backup

# Nightly portable logical dump → uploaded to Object Storage (escape-hatch layer)
0 3 * * *    pg_dump -Fc immo_prod -f /var/lib/pgbackrest/immo_prod_$(date +\%F).dump \
             && find /var/lib/pgbackrest -name 'immo_prod_*.dump' -mtime +7 -delete
```

> Use the AWS CLI or `rclone` (configured against the Hetzner S3 endpoint) to push
> the nightly `.dump` into `immo-db-backups/dumps/`. **Alert if any backup job
> fails** — an untested/missing backup is not a backup (ADR 00-5 guardrail #2).

### 8.7 Restore drills (mandatory — guardrail #2)

Document a restore runbook and run a **quarterly drill** (`super-y3a5`):

```bash
# PITR / full restore from pgBackRest (into a scratch dir or spare instance)
sudo -u postgres pgbackrest --stanza=immo --delta restore
# OR portable restore from the nightly dump (also the Neon migration path):
pg_restore -d immo_restore_test /path/to/immo_prod_YYYY-MM-DD.dump
```

Record measured **RTO/RPO** against targets after each drill.

---

## 9. Docker + Docker Compose

The Phoenix release ships as a container pulled from GHCR.

```bash
# Official Docker repo
sudo install -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker deploy        # log out/in for group to take effect
```

### 9.1 Daemon config — log rotation + sane defaults

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
sudo systemctl restart docker
```

Use `restart: unless-stopped` on long-lived services in your Compose file so the
app survives reboots.

### 9.2 Pull images from GHCR (read-only token)

Create a GitHub **fine-grained PAT** (or classic token) with **`read:packages`
only**, store it in your secrets manager (`super-pv4`), then:

```bash
echo "$GHCR_READ_TOKEN" | docker login ghcr.io -u <github-username> --password-stdin
docker pull ghcr.io/<org>/immo-app:latest
```

---

## 10. Networking & reverse proxy

### 10.1 Private network (future-proofing the DB split)

**Console → Networks → Create Network** `immo-net` (e.g. `10.0.0.0/16`), attach
`immo-prod-app`. When you split Postgres onto its own box (ADR 00-5 Growth
topology), attach that box to the same network and **bind Postgres to its private
IP only** (`listen_addresses = '10.0.0.x'`) — never the public interface.

### 10.2 Reverse proxy — Caddy (auto-LetsEncrypt, recommended)

Caddy gives automatic HTTPS with the least config. Run it on the host or in
Compose; here's the host install:

```bash
sudo apt -y install debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt -y install caddy
```

`/etc/caddy/Caddyfile`:

```caddyfile
admin.newprojects.ma {
    encode zstd gzip
    reverse_proxy 127.0.0.1:4000
}
```

```bash
sudo systemctl reload caddy
```

Caddy obtains/renews LetsEncrypt certs automatically over ports 80/443 (already
open in §6/§7). Phoenix stays on `127.0.0.1:4000`.

> **Alternative — nginx + certbot:** viable if you prefer nginx; you then manage
> certbot renewals yourself. Caddy is recommended here purely for lower ops
> surface (auto-renew, HTTP→HTTPS, HTTP/3 out of the box) — consistent with the
> "sustainable for one person" constraint in ADR 00-5.

### 10.3 Firewall rules for the reverse proxy

Already covered: ports **80/443 open** (Hetzner FW §6 + UFW §7), Phoenix **:4000**
and Postgres **:5432** never exposed. If the admin subdomain is fronted by
Cloudflare (proxied), consider restricting 80/443 inbound to **Cloudflare's IP
ranges** at the Hetzner firewall for an extra layer (matches the
"API subdomain behind Cloudflare proxy" note in ADR 00-5).

---

## 11. Cost estimate (launch scale)

> ⚠️ Approximate, EUR, mid-2026 — **verify current Hetzner pricing before you
> commit.** Figures show *structure*, not a quote. The DB is small/low-QPS (public
> site is static/CDN), so we live at the bottom of every curve.

| Item | Spec | Est. monthly |
|---|---|---|
| **VPS** | CX22 (2 vCPU / 4 GB / 40 GB) | **~€4–6** |
| ↳ *or* | CPX31 (4 vCPU / 8 GB) for headroom | ~€13–15 |
| **Object Storage** | 1 TB bucket (DB backups + general) | **~€6** |
| **Server snapshots** (optional secondary DR) | ~20% of VPS price | ~€1–3 |
| **Volume** (optional, durable DB data) | e.g. 40 GB @ ~€0.044/GB | ~€2 |
| **Traffic** | Hetzner includes 20 TB egress on Cloud VPS; admin/API traffic is tiny (public is CDN) | **~€0** |
| **Private network** | included | €0 |
| | **Launch total (CX22 + storage)** | **≈ €10–14/mo** |
| | **With CPX31 + volume + snapshots** | **≈ €22–28/mo** |

This matches ADR 00-5's "~€6/mo launch (co-located) + ~€6/mo backups" structural
estimate, plus optional durability/headroom line items.

---

## 12. Post-provision verification checklist

- [ ] `ssh deploy@immo-prod` works with key; **root login + password auth refused**.
- [ ] `sudo ufw status` shows only 22/80/443; Hetzner firewall attached.
- [ ] `sudo fail2ban-client status sshd` active; `unattended-upgrades` enabled.
- [ ] `sudo -u postgres psql -c "show listen_addresses;"` → `localhost` (not `*`).
- [ ] `pgbackrest --stanza=immo check` passes; one full backup exists in the bucket.
- [ ] Nightly `pg_dump` cron present; **backup-failure alert** wired up.
- [ ] A **restore drill** completed at least once; RTO/RPO recorded (`super-y3a5`).
- [ ] `docker pull ghcr.io/<org>/immo-app:latest` succeeds with the read-only token.
- [ ] Caddy serves `https://admin.newprojects.ma` → Phoenix `:4000` with a valid cert.
- [ ] S3 keys, DB URL, and GHCR token stored in the secrets manager (`super-pv4`),
      **not** in git.

---

## References

- **[ADR 00-5 — Database Operations](../decisions/00-5-db-ops.md)** (self-host
  Postgres on Hetzner; guardrails; Neon escape hatch).
- Hetzner: Cloud servers, Volumes, Object Storage (S3-compatible, EU), Cloud
  Firewalls, private networks.
- pgBackRest (continuous WAL archiving to S3-compatible storage); PostgreSQL 16
  PGDG apt repo.
- Beads: `super-lth` (this task), `super-8mu` (backups bucket), `super-pv4`
  (secrets), `super-rivd` (15.3 prod Postgres), `super-y3a5` (14.3 backups +
  restore drills).
