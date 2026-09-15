#!/bin/dash
# Reverses setup-console-palette.sh. Run as root:
#   doas dash unset-console-palette.sh

set -e

if [ "$(id -u)" != 0 ]; then
    echo "Run as root (doas dash unset-console-palette.sh)." >&2
    exit 1
fi

echo "-> Stopping console-palette.service"
systemctl stop console-palette.service 2>/dev/null || true

echo "-> Removing /etc/systemd/system/ly@tty2.service.d/20-console-palette.conf"
rm -f /etc/systemd/system/ly@tty2.service.d/20-console-palette.conf
# Remove the directory if empty
rmdir /etc/systemd/system/ly@tty2.service.d 2>/dev/null || true

echo "-> Removing /etc/systemd/system/console-palette.service"
rm -f /etc/systemd/system/console-palette.service

echo "-> Removing /usr/local/bin/set-tty2-palette"
rm -f /usr/local/bin/set-tty2-palette

echo "-> Restoring full_color = true in /etc/ly/config.ini"
if [ -f /etc/ly/config.ini ]; then
    # Replace full_color = false with full_color = true
    sed -i -e 's|^full_color = false$|full_color = true|' /etc/ly/config.ini

    # If no full_color line exists after replacement, it means it was set to false
    # and we just replaced it, so check if it worked
    if grep -q '^full_color = true$' /etc/ly/config.ini; then
        echo "  ✓ Set full_color = true"
    else
        echo "  !! Could not verify full_color = true in /etc/ly/config.ini." >&2
        echo "     Check /etc/ly/config.ini manually." >&2
    fi
else
    echo "  !! /etc/ly/config.ini not found." >&2
fi

systemctl daemon-reload

echo "Done. Changes take effect next time ly@tty2 starts -- either reboot, or:"
echo "  doas systemctl restart ly@tty2.service"
echo "(only do that from another tty/session: it will reset vt2's display)."
