#!/bin/bash
#
# Arch Linux installer — run from the live USB.
# Encodes: F2FS root (unencrypted, lz4 compression) · bare iwd + nftables
# with a manual zone script · doas · dash as /bin/sh · TLP · mesa/vulkan-radeon
# · scx-scheds · booster initramfs · Hyprland + ly · reflector/paccache/
# fstrim/zram maintenance. No GTK anywhere: no GTK theme either.
#
# Desktop: foot (terminal) · fuzzel (launcher) · ashell (status bar AND
# notification daemon) · yazi (file manager) · Catppuccin Macchiato everywhere.
#
# THIS SCRIPT WIPES A DISK. Read the variables below, edit them, then run it.
# It will ask you to type the disk device name back to confirm before
# touching anything.

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
REFLECTOR_COUNTRY="SV"       # two-letter country code for mirror selection
TRUSTED_SSIDS=("Home-WiFi" "MyPhone-Hotspot")   # for the nftables zone script
WIFI_IFACE="wlan0"           # confirm with `iwctl device list` before running
# ============================================================

# --- Sanity checks ---
if [[ $EUID -ne 0 ]]; then
    echo "Run this as root from the live environment." >&2
    exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    echo "Not booted in UEFI mode — systemd-boot needs UEFI. Aborting." >&2
    exit 1
fi

if [[ ! -b "$DISK" ]]; then
    echo "Disk $DISK not found. Check 'lsblk' and edit the DISK variable." >&2
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
read -rp "Type the disk device path exactly ($DISK) to confirm and continue: " CONFIRM
if [[ "$CONFIRM" != "$DISK" ]]; then
    echo "Confirmation did not match. Aborting, nothing was touched."
    exit 1
fi

# Work out partition naming (nvme/mmcblk use a 'p' before the number)
if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# Mount options used for the root filesystem, and reused verbatim in the
# bootloader's rootflags= so early boot mounts it the same way.
# compress_extension=* is what actually turns compression ON: the mkfs
# 'compression' feature plus compress_algorithm only make it *possible*;
# without an extension list (or chattr +c) nothing is ever compressed.
# The nocompress_extension= entries are the file types that are already
# compressed, so lz4 can never win on them: pacman's .zst cache, archives
# (zip and friends — deflate/LZMA output is incompressible), photo/video/audio
# containers, Godot's imported .ctex, and git packfiles. The kernel takes ONE
# extension per option, caps the list at 16 (COMPRESS_EXT_NUM) and at 7
# characters each, and rejects '*' on this side. All 16 slots are used.
ROOT_MOUNT_OPTS="compress_algorithm=lz4,compress_chksum,compress_extension=*,nocompress_extension=zst,nocompress_extension=zip,nocompress_extension=7z,nocompress_extension=gz,nocompress_extension=xz,nocompress_extension=mkv,nocompress_extension=png,nocompress_extension=jpg,nocompress_extension=jpeg,nocompress_extension=webp,nocompress_extension=ogg,nocompress_extension=mp3,nocompress_extension=mp4,nocompress_extension=webm,nocompress_extension=ctex,nocompress_extension=pack,atgc,gc_merge,lazytime,noatime,nodiscard"

echo "==> Step 0: Checking the drive's formatted LBA size"
# NVMe SSDs frequently ship formatted as 512e even though the flash is 4K
# native. Running in the native format removes a translation layer in the
# controller and lowers write amplification; the drive reports which of its
# LBA formats is preferable via the Relative Performance field (lower = better).
echo "    logical block size: $(blockdev --getss "$DISK")B   physical: $(blockdev --getpbsz "$DISK")B"
if [[ "$DISK" == /dev/nvme* ]]; then
    if ! command -v nvme >/dev/null 2>&1; then
        echo "    nvme-cli is not in this live environment — skipping the LBA-format"
        echo "    check. Run 'pacman -Sy nvme-cli' and re-run this script to enable it."
    else
        nvme id-ns -H "$DISK" | grep -E '^LBA Format' || true
        # Pick the best format the drive advertises: lowest Relative Performance,
        # largest data size on a tie, and never one that carries metadata bytes
        # (ms != 0 formats are for T10 PI, not general use).
        read -r BEST_LBAF BEST_DS CUR_LBAF CUR_DS < <(
            nvme id-ns -H "$DISK" | awk '
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
                END { print best_idx, best_ds, cur_idx, cur_ds }'
        )
        if [[ -n "$BEST_LBAF" && "$BEST_LBAF" != "$CUR_LBAF" ]]; then
            echo
            echo "    This namespace is using LBA format $CUR_LBAF (${CUR_DS}B), but format"
            echo "    $BEST_LBAF (${BEST_DS}B) is rated better by the drive itself."
            echo "    Reformatting erases the namespace — which this script is about to do"
            echo "    anyway — and usually finishes in seconds."
            read -rp "    Run 'nvme format --lbaf=$BEST_LBAF' on $DISK now? [y/N] " DOLBAF
            if [[ "$DOLBAF" =~ ^[Yy]$ ]]; then
                nvme format --lbaf="$BEST_LBAF" --force "$DISK"
                udevadm settle
                echo "    now: $(blockdev --getss "$DISK")B logical"
            fi
        else
            echo "    Already on the drive's preferred LBA format."
        fi
    fi
