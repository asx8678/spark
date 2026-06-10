# VPS provisioning runbook (P0-E3.1)

Owner task — Hetzner Cloud console access required.

## 1. Order server

1. Hetzner Cloud → **Add server**
2. **Type:** CPX31 (4 vCPU / 8 GB RAM)
3. **Location:** EU (e.g. Falkenstein or Helsinki — data stays EU per §13)
4. **Image:** Ubuntu 24.04 LTS
5. **SSH key:** add your public key at create time
6. **Name:** `immo-vps` (or value from `.env` `HETZNER_SERVER_NAME`)

## 2. First login

```bash
ssh root@<server-ip>
export SSH_PORT=2222   # non-standard port per §10.2
```

Copy `infra/vps/bootstrap.sh` to the server and run:

```bash
curl -fsSL <raw-or-scp>/bootstrap.sh | SSH_PORT=2222 bash
# or: scp infra/vps/bootstrap.sh root@<ip>:/root/ && SSH_PORT=2222 bash bootstrap.sh
```

**Before closing your session:** open a second terminal and confirm key login on the new port:

```bash
ssh -p 2222 root@<server-ip>
```

## 3. Verify

On the server:

```bash
SSH_PORT=2222 bash infra/vps/verify.sh
```

From your workstation (external port scan):

```bash
nmap -p 22,80,443,2222,4000 <server-ip>
```

Expected: only `2222/tcp` open (or your chosen `SSH_PORT`).

## 4. Acceptance (super-p0e3.1)

- [ ] CPX31, Ubuntu 24.04, EU location
- [ ] Password SSH rejected; key-only on non-standard port
- [ ] fail2ban sshd jail active
- [ ] unattended-upgrades dry-run succeeds
- [ ] External scan: only SSH port inbound

Next: **P0-E3.2** Coolify + compose stack on this host.
