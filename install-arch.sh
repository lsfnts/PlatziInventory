#!/bin/bash
#
# Arch Linux installer — run from the live USB.
# Encodes: LUKS2 + F2FS root (lz4 compression) sealed in a signed UKI
# (booster + ukify · Secure Boot with your own keys · TPM2 auto-unlock),
# booted directly by the firmware via an efibootmgr entry — no boot manager ·
# bare iwd + nftables with a manual zone script · doas · dash as /bin/sh ·
# TLP · mesa/vulkan-radeon · scx-scheds · MGLRU · zram swap (lz4 primary,
# zstd level 9 recompression) with a pinned swap file activated only to
# hibernate · suspend-then-hibernate · plymouth (arch-slider-and-glow,
# fetched from codeberg at install time) · Hyprland under uwsm + ly ·
# reflector/paccache/fstrim maintenance. No GTK anywhere: no GTK theme either.
#
# Desktop: foot (terminal) · fuzzel (launcher) · ashell (status bar AND
# notification daemon) · yazi (file manager) · Catppuccin Macchiato everywhere.
# The session is a set of systemd user units, not a process tree: uwsm starts
# the compositor and its daemons, runapp starts applications into
# app-graphical.slice, and systemd-oomd kills one of those instead of the
# desktop when memory runs out.
#
# THIS SCRIPT WIPES A DISK. Read the variables below, edit them, then run it.
# It will ask you to type the disk device name back to confirm before
# touching anything.
#
# Stays bash, unlike the dash scripts it writes: pacstrap (Step 4) is what
# lets this same file guarantee dash is installed in the TARGET system
# before chroot-setup.sh's own #!/bin/dash ever gets exec'd — but nothing
# can make the same guarantee for the live USB this script itself runs
# from. Its content has no bash-specific dependency left in it either way
# (see TRUSTED_SSIDS below for the one exception, kept as an array
# deliberately for how much friendlier it is to edit).

set -euo pipefail

# ============================================================
# EDIT THESE BEFORE RUNNING
# ============================================================
DISK="/dev/nvme0n1"          # `lsblk` to confirm — THIS ENTIRE DISK IS WIPED
HOSTNAME="magnolia"
USERNAME="luis"
TIMEZONE="America/El_Salvador"       # e.g. America/New_York — see /usr/share/zoneinfo
LANG_LOCALE="en_US.UTF-8"     # display/message language
REGIONAL_LOCALE="es_SV.UTF-8" # date/currency/number formatting (El Salvador)
REFLECTOR_COUNTRIES="US,MX,CO"
CONSOLE_KEYMAP="la-latin1"
KB_LAYOUT="latam"
# Hibernation swap file, in MiB. Not the primary swap device (zram is), so
# this only has to hold the hibernation image — see Step 8.
SWAP_SIZE_MIB=10240
TRUSTED_SSIDS=("Acuario/5g" "Galaxy S23 4A5C")   # for the nftables zone script
WIFI_IFACE="wlan0"           # confirm with `iwctl device list` before running
# ============================================================

# --- Sanity checks ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root from the live environment." >&2
    exit 1
fi

if [ ! -d /sys/firmware/efi ]; then
    echo "Not booted in UEFI mode — the UKI is booted directly by the firmware," >&2
    echo "which requires UEFI (no BIOS/CSM fallback). Aborting." >&2
    exit 1
fi

if [ ! -b "$DISK" ]; then
    echo "Disk $DISK not found. Check 'lsblk' and edit the DISK variable." >&2
    exit 1
fi

# The LUKS passphrase is typed here and re-typed at every boot, so the live
# keymap must match the installed one or a symbol turns it into a lockout.
if ! loadkeys "$CONSOLE_KEYMAP"; then
    echo "Unknown keymap '$CONSOLE_KEYMAP'. 'localectl list-keymaps' lists the" >&2
    echo "valid names; fix CONSOLE_KEYMAP at the top of this script." >&2
    exit 1
fi

# curl, not ping: plenty of networks drop ICMP while HTTPS works fine.
if ! curl -fsS --max-time 10 -o /dev/null https://archlinux.org/; then
    echo "No network reachable. Connect first with 'iwctl' (see the live-boot"
    echo "networking step), then re-run this script."
    exit 1
fi

echo "=================================================================="
echo "  About to WIPE AND PARTITION: $DISK"
lsblk "$DISK"
echo "=================================================================="
# 'read -p' is a bash-ism; 'printf' then a plain 'read -r' is the POSIX form.
printf '%s' "Type the disk device path exactly ($DISK) to confirm and continue: "
read -r CONFIRM
if [ "$CONFIRM" != "$DISK" ]; then
    echo "Confirmation did not match. Aborting, nothing was touched."
    exit 1
fi

# Work out partition naming (nvme/mmcblk use a 'p' before the number). A
# case pattern is the portable form of bash's '[[ == glob ]]'.
case "$DISK" in
    *nvme*|*mmcblk*)
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
        ;;
    *)
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
        ;;
esac

# Root mount options, reused verbatim in the bootloader's rootflags=.
# compress_extension=* is what actually enables compression; the mkfs feature
# and compress_algorithm only make it possible. The nocompress_extension list
# is data lz4 can never win on (already-compressed formats, Godot's .ctex,
# git packfiles). The kernel takes one extension per option, caps the list at
# 16 (COMPRESS_EXT_NUM) and 7 characters each, and rejects '*' here.
ROOT_MOUNT_OPTS="compress_algorithm=lz4,compress_chksum,compress_extension=*,nocompress_extension=zst,nocompress_extension=zip,nocompress_extension=7z,nocompress_extension=gz,nocompress_extension=xz,nocompress_extension=rar,nocompress_extension=png,nocompress_extension=jpg,nocompress_extension=jpeg,nocompress_extension=webp,nocompress_extension=ogg,nocompress_extension=mp3,nocompress_extension=mp4,nocompress_extension=webm,nocompress_extension=sqlite3,nocompress_extension=sqlite,atgc,gc_merge,checkpoint_merge,flush_merge,lazytime,inline_xattr,noatime,discard"

echo "==> Step 0: Checking the drive's formatted LBA size"
# Drives often ship 512e with 4Kn available. Native removes a translation
# layer in the controller; the drive rates its formats via Relative
# Performance (lower = better).
echo "    logical block size: $(blockdev --getss "$DISK")B   physical: $(blockdev --getpbsz "$DISK")B"
case "$DISK" in /dev/nvme*)
    if ! command -v nvme >/dev/null 2>&1; then
        echo "    nvme-cli is not in this live environment — skipping the LBA-format"
        echo "    check. Run 'pacman -Sy nvme-cli' and re-run this script to enable it."
    else
        nvme id-ns -H "$DISK" | grep -E '^LBA Format' || true
        # Best format: lowest Relative Performance, largest data size on a
        # tie, never one with metadata bytes (those are T10 PI). Captured as
        # one line of text, not via process substitution into 'read'
        # (dash has no '<(...)'), then split on whitespace the same way
        # 'read' would — '$@'/positional parameters are dash's stand-in for
        # an array here.
        lbaf_result="$(nvme id-ns -H "$DISK" | awk '
            /^LBA Format/ {
                idx = $3; ms = ""; ds = ""; rp = ""
                for (i = 1; i <= NF; i++) {
                    if ($i == "Size:" && $(i-1) == "Metadata")     ms = $(i+1) + 0
                    if ($i == "Size:" && $(i-1) == "Data")         ds = $(i+1) + 0
                    if ($i == "Performance:")                      rp = strtonum($(i+1))
                }
                if (index($0, "(in use)")) { cur_idx = idx; cur_ds = ds }
                if (ms != 0) next
                if (best_ds == "" || rp < best_rp || (rp == best_rp && ds > best_ds)) {
                    best_idx = idx; best_ds = ds; best_rp = rp
                }
            }
            END { print best_idx, best_ds, cur_idx, cur_ds }')"
        set -- $lbaf_result
        BEST_LBAF="${1:-}"; BEST_DS="${2:-}"; CUR_LBAF="${3:-}"; CUR_DS="${4:-}"
        if [ -n "$BEST_LBAF" ] && [ "$BEST_LBAF" != "$CUR_LBAF" ]; then
            echo
            echo "    This namespace is using LBA format $CUR_LBAF (${CUR_DS}B), but format"
            echo "    $BEST_LBAF (${BEST_DS}B) is rated better by the drive itself."
            echo "    Reformatting erases the namespace — which this script is about to do"
            echo "    anyway — and usually finishes in seconds."
            printf '%s' "    Run 'nvme format --lbaf=$BEST_LBAF' on $DISK now? [y/N] "
            read -r DOLBAF
            case "$DOLBAF" in
                [Yy])
                    nvme format --lbaf="$BEST_LBAF" --force "$DISK"
                    udevadm settle
                    echo "    now: $(blockdev --getss "$DISK")B logical"
                    ;;
            esac
        else
            echo "    Already on the drive's preferred LBA format."
        fi
    fi
    ;;
esac

# FAT32 needs >= 65525 clusters and a cluster is never smaller than a sector,
# so 4 KiB sectors put the floor at 256 MiB of data area — 256M lands just
# under it and mkfs.fat -F32 refuses, 288M clears it. (4Kn also needs
# dosfstools >= 4.2; Arch ships that.)
LBS="$(blockdev --getss "$DISK")"
if [ "$LBS" -ge 4096 ]; then
    EFI_SIZE="288M"
else
    EFI_SIZE="256M"
fi

# Alignment in SECTORS, because that is what sgdisk -a takes and a 4Kn drive
# has eight times fewer per MiB. 2 MiB rather than 1 MiB: LUKS2's data offset
# is 16 MiB, so a 2 MiB-aligned start also aligns the dm-crypt payload and
# f2fs's 2 MiB sections. Both ESP sizes are multiples of 2 MiB, so partition 2
# inherits an aligned start.
ALIGN_BYTES=2097152
ALIGN_SECTORS=$(( ALIGN_BYTES / LBS ))

echo "==> Step 1: Partitioning $DISK"
# An aborted run leaves the disk held (/mnt mounted, mapper open, swap
# active); sgdisk would rewrite the table while the kernel keeps the old one.
# Release it all first — a no-op on a clean disk. Only this disk's swap, not
# the live environment's own.
# A plain pipe, not process substitution (dash has no '<(...)'): nothing
# the loop body does needs to outlive it, so running it in a subshell (as
# a pipeline's last command does in dash) costs nothing here.
tail -n +2 /proc/swaps | while read -r sw _; do
    case "$sw" in "$DISK"*|/mnt/*) swapoff "$sw" 2>/dev/null || true;; esac
done
umount -R /mnt 2>/dev/null || true
for holder in /dev/mapper/root /dev/mapper/*; do
    [ -b "$holder" ] || continue
    case "$holder" in */control) continue;; esac
    cryptsetup close "$(basename "$holder")" 2>/dev/null || true
done
udevadm settle
# Still busy after that means something outside this script has it open —
# say the live ISO auto-mounted a partition. Name it instead of failing later.
if lsblk -nro MOUNTPOINT "$DISK" | grep -q .; then
    echo "  !! $DISK still has mounted partitions:" >&2
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$DISK" >&2
    echo "     Unmount them (or reboot the live USB) and re-run." >&2
    exit 1
fi

sgdisk --zap-all "$DISK"
# Belt and braces: zap-all clears the GPT/MBR structures but leaves other
# filesystem/LUKS signatures in the first sectors, which blkid keeps reporting.
wipefs -a "$DISK" >/dev/null
# Measured on this build: a signed UKI is ~68 MB (16.4 MB kernel + 51 MB
# zstd booster initrd carrying amdgpu and plymouth + microcode), and an
# upgrade briefly holds two, so ~136 MB peak. Both ESP sizes clear that.
sgdisk -a "$ALIGN_SECTORS" -I -n1:0:+"$EFI_SIZE" -t1:ef00 -c1:"EFI" "$DISK"
# -n2:0:0 would end on the last usable sector, 33 sectors below the end of
# the device (secondary GPT) and almost never aligned. -E reports that
# sector; round it down. Cost: the trailing partial 2 MiB.
ROOT_END=$(( ($(sgdisk -E "$DISK") + 1) / ALIGN_SECTORS * ALIGN_SECTORS - 1 ))
sgdisk -a "$ALIGN_SECTORS" -n2:0:"$ROOT_END" -t2:8300 -c2:"root" "$DISK"

# A misaligned end is silent and costs a read-modify-write per
# boundary-crossing I/O for the life of the install. Check it.
is_all_digits() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}
for pnum in 1 2; do
    # Captured as one line and split via positional parameters, not process
    # substitution into 'read' (dash has no '<(...)').
    sector_range="$(sgdisk -i"$pnum" "$DISK" | awk '
        /^First sector:/ {f=$3} /^Last sector:/ {l=$3} END {print f, l}')"
    set -- $sector_range
    pfirst="${1:-}"; plast="${2:-}"
    if ! is_all_digits "$pfirst" || ! is_all_digits "$plast"; then
        echo "  !! could not read partition $pnum's sector range from sgdisk." >&2
        exit 1
    fi
    if [ "$((pfirst % ALIGN_SECTORS))" -ne 0 ] || [ "$(( (plast + 1) % ALIGN_SECTORS ))" -ne 0 ]; then
        echo "  !! partition $pnum is not $((ALIGN_BYTES / 1048576)) MiB aligned:" >&2
        echo "     first=$pfirst last=$plast, alignment $ALIGN_SECTORS sectors of ${LBS}B" >&2
        exit 1
    fi
    echo "    p${pnum}: sectors ${pfirst}-${plast} ($(( (plast + 1 - pfirst) * LBS / 1048576 )) MiB), both ends $((ALIGN_BYTES / 1048576)) MiB aligned"
done
# partprobe can still report the old table just after a holder was released;
# blockdev --rereadpt is the harder hammer, and the loop waits for udev.
partprobe "$DISK" || blockdev --rereadpt "$DISK"
udevadm settle
for _ in $(seq 1 10); do
    [ -b "$EFI_PART" ] && [ -b "$ROOT_PART" ] && break
    sleep 1
    udevadm settle
done
if [ ! -b "$EFI_PART" ] || [ ! -b "$ROOT_PART" ]; then
    echo "  !! $EFI_PART / $ROOT_PART did not appear after re-reading the table." >&2
    echo "     The kernel is still on the old partition table — reboot the live" >&2
    echo "     USB and re-run; nothing has been written to the new layout yet." >&2
    exit 1
fi

echo "==> Step 2: Formatting"
mkfs.fat -F32 "$EFI_PART"

# --- LUKS2 -------------------------------------------------------------
# aes-xts on Zen 5's VAES is not the bottleneck; the flags are:
#   --key-size 256      
#   --sector-size 4096  match the drive's LBA size, or dm-crypt does a
#                       read-modify-write per physical block
#   --persistent + --perf-no_*_workqueue  encrypt inline instead of via
#                       kernel workqueues; stored in the header, so early
#                       boot inherits them
#   --allow-discards    otherwise fstrim.timer does nothing
echo
echo "    Set the LUKS passphrase. This is the RECOVERY credential: the TPM"
echo "    will unlock the disk day to day, but if firmware changes invalidate"
echo "    the TPM policy this passphrase is the only way back in."
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 256 --pbkdf argon2id \
    --sector-size 4096 --label archluks --iter-time 1000 "$ROOT_PART"
echo "    Unlocking it now:"
cryptsetup open --persistent --allow-discards \
    --perf-no_read_workqueue --perf-no_write_workqueue "$ROOT_PART" root
ROOT_DEV="/dev/mapper/root"
LUKS_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
if [ -z "$LUKS_UUID" ]; then
    echo "Could not read the LUKS UUID of $ROOT_PART. Aborting." >&2
    exit 1
fi

# -f overwrites any old signature.
# the matching mount options are kernel defaults and
# are deliberately not repeated in ROOT_MOUNT_OPTS. f2fs sits on top of
# dm-crypt, so compression happens before encryption.
mkfs.f2fs -f -i -O extra_attr,inode_checksum,sb_checksum,compression -l archroot "$ROOT_DEV"
udevadm settle
ROOT_FS_UUID="$(blkid -s UUID -o value "$ROOT_DEV")"
if [ -z "$ROOT_FS_UUID" ]; then
    echo "Could not read the filesystem UUID of $ROOT_DEV. Aborting." >&2
    exit 1
