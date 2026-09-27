# Changelog

## v1.0.2 — 2026-09-27
- GPU sclk detection rewritten: scan all DRM cards, parse by regex.
  Fixes GPU max reading 0 MHz on boots where the APU lands on a different
  card index, and survives the `Mhz` spelling in dpm tables
  (the old column-position awk did not).

## v1.0.1 — 2026-09-27
- Physical RAM detection: MemTotal + VRAM carve-out, rounded to GB.
  SteamOS /proc/meminfo excludes the GPU-reserved memory (default 1GB on
  both LCD and OLED, adjustable to 4GB in BIOS — no firmware flash needed).
  The naive MemTotal read undersized swap and min_free_kbytes by whatever
  amount was reserved. Now detects full physical capacity regardless of
  BIOS setting.
- MGLRU receipts made honest: the kernel reports `0x0007`, not `[Y]`, and
  the old verify check was accidentally matching the word "enabled" in the
  filename. Both fixed.

## v1.0.0 — 2026-09-27
- Clean rebuild as a single script. The v5.4 lineage was 850+ lines of
  accreted patches with unreachable blocks; this is ~320 lines, one flow,
  six modes.
- Modes: (default run), --install, --boot, --verify, --reapply, --uninstall.
- Lean `--boot` path for the systemd service: runtime tuning only. No swap
  rebuild or GRUB work at every boot — that was 9GB of fallocate every
  power cycle for no reason.
- `Environment=HOME=/root` in the boot service. systemd services run
  without HOME in their environment, and with `set -u` the script died at
  boot with "HOME: unbound variable" until it got one.
- `daemon-reload` after fstab edits — systemd caches fstab and complains
  until you poke it.
- Swap size parsed from /proc/swaps (kB-based) instead of `swapon --show`,
  which produced gems like "0GB".
- GRUB config target corrected to /efi/EFI/steamos/grub.cfg. The Deck
  does not use /boot/grub, and /esp/SteamOS/conf holds metadata, not the
  live config.

## Earlier (unreleased)
- v5.4-ALL-FIXES-V2-WATCHDOG: experimental lineage, superseded by the
  rebuild. Kept in git history for cold-boot provenance.
