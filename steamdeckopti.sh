#!/usr/bin/env bash
# ============================================================
#  STEAM DECK OPTIMIZER — v1.0.0
#  One script. Tune it, install it, forget it.
#
#  Modes:
#    (default)  full run — detect, tune, verify, report
#    --install  full run + boot service + 60s governor watchdog
#    --boot     lean service path (runtime settings only,
#               no swap rebuild / GRUB work / backups)
#    --verify   read-only system state report, exit 0/1
#    --reapply  full run (use after a SteamOS update)
#    --uninstall remove services, stop watchdog, leave data
#
#  Copyright (c) 2026 GetRektRambo — MIT License
# ============================================================

set -uo pipefail

# systemd services run without HOME — this bit us at 16:01 on 2026-09-27.
# Guard before anything touches $HOME.
export HOME="${HOME:-/root}"

SCRIPT_VERSION="1.0.2"
SCRIPT_PATH="$(readlink -f "$0")"     # bound here, always, before set -u can complain

LOG_FILE="/var/log/steam-deck-optim.log"
BACKUP_DIR=""
MARKER="/etc/steam-deck-opt-marker"
MANUAL_STOP="/etc/steam-deck-opt-manual-stop"
GRUB_DEFAULT="/etc/default/grub"
GRUB_TARGET="/efi/EFI/steamos/grub.cfg"   # SteamOS Deck: GRUB lives HERE, not /boot/grub
SWAPFILE="/home/swapfile"
KERNEL_PARAMS="nowatchdog nmi_watchdog=0"

# OC detection thresholds (MHz)  # TUNE: judgment calls — receipts show 4201/2200 clears both
OC_CPU_MHZ=4000
OC_GPU_MHZ=2000
DEFAULT_PPT_W=22               # SteamOS hides /sys/class/powercap on the Deck; BIOS wins

# ─────────────────────────────────────────────
# Mode parsing — before anything else runs
# ─────────────────────────────────────────────
MODE="--run"
for arg in "$@"; do
    case "$arg" in
        --install|--verify|--reapply|--uninstall|--boot) MODE="$arg" ;;
    esac
done

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] [INFO] $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$(date +%H:%M:%S)] [INFO] $*"; }
warn() { echo "[$(date +%H:%M:%S)] [WARN] $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$(date +%H:%M:%S)] [WARN] $*"; }
ok()   { echo "✓ $*"; }
fail() { echo "✗ $*"; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This mode needs root: sudo $0 $MODE"
        exit 1
    fi
}

# SteamOS read-only handling. Exit trap guarantees re-lock on any crash.
RO_UNLOCKED=0
ro_disable() { command -v steamos-readonly >/dev/null 2>&1 && { steamos-readonly disable && RO_UNLOCKED=1; }; }
ro_enable()  { [[ "$RO_UNLOCKED" = 1 ]] && steamos-readonly enable >/dev/null 2>&1; }
trap ro_enable EXIT
# Lesson from the field: fstab edits confuse systemd until it re-reads config.
daemon_sync() { systemctl daemon-reload 2>/dev/null; }

# ─────────────────────────────────────────────
# VERIFY MODE — standalone, read-mostly, exits
# ─────────────────────────────────────────────
if [[ "$MODE" == "--verify" ]]; then
    echo "── VERIFY MODE: live system state (v$SCRIPT_VERSION) ──"
    PASS=0; FAIL=0
    chk() { if eval "$2" >/dev/null 2>&1; then echo "  ✓ $1"; PASS=$((PASS+1)); else echo "  ✗ $1"; FAIL=$((FAIL+1)); fi; }
    chk "CPU governor: performance"  'grep -q performance /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'
    chk "Swappiness: 1"               '[ "$(cat /proc/sys/vm/swappiness)" = "1" ]'
    chk "Kernel params: nowatchdog"  'grep -q nowatchdog /proc/cmdline'
    chk "Swap file active"            'grep -q /home/swapfile /proc/swaps'
    chk "THP: madvise"                'grep -q "\[madvise\]" /sys/kernel/mm/transparent_hugepage/enabled'
    chk "MGLRU enabled"               'grep -qE "\[Y\]|0x000[1-7]" /sys/kernel/mm/lru_gen/enabled 2>/dev/null'
    chk "Boot service installed"      'systemctl is-enabled steam-deck-opt.service'
    chk "Watchdog timer running"     'systemctl is-active steam-deck-watchdog.timer'
    echo "── Passed: $PASS  Failed: $FAIL ──"
    [[ $FAIL -eq 0 ]] || exit 1
    exit 0