fi

# FAT32 needs >= 65525 clusters and a cluster can never be smaller than one
# sector, so a 4Kn drive needs 65525 * 4KiB = 256.0MiB of *data area* plus
# reserved sectors and two FATs (~0.5MiB) — 256M lands just under the cliff and
# mkfs.fat -F32 refuses. 288M clears it with ~30MiB of margin and wastes far
# less than rounding up to 512M. (4Kn also wants dosfstools >= 4.2; 4.1
# miscounted clusters and produced ESPs firmware read as FAT16. Arch ships 4.2+.)
if [[ "$(blockdev --getss "$DISK")" -ge 4096 ]]; then
    EFI_SIZE="288M"
else
    EFI_SIZE="256M"
fi

echo "==> Step 1: Partitioning $DISK"
sgdisk --zap-all "$DISK"
# One signed UKI (kernel + lz4 booster initrd + microcode) is ~60M, and an
# upgrade briefly holds two, so ~135M peak. Both sizes clear that; the 4Kn
# value is a FAT32 cluster-count floor, not a capacity need.
sgdisk -n1:0:+"$EFI_SIZE" -t1:ef00 -c1:"EFI" "$DISK"
sgdisk -n2:0:0   -t2:8300 -c2:"root" "$DISK"
partprobe "$DISK"
udevadm settle

echo "==> Step 2: Formatting"
mkfs.fat -F32 "$EFI_PART"

# --- LUKS2 -------------------------------------------------------------
# aes-xts-plain64/512 runs on Zen 5's VAES at several GB/s, so the cipher is
# not the bottleneck; the settings that matter are:
#   --sector-size 4096  match the drive's LBA size, or dm-crypt does a
#                       read-modify-write per physical block
#   --persistent + --perf-no_*_workqueue  encrypt inline instead of bouncing
#                       through kernel workqueues (latency win on NVMe),
#                       stored in the LUKS2 header so early boot inherits them
#   --allow-discards    otherwise fstrim.timer silently does nothing
echo
echo "    Set the LUKS passphrase. This is the RECOVERY credential: the TPM"
echo "    will unlock the disk day to day, but if firmware changes invalidate"
echo "    the TPM policy this passphrase is the only way back in."
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id \
    --sector-size 4096 --label archluks "$ROOT_PART"
echo "    Unlocking it now:"
cryptsetup open --persistent --allow-discards \
    --perf-no_read_workqueue --perf-no_write_workqueue "$ROOT_PART" root
ROOT_DEV="/dev/mapper/root"
LUKS_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
if [[ -z "$LUKS_UUID" ]]; then
    echo "Could not read the LUKS UUID of $ROOT_PART. Aborting." >&2
    exit 1
fi

# -f: overwrite any filesystem signature left behind on the old layout.
# flexible_inline_xattr lets xattrs live in the inode's extra-attr area (and
# makes inline_xattr_size tunable later); it is an on-disk feature, so it can
# only be turned on here. The matching mount options — inline_xattr,
# inline_data, inline_dentry, extent_cache — are already kernel defaults and
# are deliberately not repeated in ROOT_MOUNT_OPTS.
# f2fs sits ON TOP of dm-crypt, so compression shrinks the data before it is
# encrypted — the two features cooperate rather than fight.
mkfs.f2fs -f -i -O extra_attr,inode_checksum,sb_checksum,compression,flexible_inline_xattr -l archroot "$ROOT_DEV"
udevadm settle
ROOT_FS_UUID="$(blkid -s UUID -o value "$ROOT_DEV")"
if [[ -z "$ROOT_FS_UUID" ]]; then
    echo "Could not read the filesystem UUID of $ROOT_DEV. Aborting." >&2
    exit 1
