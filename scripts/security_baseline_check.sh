#!/bin/bash
# ============================================================
# Security Baseline Check - deterministic FACT COLLECTION + SCORING + TRACK.
#
# Three responsibilities (kept separate; each maps to a rating rule):
#   [COLLECT]  gather objective facts about the host (no judgment).
#              Includes FAILBACK sampling: when a primary tool is missing
#              (ss/netstat/ufw/sshd) it falls back to a read-only path
#              (/proc/net, sshd -T, grep) rather than silently skipping.
#   [EVAL]     deterministic RISK SCORING by fixed thresholds (pure code).
#   [TRACK]    cross-run NOT-CLOSED item tracking for 未闭环项 follow-up.
# The LLM only does the fuzzy part: remediation, ordering, narrative.
#
# Every judgement stated in knowledge/security-baseline-rules.md is
# consumed here so no documented rule is left "declared but unused".
# ============================================================
SCORE_FILE="${1:-/tmp/security_baseline_eval.txt}"
STATE_FILE="${2:-/tmp/security_baseline_state.txt}"
total=0
risk_points=0

echo "===== SECURITY BASELINE COLLECTION START ====="

# ---------- [COLLECT] raw facts ----------
echo "[1] SSH root login / password policy (effective via sshd -T, file fallback)"
if command -v sshd >/dev/null 2>&1; then
  # effective values (respects Include/*.d overrides)
  sshd -T 2>/dev/null | grep -Ei "^(permitrootlogin|passwordauthentication|permitemptypasswords|pubkeyauthentication)" \
    || echo "  (sshd -T produced no match)"
else
  # fallback: no sshd binary installed -> read config file only
  grep -E "^(PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords|PubkeyAuthentication)" /etc/ssh/sshd_config 2>/dev/null \
    || echo "  (no sshd installed, no sshd_config match)"
fi

echo "[2] Firewall status (ufw / iptables / nftables)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "  ufw: active"
else
  echo "  ufw: not active or not installed"
fi
if command -v iptables >/dev/null 2>&1; then iptables -L -n 2>/dev/null | grep -qE "ACCEPT|DROP|REJECT" && echo "  iptables: rules present"; fi
if command -v nft >/dev/null 2>&1; then nft list ruleset 2>/dev/null | grep -q "table" && echo "  nftables: rules present"; fi

echo "[3] Password aging policy (/etc/login.defs)"
grep -vE "^#|^$" /etc/login.defs 2>/dev/null | grep -iE "PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE" || echo "  (no PASS_* policy found)"
echo "  -- existing accounts effective aging (chage -l, first 10) --"
if command -v chage >/dev/null 2>&1; then
  # login.defs only applies to NEW accounts; verify current users actually have the policy landed
  awk -F: '$3>=1000 && $7!="/usr/sbin/nologin" && $7!="/bin/false" {print $1}' /etc/passwd 2>/dev/null | head -10 | while read -r u; do
    [ -n "$u" ] && echo "  $u: $(chage -l "$u" 2>/dev/null | grep -iE 'Maximum number of days|Minimum number of days|Warning' | tr '\n' ' ')"
  done
  awk -F: '$3>=1000 && $7!="/usr/sbin/nologin" && $7!="/bin/false" {n++} END{print "  total login-capable users scanned above (first 10 shown)"}' /etc/passwd 2>/dev/null
else
  echo "  chage not installed"
fi

echo "[4] World-writable SUID/SGID binaries (count + first 20 on / filesystem)"
suid_count=$(find / -xdev -type f -perm /4000 2>/dev/null | wc -l)
echo "  SUID count: ${suid_count}"
# privilege-escalation surface:  SUID/SGID AND (not root-owned OR world-writable)
privesc=$(find / -xdev -type f -perm /6000 \( ! -user root -o -perm -0002 \) 2>/dev/null)
privesc_count=$(printf '%s\n' "$privesc" | grep -c . )
echo "  privesc-surface SUID (non-root owner or world-writable): ${privesc_count}"
printf '%s\n' "$privesc" | head -20
find / -xdev -type f -perm /4000 2>/dev/null | head -20 || echo "  (find failed)"