fi

echo "==> Step 3: Mounting"
mount -o "$ROOT_MOUNT_OPTS" "$ROOT_DEV" /mnt
# fmask/dmask keep the ESP root-only: it holds the UKI the firmware boots
# directly, and a world-readable/writable FAT mount would let any local user
# read it or swap in their own EFI binary for the firmware to run next boot.
mount --mkdir -o fmask=0077,dmask=0077 "$EFI_PART" /mnt/boot

echo "==> Step 4: Base install (pacstrap)"
# The OmniBook 3's "Wi-Fi 6 2x2 + BT 5.4" card is an RTL8852.
# e2fsprogs is only here for filefrag, which reads the swap file's physical
# offset for resume_offset=. dash has to land here, not in chroot-setup.sh's
# own package list further down: that script's shebang is #!/bin/dash, so
# dash must already exist in /mnt the moment arch-chroot execs it — one step
# too late to install it from inside the very script that needs it to start.
pacstrap -K /mnt base linux booster cryptsetup linux-firmware-amdgpu  linux-firmware-realtek linux-firmware-other amd-ucode f2fs-tools e2fsprogs micro dash

echo "==> Step 5: fstab + resolv.conf for network inside chroot"
genfstab -U /mnt >> /mnt/etc/fstab
cp /etc/resolv.conf /mnt/etc/resolv.conf

echo "==> Step 6: Writing the nftables zone-switching scripts"
TRUSTED_SSID_LITERAL=""
for ssid in "${TRUSTED_SSIDS[@]}"; do
    TRUSTED_SSID_LITERAL+="\"$ssid\" "
done

# wifi-zone-sync is the one place that maps "currently connected SSID" to
# the nftables trust zone. wifi-connect (below) calls it after a manual
# connect, and wifi-zone-monitor (written later, inside the chroot, once
# iwd's own service exists to watch) calls it whenever iwd changes network
# on its own — its AutoConnect, and a reconnect after suspend, are both iwd
# acting without ever going through wifi-connect, which is exactly why the
# zone used to get stuck on whatever network was trusted last.
cat <<'ZONESYNC_EOF' > /mnt/usr/local/bin/wifi-zone-sync
#!/bin/dash
set -eu

IFACE="__IFACE__"
# No arrays in dash: the trusted list becomes the positional parameters
# instead (this script takes no arguments of its own, so they are free).
# Each one arrives as its own quoted word from the sed substitution below,
# so an SSID with an embedded space (e.g. "Galaxy S23 4A5C") stays intact.
set -- __TRUSTED_NETWORKS__

# Same fallback as wifi-connect: the configured name is a guess made at
# install time.
if [ ! -d "/sys/class/net/$IFACE/wireless" ]; then
    for cand in /sys/class/net/*/wireless; do
        IFACE="$(basename "$(dirname "$cand")")"
        break
    done
    # Nothing wireless at all (e.g. a docked/wired-only boot) — nothing to
    # sync, and not an error.
    [ -d "/sys/class/net/$IFACE/wireless" ] || exit 0
fi

# Called as the desktop user (from wifi-connect) and as root (from
# wifi-zone-monitor.service). Escalate only when actually needed: root is
# not itself a member of :wheel, so 'doas' as root has no permit rule to
# match against and would just fail. $EUID is a bash-ism; 'id -u' is the
# portable read of it.
run_priv() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else doas "$@"; fi
}

# iwctl's tables draw ANSI colour; strip it before matching (same trick
# wifi-connect uses on get-networks). Two-or-more spaces is the column gap,
# not part of an SSID with a single embedded space (e.g. "Galaxy S23 4A5C"),
# so this survives those without misreading the value.
#
# '|| true': a transient failure here (iwd mid-restart, station busy) must
# fall through to the flush below as "not connected to anything trusted",
# not abort the script via set -e before that flush ever runs. (No
# pipefail in dash, so it is the final sed's own status being caught here —
# harmless, since a failed iwctl upstream leaves the whole pipe's output
# empty either way, landing on the same "not connected" fallback.)
connected_ssid="$(iwctl station "$IFACE" show 2>/dev/null \
    | sed -e 's/\x1b\[[0-9;]*m//g' \
    | sed -n 's/^[[:space:]]*Connected network[[:space:]]\{2,\}//p' \
    | sed -e 's/[[:space:]]\+$//')" || connected_ssid=""

# Drop to untrusted first: not connected, or connected to something not on
# the list, must never be left holding a previous network's trusted rules.
run_priv nft flush set inet filter trusted_tcp_ports
run_priv nft flush set inet filter trusted_udp_ports

if [ -n "$connected_ssid" ]; then
    for net in "$@"; do
        if [ "$connected_ssid" = "$net" ]; then
            echo "wifi-zone-sync: '$connected_ssid' is trusted — opening SSH (22/tcp) and mDNS (5353/udp)"
            run_priv nft add element inet filter trusted_tcp_ports '{ 22 }'
            run_priv nft add element inet filter trusted_udp_ports '{ 5353 }'
            break
        fi
    done
fi
ZONESYNC_EOF
sed -i "s|__IFACE__|${WIFI_IFACE}|" /mnt/usr/local/bin/wifi-zone-sync
sed -i "s|__TRUSTED_NETWORKS__|${TRUSTED_SSID_LITERAL}|" /mnt/usr/local/bin/wifi-zone-sync
chmod 755 /mnt/usr/local/bin/wifi-zone-sync

cat <<'WIFICONNECT_EOF' > /mnt/usr/local/bin/wifi-connect
#!/bin/dash
set -eu

if [ $# -lt 1 ]; then
    echo "usage: wifi-connect <SSID>" >&2
    exit 2
fi

SSID="$1"
IFACE="__IFACE__"

# The configured name is a guess made at install time; if it is wrong, take the
# first interface the kernel reports as wireless instead of failing obscurely.
if [ ! -d "/sys/class/net/$IFACE/wireless" ]; then
    for cand in /sys/class/net/*/wireless; do
        IFACE="$(basename "$(dirname "$cand")")"
        break
    done
    if [ ! -d "/sys/class/net/$IFACE/wireless" ]; then
        echo "No wireless interface found. 'ip link' to check, and 'lspci -nnk | grep -A3 -i net'" >&2
        echo "to confirm the right linux-firmware-* package is installed." >&2
        exit 1
    fi
    echo "note: using interface $IFACE"
fi

# iwd resolves 'connect' against what it has seen; a cold station fails with
# "Invalid network name", which only means "not scanned yet". Power up,
# scan, wait for the SSID.
doas iwctl device "$IFACE" set-property Powered on >/dev/null 2>&1 || true
doas iwctl device "$IFACE" set-property Mode station >/dev/null 2>&1 || true

seen_ssid() {
    # get-networks draws a table with ANSI colour; strip it before matching.
    iwctl station "$IFACE" get-networks 2>/dev/null \
        | sed -e 's/\x1b\[[0-9;]*m//g' \
        | grep -Fq -- "$SSID"
}

if ! seen_ssid; then
    echo "Scanning for '$SSID'..."
    doas iwctl station "$IFACE" scan >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        sleep 1
        seen_ssid && break
    done
fi

# Drop to untrusted first: if the connect below fails, wifi-zone-sync is
# never reached, so this is what stops the previous network's zone from
# being carried over rather than wifi-zone-sync's own flush.
doas nft flush set inet filter trusted_tcp_ports
doas nft flush set inet filter trusted_udp_ports

if seen_ssid; then
    iwctl station "$IFACE" connect "$SSID"
else
    # Not broadcast after a full scan: either hidden, or out of range. iwd needs
    # a different verb for hidden networks.
    echo "'$SSID' is not in the scan results — trying it as a hidden network."
    echo "If that is wrong, check the exact name (it is case sensitive) with:"
    echo "  iwctl station $IFACE get-networks"
    iwctl station "$IFACE" connect-hidden "$SSID"
fi

# Apply the zone for whatever iwd actually ended up connected to — not
# assumed to be $SSID verbatim — the same way autoconnect/resume would.
/usr/local/bin/wifi-zone-sync
WIFICONNECT_EOF
sed -i "s|__IFACE__|${WIFI_IFACE}|" /mnt/usr/local/bin/wifi-connect
chmod 755 /mnt/usr/local/bin/wifi-connect

echo "==> Step 7: Writing nftables base ruleset"
mkdir -p /mnt/etc
cat <<'NFT_EOF' > /mnt/etc/nftables.conf
#!/usr/bin/nft -f
# Reloadable: drop our own table first so `nft -f` is idempotent.
destroy table inet filter

table inet filter {
    set trusted_tcp_ports {
        type inet_service
        flags interval
    }

    set trusted_udp_ports {
        type inet_service
        flags interval
    }

    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        ip protocol icmp accept
        icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept

        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept

        tcp dport @trusted_tcp_ports accept
        udp dport @trusted_udp_ports accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFT_EOF
chmod 755 /mnt/etc/nftables.conf

echo "==> Step 8: Writing chroot setup script"
cat <<'CHROOT_EOF' > /mnt/root/chroot-setup.sh
#!/bin/dash
set -eu

echo "  -> Installing remaining packages"
# -Syu, never -Sy: a plain refresh here means a partial upgrade later.
# vulkan-tools is in the acceptance checklist (vulkaninfo confirms RADV);
# uwsm wraps Hyprland in systemd user units — see the OOM handling step for
# why that matters here. It does pull python + python-dbus + python-pyxdg,
# which is the one heavyweight dependency in this install; it is paid once at
# session start and never on an app launch, because runapp (AUR, installed
# further down) is what actually starts applications.
#
# cantarell-fonts is not for the desktop (that is Monaspace + Noto): it is the
# family the plymouth theme names in Font= / TitleFont=, and booster resolves
# that name with fc-match while building the initramfs. fc-match always
# answers with *something*, so without the package the LUKS passphrase prompt
# would quietly render in Noto instead of what the theme was drawn against.
pacman -Syu --noconfirm --needed \
    opendoas base-devel git tealdeer dash \
    cryptsetup sbctl systemd-ukify sbsigntools efibootmgr openssl tpm2-tss tpm2-tools \
    iwd nftables tlp plymouth \
    pipewire pipewire-pulse pipewire-alsa wireplumber sof-firmware alsa-ucm-conf alsa-utils \
    bluez bluez-utils \
    mesa vulkan-radeon vulkan-mesa-layers xdg-desktop-portal \
    hyprland uwsm ly xdg-desktop-portal-hyprland qt5-wayland qt6-wayland \
    hypridle hyprlock hyprpolkitagent hyprpaper hyprcursor \
    foot fuzzel yazi upower \
    cliphist wl-clipboard grim slurp brightnessctl playerctl pulsemixer \
    ffmpegthumbnailer 7zip jq poppler fd ripgrep fzf zoxide imagemagick \
    otf-monaspace-nerd noto-fonts noto-fonts-emoji cantarell-fonts \
    reflector pacman-contrib \
    vulkan-tools scx-scheds scx-tools


echo "  -> Locale, timezone, hostname"
sed -i "s/^#__LANG_LOCALE__ UTF-8/__LANG_LOCALE__ UTF-8/" /etc/locale.gen
sed -i "s/^#__REGIONAL_LOCALE__ UTF-8/__REGIONAL_LOCALE__ UTF-8/" /etc/locale.gen
locale-gen
cat > /etc/locale.conf <<LOCALE_EOF
LANG=__LANG_LOCALE__
LC_TIME=__REGIONAL_LOCALE__
LC_MONETARY=__REGIONAL_LOCALE__
LC_NUMERIC=__REGIONAL_LOCALE__
LC_MEASUREMENT=__REGIONAL_LOCALE__
LC_PAPER=__REGIONAL_LOCALE__
LC_NAME=__REGIONAL_LOCALE__
LC_ADDRESS=__REGIONAL_LOCALE__
LC_TELEPHONE=__REGIONAL_LOCALE__
LOCALE_EOF

# The LUKS prompt and rescue ttys use the console keymap, not the
# compositor's — leaving this out is the classic omission.
cat > /etc/vconsole.conf <<VCONSOLE_EOF
KEYMAP=__CONSOLE_KEYMAP__
VCONSOLE_EOF
ln -sf /usr/share/zoneinfo/__TIMEZONE__ /etc/localtime
hwclock --systohc
echo "__HOSTNAME__" > /etc/hostname
cat > /etc/hosts <<HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   __HOSTNAME__.localdomain __HOSTNAME__
HOSTS_EOF

echo "  -> Plymouth (boot splash, and the LUKS prompt's front end)"
# Written before the initramfs is built: booster copies plymouthd, its
# plugins, renderers, the configured theme and plymouthd.conf INTO the image
# (generator/plymouth.go), so the theme has to be decided here, not later.
# The daemon started in the initrd is the same one the real system attaches
# to after switch_root, so the passphrase prompt, the boot and the handover
# to ly are one uninterrupted screen.
#
# The theme is arch-slider-and-glow, copied onto the target by the outer
# script immediately before it exec'd this one (or 'bgrt' if that directory
# was missing — the outer script warns and substitutes the name in here).
# ModuleName=two-step, a core plymouth plugin, so nothing extra is needed to
# render it. It sets UseFirmwareBackground=false and draws its own 1366x768
# background, which two-step scales up to the FHD panel — so unlike the stock
# bgrt theme it REPLACES the HP firmware logo rather than continuing it. That
# is the trade for an Arch splash: expect a visible switch from the HP logo to
# this one at hand-off, not a seamless continuation.
#
# Theme= is the only thing that picks a theme, and writing it is the whole of
# what plymouth-set-default-theme does (the default.plymouth symlink it also
# deletes is legacy, and booster synthesises one when it is missing). Calling
# it here would buy nothing, and its -R flag would actively break the install:
# -R runs plymouth-update-initrd, which on Arch drives mkinitcpio, which this
# system does not have — booster builds the initramfs, via kernel-install.
#
# DeviceTimeout bounds the wait for a DRM device before it falls back to
# text; ShowDelay=0 because the whole point here is to be on screen before
# the passphrase prompt is.
mkdir -p /etc/plymouth
cat > /etc/plymouth/plymouthd.conf <<'PLYMOUTHD_EOF'
[Daemon]
Theme=__PLYMOUTH_THEME__
ShowDelay=0
DeviceTimeout=8
PLYMOUTHD_EOF

# plymouth resolves a missing or unreadable theme by falling back — first to
# plymouthd.defaults, then to 'text' — and says nothing about it. booster then
# bundles whatever that fallback was, and the first sign of trouble is a
# text-mode LUKS prompt on a machine that is already encrypted. Fail here.
THEME_FILE=/usr/share/plymouth/themes/__PLYMOUTH_THEME__/__PLYMOUTH_THEME__.plymouth
if [ ! -r "$THEME_FILE" ]; then
    echo "$THEME_FILE is missing or unreadable, so plymouth would quietly" >&2
    echo "fall back to the text theme and booster would bake that into the" >&2
    echo "initramfs. Check that the theme was copied onto the target." >&2
    exit 1
fi
# Same question asked the way booster asks it (generator/plymouth.go shells
# out to exactly this). Tolerated rather than fatal: the file check above is
# the substantive one, and this wrapper carries its own failure modes.
RESOLVED_THEME=$(plymouth-set-default-theme 2>/dev/null || true)
if [ "$RESOLVED_THEME" != "__PLYMOUTH_THEME__" ]; then
    echo "  !! plymouth-set-default-theme reports '$RESOLVED_THEME', not" >&2
    echo "     __PLYMOUTH_THEME__. The splash may not be the one you expect." >&2
fi

# gtk3 is an OPTIONAL dependency of plymouth, for a renderer that only draws
# into an X11 window (a developer aid). This build has no GTK, so
# renderers/x11.so ships with an unresolvable libgtk-3.so.0 — and booster
# copies the whole renderers directory, resolving each .so's libraries, so
# the initramfs build dies with "plymouth renderers: unable to find path to
# library libgtk-3.so.0" and no UKI is produced. Deleting the renderer is
# the fix that does not drag GTK in; the hook re-applies it, because pacman
# puts the file back on every plymouth upgrade and the UKI hook runs right
# after.
rm -f /usr/lib/plymouth/renderers/x11.so
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/60-plymouth-drop-x11-renderer.hook <<'PLYX11_EOF'
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = plymouth

[Action]
Description = Removing the plymouth X11 renderer (no GTK on this system)...
When = PostTransaction
Exec = /usr/bin/rm -f /usr/lib/plymouth/renderers/x11.so
PLYX11_EOF

echo "  -> Initramfs (booster) + signed Unified Kernel Image"
# booster builds host-specific images from the modules loaded on the *live*
# system, so the ones this machine needs are named explicitly. fsck +
# fsck.f2fs restore the root check, amdgpu is force-loaded for early KMS.
# 'vconsole: true' pulls /etc/vconsole.conf's keymap into the initrd —
# without it the LUKS prompt runs on the kernel's US layout. booster parses
# this file with plain yaml.Unmarshal, so a misspelled key is ignored.
# enable_plymouth requires exactly what is already here: the GPU driver in
# modules_force_load, plus 'quiet splash' on the cmdline below.
#
# Size matters here because the image is a section of a signed UKI on a
# 256 MiB FAT ESP, and an upgrade holds two of them. Measured on this
# kernel (7.2.x, amdgpu force-loaded, plymouth on): 71.6 MB unoptimised,
# 67.0 MB with strip, 53.7 MB with strip + zstd. amdgpu is 25 MB of module
# plus 28 MB of firmware that booster pulls from the module's own modinfo
# list, so that is the floor as long as plymouth needs the real GPU driver
# in the initrd. The plymouth theme adds ~1.2 MB on top and does not shrink —
# it is 150 PNGs, already deflated — which is under a tenth of the difference
# between lz4 and zstd, so it does not change any of the reasoning below.
#   strip: symbols out of the binaries, libraries and kernel modules —
#          nothing in an initramfs is ever debugged with them in place.
#   zstd:  13 MB smaller than lz4 and ~47 ms slower to decompress (49 ms
#          vs 96 ms here). The firmware, not the kernel, reads those 13 MB
#          out of FAT before anything is decompressed, so it is roughly a
#          wash in time and a clear win on the ESP budget.
cat > /etc/booster.yaml <<'BOOSTER_EOF'
compression: zstd
strip: true
modules: f2fs,nvme,amdgpu
modules_force_load: amdgpu
extra_files: fsck,fsck.f2fs
vconsole: true
enable_plymouth: true
BOOSTER_EOF

# One signed PE binary: a loose kernel + initrd pair lets an attacker edit
# the unsigned initramfs. The UKI seals kernel, initrd, microcode and cmdline.
mkdir -p /etc/kernel /etc/kernel/secureboot
systemd-machine-id-setup
# install.conf takes only BOOT_ROOT=, layout=, initrd_generator=,
# uki_generator=, entry_name_format=. The entry token is its own file.
cat > /etc/kernel/install.conf <<'KINSTALL_EOF'
layout=uki
initrd_generator=booster
uki_generator=ukify
KINSTALL_EOF
# Pinned so kernel-install does not fall back to /etc/machine-id, which is
# not meaningfully initialised in the chroot.
echo arch > /etc/kernel/entry-token

echo "  -> Hibernation swap file (activated only while hibernating)"
# zram cannot be hibernated to — its pages live in the RAM the image must
# save — so a real swap area still has to exist. It is NOT kept active: in
# normal operation zram is the only swap, and this file is switched on for
# the duration of a hibernate and off again after resume (the unit further
# down). Nothing is ever written here by ordinary reclaim, so the SSD sees
# no swap traffic and the whole file stays free for the image.
#
# 10 GiB against 16 GiB of RAM is a bet: image_size=0 clamps the image to the
# kernel's minimum, it is lz4-compressed, and page cache is dropped rather
# than saved — but it must still hold resident anon memory plus zram's pool,
# which does not compress again. A box full of incompressible anon memory
# fails the hibernate and stays awake. Raise SWAP_SIZE_MIB above RAM if that
# is not the trade you want.
#
# f2fs swap files must be pinned, in the order the kernel mandates
# (fs/f2fs/data.c: creat(), F2FS_IOC_SET_PIN_FILE, fallocate) so fallocate
# hands out one aligned, contiguous, uncompressed extent. Get it wrong and
# f2fs logs "Swapfile is not align to section" and swapon fails.
touch /swapfile
chmod 600 /swapfile
f2fs_io pinfile set /swapfile
# Explicit, even though the kernel refuses to swapon a compressed inode: the
# root fs runs with compress_extension=*, which matches an extensionless file.
f2fs_io setflags nocompression /swapfile
# Plain fallocate is what the kernel's own message recommends; f2fs_io's
# ioctl is the fallback if this f2fs build rejects it on a pinned inode.
fallocate -l __SWAP_SIZE_MIB__M /swapfile || f2fs_io fallocate 0 0 $((__SWAP_SIZE_MIB__ * 1048576)) /swapfile
mkswap /swapfile
# Proven, not assumed: activate it here so a pinning mistake surfaces now
# instead of at the first hibernate. genfstab ran before this file existed,
# so the entry is written by hand — noauto, because swap.target must not
# pull it in; hibernate-swapfile.service owns it.
RESUME_OFFSET=""
if swapon /swapfile; then
    swapoff /swapfile
    echo '/swapfile none swap noauto,pri=10,discard=once 0 0' >> /etc/fstab
    # resume_offset is the file's FIRST physical block in PAGE_SIZE units;
    # f2fs blocks are 4 KiB, so filefrag's value is used as-is. The file is
    # pinned, so GC never relocates it — but recreating it invalidates the
    # offset and needs a UKI re-sign.
    RESUME_OFFSET="$(filefrag -v /swapfile | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')"
    # POSIX has no =~; a case pattern is the portable "is this all digits".
    case "$RESUME_OFFSET" in
        ''|*[!0-9]*)
            echo "  !! could not read the swap file offset — hibernation not wired." >&2
            RESUME_OFFSET=""
            ;;
    esac
    # Not fatal, just honest: hibernation is best-effort below this line.
    MEM_TOTAL_MIB=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
    if [ __SWAP_SIZE_MIB__ -lt "$MEM_TOTAL_MIB" ]; then
        echo "    note: swap file is ${__SWAP_SIZE_MIB__} MiB and MemTotal is ${MEM_TOTAL_MIB} MiB."
        echo "          Hibernation fits the compressed minimum image, not a full RAM dump."
    fi