fi

echo "==> Step 3: Mounting"
mount -o "$ROOT_MOUNT_OPTS" "$ROOT_DEV" /mnt
# fmask/dmask keep the ESP root-only; bootctl warns loudly otherwise.
mount --mkdir -o fmask=0077,dmask=0077 "$EFI_PART" /mnt/boot

echo "==> Step 4: Base install (pacstrap)"
# linux-firmware-mediatek: the OmniBook 3's "Wi-Fi 6 2x2 + BT 5.4" card is a
# MediaTek MT79xx on most HP SKUs; realtek is kept in case yours is an RTL8852.
# Confirm with 'lspci -nnk | grep -A3 -i net' and drop the one you don't need.
pacstrap -K /mnt base linux booster cryptsetup linux-firmware-amdgpu linux-firmware-mediatek linux-firmware-realtek linux-firmware-other amd-ucode f2fs-tools micro

echo "==> Step 5: fstab + resolv.conf for network inside chroot"
genfstab -U /mnt >> /mnt/etc/fstab
cp /etc/resolv.conf /mnt/etc/resolv.conf

echo "==> Step 6: Writing the nftables zone-switching script"
TRUSTED_SSID_LITERAL=""
for ssid in "${TRUSTED_SSIDS[@]}"; do
    TRUSTED_SSID_LITERAL+="\"$ssid\" "
done

cat <<'WIFICONNECT_EOF' > /mnt/usr/local/bin/wifi-connect
#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: wifi-connect <SSID>" >&2
    exit 2
fi

SSID="$1"
IFACE="__IFACE__"
TRUSTED_NETWORKS=(__TRUSTED_NETWORKS__)

# Drop to untrusted first: if the connect fails we stay closed.
doas nft flush set inet filter trusted_tcp_ports
doas nft flush set inet filter trusted_udp_ports

iwctl station "$IFACE" connect "$SSID"

for net in "${TRUSTED_NETWORKS[@]}"; do
  if [[ "$SSID" == "$net" ]]; then
    echo "Trusted network — opening SSH (22/tcp) and mDNS (5353/udp)"
    doas nft add element inet filter trusted_tcp_ports '{ 22 }'
    doas nft add element inet filter trusted_udp_ports '{ 5353 }'
    break
  fi
done
WIFICONNECT_EOF
sed -i "s|__IFACE__|${WIFI_IFACE}|" /mnt/usr/local/bin/wifi-connect
sed -i "s|__TRUSTED_NETWORKS__|${TRUSTED_SSID_LITERAL}|" /mnt/usr/local/bin/wifi-connect
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
#!/bin/bash
set -euo pipefail

echo "  -> Installing remaining packages"
# -Syu, never -Sy: a plain refresh here means a partial upgrade later.
pacman -Syu --noconfirm --needed \
    opendoas base-devel git tealdeer dash axel \
    cryptsetup sbctl systemd-ukify openssl tpm2-tss tpm2-tools \
    iwd nftables \
    tlp zram-generator \
    pipewire pipewire-pulse pipewire-alsa wireplumber sof-firmware alsa-ucm-conf alsa-utils \
    bluez bluez-utils \
    mesa vulkan-radeon vulkan-mesa-layers \
    scx-scheds \
    hyprland ly xdg-desktop-portal-hyprland qt5-wayland qt6-wayland \
    hypridle hyprlock hyprpolkitagent \
    foot fuzzel yazi \
    cliphist wl-clipboard grim slurp brightnessctl playerctl pulsemixer \
    ffmpegthumbnailer 7zip jq poppler fd ripgrep fzf zoxide imagemagick \
    ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji \
    reflector pacman-contrib

