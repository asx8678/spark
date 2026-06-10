#!/usr/bin/env bash
# P0-E3.1 — Verify host hardening applied by infra/vps/bootstrap.sh.
#
# Exit 0 when all checks pass; non-zero otherwise.
#
# Environment:
#   SSH_PORT   Expected SSH port (default: 2222)

set -euo pipefail

SSH_PORT="${SSH_PORT:-2222}"
FAILURES=0

pass() {
  printf '[PASS] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

warn() {
  printf '[WARN] %s\n' "$*"
}

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "command available: $1"
  else
    fail "missing command: $1"
  fi
}

log_section() {
  printf '\n--- %s ---\n' "$*"
}

log_section "Prerequisites"
check_cmd ufw
check_cmd fail2ban-client
check_cmd unattended-upgrade

log_section "fail2ban"
if systemctl is-active --quiet fail2ban; then
  pass "fail2ban service active"
else
  fail "fail2ban service not active"
fi

if fail2ban-client status sshd >/dev/null 2>&1; then
  pass "sshd jail enabled"
  fail2ban-client status sshd | sed 's/^/       /'
else
  fail "sshd jail not found or not enabled"
fi

log_section "UFW"
if ufw status | grep -q "Status: active"; then
  pass "UFW active"
else
  fail "UFW not active"
fi

if ufw status numbered | grep -q "${SSH_PORT}/tcp"; then
  pass "UFW allows TCP ${SSH_PORT}"
else
  fail "UFW missing allow rule for TCP ${SSH_PORT}"
fi

DEFAULT_IN=$(ufw status verbose | awk '/Default:/ && /incoming/ {print $0}')
if echo "$DEFAULT_IN" | grep -qi deny; then
  pass "default incoming policy is deny"
else
  fail "default incoming policy is not deny (${DEFAULT_IN:-unknown})"
fi

ufw status verbose | sed 's/^/       /'

log_section "unattended-upgrades"
AUTO_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
if [[ -f "$AUTO_FILE" ]]; then
  if grep -q 'Unattended-Upgrade "1"' "$AUTO_FILE"; then
    pass "20auto-upgrades enables unattended upgrades"
  else
    fail "20auto-upgrades missing Unattended-Upgrade \"1\""
  fi
else
  fail "missing ${AUTO_FILE}"
fi

if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
  pass "unattended-upgrades service enabled"
else
  fail "unattended-upgrades service not enabled"
fi

if command -v unattended-upgrade >/dev/null 2>&1; then
  log_section "unattended-upgrade dry-run"
  if unattended-upgrade --dry-run --debug >/tmp/immo-unattended-dry-run.log 2>&1; then
    pass "unattended-upgrade --dry-run succeeded"
  else
  warn "unattended-upgrade --dry-run exited non-zero (review /tmp/immo-unattended-dry-run.log)"
  fi
fi

log_section "sshd PasswordAuthentication"
SSHD_EFFECTIVE="$(sshd -T 2>/dev/null || true)"
if echo "$SSHD_EFFECTIVE" | grep -q '^passwordauthentication no$'; then
  pass "PasswordAuthentication no (effective)"
else
  fail "PasswordAuthentication is not no (effective config)"
  echo "$SSHD_EFFECTIVE" | grep -i passwordauthentication | sed 's/^/       /' || true
fi

if echo "$SSHD_EFFECTIVE" | grep -q '^permitrootlogin no$'; then
  pass "PermitRootLogin no (effective)"
else
  fail "PermitRootLogin is not no (effective config)"
fi

EFFECTIVE_PORT="$(echo "$SSHD_EFFECTIVE" | awk '/^port / {print $2; exit}')"
if [[ -n "$EFFECTIVE_PORT" && "$EFFECTIVE_PORT" == "$SSH_PORT" ]]; then
  pass "sshd listens on port ${SSH_PORT}"
else
  fail "sshd effective port is '${EFFECTIVE_PORT:-unknown}', expected ${SSH_PORT}"
fi

log_section "Summary"
if (( FAILURES == 0 )); then
  pass "All automated checks passed. Run an external port scan (see infra/runbooks/vps-provision.md §5)."
  exit 0
fi

fail "${FAILURES} check(s) failed"
exit 1
