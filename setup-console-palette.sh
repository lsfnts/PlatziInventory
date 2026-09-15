#!/bin/dash
# Standalone follow-up for an already-installed machine (install-arch.sh's
# "Login screen animation" step already dropped animation.dur at
# /etc/ly/config.ini's dur_file_path and set animation = dur_file). Run this
# once, as root, any time after that:
#   doas dash setup-console-palette.sh
#
# Why this exists: ly draws the login animation on vt2, and vt2's fbcon can
# only ever hold 16 simultaneous colors (vc_palette). animation.dur is now
# colorFormat "16" (see convert16.py / ascii-flowers-159x50), which makes
# ly render it through DurFile.zig's non-full_color path — a direct lookup
# into whatever 16 colors vt2's palette currently holds, no RGB involved.
# Left at the console's default palette that lookup lands on the stock
# red/green/yellow/blue ANSI colors. This script reprograms those 16 slots
# to the same colors the .dur file's cell values were computed against (8
# clusters k-means'd out of the artwork, plus each darkened 35% for the
# paired background half of every cell), so the two line up exactly instead
# of by coincidence.
set -e

if [ "$(id -u)" != 0 ]; then
    echo "Run as root (doas dash setup-console-palette.sh)." >&2
    exit 1
fi

echo "-> full_color = false (colorFormat 16 needs the native path, not RGB)"
# DurFile.zig: full_color=true with colorFormat 16 still runs, but through
# convert256ToRgb's *fixed* rgb_color_16 constants (a generic aesthetic
# palette baked into ly, unrelated to this artwork) which the kernel then
# fuzzy-snaps to the nearest vt2 palette entry. full_color=false instead
# looks vt2's palette index up directly -- exact, and what the raw values
# in ascii-flowers-159x50/animation.dur were computed for.
if [ -f /etc/ly/config.ini ]; then
    sed -i -e 's|^full_color = .*|full_color = false|' /etc/ly/config.ini
    grep -q '^full_color = false$' /etc/ly/config.ini || {
        echo "  !! Could not set full_color = false in /etc/ly/config.ini." >&2
        echo "     Set it by hand or the animation will use the wrong colors." >&2
    }
else
    echo "  !! /etc/ly/config.ini not found -- is ly installed?" >&2
fi

echo "-> /usr/local/bin/set-tty2-palette"
cat > /usr/local/bin/set-tty2-palette <<'PALETTE_EOF'
#!/bin/dash
# Set vt2's 16 hardware palette entries (ESC ] P n rrggbb, see console_codes(4)).
# Values: 0-7 are 8 colors k-means'd out of the login animation's source
# image; 8-15 are the same 8, each darkened to 35% brightness, for the
# paired background half of every cell. Regenerate both (and re-run
# convert16.py against ascii-flowers-159x50) if the animation ever changes.
p() { printf '\033]P%s%s' "$1" "$2" > /dev/tty2; }
p 0 353c2e
p 1 535246
p 2 6c6a63
p 3 778583
p 4 ab858a
p 5 849997
p 6 c7a6a9
p 7 e6c7c3
p 8 131510
p 9 1d1d18
p a 262523
p b 2a2f2e
p c 3c2f30
p d 2e3635
p e 463a3b
p f 504644
PALETTE_EOF
chmod 755 /usr/local/bin/set-tty2-palette

echo "-> console-palette.service"
cat > /etc/systemd/system/console-palette.service <<'PALETTE_UNIT_EOF'
[Unit]
Description=Program vt2's 16-color palette to match the ly login animation
After=systemd-vconsole-setup.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/set-tty2-palette
PALETTE_UNIT_EOF

echo "-> ly@tty2.service.d/20-console-palette.conf"
# Requires=, not just After=: pulls console-palette.service in as a
# dependency so it runs before ly claims the tty even though nothing
# WantedBy= it directly (same reasoning install-arch.sh already uses for
# the plymouth-quit-wait.service ordering just above the animation step).
mkdir -p /etc/systemd/system/ly@tty2.service.d
cat > /etc/systemd/system/ly@tty2.service.d/20-console-palette.conf <<'LY_PALETTE_EOF'
[Unit]
After=console-palette.service
Requires=console-palette.service
LY_PALETTE_EOF

systemctl daemon-reload

echo "Done. Takes effect next time ly@tty2 starts -- either reboot, or:"
echo "  doas systemctl restart ly@tty2.service"
echo "(only do that from another tty/session: it will reset vt2's display)."