echo "  -> pacman: axel as the download backend"
# pacman's built-in downloader is single-connection per file; axel opens
# several to the same mirror. %o is the temp file, %u the URL — pacman renames
# %o into place only on exit status 0, so a failed mirror still falls through
# to the next one. ParallelDownloads is silently ignored once XferCommand is
# set, so it gets commented out rather than left there looking effective.
sed -i 's|^#\?XferCommand = /usr/bin/curl.*|XferCommand = /usr/bin/axel -n 8 -a -T 10 -o %o %u|' /etc/pacman.conf
sed -i 's|^ParallelDownloads|#ParallelDownloads|' /etc/pacman.conf
grep -q '^XferCommand' /etc/pacman.conf || echo "  !! XferCommand not set — check /etc/pacman.conf [options]"

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
ln -sf /usr/share/zoneinfo/__TIMEZONE__ /etc/localtime
hwclock --systohc
echo "__HOSTNAME__" > /etc/hostname
cat > /etc/hosts <<HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   __HOSTNAME__.localdomain __HOSTNAME__
HOSTS_EOF

echo "  -> Initramfs (booster) + signed Unified Kernel Image"
# booster builds host-specific images from the modules loaded on the *live*
# system, so the ones this machine boots from are named explicitly instead.
# fsck + fsck.f2fs restore the root check mkinitcpio's fsck hook did, and
# amdgpu is force-loaded for early KMS (mkinitcpio's kms hook).
cat > /etc/booster.yaml <<'BOOSTER_EOF'
compression: lz4
modules: f2fs,nvme,amdgpu
modules_force_load: amdgpu
extra_files: fsck,fsck.f2fs
BOOSTER_EOF

# Everything boots as ONE signed PE binary. A loose kernel + initrd pair is
# the classic broken Secure Boot setup: the firmware verifies vmlinuz and the
# attacker just edits the unsigned initramfs. The UKI seals kernel, initrd,
# microcode AND the command line together.
mkdir -p /etc/kernel /etc/kernel/secureboot
# entry-token is pinned so kernel-install does not depend on /etc/machine-id,
# which is not yet initialised inside the chroot.
systemd-machine-id-setup
cat > /etc/kernel/install.conf <<'KINSTALL_EOF'
layout=uki
entry-token=arch
initrd_generator=booster
uki_generator=ukify
KINSTALL_EOF

# Signed cmdline: rd.luks.uuid names the container, root= the filesystem
# inside it. Neither can be edited without invalidating the signature.
cat > /etc/kernel/cmdline <<'CMDLINE_EOF'
rd.luks.uuid=__LUKS_UUID__ root=UUID=__ROOT_FS_UUID__ rootfstype=f2fs rootflags=__ROOT_MOUNT_OPTS__ rw
CMDLINE_EOF

# Secure Boot keys (sbctl) and the RSA pair that signs the PCR 11 policy.
# PCR 11 must be signed, not pinned: ukify re-signs it on every kernel build,
# so kernel updates never need TPM re-enrollment.
sbctl create-keys
openssl genpkey -algorithm rsa -pkeyopt rsa_keygen_bits:2048 -out /etc/kernel/pcr-private.pem
openssl rsa -pubout -in /etc/kernel/pcr-private.pem -out /etc/kernel/pcr-public.pem
chmod 0600 /etc/kernel/pcr-private.pem
cat > /etc/kernel/uki.conf <<'UKICONF_EOF'
[UKI]
Microcode=/boot/amd-ucode.img
SecureBootPrivateKey=/var/lib/sbctl/keys/db/db.key
SecureBootCertificate=/var/lib/sbctl/keys/db/db.pem
PCRBanks=sha256

[PCRSignature:initrd]
PCRPrivateKey=/etc/kernel/pcr-private.pem
PCRPublicKey=/etc/kernel/pcr-public.pem
UKICONF_EOF