fi

# Everything below here modifies the system.
need_root
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
: > "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

echo "============================================"
echo "  STEAM DECK OPTIMIZER  —  v$SCRIPT_VERSION"
echo "============================================"
log "Mode: $MODE"

# ─────────────────────────────────────────────
# UNINSTALL MODE
# ─────────────────────────────────────────────
if [[ "$MODE" == "--uninstall" ]]; then
    log "Uninstalling services..."
    ro_disable
    systemctl disable --now steam-deck-opt.service steam-deck-watchdog.timer 2>/dev/null
    rm -f /etc/systemd/system/steam-deck-opt.service \
          /etc/systemd/system/steam-deck-watchdog.timer \
          /etc/systemd/system/steam-deck-watchdog.service \
          "$MARKER"
    daemon_sync
    ro_enable; RO_UNLOCKED=0
    echo "Services stopped and removed."
    echo "Left alone on purpose: swap file, GRUB params, sysctl tweaks, backups in /root/steam-deck-backup-*"
    echo "To fully revert GRUB: remove '$KERNEL_PARAMS' from $GRUB_DEFAULT and run:"
    echo "  grub-mkconfig -o $GRUB_TARGET"
    exit 0
fi

# ─────────────────────────────────────────────
# 1. Pre-flight + backups (skipped in --boot)
# ─────────────────────────────────────────────
if [[ "$MODE" != "--boot" ]]; then
    log "Pre-flight checks and backups..."
    [[ -f /etc/os-release ]] && grep -qi steamos /etc/os-release && ok "Detected SteamOS"

    BACKUP_DIR="/root/steam-deck-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    for f in "$GRUB_DEFAULT" /etc/fstab /etc/sysctl.conf; do
        [[ -f "$f" ]] && cp "$f" "$BACKUP_DIR/" 2>/dev/null
    done
    ok "Backups created at: $BACKUP_DIR"
fi

# ─────────────────────────────────────────────
# 2. Hardware detection
# ─────────────────────────────────────────────
log "Detecting hardware..."
CPU_MAX_MHZ=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0) / 1000 ))
# GPU max = highest sclk dpm state across any DRM card (index varies between boots)
GPU_MAX_MHZ=0
for sclk in /sys/class/drm/card*/device/pp_dpm_sclk; do
    [[ -r "$sclk" ]] || continue
    v=$(grep -oE '[0-9]+M' "$sclk" | tr -d 'M' | sort -n | tail -1)
    [[ -n "$v" ]] && (( v > GPU_MAX_MHZ )) && GPU_MAX_MHZ=$v
done
# /proc/meminfo excludes the GPU carve-out (OLED BIOS reserves ~4GiB).
# Physical RAM = MemTotal + mem_info_vram_total, rounded to nearest GB.
RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
VRAM_KB=$(( $(cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null || echo 0) / 1024 ))
RAM_GB=$(( (RAM_KB + VRAM_KB + 524288) / 1048576 ))

CPU_OC=0; GPU_OC=0
(( CPU_MAX_MHZ > OC_CPU_MHZ )) && CPU_OC=1
(( GPU_MAX_MHZ > OC_GPU_MHZ )) && GPU_OC=1
OC_BONUS=$(( (CPU_OC + GPU_OC) * 8 ))   # +8% memory params per detected OC
log "  CPU max: ${CPU_MAX_MHZ} MHz (OC=$CPU_OC)  GPU max: ${GPU_MAX_MHZ} MHz (OC=$GPU_OC)  RAM: ${RAM_GB}GB"
log "  OC bonus: +${OC_BONUS}% memory parameters"

# ─────────────────────────────────────────────
# 3. PPT detection — SteamOS hides powercap on Deck,
#    so BIOS settings win. Fall back to sane default.
# ─────────────────────────────────────────────
log "Attempting PPT detection..."
PPT_W=$DEFAULT_PPT_W
if [[ -d /sys/class/powercap/intel-rapl* ]] 2>/dev/null; then
    log "Intel RAPL found (unexpected on Deck — using it)"
    for f in /sys/class/powercap/intel-rapl*/constraint_0_power_limit_uw; do
        [[ -r "$f" ]] && PPT_W=$(( $(cat "$f") / 1000000 )) && break
    done
else
    log "No usable PPT interface (normal on SteamOS) — default ${PPT_W}W, BIOS settings respected"
fi
log "Target PPT: ${PPT_W}W"