else
    echo "  !! swapon /swapfile failed — no fstab entry written." >&2
    echo "     Hibernation has nowhere to write its image." >&2
    echo "     Check 'dmesg | grep -i swapfile' for the f2fs alignment warning." >&2
fi


# Signed cmdline: every token costs a UKI re-sign to change, so the list is
# deliberately short.
#
# nowatchdog: drops the soft-lockup and NMI hard-lockup detectors. The latter
# is HARDLOCKUP_DETECTOR_PERF here, permanently holding one PMU counter per
# core, plus a per-CPU periodic wakeup on battery.
#
# preempt=lazy: PREEMPT_DYNAMIC=y with CONFIG_PREEMPT_LAZY unset boots
# "full", so this is a real change. Lazy keeps full preemption for RT/DL
# tasks but lets a preempted SCHED_OTHER task finish its slice — fewer
# context switches on compile bursts, without preempt=voluntary's latency.
#
#
# Deliberately NOT set (verified against Arch's config.x86_64):
#   amd_pstate=active   X86_AMD_PSTATE_DEFAULT_MODE=3 is already ACTIVE
#   tsc=nowatchdog      already auto-disabled on Zen 5
#   amdgpu.dcfeaturemask PSR is on by default for DCN >= 3.1; this is 3.5
#   iommu=pt            drops kernel DMA isolation for a few % of I/O
#   mitigations=off     security, not performance
#   amdgpu.abmlevel=N   locks panel power saving; the driver only lets
#                       userspace change it while it is -1/auto
#
# Hibernation: resume= names the same device as root=, so LUKS is opened
# first. booster writes major:minor to /sys/power/resume before mounting
# root, which is the required order; resume_offset= is consumed by the
# kernel's own __setup(). lz4 replaces the lzo default — resume time is
# dominated by decompression.
HIBERNATE_ARGS=""
if [ -n "$RESUME_OFFSET" ]; then
    HIBERNATE_ARGS=" resume=UUID=__ROOT_FS_UUID__ resume_offset=${RESUME_OFFSET} hibernate.compressor=lz4"
fi

# image_size=0 forces the image down to minimum_image_size(saveable) instead
# of the default 2/5 of RAM. Not "no image": the kernel still saves
# everything required, it just skips padding with freeable pages — which is
# what keeps it inside a 10 GiB file. sysfs, not /proc/sys, so tmpfiles.
cat > /etc/tmpfiles.d/hibernate-image-size.conf <<'IMGSIZE_EOF'
w /sys/power/image_size - - - - 0
IMGSIZE_EOF
cat > /etc/kernel/cmdline <<CMDLINE_EOF
rd.luks.uuid=__LUKS_UUID__ root=UUID=__ROOT_FS_UUID__ rootfstype=f2fs rootflags=__ROOT_MOUNT_OPTS__ rw quiet splash nowatchdog preempt=lazy zswap.enabled=0${HIBERNATE_ARGS}
CMDLINE_EOF

# Secure Boot keys plus the RSA pair that signs the PCR 11 policy. Signed,
# not pinned: ukify re-signs on every kernel build, so kernel updates never
# need TPM re-enrollment. The key paths are hardcoded in uki.conf below, so
# check them here rather than mid-build.
sbctl create-keys
for f in /var/lib/sbctl/keys/db/db.key /var/lib/sbctl/keys/db/db.pem; do
    if [ ! -f "$f" ]; then
        echo "  !! expected sbctl key $f is missing. Check 'ls -R /var/lib/sbctl/keys'" >&2
        echo "     and fix the paths in /etc/kernel/uki.conf before continuing." >&2
        exit 1
    fi
done
openssl genpkey -algorithm rsa -pkeyopt rsa_keygen_bits:2048 -out /etc/kernel/pcr-private.pem
openssl rsa -pubout -in /etc/kernel/pcr-private.pem -out /etc/kernel/pcr-public.pem
chmod 0600 /etc/kernel/pcr-private.pem
cat > /etc/kernel/uki.conf <<'UKICONF_EOF'
[UKI]
Microcode=/boot/amd-ucode.img
SecureBootSigningTool=systemd-sbsign
SignKernel=true
SecureBootPrivateKey=/var/lib/sbctl/keys/db/db.key
SecureBootCertificate=/var/lib/sbctl/keys/db/db.pem
PCRBanks=sha256

[PCRSignature:initrd]
PCRPrivateKey=/etc/kernel/pcr-private.pem
PCRPublicKey=/etc/kernel/pcr-public.pem
Phases=enter-initrd
UKICONF_EOF

# Arch does not drive kernel-install, and booster's own pacman hooks keep
# building/removing the loose (unsignable) image on every kernel change.
# Mask both; kernel-install (below and via the AUR hook further down) does
# the whole job — booster generator, then ukify signing — through the one
# path configured above.
#
# sbctl's own kernel-install plugin is masked for the same reason from the
# other direction: uki.conf already has ukify sign the UKI itself
# (SignKernel=true, SecureBootSigningTool=systemd-sbsign, against the sbctl
# keys) as part of the build, so sbctl's plugin re-signing the same file
# after the fact would be redundant at best and, since ukify already holds
# it open for writing, a race at worst.
#
# The pacman hook that rebuilds the signed UKI on every future kernel
# install/upgrade is not hand-rolled here: pacman-hook-kernel-install (AUR)
# provides it, and gets installed further down once paru exists to fetch it.
# The very first UKI, needed to boot at all, is still built directly below,
# in the Bootloader step — before paru exists and before any pacman hook
# could have fired for it.
mkdir -p /etc/pacman.d/hooks
ln -sfn /dev/null /etc/pacman.d/hooks/60-booster-remove.hook
ln -sfn /dev/null /etc/pacman.d/hooks/90-booster-install.hook
ln -sfn /dev/null /etc/kernel/install.d/91-sbctl.install

echo "  -> Root password"
echo "Set the root password:"
until passwd; do echo "  passwd failed — try again."; done

echo "  -> Creating user __USERNAME__"
useradd -m -G wheel -s /bin/bash __USERNAME__
echo "Set the password for __USERNAME__:"
until passwd __USERNAME__; do echo "  passwd failed — try again."; done

echo "  -> doas"
echo 'permit persist :wheel' > /etc/doas.conf
chmod 0400 /etc/doas.conf
mkdir -p /usr/local/bin
ln -sfn /usr/bin/doas /usr/local/bin/sudo

echo "  -> dash as /bin/sh"
ln -sfn /usr/bin/dash /usr/bin/sh
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/dash.hook <<'DASH_HOOK_EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = bash

[Action]
Description = Re-linking /usr/bin/sh to dash...
When = PostTransaction
Exec = /usr/bin/ln -sfn /usr/bin/dash /usr/bin/sh
Depends = dash
DASH_HOOK_EOF

echo "  -> Bootloader: none — the firmware boots the UKI directly"
# No systemd-boot, no loader.conf, no boot menu. A UKI is itself a valid
# PE/COFF EFI executable (systemd-stub) and ukify already signs it (uki.conf's
# SecureBootPrivateKey/Certificate above), so there is nothing left for a
# separate boot manager to do — one is one more unsigned binary (systemd-boot
# ships unsigned; sbctl would have to sign it too) and one more thing to keep
# patched for no benefit with a single kernel and no menu anyone needs.
#
# kernel-install names the UKI after the kernel version (so several can
# coexist for rollback), which means the exact filename changes on every
# kernel upgrade. With no boot manager to re-discover it, a one-time
# efibootmgr entry would go stale the moment that happens, so uki-bootentry
# below re-points the NVRAM entry at whatever is currently in
# /boot/EFI/Linux instead of naming one file once. It is run right after
# the build below, and again by its own pacman hook on every future kernel
# install/upgrade.
cat > /usr/local/bin/uki-bootentry <<'BOOTENTRY_EOF'
#!/bin/dash
# Point the "Arch Linux" UEFI boot entry at whatever UKI(s) kernel-install
# currently has in /boot/EFI/Linux. See the Bootloader step for why this
# needs re-running on every kernel change instead of being a one-shot.
set -eu

if [ "$(id -u)" -ne 0 ]; then echo "run as root (doas $0)" >&2; exit 1; fi