# Arch does not drive kernel-install itself, and booster's own hook would keep
# building the loose (unsignable) image. Mask that hook, add one that rebuilds
# every installed kernel as a signed UKI.
mkdir -p /etc/pacman.d/hooks
ln -sfn /dev/null /etc/pacman.d/hooks/90-booster-install.hook
cat > /usr/local/bin/uki-rebuild <<'UKIREBUILD_EOF'
#!/bin/bash
# Rebuild a signed UKI for every installed kernel. Called by a pacman hook.
set -euo pipefail
shopt -s nullglob
for vmlinuz in /usr/lib/modules/*/vmlinuz; do
    kver="$(basename "$(dirname "$vmlinuz")")"
    echo "  building UKI for $kver"
    kernel-install add "$kver" "$vmlinuz"
done
UKIREBUILD_EOF
chmod 755 /usr/local/bin/uki-rebuild
cat > /etc/pacman.d/hooks/95-uki.hook <<'UKIHOOK_EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Building signed Unified Kernel Image(s) with booster + ukify...
When = PostTransaction
Exec = /usr/local/bin/uki-rebuild
UKIHOOK_EOF


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

echo "  -> Bootloader"
bootctl install
systemctl enable systemd-boot-update.service
# No loader entries: systemd-boot auto-discovers the UKIs in /boot/EFI/Linux.
cat > /boot/loader/loader.conf <<'LOADER_EOF'
timeout 3
console-mode max
editor no
LOADER_EOF

# Build the UKIs now, after bootctl has established the ESP: kernel-install
# resolves its output path through `bootctl --print-boot-path`.
# uname -r inside a chroot is the LIVE ISO's kernel, so iterate the modules
# tree instead of trusting it.
/usr/local/bin/uki-rebuild
# pacstrap's booster hook already produced a loose image; unsigned, now unused.
rm -f /boot/booster-linux*.img

# Sign the loader itself, both the ESP copy and the /usr source that
# systemd-boot-update.service later copies over it — signing only the ESP copy
# is the classic way to lock yourself out on the next systemd upgrade.
sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
sbctl sign -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi

echo "  -> Network: bare iwd"
mkdir -p /etc/iwd
cat > /etc/iwd/main.conf <<'IWD_EOF'
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=systemd
IWD_EOF
systemctl enable iwd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd

echo "  -> Firewall"
systemctl enable nftables

echo "  -> Power management"
mkdir -p /etc/tlp.d
cat > /etc/tlp.d/01-wifi.conf <<'TLP_EOF'
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on
TLP_EOF
cat > /etc/tlp.d/02-cpu.conf <<'TLP_CPU_EOF'
# amd_pstate EPP: the single biggest idle/light-load win on Zen 5 mobile.
# Boost stays enabled on battery on purpose — a shader/C# compile that finishes
# sooner returns the package to idle sooner (race to idle beats a slow crawl).
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

mkdir -p /etc/systemd
# 8 GiB on 16 GiB of RAM. zram only allocates what it actually stores, and lz4
# lands ~2.5-3x on anon pages, so 8 GiB of swap costs ~2.7-3.2 GiB of real RAM
# at worst and buys ~+5 GiB of effective memory. Sizing it at full RAM is the
# common mistake: the backing store is RAM, so an incompressible fill just
# recreates the pressure it was meant to relieve, with zsmalloc overhead on top.
cat > /etc/systemd/zram-generator.conf <<'ZRAM_EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = lz4
swap-priority = 100
fs-type = swap
ZRAM_EOF

# zram is RAM-speed with no seek penalty, so the defaults tuned for disk swap
# are wrong: swap early and one page at a time, and give kswapd more headroom
# so reclaim starts before allocation stalls.
cat > /etc/sysctl.d/99-zram.conf <<'SYSCTL_EOF'
vm.swappiness = 180
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
SYSCTL_EOF

# Bluetooth is installed but NOT enabled: an idle controller is a constant
# small draw and a wakeup source. Start it when you need it:
#   doas systemctl start bluetooth

echo "  -> Login manager"
systemctl enable ly

echo "  -> CPU scheduler service (enable only — pick a scheduler after first boot)"
systemctl enable scx_loader

echo "  -> Maintenance"
sed -i "s/^Country = .*/Country = __REFLECTOR_COUNTRY__/" /etc/xdg/reflector/reflector.conf 2>/dev/null || true
reflector --country __REFLECTOR_COUNTRY__ --latest 10 --sort rate --save /etc/pacman.d/mirrorlist || echo "reflector failed — check network, you can re-run it after first boot"
systemctl enable reflector.timer
systemctl enable paccache.timer
systemctl enable fstrim.timer

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-size.conf <<'JOURNALD_EOF'
[Journal]
SystemMaxUse=200M
JOURNALD_EOF