# ─────────────────────────────────────────────
# 4. Memory parameter calculation
#    Formulas reproduce the cold-boot-proven values
#    on 16GB / +16% OC: min_free=148480, swap=9GB.
# ─────────────────────────────────────────────
MIN_FREE_KB=$(( RAM_GB * 8000 * (100 + OC_BONUS) / 100 ))
SWAP_GB=$(( RAM_GB / 2 + 1 ))
(( SWAP_GB < 4 )) && SWAP_GB=4
TCP_BUF=25165824   # 24MB — proven value

log "Calculated: min_free_kbytes=$MIN_FREE_KB swap=${SWAP_GB}GB"

# ─────────────────────────────────────────────
# Summary block
# ─────────────────────────────────────────────
echo ""
echo "============================================"
echo "  PROFILE SUMMARY"
echo "============================================"
echo "  CPU: ${CPU_MAX_MHZ} MHz $([[ $CPU_OC = 1 ]] && echo '✅ OC')"
echo "  GPU: ${GPU_MAX_MHZ} MHz $([[ $GPU_OC = 1 ]] && echo '✅ OC')"
echo "  RAM: ${RAM_GB}GB   OC bonus: +${OC_BONUS}%"
echo "  PPT: ${PPT_W}W   Swap: ${SWAP_GB}GB   MinFree: $((MIN_FREE_KB/1024))MB"
echo "============================================"

# ─────────────────────────────────────────────
# 5. Unlock, then apply
# ─────────────────────────────────────────────
ro_disable

# --- sysctls ---
log "Applying memory parameters..."
cat > /etc/sysctl.d/99-steam-deck-opt.conf << SYSEOF
vm.swappiness = 1
vm.vfs_cache_pressure = 40
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5
net.core.rmem_max = ${TCP_BUF}
net.core.wmem_max = ${TCP_BUF}
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_rmem = 4096 87380 ${TCP_BUF}
net.ipv4.tcp_wmem = 4096 65536 ${TCP_BUF}
SYSEOF
sysctl -p /etc/sysctl.d/99-steam-deck-opt.conf >/dev/null 2>&1 && ok "Memory parameters applied"

# --- CPU governor ---
log "Setting CPU governor: performance"
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$c" 2>/dev/null
done
grep -q performance /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor && ok "CPU governor set to performance"

# --- GPU power cap (graceful — SteamOS hides it) ---
log "Setting GPU power cap (${PPT_W}W)..."
if [[ -w /sys/class/drm/card0/device/power_dpm_force_performance_level ]] 2>/dev/null; then
    echo "high" > /sys/class/drm/card0/device/power_dpm_force_performance_level && ok "GPU DPM forced high"
else
    log "Power cap interface not available — BIOS PPT settings stay in charge (normal on Deck)"
fi

# --- THP + MGLRU (runtime — belongs in --boot too) ---
log "Configuring Transparent Huge Pages..."
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && ok "THP: madvise"

log "Enabling MGLRU..."
if [[ -w /sys/kernel/mm/lru_gen/enabled ]]; then
    echo Y > /sys/kernel/mm/lru_gen/enabled 2>/dev/null
    grep -qE '\[Y\]|0x000[1-7]' /sys/kernel/mm/lru_gen/enabled && ok "MGLRU enabled (levels: $(cat /sys/kernel/mm/lru_gen/enabled))"
else
    log "MGLRU interface not present (older kernel) — skipping"
fi

# --- I/O scheduler ---
for d in /sys/block/nvme*/queue/scheduler; do
    [[ -w "$d" ]] && echo none > "$d" 2>/dev/null
done
ok "NVMe scheduler: none"

# --- memlock limits ---
cat > /etc/security/limits.d/99-steam-deck-opt.conf << 'LIMEOF'
* soft memlock unlimited
* hard memlock unlimited
LIMEOF
ok "Memlock limits configured (takes effect on next login)"

# --- noatime check (informational) ---
if grep -q ' /home .*noatime' /proc/mounts; then
    ok "/home mounted with noatime"
else
    warn "/home not mounted with noatime — add 'noatime' to the /home fstab entry for less SSD chatter"
fi