# No arrays, and no nullglob, in dash: loop the glob directly and skip an
# unexpanded match (nothing found) rather than array-ing the result first.
# uki_list is built purely for the summary echo at the end.
uki_count=0
uki_list=""
for uki in /boot/EFI/Linux/*.efi; do
    [ -e "$uki" ] || continue
    uki_count=$((uki_count + 1))
    uki_list="${uki_list:+$uki_list }$uki"
done
if [ "$uki_count" -eq 0 ]; then
    echo "no UKI in /boot/EFI/Linux — nothing to point the boot entry at" >&2
    exit 1
fi

# efibootmgr wants the ESP's disk and partition number as separate
# arguments. Read them back from whatever is actually mounted at /boot
# instead of assuming a disk name, so this keeps working even across a
# replaced drive or a clone to different hardware. 'expr' (POSIX, not a
# bashism) peels the trailing run of digits off as the partition number;
# nvme/mmcblk naming leaves a literal 'p' behind it (nvme0n1p1 -> nvme0n1p),
# which the case below strips too — plain disks (sda1 -> sda) have none to
# strip, so it is a no-op for them.
ESP_DEV="$(findmnt -no SOURCE /boot)"
if ! ESP_PART="$(expr "$ESP_DEV" : '.*[^0-9]\([0-9][0-9]*\)$')"; then
    echo "cannot parse ESP device '$ESP_DEV' into disk + partition number" >&2
    exit 1
fi
ESP_DISK="${ESP_DEV%"$ESP_PART"}"
case "$ESP_DISK" in
    *p) ESP_DISK="${ESP_DISK%p}" ;;
esac

# Drop any existing "Arch Linux" entries first — efibootmgr also drops a
# deleted entry from BootOrder for us — so a re-run (or the next kernel
# upgrade) never piles up stale ones. Piped into the read loop on purpose:
# nothing in it needs to survive past the loop, unlike rest_order below.
efibootmgr | awk '/Arch Linux/ {print substr($1,5,4)}' | while read -r bootnum; do
    efibootmgr -b "$bootnum" -B >/dev/null
done

# What is left of BootOrder at this point is everything NOT ours (a vendor
# recovery entry, say). efibootmgr already prints it as the exact comma list
# '-o' wants, so it is kept as plain text — no array to round-trip it
# through, and no pipe-into-a-loop to lose it to a subshell in.
rest_order="$(efibootmgr | awk -F': ' '/^BootOrder/ {print $2}')"

for uki in /boot/EFI/Linux/*.efi; do
    [ -e "$uki" ] || continue
    efibootmgr --create --disk "$ESP_DISK" --part "$ESP_PART" \
        --label "Arch Linux" --loader "\\EFI\\Linux\\$(basename "$uki")" >/dev/null
done
# Every "Arch Linux" entry left is one just created above (the stale ones
# were deleted before this loop, and nothing else names itself that).
new_order="$(efibootmgr | awk '/Arch Linux/ {print substr($1,5,4)}' | tr '\n' ',' | sed 's/,$//')"

# Ours first, so it is what the firmware boots by default; whatever else
# was already there stays reachable behind it rather than being dropped.
order="$new_order"
[ -n "$rest_order" ] && order="$order,$rest_order"
efibootmgr -o "$order" >/dev/null
echo "  -> $(efibootmgr | grep -c 'Arch Linux') UEFI boot entry/entries pointed at: $uki_list"
BOOTENTRY_EOF
chmod 755 /usr/local/bin/uki-bootentry

# 99-, deliberately later than pacman-hook-kernel-install's own hook (added
# further down, once paru can fetch it), so the new UKI already exists in
# /boot/EFI/Linux by the time this runs against the same trigger.
cat > /etc/pacman.d/hooks/99-uki-bootentry.hook <<'BOOTENTRYHOOK_EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Re-pointing the UEFI boot entry at the current UKI...
When = PostTransaction
Exec = /usr/local/bin/uki-bootentry
BOOTENTRYHOOK_EOF

# uname -r in a chroot is the live ISO's kernel, so add-all (which iterates
# /usr/lib/modules/* itself) is used instead of naming one version.
kernel-install add-all
# pacstrap's booster hook ran once before it was masked and dropped an
# unsigned vmlinuz + initramfs on the ESP. Nothing boots them (the UKI
# bundles its own), and 'sbctl verify' would report them unsigned forever.
rm -f /boot/booster-linux*.img /boot/vmlinuz-*

# Fail loudly here rather than at the first reboot: without a UKI on the ESP
# there is nothing for the firmware to boot.
uki_built_count=0
uki_built_list=""
for f in /boot/EFI/Linux/*.efi; do
    [ -e "$f" ] || continue
    uki_built_count=$((uki_built_count + 1))
    uki_built_list="${uki_built_list:+$uki_built_list }$f"
done
if [ "$uki_built_count" -eq 0 ]; then
    echo "  !! No UKI was produced in /boot/EFI/Linux — the system will NOT boot." >&2
    echo "     Re-run 'kernel-install add-all' and read its output before rebooting." >&2
    exit 1
fi
echo "  -> UKI(s): $uki_built_list"

echo "  -> Registering the UKI with the firmware (efibootmgr)"
/usr/local/bin/uki-bootentry

echo "  -> Network: bare iwd"
mkdir -p /etc/iwd
cat > /etc/iwd/main.conf <<'IWD_EOF'
[General]
EnableNetworkConfiguration=true
# Cafe hygiene: without this the card presents its permanent, globally unique
# MAC to every network it ever touches, which is a stable identifier any
# venue's AP (or anyone listening) can log across visits.
#
# 'network', not 'once': the address is derived from the SSID plus the
# permanent MAC, so it is random per-network but STABLE for a given network.
# That keeps captive-portal sessions and any "remember this device" state
# working on a return visit, which 'once' (re-randomised on every iwd start)
# would break.
AddressRandomization=network

[Network]
NameResolvingService=systemd
IWD_EOF
systemctl enable iwd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd

echo "  -> Re-syncing the nftables trust zone when iwd changes network on its own"
# wifi-connect (Step 6, outer script) is the only thing that has ever called
# wifi-zone-sync so far — which means iwd's own AutoConnect to a known
# network, and a reconnect after suspend, never touched the zone at all: the
# laptop could wake in a cafe still trusting whatever network it had at
# home. Both of those are, from iwd's point of view, just the Station
# reaching the "connected" state on its own; this watches for exactly that
# instead of trying to special-case autoconnect vs. resume separately.
cat > /usr/local/bin/wifi-zone-monitor <<'ZONEMON_EOF'
#!/bin/dash
# Long-running. Restarted by systemd (Restart=always) if busctl's connection
# ever drops, e.g. iwd itself restarting — After=/PartOf=iwd.service below
# also restarts this unit whenever that happens.
set -u

# Covers whatever iwd is already connected to by the time this starts
# (a fresh boot that autoconnected before this unit came up).
/usr/local/bin/wifi-zone-sync || true

# net.connman.iwd is iwd's D-Bus name (a holdover from its ConnMan-integration
# origins, kept standalone). PropertiesChanged is what Station emits on
# State/ConnectedNetwork changes — connect, disconnect, roam — and iwd does
# not emit it continuously, so re-syncing on every occurrence is cheap.
# Matched broadly (not narrowed to one object path or property) because the
# cost of a spurious re-sync is one idempotent nft flush+maybe-add, and that
# is far cheaper than hand-parsing which property changed out of the signal
# payload.
busctl monitor --json=short net.connman.iwd 2>/dev/null | while read -r line; do
    # '<<<' is a bash-ism; a pipe does the same job in dash.
    member="$(printf '%s\n' "$line" | jq -r '.member // empty' 2>/dev/null || true)"
    if [ "$member" = "PropertiesChanged" ]; then
        /usr/local/bin/wifi-zone-sync || true
    fi
done
ZONEMON_EOF
chmod 755 /usr/local/bin/wifi-zone-monitor
cat > /etc/systemd/system/wifi-zone-monitor.service <<'ZONEMONUNIT_EOF'
[Unit]
Description=Re-sync the nftables trust zone with whatever iwd is actually connected to
After=iwd.service
PartOf=iwd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wifi-zone-monitor
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
ZONEMONUNIT_EOF
systemctl enable wifi-zone-monitor.service

echo "  -> Firewall"
systemctl enable nftables

echo "  -> Power management"
mkdir -p /etc/tlp.d
cat > /etc/tlp.d/01-wifi.conf <<'TLP_EOF'
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on
TLP_EOF
cat > /etc/tlp.d/02-cpu.conf <<'TLP_CPU_EOF'
# amd_pstate EPP: the biggest idle/light-load win on Zen 5 mobile. Boost
# stays on on battery: a compile that finishes sooner idles sooner.
CPU_DRIVER_OPMODE_ON_AC=active
CPU_DRIVER_OPMODE_ON_BAT=active
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=1
PLATFORM_PROFILE_ON_AC=balanced
PLATFORM_PROFILE_ON_BAT=low-power
TLP_CPU_EOF
cat > /etc/tlp.d/03-runtimepm.conf <<'TLP_PM_EOF'
RUNTIME_PM_ON_AC=auto
RUNTIME_PM_ON_BAT=auto
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave
# NVMe APST is handled by the kernel; do not let TLP disable it.
USB_AUTOSUSPEND=1
TLP_PM_EOF
systemctl enable tlp
systemctl mask systemd-rfkill.service systemd-rfkill.socket 2>/dev/null || true
systemctl mask power-profiles-daemon.service 2>/dev/null || true

echo "  -> Sleep: suspend-then-hibernate"
# s2idle only (no S3 on current AMD laptops) costs 1-2 %/h on a 41 Wh
# battery. HibernateDelaySec=45min suspends first so a short break resumes
# instantly; HibernateOnACPower=no keeps a plugged-in session suspended.
mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/10-hibernate.conf <<'SLEEP_EOF'
[Sleep]
HibernateDelaySec=45min
HibernateOnACPower=no
SLEEP_EOF

# Closing the lid is the common case and needs saying separately: logind's
# default action is a plain suspend, which never consults HibernateDelaySec.
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-lid.conf <<'LOGIND_EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
HandleLidSwitchDocked=ignore
LOGIND_EOF

# The swap file is off in normal operation, so it has to be switched on
# around a hibernate. A /usr/lib/systemd/system-sleep hook is too late:
# systemd-sleep calls find_suitable_hibernation_device() — which reads
# /proc/swaps — BEFORE it runs those hooks (src/sleep/sleep.c, execute()).
# So this is a unit ordered ahead of the sleep services instead.
#
# StopWhenUnneeded is what switches it back off: once the hibernate service
# has finished (i.e. after resume) nothing wants this unit any more, and the
# stop job is ordered after it because of the Before= above.
cat > /etc/systemd/system/hibernate-swapfile.service <<'HIBSWAP_EOF'
[Unit]
Description=Activate /swapfile for the duration of a hibernate
ConditionPathExists=/swapfile
Before=systemd-hibernate.service systemd-suspend-then-hibernate.service
StopWhenUnneeded=yes

[Service]
Type=oneshot
# Load-bearing: without it the oneshot goes inactive the moment swapon
# returns, and ExecStop would swapoff again before the hibernate ever starts.
RemainAfterExit=yes
# Options (pri=10,discard=once) come from the noauto fstab entry. Nothing
# here depends on them: pri only has to stay under zram's 100, and the resume
# side is pinned by resume=/resume_offset= on the kernel cmdline, not by
# priority. Confirm with 'swapon --show' after the first hibernate if curious.
ExecStart=/usr/bin/swapon /swapfile
# swapoff has to fault back anything the kernel put there; '-' so a failure
# leaves the file active rather than blocking the resume path.
ExecStop=-/usr/bin/swapoff /swapfile

[Install]
WantedBy=systemd-hibernate.service systemd-suspend-then-hibernate.service
HIBSWAP_EOF
systemctl enable hibernate-swapfile.service

# logind refuses the D-Bus call before any of that runs: it asks
# hibernation_is_safe(), which returns -ENOSPC when /proc/swaps holds no
# usable device (zram is skipped for hibernation by design). This env var is
# the documented escape hatch for exactly this setup — swap that only exists
# once hibernation has already started. It also drops logind's "is the image
# going to fit" estimate, which is the same bet SWAP_SIZE_MIB already makes;
# systemd-sleep still fails cleanly, and the machine stays awake, if it does
# not fit.
mkdir -p /etc/systemd/system/systemd-logind.service.d
cat > /etc/systemd/system/systemd-logind.service.d/10-hibernate-swapfile.conf <<'LOGIND_ENV_EOF'
[Service]
Environment=SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1
LOGIND_ENV_EOF

echo "  -> zram: primary swap, lz4 with zstd level 9 recompression"
# zram is a compressed block device in RAM used as the primary swap device:
# reclaimed anon pages are compressed and stay resident instead of going
# through dm-crypt to the SSD. No zram-generator — the setup is a handful of
# sysfs writes, and the generator cannot set a secondary algorithm's level
# anyway (it writes those parameters to .../recompress, the trigger, not to
# .../algorithm_params).
#
# The order below is forced by the kernel (drivers/block/zram/zram_drv.c):
# an algorithm write resets that priority's parameters, and algorithm_params
# returns -EBUSY once disksize is set. Algorithm, parameters, then disksize.
#
# Half of RAM, uncompressed: ~8 GiB of swap area for ~3 GiB of real memory
# at lz4's usual ratio. Not larger — everything zram holds is anon memory
# the 10 GiB hibernation image must also carry, already compressed.
cat > /usr/local/bin/zram-swap <<'ZRAMSWAP_EOF'
#!/bin/dash
# zram-swap start|stop — driven by zram-swap.service.
set -e
dev=/sys/block/zram0
case "$1" in
start)
    modprobe zram num_devices=1
    echo lz4 > "$dev/comp_algorithm"
    echo "algo=zstd priority=1" > "$dev/recomp_algorithm"
    echo "priority=1 level=9" > "$dev/algorithm_params"
    echo "$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 2 ))K" > "$dev/disksize"
    mkswap -U clear /dev/zram0 >/dev/null
    # pri=100: above the hibernation file's 10, for the minutes it is active.
    swapon --priority 100 --discard /dev/zram0
    ;;
stop)
    swapoff /dev/zram0 || true
    echo 1 > "$dev/reset"
    ;;
esac
ZRAMSWAP_EOF
chmod 755 /usr/local/bin/zram-swap

cat > /etc/systemd/system/zram-swap.service <<'ZRAMUNIT_EOF'
[Unit]
Description=zram swap device (lz4, zstd level 9 recompression)
# DefaultDependencies=no is load-bearing: the implicit After=sysinit.target
# plus Before=swap.target is an ordering cycle (sysinit.target is itself
# After=swap.target), which systemd resolves by dropping an edge at random.
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/zram-swap start
ExecStop=/usr/local/bin/zram-swap stop

[Install]
WantedBy=swap.target
ZRAMUNIT_EOF
systemctl enable zram-swap.service

# zram only ever compresses with the primary algorithm; the secondary runs
# when userspace asks for it (zram_drv.c recompress_store). This timer asks.
cat > /etc/systemd/system/zram-recompress.service <<'ZRAMRECOMP_EOF'
[Unit]
Description=Recompress idle zram pages with the secondary algorithm
After=zram-swap.service

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
# Skip cleanly instead of failing when the device is not initialised.
ExecCondition=/usr/bin/grep -qx 1 /sys/block/zram0/initstate
# Candidates: slots untouched for 15 minutes, compressed to 1 KiB or more
# (below that zstd has nothing left to win). Incompressible pages are stored
# whole, so they always qualify — they are what this is for.
ExecStart=/usr/bin/sh -c 'echo 900 > /sys/block/zram0/idle'
ExecStart=/usr/bin/sh -c 'echo "type=idle threshold=1024 priority=1" > /sys/block/zram0/recompress'
# Compaction is what returns the freed zspage space.
ExecStart=/usr/bin/sh -c 'echo 1 > /sys/block/zram0/compact'
ZRAMRECOMP_EOF

cat > /etc/systemd/system/zram-recompress.timer <<'ZRAMTIMER_EOF'
[Unit]
Description=Periodic idle-page recompression for zram

[Timer]
OnBootSec=15min
OnUnitActiveSec=15min
AccuracySec=2min

[Install]
WantedBy=timers.target
ZRAMTIMER_EOF
systemctl enable zram-recompress.timer

# Swap reads come out of RAM, not the SSD, so the disk-swap defaults are
# wrong: swap early, one page at a time, and give kswapd headroom.
#   swappiness 180  evicting anon = an lz4 compression into RAM; evicting a
#                   file page = re-reading it through dm-crypt later
#   page-cluster 0  swap-in readahead has no seek to amortise on zram
#   watermark_scale_factor 250 (0.1% -> 2.5%): keeps the compression work
#                   in kswapd instead of direct reclaim, where the
#                   allocating task stalls for it
#   watermark_boost_factor 10: boosting reclaims extra for compaction after
#                   a fragmentation event. Kept small, not zero — with no
#                   disk swap under zram there is no cheap store to absorb it
cat > /etc/sysctl.d/99-swap.conf <<'SYSCTL_EOF'
vm.swappiness = 180
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.dirty_expire_centisecs = 12000
vm.dirty_writeback_centisecs = 12000
vm.watermark_boost_factor = 10
vm.watermark_scale_factor = 250
vm.min_free_kbytes = 134217
SYSCTL_EOF


echo "  -> Network sysctls"

cat > /etc/sysctl.d/90-net-local.conf <<'NETCTL_EOF'
net.ipv4.tcp_rmem = 4096 131072 16777216
net.core.rmem_max = 6291456

# PMTU black-hole recovery: captive portals, PPPoE, VPN/WireGuard overhead.
# Kernel default is 0 (disabled); 1 = enable only once a black hole is detected.
net.ipv4.tcp_mtu_probing = 1

# Don't collapse cwnd after an idle RTO - helps long-lived HTTP/2, SSH, mosh.
# Kernel default is 1 (enabled).
net.ipv4.tcp_slow_start_after_idle = 0

# Cap unsent bytes in the write queue: lower latency for interactive/upload-heavy
# apps (video calls, screen sharing). 128 KiB is Google's recommended value.
net.ipv4.tcp_notsent_lowat = 131072

# IPv6 privacy extensions: kernel default is 0 = OFF for most devices.
# 2 = enable and *prefer* temporary addresses.
net.ipv6.conf.all.use_tempaddr = 2
net.ipv6.conf.default.use_tempaddr = 2

# Hostile-LAN hygiene (cafe). Redirect acceptance defaults to on for hosts.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
NETCTL_EOF

echo "  -> OOM handling (systemd-oomd)"
# With the swap file inactive, zram is the only swap there is: once its
# ~8 GiB of area is full, reclaim has nowhere left to put an anon page and
# the machine wedges without any allocation failing, so the in-kernel OOM
# killer never runs. The trigger has to be *stall*, which is what PSI
# measures and what systemd-oomd consumes. Arch has CONFIG_PSI=y with
# PSI_DEFAULT_DISABLED unset, so no psi=1 token and no UKI re-sign.
#
# oomd kills a CGROUP, so the session has to be laid out in cgroups that are
# worth killing. That is the whole reason uwsm is here: it starts the
# compositor as wayland-wm@hyprland.service in session.slice, ships the
# nested app-graphical/background-graphical/session-graphical slices, and
# exports the session environment into the systemd user manager so units
# started later can actually find the Wayland socket. runapp (AUR) then puts
# each application into app-graphical.slice as its own transient
# app-Hyprland-<name>@<hash>.service. Nothing shares one session-N.scope any
# more.
#
# Only app.slice is monitored, and app-graphical.slice nests inside it by
# systemd's dash-naming rule, so this one drop-in covers every runapp-launched
# app plus anything the XDG autostart generator emits. Only leaf cgroups below
# a monitored unit are candidates, and everything that must survive an OOM
# event is structurally somewhere else — no protection list to maintain:
#   compositor          session.slice/wayland-wm@hyprland.service
#   hyprpolkitagent     session.slice              (upstream unit sets it)
#   hyprpaper           session.slice              (upstream unit sets it)
#   ashell              session-graphical.slice    (drop-in, below)
#   hypridle, cliphist  background-graphical.slice (drop-ins, below)
#   hyprlock            session-graphical.slice    (runapp -i, hyprland.lua)
# -.slice is deliberately not monitored even though the man page suggests it
# for swap: its candidates would include the compositor, and
# ManagedOOMPreference= xattrs are ignored when the monitored ancestor is
# root-owned and the candidate is not.
#
# A user-level drop-in suffices: the user manager reports its monitored
# cgroups to oomd over varlink. The Wants=systemd-oomd.service systemd
# injects alongside OOMRules= names a system unit the user manager does not
# have; that is harmless and logged at debug only.
#
# .oomrule files (systemd 261), not the older ManagedOOMMemoryPressure=/
# ManagedOOMSwap= pair: that pair fires on "memory used" AND "swap used" over
# one global SwapUsedLimit=, with no duration, and "memory used" is a crude
# denominator on a box with a large page cache. A ruleset ANDs
# MemoryPressureAbove= with SwapUsageMax= and has a per-rule LastingSec=.
# Kill selection is the same code either way.
#
# No oomd.conf.d drop-in: SwapUsedLimit= and DefaultMemoryPressure* only feed
# the ManagedOOM* path, which nothing here uses.
mkdir -p /etc/systemd/oomd/rules.d

# Ruleset name = file name minus .oomrule, and that is what OOMRules=
# references, so no numeric prefix.
cat > /etc/systemd/oomd/rules.d/app-stall.oomrule <<'OOMRULE_STALL_EOF'
[Rule]
# PSI "full" avg10 of app.slice: every task in it stalled on memory for half of
# the last 10 seconds. Held for 20s, which rides out a Godot import or a link
# step and still acts long before the desktop is unusable.
MemoryPressureAbove=50%
LastingSec=20s
# Kills the descendant leaf cgroup with the highest recent page-scan rate,
# i.e. the app service actually driving reclaim.
Action=kill-by-pgscan
OOMRULE_STALL_EOF

cat > /etc/systemd/oomd/rules.d/swap-exhaustion.oomrule <<'OOMRULE_WALL_EOF'
[Rule]
# SwapUsageMax is a percentage of SwapTotal, and SwapTotal is zram alone
# (the swap file is only active during a hibernate). 80% of the compressed
# device means reclaim is nearly out of room; the pressure term separates
# that from a well-filled zram on an idle machine. 5s, faster than
# app-stall, because this state only gets worse.
MemoryPressureAbove=20%
SwapUsageMax=80%
LastingSec=5s
# Kills the descendant leaf cgroup holding the most swap, i.e. whatever
# filled it.
Action=kill-by-swap
OOMRULE_WALL_EOF

mkdir -p /etc/systemd/user/app.slice.d
cat > /etc/systemd/user/app.slice.d/10-oomd.conf <<'OOMD_APP_EOF'
[Slice]
# Explicit rather than trusting DefaultMemoryAccounting=yes: oomd skips any
# cgroup without memory accounting.
MemoryAccounting=yes
OOMRules=app-stall swap-exhaustion
OOMD_APP_EOF
systemctl enable systemd-oomd.service

echo "  -> Session daemons as systemd user units (uwsm's graphical slices)"
# Under uwsm the compositor no longer needs to fork these itself, and it
# should not: as units they get Restart=on-failure, ordering against
# graphical-session.target, a Slice= of their own, and `systemctl --user
# status` — none of which a forked child has. Every one of them ships a unit
# with [Install] WantedBy=graphical-session.target, and uwsm is what activates
# that target. --global, not --user: there is no user manager to talk to
# inside the chroot, so the .wants symlinks go into /etc/systemd/user/.
# ashell is AUR and is enabled further down, in its own install branch.
systemctl --global enable hyprpaper.service hypridle.service \
    hyprpolkitagent.service cliphist.service

# hyprpaper and hyprpolkitagent already pin themselves to session.slice
# upstream. hypridle and cliphist do not, so they would default into
# app.slice and become OOM candidates — which is backwards, since losing
# either costs more than it frees and neither is ever what ballooned.
for unit in hypridle cliphist; do
    mkdir -p "/etc/systemd/user/${unit}.service.d"
    cat > "/etc/systemd/user/${unit}.service.d/10-slice.conf" <<'OOMD_BG_EOF'
[Service]
# background-graphical.slice nests under background.slice, not app.slice,
# so the OOMRules= above cannot reach it.
Slice=background-graphical.slice
OOMD_BG_EOF
done

# ashell is AUR, installed further down and possibly not at all, but its
# drop-in is written here unconditionally so a later `paru -S ashell` lands in
# the right slice without anyone having to remember this. Its unit sets no
# Slice= either, and the bar carries the notification daemon with it, so an
# OOM kill would take both. session-graphical.slice rather than background:
# it is session UI, the same tier as the compositor and the polkit agent.
mkdir -p /etc/systemd/user/ashell.service.d
cat > /etc/systemd/user/ashell.service.d/10-slice.conf <<'OOMD_ASHELL_EOF'
[Service]
Slice=session-graphical.slice
OOMD_ASHELL_EOF

echo "  -> Panel power saving (amdgpu ABM) on battery only"
# The 300-nit eDP panel is the largest consumer on this machine. amdgpu
# exposes ABM per eDP connector as .../amdgpu/panel_power_savings (0-4,
# larger = dimmer and less colour-accurate). Not amdgpu.abmlevel=: that locks
# the level for the whole boot, and the driver only accepts userspace writes
# while it is left at -1/auto.
cat > /usr/local/bin/panel-power-savings <<'PPS_EOF'
#!/bin/dash
# panel-power-savings [0-4|auto]
# auto: LEVEL_ON_BAT while discharging, 0 on AC.
# Colour accuracy matters for art work, so AC is always level 0. Drop
# LEVEL_ON_BAT to 1 if the shift bothers you on battery too, 0 to disable.
set -u
LEVEL_ON_BAT=2

level="${1:-auto}"
if [ "$level" = auto ]; then
    level="$LEVEL_ON_BAT"
    # No nullglob in dash: skip an unexpanded glob (nothing matched) directly
    # rather than trying to read it as a file.
    for ac in /sys/class/power_supply/*/type; do
        [ -e "$ac" ] || continue
        # '$(< file)' is a bash-only shortcut for '$(cat file)'.
        [ "$(cat "$ac")" = Mains ] || continue
        [ "$(cat "${ac%/type}/online")" = 1 ] && level=0
    done
