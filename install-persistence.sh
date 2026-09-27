#!/usr/bin/env bash
set -uo pipefail
# install-persistence.sh — boot service + 60s governor watchdog for steamdeckopti.sh
# Runs next to steamdeckopti.sh; standalone by design.

if [[ $EUID -ne 0 ]]; then echo "[✗] Run as root: sudo $0"; exit 1; fi

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
OPT="$DIR/steamdeckopti.sh"
[[ -f "$OPT" ]] || { echo "[✗] steamdeckopti.sh not found in $DIR"; exit 1; }
chmod +x "$OPT"

# SteamOS read-only dance (same pattern as the optimizer itself)
RW=0
if command -v steamos-readonly >/dev/null 2>&1; then
    steamos-readonly disable && RW=1
    trap '[[ "$RW" = 1 ]] && steamos-readonly enable >/dev/null 2>&1' EXIT
fi

cat > /etc/systemd/system/steam-deck-opt.service << SVCEOF
[Unit]
Description=Steam Deck Optimizer boot apply
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$OPT --run
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/steam-deck-watchdog.service << 'SVCEOF'
[Unit]
Description=Steam Deck governor watchdog (60s re-assert)
[Service]
Type=oneshot
ExecStart=/bin/bash -c '[[ -f /etc/steam-deck-opt-manual-stop ]] && exit 0; for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$c"; done'
SVCEOF

cat > /etc/systemd/system/steam-deck-watchdog.timer << 'SVCEOF'
[Unit]
Description=Steam Deck governor watchdog timer

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
Persistent=true

[Install]
WantedBy=timers.target
SVCEOF

systemctl daemon-reload
systemctl enable --now steam-deck-opt.service
systemctl enable --now steam-deck-watchdog.timer
touch /etc/steam-deck-opt-marker

echo ""
echo "── RECEIPTS ──"
systemctl is-enabled steam-deck-opt.service >/dev/null && echo "✅ Boot service enabled" || echo "❌ Boot service NOT enabled"
systemctl is-active steam-deck-watchdog.timer >/dev/null && echo "✅ Watchdog timer active" || echo "❌ Watchdog timer NOT active"
[[ -f /etc/steam-deck-opt-marker ]] && echo "✅ Marker present"
grep ExecStart /etc/systemd/system/steam-deck-opt.service
echo ""
echo "Manual stop marker (to suspend watchdog): touch /etc/steam-deck-opt-manual-stop"
echo "Reboot to test boot persistence, then: journalctl -u steam-deck-opt.service | tail -5"