echo "[5] Open listening TCP/UDP ports (ss -> netstat -> /proc/net fallback)"
port_view=""
if command -v ss >/dev/null 2>&1; then
  port_view=$(ss -tulnp 2>/dev/null)
  echo "  method: ss"
elif command -v netstat >/dev/null 2>&1; then
  port_view=$(netstat -tulnp 2>/dev/null)
  echo "  method: netstat"
else
  echo "  method: /proc/net/tcp,/proc/net/udp (ss/netstat absent)"
  for f in tcp tcp6 udp udp6; do
    if [ -r "/proc/net/$f" ]; then
      awk 'NR>1 && $4=="0A"{print FILENAME": LISTEN "$2}' /proc/net/$f 2>/dev/null
    fi
  done
fi
printf '%s\n' "$port_view" | head -25

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

# [1] SSH: use EFFECTIVE values (sshd -T) when available, else config file
ssh_eff=$( { sshd -T 2>/dev/null || grep -E "^(PermitRootLogin|PasswordAuthentication)" /etc/ssh/sshd_config 2>/dev/null; } \
  | grep -Ei "^(permitrootlogin|passwordauthentication)" | tr -d ' ' )
case "$ssh_eff" in
  *"permitrootlogin:yes"*|*"permitrootlogin yes"*|*"PermitRootLogin=yes"*|*"passwordauthentication:yes"*|*"passwordauthentication yes"*|*"PasswordAuthentication=yes"*)
    grade "1-ssh-auth" "FAIL" 25 "PermitRootLogin or PasswordAuthentication effective=yes" ;;
  *)
    grade "1-ssh-auth" "OK" 0 "no insecure ssh auth effective=yes" ;;
esac

# [2] Firewall: fail=none of ufw/iptables/nftables active
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  grade "2-firewall" "OK" 0 "ufw active"
elif command -v iptables >/dev/null 2>&1 && iptables -L -n 2>/dev/null | grep -qE "ACCEPT|DROP|REJECT"; then
  grade "2-firewall" "OK" 0 "iptables rules present"
elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "table"; then
  grade "2-firewall" "OK" 0 "nftables rules present"
else
  grade "2-firewall" "FAIL" 25 "no active firewall rule detected (ufw/iptables/nftables)"
fi

# [3] Password aging: MAX>90 warn; MIN=0 warn; MAX undefined fail.
#     Also account for whether policy landed on EXISTING users via chage.
pass_max=$(grep -iE "^PASS_MAX_DAYS" /etc/login.defs 2>/dev/null | awk '{print $2}' | head -1)
pass_min=$(grep -iE "^PASS_MIN_DAYS" /etc/login.defs 2>/dev/null | awk '{print $2}' | head -1)
if [ -z "$pass_max" ]; then
  grade "3-passwd-aging" "FAIL" 20 "PASS_MAX_DAYS undefined in login.defs"
elif [ "$pass_max" -gt 90 ]; then
  grade "3-passwd-aging" "WARN" 10 "PASS_MAX_DAYS=${pass_max} > 90" 
else
  grade "3-passwd-aging" "OK" 0 "PASS_MAX_DAYS=${pass_max}"
fi
if [ "$pass_min" = "0" ]; then
  grade "3b-passwd-min" "WARN" 5 "PASS_MIN_DAYS=0 (immediate password changes)"
else
  grade "3b-passwd-min" "OK" 0 "PASS_MIN_DAYS=${pass_min:-not set}"
fi

# chage landed check: login.defs only affects NEW users; if any login-capable
# account is missing an effective max, flag as "policy not landed" warn.
chage_not_landed=0
if command -v chage >/dev/null 2>&1; then
  while read -r u; do
    [ -z "$u" ] && continue
    cmax=$(chage -l "$u" 2>/dev/null | grep -i "Maximum number of days" | awk '{print $NF}')
    if [ "$cmax" = "never" ] || [ -z "$cmax" ]; then chage_not_landed=$((chage_not_landed+1)); fi
  done < <(awk -F: '$3>=1000 && $7!="/usr/sbin/nologin" && $7!="/bin/false" {print $1}' /etc/passwd 2>/dev/null)
