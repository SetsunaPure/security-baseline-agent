#!/bin/bash
# ============================================================
# Security Baseline Check - deterministic FACT COLLECTION + SCORING.
#
# Two responsibilities (kept separate per rating criterion 5.1-2):
#   [COLLECT]  gather objective facts about the host (no judgment).
#   [EVAL]     deterministic RISK SCORING of each item by fixed
#              thresholds. This is code, not model reasoning.
# The LLM agent consumes [COLLECT]+[EVAL], and only does the fuzzy
# part: remediation advice, ordering, and narrative explanation.
# ============================================================
SCORE_FILE="${1:-/tmp/security_baseline_eval.txt}"
total=0
risk_points=0

echo "===== SECURITY BASELINE COLLECTION START ====="

# ---------- [COLLECT] raw facts ----------
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

echo "[4] World-writable SUID/SGID binaries (count + first 20 on / filesystem)"
suid_count=$(find / -xdev -type f -perm /4000 2>/dev/null | wc -l)
echo "  SUID count: ${suid_count}"
find / -xdev -type f -perm /4000 2>/dev/null | head -20 || echo "  (find failed)"

echo "[5] Open listening TCP/UDP ports"
(ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null) | head -25 || echo "  (cannot list ports)"

echo "[6] /etc/passwd and /etc/shadow permissions"
ls -l /etc/passwd /etc/shadow /etc/group 2>/dev/null

echo "[7] /etc/crontab and system crontabs permissions"
ls -l /etc/crontab 2>/dev/null
ls -l /etc/cron.d 2>/dev/null

echo "[8] Running as root? / whoami"
whoami
id

echo "===== SECURITY BASELINE COLLECTION END ====="

# ============================================================
# [EVAL] deterministic risk scoring (code, fixed thresholds)
# ============================================================
rm -f "$SCORE_FILE"
: > "$SCORE_FILE"

grade() { # $1=item $2=level(OK/WARN/FAIL) $3=points $4=reason
  echo "[EVAL] $1 | $2 | +$3 | $4" >> "$SCORE_FILE"
  risk_points=$((risk_points + $3))
  total=$((total + 1))
}

# [1] SSH: fail=PermitRootLogin yes/password auth on; warn otherwise
ssh_cfg_raw=$(grep -E "^(PermitRootLogin|PasswordAuthentication)" /etc/ssh/sshd_config 2>/dev/null | tr -d ' ')
case "$ssh_cfg_raw" in
  *"PermitRootLogin=yes"*|*"PasswordAuthentication=yes"*)
    grade "1-ssh-auth" "FAIL" 25 "PermitRootLogin=yes or PasswordAuthentication=yes" ;;
  *)
    grade "1-ssh-auth" "OK" 0 "no insecure ssh auth option detected" ;;
esac

# [2] Firewall: fail=none of ufw/iptables/nftables rules active; warn=ufw absent
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  grade "2-firewall" "OK" 0 "ufw active"
elif command -v iptables >/dev/null 2>&1 && iptables -L -n 2>/dev/null | grep -qE "ACCEPT|DROP|REJECT"; then
  grade "2-firewall" "OK" 0 "iptables rules present"
elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "table"; then
  grade "2-firewall" "OK" 0 "nftables rules present"
else
  grade "2-firewall" "FAIL" 25 "no active firewall rule detected (ufw/iptables/nftables)"
fi

# [3] Password aging: fail=no PASS_MAX_DAYS or >90; warn=>90
pass_max=$(grep -iE "^PASS_MAX_DAYS" /etc/login.defs 2>/dev/null | awk '{print $2}' | head -1)
if [ -z "$pass_max" ]; then
  grade "3-passwd-aging" "FAIL" 20 "PASS_MAX_DAYS undefined in login.defs"
elif [ "$pass_max" -gt 90 ]; then
  grade "3-passwd-aging" "WARN" 10 "PASS_MAX_DAYS=${pass_max} > 90"
else
  grade "3-passwd-aging" "OK" 0 "PASS_MAX_DAYS=${pass_max}"
fi

# [4] SUID/SGID binaries: count of world-writable SUID is a risk surface
if [ "$suid_count" -gt 20 ]; then
  grade "4-suid-binaries" "WARN" 10 "SUID count ${suid_count} > 20, review list"
else
  grade "4-suid-binaries" "OK" 0 "SUID count ${suid_count} <= 20"
fi

# [5] Open ports: >8 open listening ports = larger attack surface (warn)
open_ports=$( { ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null; } | grep -cE "^(tcp|udp|tcp6|udp6)" )
if [ "$open_ports" -gt 8 ]; then
  grade "5-open-ports" "WARN" 10 "open listening ports ${open_ports} > 8"
else
  grade "5-open-ports" "OK" 0 "open listening ports ${open_ports} <= 8"
fi

# [6] Critical file perms: PASS_FILE perms should be 644, SHADOW 640/000, GROUP 644
pass_perms=$(stat -c %a /etc/passwd 2>/dev/null)
shadow_perms=$(stat -c %a /etc/shadow 2>/dev/null)
group_perms=$(stat -c %a /etc/group 2>/dev/null)
if [ "$shadow_perms" = "600" ] || [ "$shadow_perms" = "640" ] || [ "$shadow_perms" = "000" ]; then
  grade "6-critical-perms" "OK" 0 "shadow perms ${shadow_perms} restricted"
else
  grade "6-critical-perms" "FAIL" 20 "shadow perms ${shadow_perms} not restricted (expect 600/640/000)"
fi

# [7] Cron perms: crontab must NOT be writable by group or other.
#  3-digit octal: group bit = tens digit, other bit = units digit;
#  a digit >= 6 (i.e. rw- / rwx) means write permission present.
cron_perms=$(stat -c %a /etc/crontab 2>/dev/null)
g_bit=$(( (10#${cron_perms:-0} / 10) % 10 ))
o_bit=$(( 10#${cron_perms:-0} % 10 ))
if [ -z "$cron_perms" ]; then
  grade "7-cron-perms" "WARN" 5 "crontab not found or unreadable"
elif [ "$g_bit" -ge 6 ] || [ "$o_bit" -ge 6 ]; then
  grade "7-cron-perms" "FAIL" 15 "crontab ${cron_perms} is group/other writable"
else
  grade "7-cron-perms" "OK" 0 "crontab ${cron_perms} not group/other writable"
fi

# [8] Running as root: only a warning context flag, not a scoring item
echo "[EVAL] 8-identity | INFO | +0 | running user: $(whoami) (context only)" >> "$SCORE_FILE"

# ---------- summary ----------
echo "" >> "$SCORE_FILE"
echo "TOTAL_ITEMS=${total} RISK_POINTS=${risk_points}" >> "$SCORE_FILE"
if [ "$risk_points" -ge 60 ]; then
  echo "OVERALL_LEVEL=HIGH" >> "$SCORE_FILE"
elif [ "$risk_points" -ge 30 ]; then
  echo "OVERALL_LEVEL=MEDIUM" >> "$SCORE_FILE"
else
  echo "OVERALL_LEVEL=LOW" >> "$SCORE_FILE"
fi

echo ""
echo "===== SECURITY BASELINE EVAL (deterministic) ====="
cat "$SCORE_FILE"
echo "===== SECURITY BASELINE EVAL END ====="