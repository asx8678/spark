#!/usr/bin/env bash
# P0-E3.1 — Idempotent Ubuntu 24.04 host hardening (§10.2 / §12.2).
#
# Run as root on a fresh Hetzner CPX31 (Ubuntu 24.04 LTS) after adding your SSH
# public key via the Hetzner console or cloud-init.
#
# Environment:
#   SSH_PORT   SSH listen port (default: 2222). When != 22, sshd is moved to this
#              port after the new port is allowed in UFW — keep a second session open
#              until you confirm key login on SSH_PORT.
#
# Usage:
#   sudo SSH_PORT=2222 ./bootstrap.sh

set -euo pipefail

if [[ "${EUID:-}" -ne 0 ]]; then
  echo "Run as root (e.g. sudo $0)" >&2
  exit 1
fi

SSH_PORT="${SSH_PORT:-2222}"

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  echo "Invalid SSH_PORT: ${SSH_PORT}" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log() {
  printf '==> %s\n' "$*"
}

apt_install() {
  local pkg
  for pkg in "$@"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      log "Package already installed: ${pkg}"
    else
      apt-get install -y -qq "$pkg"
    fi
  done
}

log "Refreshing apt metadata..."
apt-get update -qq

log "Installing base packages..."
apt_install ufw fail2ban unattended-upgrades apt-listchanges

log "Configuring UFW (deny incoming by default; allow SSH on port ${SSH_PORT})..."
ufw default deny incoming >/dev/null 2>&1 || true
ufw default allow outgoing >/dev/null 2>&1 || true
if ! ufw status | grep -q "${SSH_PORT}/tcp"; then
  ufw allow "${SSH_PORT}/tcp" comment 'SSH (immo hardened)'
fi
ufw --force enable

SSHD_DROPIN="/etc/ssh/sshd_config.d/99-immo-hardening.conf"
log "Configuring SSH hardening (${SSHD_DROPIN})..."
mkdir -p /etc/ssh/sshd_config.d
cat >"$SSHD_DROPIN" <<EOF
# Managed by infra/vps/bootstrap.sh — do not edit by hand.
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
EOF

if [[ "$SSH_PORT" != "22" ]]; then
  log "Moving sshd to port ${SSH_PORT} (UFW already allows it)."
  log "SAFETY: keep this session open; verify key login on port ${SSH_PORT} before disconnecting."
  cat >>"$SSHD_DROPIN" <<EOF
Port ${SSH_PORT}
EOF
fi

if sshd -t -f /etc/ssh/sshd_config; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
else
  echo "sshd config test failed; not reloading sshd" >&2
  exit 1
fi

FAIL2BAN_JAIL="/etc/fail2ban/jail.d/immo-sshd.local"
log "Configuring fail2ban sshd jail (${FAIL2BAN_JAIL})..."
mkdir -p /etc/fail2ban/jail.d
cat >"$FAIL2BAN_JAIL" <<EOF
# Managed by infra/vps/bootstrap.sh
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
EOF

systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"
log "Enabling unattended security upgrades (${AUTO_UPGRADES})..."
cat >"$AUTO_UPGRADES" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

UNATTENDED="/etc/apt/apt.conf.d/50unattended-upgrades"
if [[ -f "$UNATTENDED" ]] && ! grep -q '"${distro_id}:${distro_codename}-security";' "$UNATTENDED"; then
  log "Note: verify ${UNATTENDED} includes security origin for your distro."
fi

systemctl enable unattended-upgrades >/dev/null 2>&1 || true
systemctl restart unattended-upgrades >/dev/null 2>&1 || true

log "Bootstrap complete."
log "Next: run infra/vps/verify.sh, then continue with P0-E3.2 (Coolify + compose)."
if [[ "$SSH_PORT" != "22" ]]; then
  log "SSH listens on port ${SSH_PORT}. Test: ssh -p ${SSH_PORT} <user>@<host>"
fi