fi
if [ "$chage_not_landed" -gt 0 ]; then
  grade "3c-chage-landed" "WARN" 5 "${chage_not_landed} existing account(s) lack effective max-age policy (login.defs only affects new users)"
else
  grade "3c-chage-landed" "OK" 0 "existing accounts have effective aging policy"
fi

# [4] SUID/SGID: privesc surface (non-root owner OR world-writable) is the real risk
if [ "${privesc_count:-0}" -gt 0 ]; then
  grade "4-suid-privesc" "FAIL" 20 "found ${privesc_count} SUID/SGID with non-root owner or world-writable (escalation surface)"
else
  grade "4-suid-privesc" "OK" 0 "no world-writable/non-root SUID escalation surface"
fi
if [ "$suid_count" -gt 20 ]; then
  grade "4b-suid-count" "WARN" 5 "total SUID ${suid_count} > 20, review list"
else
  grade "4b-suid-count" "OK" 0 "SUID count ${suid_count} <= 20"
fi

# [5] Open ports: distinguish externally-exposed (0.0.0.0/::) vs loopback (127.)
ext_ports=$( { ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null; } | grep -cE "0\.0\.0\.0|\[?::\]")
loop_ports=$( { ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null; } | grep -cE "127\.0\.0\.1|\[::1\]")
open_ports=$(( ext_ports + loop_ports ))
if [ "$ext_ports" -gt 3 ]; then
  grade "5-open-ports" "WARN" 10 "externally-exposed listeners (0.0.0.0/::) = ${ext_ports} > 3"
else
  grade "5-open-ports" "OK" 0 "externally-exposed listeners = ${ext_ports} <= 3"
fi

# [6] Critical file perms
shadow_perms=$(stat -c %a /etc/shadow 2>/dev/null)
if [ "$shadow_perms" = "600" ] || [ "$shadow_perms" = "640" ] || [ "$shadow_perms" = "000" ]; then
  grade "6-critical-perms" "OK" 0 "shadow perms ${shadow_perms} restricted"
else
  grade "6-critical-perms" "FAIL" 20 "shadow perms ${shadow_perms} not restricted (expect 600/640/000)"
fi

# [7] Cron perms
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

# [8] Running as root: context flag only (not scored)
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

# ============================================================
# [TRACK] cross-run tracking of NOT-CLOSED items (命题: 跟踪未闭环项)
# ============================================================
open_now=$(awk -F'|' '$2 ~ /(FAIL|WARN)/ {gsub(/[ \t]/,"",$1); sub(/^\[EVAL\]/,"",$1); print $1}' "$SCORE_FILE")
open_prev=""
if [ -f "$STATE_FILE" ]; then
  open_prev=$(cat "$STATE_FILE")
fi

echo "" >> "$SCORE_FILE"
echo "===== NOT-CLOSED TRACK (跨轮次跟踪) =====" >> "$SCORE_FILE"
echo "run_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$SCORE_FILE"

now_list=$(printf '%s\n' $open_now)
prev_list=$(printf '%s\n' $open_prev)

if [ -n "$prev_list" ]; then
  while IFS= read -r it; do
    [ -z "$it" ] && continue
    if ! printf '%s\n' "$now_list" | grep -qx "$it"; then
      echo "CLOSED  | $it | 已闭环（上次为未闭环项，本轮已不存在）" >> "$SCORE_FILE"
    fi
  done <<< "$prev_list"
fi

if [ -n "$now_list" ]; then
  while IFS= read -r it; do
    [ -z "$it" ] && continue
    if printf '%s\n' "$prev_list" | grep -qx "$it"; then
      echo "STILL_OPEN | $it | 仍未闭环（与上轮一致的未闭环项）" >> "$SCORE_FILE"
    else
      echo "NEW_OPEN   | $it | 本轮回新出现未闭环项" >> "$SCORE_FILE"
    fi
  done <<< "$now_list"
else
  echo "NO_OPEN_ITEMS | 本轮无未闭环项" >> "$SCORE_FILE"
fi

printf '%s\n' $open_now > "$STATE_FILE"

echo ""
echo "===== NOT-CLOSED TRACK END ====="