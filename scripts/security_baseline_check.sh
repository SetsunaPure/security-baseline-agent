#!/bin/bash
# ============================================================
# Security Baseline Check - deterministic FACT COLLECTION.
# This script ONLY collects objective facts about the host.
# It makes NO judgment. The LLM agent is responsible for
# risk assessment and remediation suggestions based on this data.
# ============================================================
echo "===== SECURITY BASELINE COLLECTION START ====="

echo "[1] SSH root login / password policy (/etc/ssh/sshd_config)"
grep -E "^(PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords|PubkeyAuthentication)" /etc/ssh/sshd_config 2>/dev/null || echo "  (no sshd_config match)"

echo "[2] Firewall status (ufw)"
if command -v ufw >/dev/null 2>&1; then
  ufw status 2>/dev/null || echo "  (ufw status unavailable)"
else
  echo "  ufw not installed"
fi

echo "[3] Password aging policy (/etc/login.defs)"
grep -vE "^#|^$" /etc/login.defs 2>/dev/null | grep -iE "PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE" || echo "  (no PASS_* policy found)"

echo "[4] World-writable SUID/SGID binaries (first 20 on / filesystem)"
find / -xdev -type f -perm /4000 2>/dev/null | head -20 || echo "  (none / find failed)"

echo "[5] Open listening TCP/UDP ports"
ss -tulnp 2>/dev/null | head -25 || netstat -tulnp 2>/dev/null | head -25 || echo "  (cannot list ports)"

echo "[6] /etc/passwd and /etc/shadow permissions"
ls -l /etc/passwd /etc/shadow /etc/group 2>/dev/null

echo "[7] /etc/crontab and system crontabs permissions"
ls -l /etc/crontab 2>/dev/null
ls -l /etc/cron.d 2>/dev/null

echo "[8] Running with root? / whoami"
whoami
id

echo "===== SECURITY BASELINE COLLECTION END ====="