fi

for f in /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings; do
    [ -e "$f" ] || continue
    # Writing this file forces a modeset, so never write the same value twice.
    [ "$(cat "$f")" = "$level" ] && continue
    echo "$level" > "$f" || true
done
PPS_EOF
chmod 755 /usr/local/bin/panel-power-savings

cat > /etc/udev/rules.d/95-panel-power-savings.rules <<'PPS_UDEV_EOF'
ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="/usr/local/bin/panel-power-savings auto"
PPS_UDEV_EOF

# udev only sees plug/unplug transitions, so the initial state is applied once
# at boot. The eDP connector exists as soon as amdgpu has modeset, which is
# well before multi-user.target.
cat > /etc/systemd/system/panel-power-savings.service <<'PPS_UNIT_EOF'
[Unit]
Description=Apply amdgpu panel power saving for the current power source
# NOT After=multi-user.target: with the WantedBy= below that is an ordering
# cycle, and systemd breaks it by dropping an edge of its own choosing.
# The eDP connector exists once amdgpu has probed, which the initramfs
# already forced.
After=systemd-udev-trigger.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/panel-power-savings auto

[Install]
WantedBy=multi-user.target
PPS_UNIT_EOF
systemctl enable panel-power-savings.service

# Bluetooth is installed but NOT enabled: an idle controller is a constant
# small draw and a wakeup source. Start it when you need it:
#   doas systemctl start bluetooth

echo "  -> Login manager"
# ly 1.x ships ONLY templated units (ly@.service, ly-kmsconvt@.service) — there
# is no plain ly.service to enable. The instance name is the tty it owns.
systemctl enable ly@tty2.service
# ly draws on a tty, plymouth owns the display until it quits. Without this
# ordering the two race and you get a flash of console or a dead splash
# holding the screen over the greeter. plymouth-quit-wait.service is pulled
# in by the package itself (multi-user.target.wants), so only the edge is
# missing.
mkdir -p /etc/systemd/system/ly@tty2.service.d
cat > /etc/systemd/system/ly@tty2.service.d/10-plymouth.conf <<'LY_PLY_EOF'
[Unit]
After=plymouth-quit-wait.service
LY_PLY_EOF

# The hyprland package ships TWO session entries: hyprland.desktop (bare) and
# hyprland-uwsm.desktop ("Hyprland (uwsm-managed)"). Picking the bare one
# gives a session where the systemd user manager never learns WAYLAND_DISPLAY,
# so runapp starts units that immediately fail and oomd has nothing to watch —
# a confusing half-broken desktop, one keypress away, every login. ly has no
# filter, so point it at a directory holding only the entry we want.
#
# A symlink, not a copy: the entry then keeps tracking whatever the hyprland
# package ships, including a future change to its Exec= line.
mkdir -p /etc/ly/wayland-sessions
ln -sfn /usr/share/wayland-sessions/hyprland-uwsm.desktop \
    /etc/ly/wayland-sessions/hyprland-uwsm.desktop
# sed, not a rewritten file: /etc/ly/config.ini is a packaged config with
# ~80 documented keys, and these are plain uncommented `key = value` lines.
# xsessions/xinitrc go to null because nothing X11 is installed and an entry
# that cannot work is just another wrong thing to select. `shell = true` is
# left alone on purpose — it is the way back in if Hyprland ever fails to
# start. `save = true` (ly's default) then remembers the choice.
sed -i \
    -e 's|^waylandsessions = .*|waylandsessions = /etc/ly/wayland-sessions|' \
    -e 's|^xsessions = .*|xsessions = null|' \
    -e 's|^xinitrc = .*|xinitrc = null|' \
    /etc/ly/config.ini
# A sed that matches nothing is silent, and the failure mode here is a greeter
# that quietly goes on offering the bare Hyprland entry. Check, don't assume.
grep -q '^waylandsessions = /etc/ly/wayland-sessions$' /etc/ly/config.ini || {
    echo "  !! ly's config.ini did not take the session-list edit. Set"
    echo "     'waylandsessions = /etc/ly/wayland-sessions' in /etc/ly/config.ini"
    echo "     by hand, or the greeter will also offer the non-uwsm session."
}

echo "  -> CPU scheduler (scx_lavd via scx_loader)"
# scx_loader.service lives in scx-tools, NOT scx-scheds (which is just the
# scheduler binaries — both are pulled in above). scxctl is the CLI that
# talks to it over D-Bus for runtime switching.
#
# scx_lavd (Latency-criticality Aware Virtual Deadline) is gaming-motivated:
# it tracks how latency-critical each task is and prioritises accordingly,
# which is the profile this machine wants — Godot play-testing alongside a
# browser and an editor, not a compile farm. It also builds a separate
# scheduling domain per-CCX/per-core-type, so it stays correct if a future
# machine swaps in a big.LITTLE or multi-CCD chip; on this single-CCX Zen 5
# mobile part that just costs nothing.
#
# default_sched picks what scx_loader starts on boot; config.toml is checked
# BEFORE the built-in default (which starts no scheduler at all), so this is
# the one line that matters. default_mode is left unset — "Auto" is already
# the built-in default, and Auto's built-in flags for scx_lavd are
# --autopilot, not --autopower: autopilot decides core compaction from
# system load, autopower instead reads a power-profiles-daemon session over
# D-Bus, which this install does not run (TLP manages power here instead).
# Switch modes by hand for a play-testing session:
#   scxctl switch -m gaming        # scx_lavd's --performance, no compaction
#   scxctl switch -m auto          # back to --autopilot
mkdir -p /etc/scx_loader
cat > /etc/scx_loader/config.toml <<'SCXLOADER_EOF'
default_sched = "scx_lavd"
SCXLOADER_EOF
systemctl enable scx_loader.service

echo "  -> Maintenance"
# The shipped reflector.conf is an ARGUMENT list, not key=value, and ships
# commented out — the usual `sed s/^Country = .*/` matches nothing and the
# timer then runs unfiltered. Write the file, don't patch it.
mkdir -p /etc/xdg/reflector
cat > /etc/xdg/reflector/reflector.conf <<REFLECTOR_EOF
--save /etc/pacman.d/mirrorlist
--protocol https
--country __REFLECTOR_COUNTRIES__
--latest 10
--sort rate
REFLECTOR_EOF
reflector --country __REFLECTOR_COUNTRIES__ --protocol https --latest 10 --sort rate \
    --save /etc/pacman.d/mirrorlist \
    || echo "reflector failed — check network, you can re-run it after first boot"
systemctl enable reflector.timer
systemctl enable paccache.timer
systemctl enable fstrim.timer

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-size.conf <<'JOURNALD_EOF'
[Journal]
SystemMaxUse=200M
JOURNALD_EOF

echo "  -> makepkg: escalate through doas, not the sudo shim"
# makepkg calls PACMAN_AUTH for build deps. Unset, it looks for sudo, and the
# /usr/local/bin/sudo -> doas symlink is not faithful enough (sudo-style
# flags doas rejects). No -n, or interactive `makepkg -si` breaks later.
mkdir -p /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/10-doas.conf <<'MAKEPKG_DOAS_EOF'
PACMAN_AUTH=(doas)
MAKEPKG_DOAS_EOF