echo "  -> Building ashell from the AUR (status bar + notification daemon)"
# ashell is AUR-only. makepkg refuses to run as root, and it shells out to
# `sudo pacman` for deps — which is the doas symlink created above, so the
# policy is relaxed to nopass for the duration of the build only.
echo 'permit nopass :wheel' > /etc/doas.conf
if runuser -l __USERNAME__ -c '
    set -euo pipefail
    build=$(mktemp -d)
    trap "rm -rf \"$build\"" EXIT
    git clone --depth=1 https://aur.archlinux.org/ashell.git "$build/ashell"
    cd "$build/ashell"
    makepkg -si --noconfirm --needed
'; then
    echo "  -> ashell installed"
else
    echo "  !! ashell build FAILED. The bar config is still deployed; build it"
    echo "     after first boot with:"
    echo "       git clone https://aur.archlinux.org/ashell.git && cd ashell && makepkg -si"
fi
echo 'permit persist :wheel' > /etc/doas.conf
chmod 0400 /etc/doas.conf

echo "  -> Secure Boot / TPM2 helper scripts (run after first boot)"
cat > /usr/local/bin/secureboot-enroll <<'SBENROLL_EOF'
#!/bin/bash
# Step 1 of the Secure Boot bring-up. Run from a booted system, AFTER putting
# the firmware in setup mode (HP: Esc -> F10 -> Advanced -> Secure Boot
# Configuration -> "Erase all Secure Boot keys", and set a BIOS admin password
# while you are in there, or anyone can just switch Secure Boot back off).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "run as root (doas $0)" >&2; exit 1; fi

echo "== current state =="
sbctl status

if ! sbctl status | grep -q "Setup Mode:.*Enabled"; then
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
sbctl verify

echo
echo "All green? Reboot, enable Secure Boot in the BIOS, and confirm with"
echo "  sbctl status        (Secure Boot: Enabled)"
echo "Then run: doas tpm-autounlock"
SBENROLL_EOF
chmod 755 /usr/local/bin/secureboot-enroll

cat > /usr/local/bin/tpm-autounlock <<'TPMENROLL_EOF'
#!/bin/bash
# Step 2. Run this only once Secure Boot is ENABLED with your own keys --
# the whole point of the PCR 7 binding is that it records "booted an image
# signed by a key in db". Enrolling before that binds to a worthless value.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "run as root (doas $0)" >&2; exit 1; fi

LUKS_DEV="$(blkid -t TYPE=crypto_LUKS -o device | head -n1)"
[[ -b "$LUKS_DEV" ]] || { echo "no LUKS device found" >&2; exit 1; }
echo "LUKS device: $LUKS_DEV"

if ! sbctl status | grep -q "Secure Boot:.*Enabled"; then
    echo "Secure Boot is not enabled yet — run secureboot-enroll first." >&2
    exit 1
fi

# PCR 7  : Secure Boot policy (which keys are enrolled)
# PCR 11 : the UKI itself, bound by SIGNATURE rather than by value, so a
#          kernel update re-signs it and needs no re-enrollment
# PCR 15 : all-zero latch, booster extends it after unlocking so a second
#          "supplanted" volume cannot re-unseal the same key
systemd-cryptenroll --tpm2-device=auto \
    --tpm2-pcrs=7+15:sha256=0000000000000000000000000000000000000000000000000000000000000000 \
    --tpm2-public-key=/etc/kernel/pcr-public.pem --tpm2-public-key-pcrs=11 \
    "$LUKS_DEV"

echo
echo "Enrolled. The passphrase keyslot is untouched and remains your recovery"
echo "path. Reboot to confirm the disk unlocks with no prompt."
echo "If firmware changes ever break it: enter the passphrase, then re-run"
echo "this script (systemd-cryptenroll --wipe-slot=tpm2 first)."
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
sed -i "s|__REFLECTOR_COUNTRY__|${REFLECTOR_COUNTRY}|g" /mnt/root/chroot-setup.sh
chmod 755 /mnt/root/chroot-setup.sh

echo "==> Step 9: Entering chroot to finish setup (you'll be asked for passwords)"
arch-chroot /mnt /root/chroot-setup.sh

echo "==> Step 10: Deploying desktop configs for $USERNAME"
CFG="/mnt/home/${USERNAME}/.config"
mkdir -p "$CFG"/{hypr,foot,fuzzel,ashell,yazi}

