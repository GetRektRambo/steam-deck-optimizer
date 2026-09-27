# Steam Deck Optimizer

A single-script system optimizer for SteamOS on the Steam Deck (LCD and OLED).
One script, six modes, one boot service, one governor watchdog. Set it and forget it.

**What this is not:** a magic FPS doubler. If someone promises you double
framerate from sysctls, they're lying. What this actually does is make the
system tighter and more consistent — snappier desktop, fewer hitches,
cleaner frametimes in the bad moments, and settings that survive reboots
and SteamOS updates instead of silently reverting.

## What it changes (stock vs optimized)

| Setting | SteamOS stock | After this script |
|---|---|---|
| CPU governor | schedutil (variable, comfort-biased) | performance (locked) |
| vm.swappiness | 60 (swap-friendly) | 1 (RAM-first) |
| Swap | zram only (~1GB effective) | zram + 9GB file swap fallback |
| vm.min_free_kbytes | ~90MB | 148MB on 16GB (scaled to RAM + OC) |
| Kernel watchdog | active (hardware watchdog polling) | disabled (nowatchdog, nmi_watchdog=0) |
| THP | madvise | madvise (verified, not assumed) |
| MGLRU | enabled by default | verified enabled, all 7 levels |
| I/O scheduler | mq-deadline on NVMe | none (native NVMe queueing) |
| TCP buffers | ~4MB max | 24MB |
| Persistence | none — reverts on reboot | boot service + 60s governor watchdog |

## The honest expectations

Measured on the my Steam Deck OLED (flashed BIOS via Smokeless, 30W TDP):

- **Frame time spikes reduced.** Killing the hardware watchdog (nowatchdog)
  removes regular polling interrupts. In the worst cases — shader
  compilation, traversal stutters — the tail gets shorter. This is the
  setting most people actually feel.
- **Snappier outside of games.** The performance governor matters most in
  desktop mode and light loads, where stock schedutil parks cores to save
  battery.
- **Fewer out-of-memory situations.** A real 9GB swap file behind zram
  means heavy games plus a browser plus Discord don't hit the wall.
  min_free_kbytes tuning keeps the allocator ahead of demand.
- **Load times unchanged.** The NVMe scheduler switch is mostly tidiness.
  Expect nothing here and you'll be correct.

If you want numbers for your own machine: run `--verify` before and after
a gaming session, and watch frametime graphs in your overlay of choice.
Don't trust anyone's percentages but your own.

## The power trade-off, stated plainly

The performance governor and watchdog-off settings trade idle power draw
for responsiveness. **Battery life in light use will drop** — parked cores
sip power. In gaming, the APU TDP dominates power draw and you won't
notice a difference. If you want the governor back on battery:

    sudo touch /etc/steam-deck-opt-manual-stop   # watchdog sleeps
    echo powersave | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

Delete the marker file to re-arm the watchdog.

## Quick start

    sudo ./steamdeckopti.sh --install     # tune everything + install persistence
    sudo reboot                            # kernel params apply here
    sudo ./steamdeckopti.sh --verify       # want: 8/8

That's it. From now on, every boot runs the lean tuning path and a
watchdog re-asserts the governor every 60 seconds.

### All modes

| Mode | What it does |
|---|---|
| *(none)* | Full detect-tune-verify run |
| `--install` | Full run + boot service + watchdog timer |
| `--verify` | Read-only report of live state, 8 checks, exit 0/1 |
| `--reapply` | Full run — use after a SteamOS update nukes things |
| `--uninstall` | Removes services. Leaves swap, GRUB params, sysctls, and backups alone |

## Things SteamOS doesn't tell you

These are the receipts from actually building this. Every one of them
cost an evening to discover:

- **`/proc/meminfo` lies about your RAM.** GPU-reserved memory (1GB stock,
  up to 4GB if you raise it in BIOS — no flash needed) is excluded from
  MemTotal. A naive reader sizes swap and min_free_kbytes against RAM you
  can't use. This script reads the actual reservation and sizes correctly.
- **The power cap interface doesn't exist.** SteamOS hides the APU power
  limit on recent builds (`/sys/class/powercap` is absent). Your BIOS PPT
  settings still apply at the firmware level — the script detects this and
  falls back gracefully instead of pretending it capped something.
- **GRUB doesn't live in /boot/grub.** The Deck's config is
  `/efi/EFI/steamos/grub.cfg`, and `/esp/SteamOS/conf` holds metadata, not
  the live config. Kernel params go into `/etc/default/grub`, then
  `grub-mkconfig -o /efi/EFI/steamos/grub.cfg`.
- **That ESP is autofs-mounted.** If `/efi` has gone to sleep, writes
  silently fail. The script tolerates this; if you're poking manually,
  `ls /efi` first to wake the mount.
- **systemd services have no HOME.** A `set -u` script that touches
  `$HOME` dies instantly at boot. The service carries
  `Environment=HOME=/root` for exactly this reason.

## Hardware detection

The profile is calculated, not hardcoded — CPU/GPU max clocks, physical
RAM (with VRAM carve-out), and detected overclocks feed the memory
parameters. Both stock Decks and overclocked ones (flashed BIOS or
otherwise) are sized appropriately. The OC bonus scales memory parameters
by +8% per detected OC headroom.

## Requirements

- Steam Deck (LCD or OLED) running SteamOS, any recent build
- Terminal access (desktop mode) and `sudo`

## Credits

Built the stubborn way: run it, read the receipts, fix what lied, repeat.
Companion piece to [steam-machine-optimizer](https://github.com/GetRektRambo/steam-machine-optimizer),
same architecture, different bootloader. The watchdog watches the
governor. The governor doesn't know.