echo "  -> Building paru from the AUR (AUR helper)"
# paru is itself AUR-only, so it needs one bootstrap build via makepkg like
# any other AUR package. makepkg refuses to run as root and escalates through
# PACMAN_AUTH (doas, set above) to install build deps, so the policy is
# relaxed to nopass for the duration of the build only. pacman-hook-kernel-install,
# runapp, ashell, zen-browser-bin and xdg-desktop-portal-termfilechooser are
# installed right after, through paru, so all five go out under the same
# relaxed window. The cursor theme further
# down is not an AUR package, so it is fetched after doas is locked back down.
echo 'permit nopass :wheel' > /etc/doas.conf
if runuser -l __USERNAME__ -c '
    set -euo pipefail
    build=$(mktemp -d)
    trap "rm -rf \"$build\"" EXIT
    git clone --depth=1 https://aur.archlinux.org/paru.git "$build/paru"
    cd "$build/paru"
    makepkg -si --noconfirm --needed
'; then
    echo "  -> paru installed"

    echo "  -> Installing pacman-hook-kernel-install via paru (rebuilds the signed"
    echo "     UKI automatically on every future kernel install/upgrade)"
    if runuser -l __USERNAME__ -c 'paru -S --noconfirm --needed pacman-hook-kernel-install'; then
        echo "  -> pacman-hook-kernel-install installed"
    else
        echo "  !! pacman-hook-kernel-install install FAILED. Future kernel upgrades"
        echo "     will NOT rebuild the UKI on their own — run 'doas kernel-install"
        echo "     add-all' by hand after each one, or install it later with:"
        echo "       paru -S pacman-hook-kernel-install"
    fi

    echo "  -> Installing runapp via paru (launches apps into app-graphical.slice)"
    # This sits on the hot path of every application launch, which is why it
    # is runapp and not `uwsm app`: same job, same default slice, but a small
    # C++ binary against systemd's private socket instead of a Python start-up
    # per launch — and no daemon to keep alive the way `uwsm-app` needs.
    if runuser -l __USERNAME__ -c 'paru -S --noconfirm --needed runapp'; then
        echo "  -> runapp installed"
    else
        echo "  !! runapp install FAILED. fuzzel's launch-prefix and the SUPER"
        echo "     binds reference it, so applications will NOT start until it is"
        echo "     there. Install it before relying on the desktop:"
        echo "       paru -S runapp"
        echo "     Until then 'uwsm app -- <cmd>' does the same job, slower."
    fi

    echo "  -> Installing ashell via paru (status bar + notification daemon)"
    if runuser -l __USERNAME__ -c 'paru -S --noconfirm --needed ashell'; then
        echo "  -> ashell installed"
        # The slice drop-in was written back in the OOM handling step.
        systemctl --global enable ashell.service
    else
        echo "  !! ashell install FAILED. Its config and slice drop-in are still"
        echo "     deployed; install it after first boot with:  paru -S ashell"
        echo "     then:  systemctl --user enable --now ashell.service"
    fi

    echo "  -> Installing zen-browser-bin via paru"
    if runuser -l __USERNAME__ -c 'paru -S --noconfirm --needed zen-browser-bin'; then
        echo "  -> zen-browser-bin installed"
    else
        echo "  !! zen-browser-bin install FAILED. you'll need to manually install a browser"
    fi

    echo "  -> Installing xdg-desktop-portal-termfilechooser via paru"
    # AUR-only, despite reading like a repo package: there is no official
    # xdg-desktop-portal-termfilechooser. It is what keeps this install
    # GTK-free and still able to open a file dialog — xdg-desktop-portal-hyprland
    # implements ScreenCast/Screenshot but NOT FileChooser, so without this
    # backend any app that asks the portal for a file picker gets nothing.
    if runuser -l __USERNAME__ -c 'paru -S --noconfirm --needed xdg-desktop-portal-termfilechooser'; then
        echo "  -> xdg-desktop-portal-termfilechooser installed"
        # /etc/xdg/, not /etc/: portals.conf is searched along XDG_CONFIG_DIRS
        # (default /etc/xdg) and then /usr/share — see portals.conf(5). The
        # file is named after XDG_CURRENT_DESKTOP, which uwsm sets to Hyprland
        # from hyprland-uwsm.desktop's DesktopNames=.
        #
        # 'default=hyprland;*' rather than a bare 'hyprland': xdg-desktop-portal
        # -hyprland only implements ScreenCast/Screenshot/GlobalShortcuts, and
        # pinning default to it alone would leave every other interface with no
        # backend at all. '*' means "first implementation found" and is the
        # documented catch-all.
        mkdir -p /etc/xdg/xdg-desktop-portal
        cat > /etc/xdg/xdg-desktop-portal/hyprland-portals.conf <<'PORTALS_EOF'
[preferred]
default=hyprland;*
org.freedesktop.impl.portal.FileChooser=termfilechooser
PORTALS_EOF
    else
        echo "  !! xdg-desktop-portal-termfilechooser install FAILED. Portal file"
        echo "     dialogs will not open until it is there:"
        echo "       paru -S xdg-desktop-portal-termfilechooser"
    fi
else
    echo "  !! paru build FAILED, so NONE of the AUR packages were installed."
    echo "     The configs are still deployed; after first boot build paru with:"
    echo "       git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si"
    echo "     then install all five with:"
    echo "       paru -S pacman-hook-kernel-install runapp ashell zen-browser-bin \\"
    echo "               xdg-desktop-portal-termfilechooser"
fi
echo 'permit persist :wheel' > /etc/doas.conf
chmod 0400 /etc/doas.conf

echo "  -> Fetching the Nordzy-catppuccin-frappe-light cursor theme"
# Not an AUR package: gboehm/Nordzy-cursors (GitLab) ships pre-built cursors
# for every flavor/accent combination as plain directories in the repo, not as
# per-flavor release assets, so this pulls straight from the git tree instead
# of going through paru. GitLab's archive endpoint takes a `path=` and returns
# just that subtree — no need to clone the whole repo (it also carries
# Windows/macOS cursor builds and ~150 other flavor combinations).
#
# Two subtrees, not one: hyprcursors/themes/... is the vector format Hyprland
# renders natively; xcursors/... is the compiled XCursor format that XWayland,
# GTK and Qt fall back to. Both are copied into the SAME theme directory —
# manifest.hl/hyprcursors/ and index.theme/cursors/ are disjoint filenames, so
# they don't collide — meaning one theme name covers every app. That name is
# CURSOR_THEME below, and it must match HYPRCURSOR_THEME/XCURSOR_THEME in
# ~/.config/uwsm/env{,-hyprland} (Step 10) exactly: hyprcursor's own docs say
# the theme is identified by its directory name under /usr/share/icons, not
# by manifest.hl's internal name= field.
CURSOR_THEME="Nordzy-catppuccin-frappe-light"
CURSOR_API="https://gitlab.com/api/v4/projects/gboehm%2FNordzy-cursors/repository/archive.tar.gz"
CURSOR_TMP="$(mktemp -d)"
CURSOR_DST="/usr/share/icons/${CURSOR_THEME}"

# $1: repo path to fetch, $2: leaf directory name to hand back. The archive
# comes back wrapped in a generated <repo>-<ref>-<hash>-<slugified-path>/
# directory rather than the bare leaf, so find locates the real content
# instead of the script depending on that wrapper's exact naming.
fetch_cursor_subtree() {
    curl -fsSL --max-time 60 "${CURSOR_API}?sha=main&path=$1" \
        | tar -xzf - -C "$CURSOR_TMP" \
        && find "$CURSOR_TMP" -type d -name "$2" -print -quit
}

CURSOR_OK=1
HYPR_SRC=$(fetch_cursor_subtree \
    "hyprcursors/themes/Nordzy-hyprcursors-catppuccin-frappe-light" \
    "Nordzy-hyprcursors-catppuccin-frappe-light") || CURSOR_OK=0
XCUR_SRC=$(fetch_cursor_subtree \
    "xcursors/Nordzy-catppuccin-frappe-light" \
    "Nordzy-catppuccin-frappe-light") || CURSOR_OK=0

if [ "$CURSOR_OK" = 1 ] && [ -n "$HYPR_SRC" ] && [ -n "$XCUR_SRC" ]; then
    rm -rf "$CURSOR_DST"
    mkdir -p "$CURSOR_DST"
    cp -r "$HYPR_SRC/manifest.hl" "$HYPR_SRC/hyprcursors" "$CURSOR_DST/"
    cp -r "$XCUR_SRC/index.theme" "$XCUR_SRC/cursors" "$CURSOR_DST/"
    chown -R 0:0 "$CURSOR_DST"
    find "$CURSOR_DST" -type d -exec chmod 755 {} +
    find "$CURSOR_DST" -type f -exec chmod 644 {} +
    echo "  -> $CURSOR_THEME installed to $CURSOR_DST"
else
    echo "  !! Could not fetch $CURSOR_THEME from gitlab.com/gboehm/Nordzy-cursors —"
    echo "     the session env still names it as the cursor theme, so Hyprland" >&2
    echo "     and XWayland apps fall back to their built-in cursor until it is" >&2
    echo "     installed by hand:" >&2
    echo "       doas curl -fsSL '${CURSOR_API}?sha=main&path=hyprcursors/themes/Nordzy-hyprcursors-catppuccin-frappe-light' | tar xz" >&2
    echo "       doas curl -fsSL '${CURSOR_API}?sha=main&path=xcursors/Nordzy-catppuccin-frappe-light' | tar xz" >&2
    echo "     then merge both extracted directories into $CURSOR_DST" >&2
fi
rm -rf "$CURSOR_TMP"

echo "  -> Secure Boot / TPM2 helper scripts (run after first boot)"
cat > /usr/local/bin/secureboot-enroll <<'SBENROLL_EOF'
#!/bin/dash
# Step 1 of the Secure Boot bring-up. Run from a booted system, AFTER putting
# the firmware in setup mode (HP: Esc -> F10 -> Advanced -> Secure Boot
# Configuration -> "Erase all Secure Boot keys", and set a BIOS admin password
# while you are in there, or anyone can just switch Secure Boot back off).
set -eu

if [ "$(id -u)" -ne 0 ]; then echo "run as root (doas $0)" >&2; exit 1; fi

echo "== current state =="
sbctl status

# Parsed from --json, not from the human table: that output is colourised and
# its wording is not an API.
if [ "$(sbctl status --json | jq -r .setup_mode)" != true ]; then
    echo
    echo "Firmware is NOT in setup mode. Reboot into the BIOS, erase the"
    echo "Secure Boot keys, then run this again." >&2
    exit 1
fi

# -m keeps Microsoft's CA enrolled. On HP hardware that matters: option ROMs
# and firmware updates are frequently signed by it, and dropping it can leave
# you with a machine that will not POST an add-in card or apply an update.
sbctl enroll-keys -m

echo "== verifying every EFI binary on the ESP is signed =="
sbctl verify || true
# The exit status is useless as a gate: verify returns nil even after
# printing "is not signed" for every file. Read the JSON. is_signed: 1
# signed, 0 unsigned, -1 missing file (a stale db entry, not a boot problem).
# `false` is matched alongside `0` on purpose: this gate is the only thing
# standing between you and a reboot into Secure Boot with an unsigned boot
# path, and it fails OPEN if sbctl ever emits that field as a bool instead —
# selecting nothing, reporting all green, and locking you out at the reboot.
# Matching both costs nothing and is correct either way. (-1 stays excluded:
# a db entry whose file is gone boots nothing and is not a problem.)
unsigned="$(sbctl verify --json | jq -r '.[] | select(.is_signed == 0 or .is_signed == false) | .file_name')"
if [ -n "$unsigned" ]; then
    echo
    echo "These files on the ESP are NOT signed by your keys:" >&2
    printf '  %s\n' $unsigned >&2
    echo >&2
    echo "Do NOT enable Secure Boot yet — the firmware would refuse to boot" >&2
    echo "anything unsigned in the boot path. Fix, then re-run this script:" >&2
    echo "  *.efi in /boot/EFI/Linux   -> doas kernel-install add-all (rebuilds it" >&2
    echo "                                signed; there is no separate loader to sign" >&2
    echo "                                here, the UKI is the only thing that boots)" >&2
    echo "  any other unsigned *.efi   -> doas sbctl sign -s <path>" >&2
    echo "  /boot/vmlinuz-* or *.img   -> leftovers from booster's pacman hook," >&2
    echo "                                nothing boots them: doas rm <path>" >&2
    exit 1
fi

echo
echo "All green. Reboot, enable Secure Boot in the BIOS, and confirm with"
echo "  sbctl status        (Secure Boot: Enabled)"
echo "Then run: doas tpm-autounlock"
SBENROLL_EOF
chmod 755 /usr/local/bin/secureboot-enroll

cat > /usr/local/bin/tpm-autounlock <<'TPMENROLL_EOF'
#!/bin/dash
# Step 2. Run this only once Secure Boot is ENABLED with your own keys --
# the whole point of the PCR 7 binding is that it records "booted an image
# signed by a key in db". Enrolling before that binds to a worthless value.
set -eu

if [ "$(id -u)" -ne 0 ]; then echo "run as root (doas $0)" >&2; exit 1; fi

LUKS_DEV="$(blkid -t TYPE=crypto_LUKS -o device | head -n1)"
[ -b "$LUKS_DEV" ] || { echo "no LUKS device found" >&2; exit 1; }
echo "LUKS device: $LUKS_DEV"

if [ "$(sbctl status --json | jq -r .secure_boot)" != true ]; then
    echo "Secure Boot is not enabled yet — run secureboot-enroll first, then" >&2
    echo "enable Secure Boot in the BIOS and boot back in." >&2
    exit 1
fi

# WHICH POLICY IS USABLE IS DECIDED BY THE INITRD, NOT BY PREFERENCE.
# A signed (authorized) PCR 11 policy — `--tpm2-public-key` — seals the key
# against a public key via TPM2_PolicyAuthorize, and the initrd has to (a)
# find the signature systemd-stub drops at /.extra/tpm2-pcr-signature.json
# and (b) satisfy PolicyAuthorize with it. Arch's booster 0.13 does neither:
# its init understands only literal-PCR systemd-tpm2 tokens (tpm2-blob,
# tpm2-pcrs, tpm2-policy-hash, tpm2_srk) and contains no tpm2_pubkey handling
# at all. Enrolling a signed policy against it produces a token that never
# unseals — the disk simply falls back to the passphrase prompt on every
# boot, with no error that points at the cause.
#
# So: probe the installed init for the marker and enroll what it can actually
# use. Upstream booster has the signed path, so this picks it up by itself
# the day Arch ships that version.
BOOSTER_INIT=/usr/lib/booster/init
if [ -f "$BOOSTER_INIT" ] && grep -qa tpm2_pubkey "$BOOSTER_INIT"; then
    SIGNED_POLICY=yes
else
    SIGNED_POLICY=no
fi
echo "booster signed-PCR-policy support: $SIGNED_POLICY"