# ---------------------------------------------------------------- Hyprland
# Hyprland 0.55+ deprecated the hyprlang .conf format; 0.56 ships Lua and the
# old file is ignored entirely when hyprland.lua exists.
cat <<'HYPRLUA_EOF' > "$CFG/hypr/hyprland.lua"
-- ~/.config/hypr/hyprland.lua — Hyprland 0.56+ Lua config
-- Godot game dev + web dev, integrated Radeon, battery-priority.
-- Palette: Catppuccin Macchiato (https://catppuccin.com).

----------------------------------------------------------------- programs
local terminal    = "foot"
local fileManager = "foot --app-id=yazi yazi"
local menu        = "fuzzel"
local mainMod     = "SUPER"

----------------------------------------------------------------- monitors
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-------------------------------------------------------------- environment
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")

---------------------------------------------------------------- autostart
-- ashell is both the status bar and the notification daemon; no mako/dunst.
hl.on("hyprland.start", function()
    hl.exec_cmd("ashell")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("systemctl --user start hyprpolkitagent.service")
    hl.exec_cmd("wl-paste --watch cliphist store")
end)

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
        kb_layout    = "us",
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
hl.bind(mainMod .. " + L",         hl.dsp.exec_cmd("pidof hyprlock || hyprlock"))
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exit())

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
    float  = true,
    size   = { 1280, 720 },
    center = true,
})
HYPRLUA_EOF

cat <<'HYPRIDLE_EOF' > "$CFG/hypr/hypridle.conf"
# hypridle still uses hyprlang (only the compositor moved to Lua), but the
# dispatchers it calls through hyprctl are Lua now.
general {
    lock_cmd = pidof hyprlock || hyprlock
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
    on-timeout = systemctl suspend
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
[colors]
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
terminal=foot -e
layer=overlay
prompt="❯ "
icons-enabled=no
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
radius=8
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

# checkupdates ships with pacman-contrib; no AUR helper is installed.
[updates]
check_cmd = "checkupdates"
update_cmd = 'foot -e sh -c "doas pacman -Syu; echo; echo Done - press enter; read _" &'
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
lock_cmd = "pidof hyprlock || hyprlock"
audio_sinks_more_cmd = "foot -e pulsemixer"
audio_sources_more_cmd = "foot -e pulsemixer"
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

arch-chroot /mnt chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config"

echo "==> Step 11: Fetching the Catppuccin Macchiato flavor for yazi"
if ! arch-chroot /mnt runuser -l "$USERNAME" -c 'ya pkg add yazi-rs/flavors:catppuccin-macchiato'; then
    echo "  !! flavor fetch failed — yazi falls back to its default theme."
    echo "     Re-run after first boot: ya pkg add yazi-rs/flavors:catppuccin-macchiato"
fi

echo "==> Step 12: Handing DNS over to systemd-resolved"
# Done last: everything above (pacman, reflector, makepkg, ya) needed the
# live environment's resolv.conf, and the stub file only exists once
# systemd-resolved is actually running on the installed system.
arch-chroot /mnt ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

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
echo "  1. paru/AUR helper: not installed (ashell was built directly with"
echo "     makepkg). After first login: git clone https://aur.archlinux.org/paru.git"
echo "     && cd paru && makepkg -si  (uses your doas symlink automatically)"
echo ""
echo "  2. CPU scheduler: scx_loader is enabled but no scheduler is chosen."
echo "     After first boot: check 'scx_loader --help' for the current"
echo "     syntax, then switch to scx_lavd."
echo ""
echo "  3. Connect Wi-Fi with: wifi-connect \"YourSSID\" (not raw iwctl) so"
echo "     the nftables trust zone gets set correctly."
echo ""
echo "  4. hyprland.lua's Godot window rules are unverified — run"
echo "     'hyprctl clientinfo' with the editor and a running game open,"
echo "     and adjust the class/title match strings if needed."
echo ""
echo "  5. Desktop keys: SUPER+Return foot · SUPER+D fuzzel · SUPER+E yazi"
echo "     · SUPER+V clipboard history · SUPER+L lock · Print region shot."
echo "=================================================================="

read -rp "Unmount and reboot now? [y/N] " DOREBOOT
if [[ "$DOREBOOT" =~ ^[Yy]$ ]]; then
    umount -R /mnt
    cryptsetup close root
    reboot
else
    echo "Skipping reboot. When ready:"
    echo "  umount -R /mnt && cryptsetup close root && reboot"
fi