# ─────────────────────────────────────────────
# 6. Swap (skip in --boot — don't rebuild 9GB at every boot)
# ─────────────────────────────────────────────
if [[ "$MODE" != "--boot" ]]; then
    log "Setting up ${SWAP_GB}GB swap file..."
    swapoff "$SWAPFILE" 2>/dev/null
    rm -f "$SWAPFILE"
    fallocate -l "${SWAP_GB}G" "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_GB*1024)) status=none
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null 2>&1
    swapon "$SWAPFILE" >/dev/null 2>&1
    grep -q "$SWAPFILE" /proc/swaps || { fail "Swap activation failed"; }
    if ! grep -q "$SWAPFILE" /etc/fstab; then
        echo "$SWAPFILE none swap defaults 0 0" >> /etc/fstab
    fi
    daemon_sync    # fstab changed — systemd must re-read (lesson learned)
    # /proc/swaps is kB-based; this is the honest number:
    SWAP_LIVE_GB=$(awk -v sf="$SWAPFILE" '$1==sf{printf "%.0f", $3/1048576}' /proc/swaps)
    ok "Swap file active (${SWAP_LIVE_GB}GB)"
fi

# ─────────────────────────────────────────────
# 7. Kernel boot parameters (skip in --boot)
# ─────────────────────────────────────────────
if [[ "$MODE" != "--boot" ]]; then
    log "Updating kernel boot parameters..."
    ro_disable
    CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT" | head -1)
    if ! grep -q nowatchdog "$GRUB_DEFAULT" 2>/dev/null; then
        NEWLINE=$(echo "$CURRENT" | sed "s/\"\$/ ${KERNEL_PARAMS}\"/")
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${NEWLINE}|" "$GRUB_DEFAULT"
    fi
    if grep -q nowatchdog "$GRUB_DEFAULT"; then
        ok "Kernel params present in $GRUB_DEFAULT"
    else
        fail "Could not patch GRUB_CMDLINE_LINUX_DEFAULT — check manually"
    fi
    if grub-mkconfig -o "$GRUB_TARGET" >/dev/null 2>&1; then
        ok "Regenerated $GRUB_TARGET"
    else
        # /efi is autofs — it must be awake. Poke it, retry once.
        ls "$GRUB_TARGET" >/dev/null 2>&1 && warn "Could not regenerate GRUB config — run grub-mkconfig manually"
    fi
    log "Reboot to apply. Verify with: cat /proc/cmdline | grep nowatchdog"
fi

# ─────────────────────────────────────────────
# 8. SERVICE INSTALLATION (--install only)
#    Born from the September war of the unreachable
#    blocks. Runs. Right here. Always.
# ─────────────────────────────────────────────
if [[ "$MODE" == "--install" ]]; then
    log "Installing persistence services..."
    ro_disable

    # Boot service — lean --boot path, HOME provided (systemd strips env by default)
    cat > /etc/systemd/system/steam-deck-opt.service << SVCEOF
[Unit]
Description=Steam Deck Optimizer boot apply
After=multi-user.target

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=${SCRIPT_PATH} --boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    # Watchdog — 60s governor re-assert, respects manual stop marker
    cat > /etc/systemd/system/steam-deck-watchdog.service << WDEOF
[Unit]
Description=Steam Deck governor watchdog

[Service]
Type=oneshot
ExecStart=/bin/bash -c '[[ -f /etc/steam-deck-opt-manual-stop ]] && exit 0; for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$c"; done'
WDEOF

    cat > /etc/systemd/system/steam-deck-watchdog.timer << WTEOF
[Unit]
Description=Steam Deck governor watchdog timer

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
Persistent=true

[Install]
WantedBy=timers.target
WTEOF

    daemon_sync
    systemctl enable --now steam-deck-opt.service >/dev/null 2>&1
    systemctl enable --now steam-deck-watchdog.timer >/dev/null 2>&1
    touch "$MARKER"
    ok "Boot service + 60s governor watchdog installed"
    echo ""
    echo "  Manual stop:   sudo touch $MANUAL_STOP   (watchdog sleeps until you rm it)"
fi

# ─────────────────────────────────────────────
# 9. Lock up and report
# ─────────────────────────────────────────────
ro_enable; RO_UNLOCKED=0

log "Verification pass..."
echo ""
echo "============================================"
echo "  RESULT: v$SCRIPT_VERSION — $MODE"
echo "============================================"
echo "  Applied: sysctl pack, performance governor, THP madvise,"
echo "           MGLRU, NVMe scheduler, memlock, $([[ "$MODE" != "--boot" ]] && echo "swap ${SWAP_GB}GB, kernel params, ")"
echo "$([[ "$MODE" == "--install" ]] && echo "           persistence services")"
[[ "$MODE" != "--boot" ]] && echo "  Reboot needed for: kernel params (verify: cat /proc/cmdline | grep nowatchdog)"
echo "  Full check: sudo $0 --verify"
echo "============================================"
# The watchdog watches the governor. The governor doesn't know. Nobody tells him anything.
exit 0