# PCR 7  : Secure Boot policy — which keys are enrolled, and which one
#          verified each binary in the boot path
# PCR 15 : all-zero latch. Nothing has extended it when the initrd unseals,
#          and whatever runs later cannot re-unseal with the same policy.
# --wipe-slot=tpm2 makes this idempotent: re-running after a firmware update
# replaces the old token instead of stacking a second, stale one.
if [ "$SIGNED_POLICY" = yes ]; then
    # PCR 11 (the UKI's own measurement) bound by SIGNATURE, so a kernel
    # update re-signs it and needs no re-enrollment. The signature lives in
    # the UKI's .pcrsig section; booster is not a systemd initrd and does not
    # copy it to /run, so it is pulled straight out of the running kernel's
    # image — as the existence check and as cryptenroll's safety net, which
    # replays the policy against the current PCRs and refuses if it would not
    # unlock.
    UKI="/boot/EFI/Linux/arch-$(uname -r).efi"
    if [ ! -f "$UKI" ]; then
        # No arrays, no nullglob, in dash: count matches by hand instead of
        # asking an array's length, and only trust the result when exactly
        # one file matched (ambiguous otherwise, so leave UKI unset).
        ukis_count=0
        ukis_single=""
        for f in /boot/EFI/Linux/*.efi; do
            [ -e "$f" ] || continue
            ukis_count=$((ukis_count + 1))
            ukis_single="$f"
        done
        [ "$ukis_count" -eq 1 ] && UKI="$ukis_single"
    fi
    if [ ! -f "$UKI" ]; then
        echo "Cannot identify the running UKI in /boot/EFI/Linux." >&2
        echo "Run 'doas kernel-install add-all', reboot, then re-run this." >&2
        exit 1
    fi
    echo "UKI: $UKI"
    PCRSIG="$(mktemp)"
    trap 'rm -f "$PCRSIG"' EXIT
    if ! objcopy -O binary --only-section=.pcrsig "$UKI" "$PCRSIG" 2>/dev/null || [ ! -s "$PCRSIG" ]; then
        echo "$UKI carries no .pcrsig section — check [PCRSignature:initrd] in" >&2
        echo "/etc/kernel/uki.conf, run 'doas kernel-install add-all', reboot, re-run this." >&2
        exit 1
    fi
    systemd-cryptenroll --wipe-slot=0 "$LUKS_DEV"
    systemd-cryptenroll --recovery-key "$LUKS_DEV"
    systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto \
        --tpm2-pcrs=7+15:sha256=0000000000000000000000000000000000000000000000000000000000000000 \
        --tpm2-public-key=/etc/kernel/pcr-public.pem --tpm2-public-key-pcrs=11 \
        --tpm2-signature="$PCRSIG" \
        "$LUKS_DEV"
else
    systemd-cryptenroll --wipe-slot=0 "$LUKS_DEV"
    systemd-cryptenroll --recovery-key "$LUKS_DEV"
    systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto \
        --tpm2-pcrs=7+15:sha256=0000000000000000000000000000000000000000000000000000000000000000 \
        "$LUKS_DEV"
fi

echo "== enrolled tokens =="
cryptsetup luksDump "$LUKS_DEV" | grep -A2 -E "^Tokens:|systemd-tpm2" || true

echo
echo "Enrolled. The passphrase keyslot is untouched and remains your recovery"
echo "path. Reboot to confirm the disk unlocks with no prompt."
echo "If a firmware update ever breaks it: enter the passphrase and just"
echo "re-run this script — it wipes the old tpm2 slot before enrolling."
if [ "$SIGNED_POLICY" = no ]; then
    echo
    echo "NOTE on what this policy does and does not protect:"
    echo "  The key is bound to PCR 7 only — the Secure Boot key state — so"
    echo "  ANY binary the firmware accepts can unseal it. Microsoft's CA is"
    echo "  enrolled (sbctl enroll-keys -m, needed for HP option ROMs), so"
    echo "  that includes Microsoft-signed loaders booted from removable"
    echo "  media. Close that off in the BIOS: admin password set, and boot"
    echo "  from USB/optical disabled. If you would rather pay for it at"
    echo "  every boot, re-run this with --tpm2-with-pin=yes added."
fi
TPMENROLL_EOF
chmod 755 /usr/local/bin/tpm-autounlock

echo "  -> Chroot setup complete."
CHROOT_EOF

# Substitute all the placeholders into the chroot script. '|' as the sed
# delimiter so paths and locales with slashes need no escaping.
sed -i "s|__LANG_LOCALE__|${LANG_LOCALE}|g" /mnt/root/chroot-setup.sh
sed -i "s|__REGIONAL_LOCALE__|${REGIONAL_LOCALE}|g" /mnt/root/chroot-setup.sh
sed -i "s|__TIMEZONE__|${TIMEZONE}|g" /mnt/root/chroot-setup.sh
sed -i "s|__HOSTNAME__|${HOSTNAME}|g" /mnt/root/chroot-setup.sh
sed -i "s|__USERNAME__|${USERNAME}|g" /mnt/root/chroot-setup.sh
sed -i "s|__ROOT_MOUNT_OPTS__|${ROOT_MOUNT_OPTS}|g" /mnt/root/chroot-setup.sh
sed -i "s|__LUKS_UUID__|${LUKS_UUID}|g" /mnt/root/chroot-setup.sh
sed -i "s|__ROOT_FS_UUID__|${ROOT_FS_UUID}|g" /mnt/root/chroot-setup.sh
sed -i "s|__REFLECTOR_COUNTRIES__|${REFLECTOR_COUNTRIES}|g" /mnt/root/chroot-setup.sh
sed -i "s|__CONSOLE_KEYMAP__|${CONSOLE_KEYMAP}|g" /mnt/root/chroot-setup.sh
sed -i "s|__SWAP_SIZE_MIB__|${SWAP_SIZE_MIB}|g" /mnt/root/chroot-setup.sh

# --- Plymouth theme --------------------------------------------------------
# Fetched rather than packaged: the theme is a plain directory of PNGs and one
# .plymouth file, with no AUR package behind it. It has to be on the target
# BEFORE the chroot runs, because booster reads the configured theme out of
# /usr/share/plymouth/themes while building the initramfs, and a theme that is
# not there at that moment silently degrades to 'text' — a bare console for
# the LUKS prompt, with nothing in the log saying why.
#
# The tarball, not `git clone`: one HTTPS GET of ~1 MB against a clone that
# fetches the same bytes plus a .git directory nothing here will ever use.
# --strip-components=1 because the archive's top-level directory is named
# after the repo, which is not something to depend on.
#
# The upstream install.sh inside it is not used: it wants a live system to run
# plymouth-set-default-theme -R against. This does the same two things (put
# the files in place, name the theme in plymouthd.conf) offline, in a chroot.
#
# The destination path is not free: the theme's ImageDir= is the absolute
# /usr/share/plymouth/themes/arch-slider-and-glow/resources, so installing it
# anywhere else means editing the .plymouth file too.
PLYMOUTH_THEME_URL="https://codeberg.org/HasanAgitUnal/ArchSliderGlowPlymouth/archive/main.tar.gz"
PLYMOUTH_THEME="arch-slider-and-glow"
echo "  -> Fetching the $PLYMOUTH_THEME plymouth theme"
THEME_TMP="$(mktemp -d)"
THEME_DST="/mnt/usr/share/plymouth/themes/${PLYMOUTH_THEME}"
# pipefail is on, so a curl that 404s or times out fails the whole pipeline
# and lands in the else branch rather than feeding tar an error page.
if curl -fsSL --max-time 120 "$PLYMOUTH_THEME_URL" \
       | tar -xzf - -C "$THEME_TMP" --strip-components=1 \
   && [ -f "$THEME_TMP/${PLYMOUTH_THEME}.plymouth" ]; then
    rm -rf "$THEME_DST"
    mkdir -p "$THEME_DST"
    # LICENSE travels with it: the theme is MIT, which asks that the notice
    # ship with copies, and this is a copy. It costs 1 KB in the initramfs.
    # README/install.sh/screenshots are left behind — they would only be dead
    # weight in an initramfs that is a section of a signed UKI.
    cp -r "$THEME_TMP/${PLYMOUTH_THEME}.plymouth" \
          "$THEME_TMP/resources" \
          "$THEME_TMP/LICENSE" "$THEME_DST/"
    chown -R 0:0 "$THEME_DST"
    find "$THEME_DST" -type d -exec chmod 755 {} +
    find "$THEME_DST" -type f -exec chmod 644 {} +
else
    echo "  !! Could not fetch the theme from $PLYMOUTH_THEME_URL — falling"
    echo "     back to the stock 'bgrt' theme (firmware logo + spinner)."
    echo "     To apply it after first boot: extract the tarball to"
    echo "     /usr/share/plymouth/themes/$PLYMOUTH_THEME, then"
    echo "       doas plymouth-set-default-theme $PLYMOUTH_THEME"
    echo "       doas kernel-install add-all"
    PLYMOUTH_THEME="bgrt"
fi
rm -rf "$THEME_TMP"
sed -i "s|__PLYMOUTH_THEME__|${PLYMOUTH_THEME}|g" /mnt/root/chroot-setup.sh

chmod 755 /mnt/root/chroot-setup.sh

echo "==> Step 9: Entering chroot to finish setup (you'll be asked for passwords)"
arch-chroot /mnt /root/chroot-setup.sh

echo "==> Step 10: Deploying desktop configs for $USERNAME"
CFG="/mnt/home/${USERNAME}/.config"
mkdir -p "$CFG"/{hypr,uwsm,foot,fuzzel,ashell,yazi}

# -------------------------------------------------------------------- uwsm
# uwsm sources these with a shell and pushes the result into the systemd user
# manager's environment BEFORE the compositor starts, so every unit in the
# session — the bar, hypridle, every runapp launch — sees the same values.
# hl.env() in hyprland.lua would only reach the compositor and its own forks,
# which under this setup is almost nothing.
#
# env is read for every compositor; env-hyprland only when the session being
# started is Hyprland. HYPR*/AQ_* belong in the latter by convention, so they
# never leak into another compositor's session.
#
# Nothing XDG_* here on purpose: uwsm sets XDG_CURRENT_DESKTOP,
# XDG_SESSION_DESKTOP, XDG_SESSION_TYPE and the menu/data dirs itself.
cat > "$CFG/uwsm/env" <<'UWSM_ENV_EOF'
export XCURSOR_SIZE=24
export XCURSOR_THEME=Nordzy-catppuccin-frappe-light
export QT_QPA_PLATFORM="wayland;xcb"
UWSM_ENV_EOF

cat > "$CFG/uwsm/env-hyprland" <<'UWSM_ENV_HYPR_EOF'
export HYPRCURSOR_SIZE=24
export HYPRCURSOR_THEME=Nordzy-catppuccin-frappe-light
UWSM_ENV_HYPR_EOF

# ---------------------------------------------------------------- Hyprland
# Hyprland 0.55+ deprecated the hyprlang .conf format; 0.56 ships Lua and the
# old file is ignored entirely when hyprland.lua exists.
cat <<'HYPRLUA_EOF' > "$CFG/hypr/hyprland.lua"
-- ~/.config/hypr/hyprland.lua — Hyprland 0.56+ Lua config
-- Godot game dev + web dev, integrated Radeon, battery-priority.
-- Palette: Catppuccin Macchiato (https://catppuccin.com).

----------------------------------------------------------------- programs
-- This session is started by uwsm, so the compositor itself is
-- wayland-wm@hyprland.service. `runapp` starts a command as its own
-- app-Hyprland-<name>@<hash>.service in app-graphical.slice, which nests
-- under app.slice — the only place systemd-oomd looks for kill candidates.
-- Anything started WITHOUT it runs inside the compositor's own unit, out of
-- reach: deliberate for the one-shot key handlers further down (wpctl,
-- brightnessctl, playerctl, grim), which are over before oomd could sample
-- them and are not worth a unit each.
--   systemctl --user status 'app-Hyprland-foot@*.service'
local terminal    = "runapp foot"
local fileManager = "runapp foot --app-id=yazi yazi"
local menu        = "fuzzel"
local mainMod     = "SUPER"

-- The lock screen is asked for from three places (this file, hypridle.conf,
-- ashell's config.toml) and must outlive all of them, so it gets its own unit
-- in session-graphical.slice: oomd never looks outside app.slice, and
-- restarting ashell or hypridle can no longer kill the lock screen along with
-- the daemon's cgroup. Keep the three copies of this string in step.
local lock        = "pidof hyprlock || runapp -i session-graphical.slice hyprlock"

----------------------------------------------------------------- monitors
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-------------------------------------------------------------- environment
-- Deliberately empty. hl.env() only reaches the compositor and what it forks,
-- which under uwsm is almost nothing: the bar, hypridle and every runapp
-- launch are systemd units and would come up without any of it. The
-- environment has to reach the user MANAGER instead, which is what uwsm
-- exports from ~/.config/uwsm/env (toolkit/cursor) and
-- ~/.config/uwsm/env-hyprland (HYPR*/AQ_*) — both written by the installer.

---------------------------------------------------------------- autostart
-- Also deliberately empty. hyprpaper, hypridle, hyprpolkitagent, cliphist and
-- ashell (status bar AND notification daemon — no mako/dunst) each ship a
-- systemd user unit wanted by graphical-session.target, which uwsm activates,
-- and the installer enabled them. As units they restart on failure, sit in
-- slices the OOMRules= never reach, and survive a compositor restart; as
-- forked children of the compositor they would do none of the three.
--   systemctl --user status ashell hypridle hyprpaper cliphist hyprpolkitagent

------------------------------------------------------------ look and feel
hl.config({
    general = {
        gaps_in     = 4,
        gaps_out    = 8,
        border_size = 2,

        col = {
            -- Macchiato blue -> mauve
            active_border   = { colors = { "rgba(8aadf4ff)", "rgba(c6a0f6ff)" }, angle = 45 },
            -- Macchiato surface1
            inactive_border = "rgba(494d64aa)",
        },

        resize_on_border = true,
        -- Lets a fullscreen Godot game tear instead of waiting on vsync.
        allow_tearing    = true,
        layout           = "dwindle",
    },

    -- Blur and shadows are measurable GPU cost on the same iGPU that runs the
    -- game you are testing. Off on purpose.
    decoration = {
        rounding = 6,
        shadow = { enabled = false },
        blur   = { enabled = false },
    },

    animations = { enabled = true },

    dwindle = { preserve_split = true },

    misc = {
        -- This panel is a 60Hz FHD IPS with no adaptive sync, so VRR is dead
        -- weight; 0 avoids the mode-set churn some amdgpu builds do when asked.
        vrr                      = 0,
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
        force_default_wallpaper  = 0,
        -- Macchiato base, shown where no window is
        background_color         = 0xff24273a,
    },

    input = {
        kb_layout    = "__KB_LAYOUT__",
        follow_mouse = 1,
        sensitivity  = 0,
        touchpad = {
            natural_scroll       = true,
            tap_to_click         = true,
            disable_while_typing = true,
        },
    },
})

-- Fast, cheap animations rather than none at all: zero animation reads as
-- broken on window open/close, and these are too short to cost anything.
hl.curve("quick", { type = "bezier", points = { {0.15, 0}, {0.1, 1} } })
hl.animation({ leaf = "global",     enabled = true, speed = 6, bezier = "quick" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 5, bezier = "quick", style = "fade" })

-- 3-finger horizontal swipe flips workspaces (editor <-> browser <-> game).
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

------------------------------------------------------------------- binds
hl.bind(mainMod .. " + Return",    hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + D",         hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + E",         hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + Q",         hl.dsp.window.close())
hl.bind(mainMod .. " + F",         hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + M",         hl.dsp.window.fullscreen({ action = "toggle" }))
hl.bind(mainMod .. " + P",         hl.dsp.window.pseudo())
hl.bind(mainMod .. " + J",         hl.dsp.layout("togglesplit"))
hl.bind(mainMod .. " + L",         hl.dsp.exec_cmd(lock))
-- `uwsm stop`, not hl.dsp.exit(): exiting the compositor directly pulls the
-- display out from under its clients and turns an ordered shutdown into a
-- forced one. uwsm stops graphical-session.target first, then the compositor,
-- then the login session bound to it.
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd("uwsm stop"))

-- Clipboard history (cliphist + fuzzel in dmenu mode)
hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("cliphist list | fuzzel --dmenu | cliphist decode | wl-copy"))

-- Focus
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))

-- Workspaces: 1 terminal/tools · 2 browser · 3 Godot editor · 4 play-test · 5+ misc
for i = 1, 10 do
    local key = i % 10 -- 10 maps to key 0
    hl.bind(mainMod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + mouse:272",  hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273",  hl.dsp.window.resize(), { mouse = true })

-- Screenshots
hl.bind("Print",           hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))
hl.bind("SHIFT + Print",   hl.dsp.exec_cmd("grim - | wl-copy"))

-- Laptop keys
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true })
hl.bind("XF86AudioNext",         hl.dsp.exec_cmd("playerctl next"),                                 { locked = true })
hl.bind("XF86AudioPrev",         hl.dsp.exec_cmd("playerctl previous"),                             { locked = true })
hl.bind("XF86AudioPlay",         hl.dsp.exec_cmd("playerctl play-pause"),                           { locked = true })
hl.bind("XF86AudioPause",        hl.dsp.exec_cmd("playerctl play-pause"),                           { locked = true })

------------------------------------------------------------ window rules
hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

-- yazi opens as a floating scratch file manager
hl.window_rule({
    name  = "yazi-float",
    match = { class = "^yazi$" },
    float = true,
    size  = { 1100, 700 },
    center = true,
})

-- Godot's editor and a running/exported game are SEPARATE windows with their
-- own class/title, and the values vary by version. Verify with
-- `hyprctl clientinfo` and adjust these matches.
hl.window_rule({
    name  = "godot-editor",
    match = { class = "^Godot$" },
    tile  = true,
})

hl.window_rule({
    name   = "godot-debug",
    match  = { title = ".*\\(DEBUG\\)" },
    immediate = true,
    float  = true,
    size   = { 1280, 720 },
    center = true,
})
HYPRLUA_EOF
sed -i "s|__KB_LAYOUT__|${KB_LAYOUT}|" "$CFG/hypr/hyprland.lua"

cat <<'HYPRIDLE_EOF' > "$CFG/hypr/hypridle.conf"
# hypridle still uses hyprlang (only the compositor moved to Lua), but the
# dispatchers it calls through hyprctl are Lua now.
general {
    # Same string as hyprland.lua's `lock` — hypridle now runs as a systemd
    # unit, so a bare `hyprlock` here would be a child of hypridle.service and
    # would be killed with it on any restart, unlocking the screen.
    lock_cmd = pidof hyprlock || runapp -i session-graphical.slice hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch 'hl.dsp.dpms({action = "on"})'
}

# The panel is the single largest draw on this machine, so dim well before
# locking: 2.5min at 10% costs almost nothing and is instantly reversible.
listener {
    timeout = 150
    on-timeout = brightnessctl -s set 10%
    on-resume = brightnessctl -r
}

listener {
    timeout = 300
    on-timeout = loginctl lock-session
}

listener {
    timeout = 330
    on-timeout = hyprctl dispatch 'hl.dsp.dpms({action = "off"})'
    on-resume = hyprctl dispatch 'hl.dsp.dpms({action = "on"})'
}

listener {
    timeout = 900
    # suspend-then-hibernate, not suspend: the logind/sleep drop-ins then move
    # the session to disk 45 min later instead of trickling a 41 Wh battery
    # away in s2idle while the laptop sits in a bag.
    on-timeout = systemctl suspend-then-hibernate
}
HYPRIDLE_EOF

cat <<'HYPRLOCK_EOF' > "$CFG/hypr/hyprlock.conf"
# Catppuccin Macchiato
$font = JetBrainsMono Nerd Font

general {
    hide_cursor = true
}

background {
    monitor =
    color = rgba(24273aff)
}

input-field {
    monitor =
    size = 280, 56
    outline_thickness = 2
    rounding = 8

    inner_color = rgba(363a4fff)
    font_color  = rgba(cad3f5ff)
    outer_color = rgba(8aadf4ff) rgba(c6a0f6ff) 45deg
    check_color = rgba(eed49fff)
    fail_color  = rgba(ed8796ff)

    font_family = $font
    placeholder_text = <i>Password...</i>
    fail_text = $PAMFAIL

    position = 0, -40
    halign = center
    valign = center
}

label {
    monitor =
    text = $TIME
    color = rgba(cad3f5ff)
    font_size = 64
    font_family = $font

    position = 0, 80
    halign = center
    valign = center
}
HYPRLOCK_EOF

# -------------------------------------------------------------------- foot
cat <<'FOOT_EOF' > "$CFG/foot/foot.ini"
font=JetBrainsMono Nerd Font:size=11
pad=8x8
dpi-aware=yes

[cursor]
style=beam
blink=no

[mouse]
hide-when-typing=yes

# Catppuccin Macchiato
# foot >= 1.17 split the old [colors] section into [colors-dark] and
# [colors-light] and rejects the old name outright; dark is the default theme.
[colors-dark]
alpha=1.0
foreground=cad3f5
background=24273a

regular0=494d64
regular1=ed8796
regular2=a6da95
regular3=eed49f
regular4=8aadf4
regular5=f5bde6
regular6=8bd5ca
regular7=b8c0e0

bright0=5b6078
bright1=ed8796
bright2=a6da95
bright3=eed49f
bright4=8aadf4
bright5=f5bde6
bright6=8bd5ca
bright7=a5adcb

selection-foreground=cad3f5
selection-background=494d64
search-box-no-match=181926 ed8796
search-box-match=cad3f5 363a4f
jump-labels=181926 f5a97f
urls=8aadf4
FOOT_EOF

# ------------------------------------------------------------------ fuzzel
cat <<'FUZZEL_EOF' > "$CFG/fuzzel/fuzzel.ini"
font=JetBrainsMono Nerd Font:size=12
dpi-aware=yes

# fuzzel starts most applications, so this is what actually populates
# app-graphical.slice. Without it an app inherits the cgroup of whatever
# started fuzzel: the compositor's unit from SUPER+D, or ashell.service from
# the bar's launcher button — where a bar restart would take the app with it.
# runapp also reads what fuzzel exports about the selected desktop entry, so
# units come out named after the .desktop rather than the binary:
# app-Hyprland-firefox@<hash>.service, Description=Firefox.
launch-prefix=runapp
terminal=foot -e
fields=name,generic,comment,categories,filename,keywords
layer=overlay
exit-on-Keyboard-focus-loss=yes
prompt="❯ "
icons-enabled=no
horizontal-pad=20
vertical-pad=12
lines=12
width=42

# Catppuccin Macchiato
[colors]
background=24273aff
text=cad3f5ff
prompt=b8c0e0ff
placeholder=8087a2ff
input=cad3f5ff
match=8aadf4ff
selection=494d64ff
selection-text=cad3f5ff
selection-match=8aadf4ff
counter=8087a2ff
border=b7bdf8ff

[border]
width=2
radius=12
FUZZEL_EOF

# ------------------------------------------------------------------ ashell
cat <<'ASHELL_EOF' > "$CFG/ashell/config.toml"
# ashell — status bar AND notification daemon (org.freedesktop.Notifications).
# Palette: Catppuccin Macchiato.
position = "Top"

[modules]
left   = [ [ "appLauncher", "Workspaces" ] ]
center = [ "WindowTitle" ]
right  = [ "SystemInfo", "MediaPlayer", [ "Updates", "Notifications", "Tray", "Tempo", "Privacy", "Settings" ] ]

[[CustomModule]]
name    = "appLauncher"
icon    = "☰"
command = "fuzzel"

[window_title]
mode = "Title"
truncate_title_after_length = 80

[workspaces]
visibility_mode = "All"
indicator_format = "Name"

[system_info]
indicators = [ "Cpu", "Memory", "Temperature" ]
interval = 5

# checkupdates ships with pacman-contrib and covers repo packages; paru (the
# AUR helper this install builds) is left for manual `paru -Syu` runs rather
# than wired in here.
[updates]
check_cmd = "checkupdates"
# runapp, and no trailing '&': everything ashell spawns is otherwise a child
# of ashell.service and dies when the bar restarts — mid-upgrade, here. runapp
# hands the terminal to systemd and returns immediately, so there is nothing
# left to background.
update_cmd = 'runapp foot -e sh -c "doas pacman -Syu; echo; echo Done - press enter; read _"'
# 6h, not hourly: every check is a repo-DB download, and radio wakeups on
# battery cost more than knowing about updates a few hours sooner.
interval = 21600

[tempo]
clock_format = "%a %d %b %H:%M"

[notifications]
format = "%H:%M"
show_timestamps = true
show_bodies = true
grouped = true
toast = true
toast_position = "TopRight"
toast_timeout = 5000

[settings]
lock_cmd = "pidof hyprlock || runapp -i session-graphical.slice hyprlock"
audio_sinks_more_cmd = "runapp foot -e pulsemixer"
audio_sources_more_cmd = "runapp foot -e pulsemixer"
battery_format = "IconAndPercentage"

[appearance]
font_name = "JetBrainsMono Nerd Font"
primary_color = "#8aadf4"
success_color = "#a6da95"
warning_color = "#eed49f"
danger_color  = "#ed8796"
text_color    = "#cad3f5"
workspace_colors = [ "#8aadf4", "#c6a0f6" ]

[appearance.bar]
surface = "solid"
radius = "md"
margin = "xs"

[appearance.background_color]
base   = "#24273a"
weak   = "#363a4f"
strong = "#494d64"
text   = "#cad3f5"
ASHELL_EOF

# -------------------------------------------------------------------- yazi
cat <<'YAZI_THEME_EOF' > "$CFG/yazi/theme.toml"
[flavor]
dark = "catppuccin-macchiato"
YAZI_THEME_EOF

# ---------------------------------------------------------------- wallpaper
# Fetched rather than read off local disk: same reasoning as the plymouth
# theme above — this runs from a live USB, and a URL travels with the script
# where a sibling file would not. hyprpaper decodes JXL natively, so this is
# just a download + a config pointing at it — no conversion step needed.
#
# --fail so a 404/redirect-to-HTML page does not get written out as if it
# were the image; -o straight into place since there is nothing to extract.
WALLPAPER_URL="https://raw.githubusercontent.com/lsfnts/PlatziInventory/master/wallpaper.jxl"
echo "  -> Fetching wallpaper"
if curl -fsSL --max-time 60 "$WALLPAPER_URL" -o "$CFG/hypr/wallpaper.jxl"; then
    cat > "$CFG/hypr/hyprpaper.conf" <<'HYPRPAPER_EOF'
splash = false
preload = ~/.config/hypr/wallpaper.jxl
wallpaper = ,~/.config/hypr/wallpaper.jxl
HYPRPAPER_EOF
else
    echo "  !! Could not fetch the wallpaper from $WALLPAPER_URL — skipping" >&2
    echo "     hyprpaper.conf. hyprpaper will start with no wallpaper configured;" >&2
    echo "     drop an image at ~/.config/hypr/wallpaper.jxl and write" >&2
    echo "     ~/.config/hypr/hyprpaper.conf (see this script's Step 10) by hand." >&2
    rm -f "$CFG/hypr/wallpaper.jxl"
fi

arch-chroot /mnt chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config"

echo "==> Step 11: Fetching the Catppuccin Macchiato flavor for yazi"
if ! arch-chroot /mnt runuser -l "$USERNAME" -c 'ya pkg add yazi-rs/flavors:catppuccin-macchiato'; then
    echo "  !! flavor fetch failed — yazi falls back to its default theme."
    echo "     Re-run after first boot: ya pkg add yazi-rs/flavors:catppuccin-macchiato"
fi

echo "==> Step 12: Handing DNS over to systemd-resolved"
# Done last: everything above needed the live environment's resolv.conf, and
# the stub only exists once systemd-resolved runs on the installed system.
# Not via arch-chroot: it bind-mounts the host's resolv.conf over the
# chroot's, so replacing the file from inside fails with EBUSY.
ln -sfn /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

echo "=================================================================="
echo "  DISK IS ENCRYPTED — finish the Secure Boot / TPM2 bring-up first"
echo "=================================================================="
echo "  Right now the disk unlocks with your passphrase and nothing else."
echo "  Two reboots turn that into hands-free TPM2 unlocking:"
echo ""
echo "  A. Reboot, enter the BIOS (Esc at power-on, then F10):"
echo "       Advanced -> Secure Boot Configuration -> Erase all Secure Boot keys"
echo "       ...and SET A BIOS ADMIN PASSWORD while you are there, otherwise"
echo "       anyone can simply turn Secure Boot back off."
echo "     Boot Arch (passphrase), then:  doas secureboot-enroll"
echo ""
echo "  B. Reboot into the BIOS again, ENABLE Secure Boot, boot Arch, then:"
echo "       doas tpm-autounlock"
echo "     Reboot once more — the disk should unlock with no prompt."
echo ""
echo "  Do NOT skip the order: the TPM binds to PCR 7, which only records a"
echo "  meaningful value once Secure Boot is on with your own keys."
echo "  Your passphrase keyslot always remains as the recovery path."
echo ""
echo "=================================================================="
echo "  Install complete. Before you reboot, note the manual follow-ups:"
echo "=================================================================="
echo "  1. paru (AUR helper) is installed and was used to install runapp, ashell,"
echo "     zen-browser-bin and pacman-hook-kernel-install (which rebuilds the"
echo "     signed UKI on future kernel upgrades). For other AUR packages:"
echo "       paru -S <pkg>"
echo ""
echo "  2. CPU scheduler: scx_loader is enabled and starts scx_lavd in Auto mode"
echo "     on every boot (/etc/scx_loader/config.toml). Check after login with"
echo "     'scxctl get', and switch modes for a play-testing session with"
echo "     'scxctl switch -m gaming' ('scxctl switch -m auto' to go back)."
echo ""
echo "  3. Connect Wi-Fi with: wifi-connect \"YourSSID\" — it also handles the"
echo "     scan/hidden-network fallback raw iwctl needs. The nftables trust"
echo "     zone itself now re-syncs on its own after any connection change"
echo "     (wifi-zone-monitor.service), including iwd's AutoConnect and a"
echo "     reconnect after suspend, so it stays correct either way."
echo ""
echo "  4. hyprland.lua's Godot window rules are unverified — run"
echo "     'hyprctl clientinfo' with the editor and a running game open,"
echo "     and adjust the class/title match strings if needed."
echo ""
echo "  5. Desktop keys: SUPER+Return foot · SUPER+D fuzzel · SUPER+E yazi"
echo "     · SUPER+V clipboard history · SUPER+L lock · Print region shot."
echo ""
echo "  6. ly offers exactly one Wayland session, 'Hyprland (uwsm-managed)',"
echo "     plus a plain shell as the way back in if it ever fails to start."
echo "     Log OUT with SUPER+SHIFT+E (runs 'uwsm stop'), never by killing"
echo "     Hyprland: that skips the ordered shutdown."
echo ""
echo "  7. The whole session is systemd units. Applications launched from"
echo "     fuzzel or the SUPER binds get their own transient service in"
echo "     app-graphical.slice (via runapp), and that is what systemd-oomd"
echo "     kills under memory pressure instead of the whole desktop. The"
echo "     compositor, the bar, hypridle, hyprpaper, cliphist, the polkit"
echo "     agent and the lock screen all sit in slices oomd does not watch."
echo "     Check after login with:"
echo "       oomctl                                  # app.slice must be listed"
echo "       systemd-cgls --user-unit app-graphical.slice"
echo "       systemctl --user status ashell hypridle hyprpaper cliphist"
echo "     Session-wide environment goes in ~/.config/uwsm/env (and"
echo "     env-hyprland for HYPR*/AQ_*), NOT in hyprland.lua."
echo ""
echo "  8. Boot splash: the arch-slider-and-glow theme was downloaded from"
echo "     codeberg.org/HasanAgitUnal/ArchSliderGlowPlymouth, installed to"
echo "     /usr/share/plymouth/themes and baked into the initramfs. It draws"
echo "     its own background, so the HP firmware logo is replaced at hand-off"
echo "     rather than continued the way the stock bgrt theme does."
echo "     To change it later:"
echo "       doas plymouth-set-default-theme -l        # what is available"
echo "       doas plymouth-set-default-theme <name>    # writes plymouthd.conf"
echo "       doas kernel-install add-all               # rebuild + re-sign UKI"
echo "     Do NOT use its -R flag: it drives mkinitcpio, which this system does"
echo "     not have. kernel-install is what rebuilds the initramfs here."
echo ""
echo "  9. Cursor theme: Nordzy-catppuccin-frappe-light was fetched straight from"
echo "     gitlab.com/gboehm/Nordzy-cursors (both the hyprcursor and matching"
echo "     XCursor builds, merged into one /usr/share/icons directory) and named"
echo "     in ~/.config/uwsm/env{,-hyprland}. If that fetch failed at install"
echo "     time you'll see a warning above with the exact commands to redo it."
echo ""
echo " 10. Keyboard: console keymap '$CONSOLE_KEYMAP', Hyprland/xkb '$KB_LAYOUT'."
echo "     The installer ran 'loadkeys $CONSOLE_KEYMAP' before asking for the"
echo "     LUKS passphrase, and booster carries the same keymap into the initrd,"
echo "     so the boot prompt and this session agree on where the symbols are."
echo "=================================================================="

printf '%s' "Unmount and reboot now? [y/N] "
read -r DOREBOOT
case "$DOREBOOT" in
    [Yy])
        umount -R /mnt
        cryptsetup close root
        reboot
        ;;
    *)
        echo "Skipping reboot. When ready:"
        echo "  umount -R /mnt && cryptsetup close root && reboot"
        ;;
esac
