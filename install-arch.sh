#!/bin/bash
#
# Arch Linux installer — run from the live USB.
# Encodes: F2FS root (unencrypted, lz4 compression) · bare iwd + nftables
# with a manual zone script · doas · dash as /bin/sh · TLP · mesa/vulkan-radeon
# · scx-scheds · booster initramfs · Hyprland + ly · reflector/paccache/
# fstrim/zswap maintenance. No GTK anywhere: no GTK theme either.
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
TRUSTED_SSIDS=("Acuario/5g" "Galaxy S23 4A5C")   # for the nftables zone script
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
# aes-xts-plain64/256 runs on Zen 5's VAES at several GB/s, so the cipher is
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
    --cipher aes-xts-plain64 --key-size 256 --pbkdf argon2id \
    --sector-size 4096 --label archluks --iter-time 500 "$ROOT_PART"
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
# e2fsprogs is not part of 'base'; it is pulled in only for filefrag, which
# reads the swap file's physical offset for resume_offset=.
pacstrap -K /mnt base linux booster cryptsetup linux-firmware-amdgpu linux-firmware-realtek linux-firmware-other amd-ucode f2fs-tools e2fsprogs micro

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
    cryptsetup sbctl systemd-ukify sbsigntools openssl tpm2-tss tpm2-tools \
    iwd nftables \
    tlp earlyoom \
    pipewire pipewire-pulse pipewire-alsa wireplumber sof-firmware alsa-ucm-conf alsa-utils \
    bluez bluez-utils \
    mesa vulkan-radeon vulkan-mesa-layers \
    scx-scheds scx-tools \
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
systemd-machine-id-setup
# install.conf understands only BOOT_ROOT=, layout=, initrd_generator=,
# uki_generator= and entry_name_format=. The entry token is NOT a key here —
# it is its own file, or kernel-install warns "unknown key" and ignores it.
cat > /etc/kernel/install.conf <<'KINSTALL_EOF'
layout=uki
initrd_generator=booster
uki_generator=ukify
KINSTALL_EOF
# Pinned so kernel-install does not fall back to /etc/machine-id, which is not
# meaningfully initialised inside the chroot.
echo arch > /etc/kernel/entry-token

echo "  -> Swap file (backing store for zswap, and the hibernation target)"
# zswap is a compressed RAM cache *in front of* a real swap device, so unlike
# zram it needs one to exist. 8 GiB on 16 GiB of RAM: this is the ceiling on
# how much anon memory can be pushed into the zswap pool, not disk that gets
# written — with writeback disabled (below) pages that fail to compress are
# rejected and stay resident instead of landing on the SSD.
#
# f2fs swap files must be pinned, and the order is mandated by the kernel
# (fs/f2fs/data.c: "1) creat(), 2) ioctl(F2FS_IOC_SET_PIN_FILE), 3)
# fallocate(2MB * N)"): pin the empty inode first so fallocate hands out one
# aligned, contiguous, non-compressed extent. Getting it wrong is not fatal but
# f2fs then logs "Swapfile is not align to section" and swapon fails.
touch /swapfile
chmod 600 /swapfile
f2fs_io pinfile set /swapfile
# Explicit, even though the kernel refuses to swapon a compressed inode: the
# root fs runs with compress_extension=*, and a file with no extension is
# exactly what that matches.
f2fs_io setflags nocompression /swapfile
# Plain fallocate is what the kernel's own message recommends; f2fs_io's
# ioctl is the fallback if this f2fs build rejects it on a pinned inode.
fallocate -l 8192M /swapfile || f2fs_io fallocate 0 0 8589934592 /swapfile
mkswap /swapfile
# Proven, not assumed: activate it here (the fs is really mounted) so a
# pinning/alignment mistake surfaces now instead of as a silent no-swap boot.
# genfstab ran before this file existed, so the entry is written by hand.
RESUME_OFFSET=""
if swapon /swapfile; then
    swapoff /swapfile
    echo '/swapfile none swap defaults,pri=100 0 0' >> /etc/fstab
    # Hibernation needs the swap file's FIRST physical block, in PAGE_SIZE
    # units — f2fs blocks are 4 KiB, so filefrag's value is used as-is. The
    # file is pinned, so f2fs GC will never relocate it and this stays valid;
    # recreating the swap file invalidates it and needs a UKI re-sign.
    RESUME_OFFSET="$(filefrag -v /swapfile | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')"
    if [[ ! "$RESUME_OFFSET" =~ ^[0-9]+$ ]]; then
        echo "  !! could not read the swap file offset — hibernation not wired." >&2
        RESUME_OFFSET=""
    fi
else
    echo "  !! swapon /swapfile failed — no fstab entry written." >&2
    echo "     zswap needs a backing device; without one it does nothing," >&2
    echo "     and hibernation has nowhere to write its image." >&2
    echo "     Check 'dmesg | grep -i swapfile' for the f2fs alignment warning." >&2
fi


# Signed cmdline: rd.luks.uuid names the container, root= the filesystem
# inside it. Neither can be edited without invalidating the signature — every
# token here costs a re-sign to change, so this is deliberately short.
#
# nowatchdog: turns off the soft-lockup and NMI hard-lockup detectors. The
# hard-lockup detector on this kernel is HARDLOCKUP_DETECTOR_PERF, i.e. it
# permanently occupies one PMU counter per core; disabling it frees those for
# perf/Godot profiling and removes a per-CPU periodic wakeup on battery.
#
# Deliberately NOT set (verified against Arch's config.x86_64):
#   amd_pstate=active   X86_AMD_PSTATE_DEFAULT_MODE=3 is already ACTIVE
#   preempt=full        CONFIG_PREEMPT=y + PREEMPT_DYNAMIC = full by default
#   tsc=nowatchdog      already auto-disabled on Zen 5 (CONSTANT+NONSTOP TSC
#                       + TSC_ADJUST, one package: arch/x86/kernel/tsc.c)
#   amdgpu.dcfeaturemask PSR is on by default for DCN >= 3.1; this is 3.5
#   iommu=pt            a few % on DMA-heavy I/O, but drops kernel DMA
#                       isolation — wrong trade on a laptop built around LUKS
#   mitigations=off     see arch-install-steps.md; security, not performance
#   amdgpu.abmlevel=N   would LOCK panel power saving at boot: the driver only
#                       lets userspace change it while it is -1/auto
#
# Hibernation: resume= names the same device as root= (the unlocked mapper, so
# LUKS is opened first), resume_offset= the swap file's first physical block.
# booster parses resume= and writes major:minor to /sys/power/resume BEFORE it
# mounts root (init/main.go), which is the required order; resume_offset= is
# consumed by the kernel's own __setup() and survives that write.
# hibernate.compressor=lz4 replaces the built-in default of lzo — lz4
# decompresses several times faster, and resume time is dominated by it.
HIBERNATE_ARGS=""
if [[ -n "$RESUME_OFFSET" ]]; then
    HIBERNATE_ARGS=" resume=UUID=__ROOT_FS_UUID__ resume_offset=${RESUME_OFFSET} hibernate.compressor=lz4"
fi
cat > /etc/kernel/cmdline <<CMDLINE_EOF
rd.luks.uuid=__LUKS_UUID__ root=UUID=__ROOT_FS_UUID__ rootfstype=f2fs rootflags=__ROOT_MOUNT_OPTS__ rw nowatchdog zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=25 zswap.shrinker_enabled=0${HIBERNATE_ARGS}
CMDLINE_EOF

# Secure Boot keys (sbctl) and the RSA pair that signs the PCR 11 policy.
# PCR 11 must be signed, not pinned: ukify re-signs it on every kernel build,
# so kernel updates never need TPM re-enrollment.
sbctl create-keys
# ukify is pointed at these by absolute path below; if a future sbctl changes
# the layout, catch it here instead of mid-build.
for f in /var/lib/sbctl/keys/db/db.key /var/lib/sbctl/keys/db/db.pem; do
    if [[ ! -f "$f" ]]; then
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

# Fail loudly here rather than at the first reboot: without a UKI on the ESP
# there is nothing for systemd-boot to find.
shopt -s nullglob
uki_built=(/boot/EFI/Linux/*.efi)
if (( ${#uki_built[@]} == 0 )); then
    echo "  !! No UKI was produced in /boot/EFI/Linux — the system will NOT boot." >&2
    echo "     Re-run '/usr/local/bin/uki-rebuild' and read its output before rebooting." >&2
    exit 1
fi
echo "  -> UKI(s): ${uki_built[*]}"
shopt -u nullglob

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

echo "  -> zswap: disable writeback everywhere (RAM-only, zram-like behaviour)"
# Writeback is a per-cgroup property with no global module parameter
# (mm/zswap.c exposes only enabled/compressor/max_pool_percent/
# accept_threshold_percent/shrinker_enabled). The kernel resolves it
# hierarchically, though — mem_cgroup_zswap_writeback_enabled() walks to the
# root and returns false if ANY ancestor has it off — and memory.zswap.writeback
# is one of the few memory.* files that exists on the ROOT cgroup (no
# CFTYPE_NOT_ON_ROOT flag). So one write to the root covers every cgroup, now
# and in the future, including anything systemd never manages.
#
# Done as a unit rather than tmpfiles because ordering matters: sysinit.target
# is After=swap.target, so swap units are already active before
# systemd-tmpfiles-setup runs. Before=swap.target closes that window.
cat > /etc/systemd/system/zswap-disable-writeback.service <<'ZSWAP_UNIT_EOF'
[Unit]
Description=Disable zswap writeback for every cgroup
DefaultDependencies=no
Before=sysinit.target swap.target
ConditionPathExists=/sys/fs/cgroup/memory.zswap.writeback

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sh -c 'echo 0 > /sys/fs/cgroup/memory.zswap.writeback'

[Install]
WantedBy=sysinit.target
ZSWAP_UNIT_EOF
systemctl enable zswap-disable-writeback.service

# Belt and braces: stop either manager writing 1 back into a unit's own knob.
# DefaultMemoryZSwapWriteback= (systemd 261+) is parsed from the SAME table for
# both managers (src/core/main.c parse_config_file), so one drop-in per manager
# covers every unit type — no need for the six per-type files the AUR package
# ships for older systemd.
for scope in system user; do
    mkdir -p "/etc/systemd/${scope}.conf.d"
    cat > "/etc/systemd/${scope}.conf.d/zswap-disable-writeback.conf" <<'ZSWAP_MGR_EOF'
[Manager]
DefaultMemoryZSwapWriteback=no
ZSWAP_MGR_EOF
done

# Reads come out of the compressed pool in RAM, not off the SSD, so the
# defaults tuned for disk swap are wrong: swap early, one page at a time, and
# give kswapd headroom so reclaim starts before allocation stalls.
cat > /etc/sysctl.d/99-swap.conf <<'SYSCTL_EOF'
vm.swappiness = 120
vm.page-cluster = 0
SYSCTL_EOF

echo "  -> Network sysctls"
# Deliberately no tcp_rmem/tcp_wmem/rmem_max pinning: the kernel autotunes
# tcp_rmem[2] far above the usual copy-pasted 16 MiB on a 16 GiB box, and the
# BDP here is ~1.25 MB (100 Mbps x 100 ms cafe Wi-Fi), ~7.5 MB even on a
# 300 Mbps/200 ms transatlantic path. Receive-buffer tuning is a 10-100 GbE
# concern. Check with: sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max
cat > /etc/sysctl.d/90-net-local.conf <<'NETCTL_EOF'
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

echo "  -> OOM handling (earlyoom)"
# Why earlyoom and not systemd-oomd, which is already installed: oomd kills a
# whole CGROUP. Hyprland is started straight from ly, so every application
# lives in one session-N.scope — an oomd kill would take the entire desktop
# with it. Per-app cgroups (uwsm, app-*.slice) would change that answer.
# earlyoom kills one process by badness instead, and polls /proc/meminfo on an
# adaptive 100-1000 ms sleep (1 s while memory is plentiful, i.e. always on
# battery), which is a rounding error next to the panel.
#
# This matters more than it would with plain disk swap: with zswap writeback
# disabled the SSD is never written, so when the pool and the swap slots are
# full the kernel simply cannot reclaim anon memory any further
# (mm/page_io.c returns AOP_WRITEPAGE_ACTIVATE and the page stays resident).
# The failure mode is a hard wall, not a slow thrash you can notice and react
# to — which is exactly the case a userspace OOM killer exists for.
#
# -r 0    no periodic memory report: kills are still logged, but an idle
#         laptop does not wake journald once an hour to write a stat line.
# -m/-s   percentages of MemAvailable / SwapFree; both must be under the
#         threshold before earlyoom acts. SwapFree is a good zswap gauge here
#         because a stored page holds its swap slot even though nothing is
#         written to disk.
# --avoid the session's own infrastructure: killing these logs you out and
#         costs more than the process that actually leaked.
# --prefer browser content processes: the usual memory hogs next to Godot, and
#         the cheapest thing on the machine to lose.
# No quotes inside EARLYOOM_ARGS: the unit passes it unquoted through systemd
# word splitting, so a quote would end up inside the regex and match nothing.
# The regexes are matched against /proc/PID/comm (kill.c: get_comm), which the
# kernel truncates to 15 characters — hence "Isolated Web Co" (Firefox content,
# exactly 15) and "WebKitWebProces" with no trailing s.
cat > /etc/default/earlyoom <<'EARLYOOM_EOF'
EARLYOOM_ARGS=-r 0 -m 5,3 -s 5,2 --avoid ^(Hyprland|ashell|hypridle|ly|systemd|dbus-.*)$ --prefer ^(firefox|chrom(e|ium)|electron|Isolated[[:space:]]Web[[:space:]]Co|WebKitWebProces|steam.*)$
EARLYOOM_EOF
systemctl enable earlyoom.service

echo "  -> Panel power saving (amdgpu ABM) on battery only"
# The 300-nit eDP panel is the single largest consumer on this machine. amdgpu
# exposes Adaptive Backlight Management per eDP connector as
# /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings (0-4, larger = dimmer
# and less colour-accurate). It is NOT set via amdgpu.abmlevel=: that module
# param locks the level for the whole boot, and the driver only accepts
# userspace writes while it is left at -1/auto.
cat > /usr/local/bin/panel-power-savings <<'PPS_EOF'
#!/bin/bash
# panel-power-savings [0-4|auto]
# auto: LEVEL_ON_BAT while discharging, 0 on AC.
# Colour accuracy matters for art work, so AC is always level 0. Drop
# LEVEL_ON_BAT to 1 if the shift bothers you on battery too, 0 to disable.
set -uo pipefail
LEVEL_ON_BAT=2

level="${1:-auto}"
if [[ "$level" == auto ]]; then
    level="$LEVEL_ON_BAT"
    for ac in /sys/class/power_supply/*/type; do
        [[ "$(< "$ac")" == Mains ]] || continue
        [[ "$(< "${ac%/type}/online")" == 1 ]] && level=0
    done
fi

shopt -s nullglob
for f in /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings; do
    # Writing this file forces a modeset, so never write the same value twice.
    [[ "$(< "$f")" == "$level" ]] && continue
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
After=multi-user.target

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

echo "  -> CPU scheduler service (enable only — pick a scheduler after first boot)"
# scx_loader.service lives in scx-tools, NOT scx-scheds (which is just the
# scheduler binaries). scxctl is the CLI that talks to it.
systemctl enable scx_loader.service

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

echo "  -> makepkg: escalate through doas, not the sudo shim"
# makepkg calls PACMAN_AUTH to install build deps. Left unset it looks for
# sudo, and the /usr/local/bin/sudo -> doas symlink is not a faithful enough
# stand-in (makepkg passes sudo-style flags doas rejects). Point it at doas
# directly. No -n: that would break interactive `makepkg -si` later, once the
# nopass policy below is reverted to `permit persist`.
mkdir -p /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/10-doas.conf <<'MAKEPKG_DOAS_EOF'
PACMAN_AUTH=(doas)
MAKEPKG_DOAS_EOF

echo "  -> Building ashell from the AUR (status bar + notification daemon)"
# ashell is AUR-only. makepkg refuses to run as root and escalates through
# PACMAN_AUTH (doas, set above) to install build deps, so the policy is relaxed
# to nopass for the duration of the build only.
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

# Parsed from --json, not from the human table: that output is colourised and
# its wording is not an API.
if [[ "$(sbctl status --json | jq -r .setup_mode)" != true ]]; then
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
# Gate on the exit status: an unsigned binary here means the next boot with
# Secure Boot enabled fails, and that is much better caught now.
if ! sbctl verify; then
    echo
    echo "Something on the ESP is NOT signed by your keys. Do NOT enable Secure" >&2
    echo "Boot yet. Sign the UKI with 'doas uki-rebuild', sign the loader with" >&2
    echo "  doas sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI" >&2
    echo "  doas sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi" >&2
    echo "then re-run 'sbctl verify' until every line is signed." >&2
    exit 1
fi

echo
echo "All green. Reboot, enable Secure Boot in the BIOS, and confirm with"
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

if [[ "$(sbctl status --json | jq -r .secure_boot)" != true ]]; then
    echo "Secure Boot is not enabled yet — run secureboot-enroll first, then" >&2
    echo "enable Secure Boot in the BIOS and boot back in." >&2
    exit 1
fi

# The signed-PCR-11 policy only works if the UKI actually carries a .pcrsig
# section: at boot systemd-stub unpacks it to /.extra/tpm2-pcr-signature.json
# inside the initramfs, which is where booster reads it. That path is gone by
# the time this script runs (booster is not a systemd initrd and does not copy
# it to /run), so the signature is pulled straight out of the running kernel's
# own image instead — both as the existence check and, below, as
# systemd-cryptenroll's safety net.
UKI="/boot/EFI/Linux/arch-$(uname -r).efi"
if [[ ! -f "$UKI" ]]; then
    shopt -s nullglob
    ukis=(/boot/EFI/Linux/*.efi)
    shopt -u nullglob
    (( ${#ukis[@]} == 1 )) && UKI="${ukis[0]}"
fi
if [[ ! -f "$UKI" ]]; then
    echo "Cannot identify the running UKI in /boot/EFI/Linux." >&2
    echo "Run 'doas uki-rebuild', reboot, then re-run this." >&2
    exit 1
fi
echo "UKI: $UKI"

PCRSIG="$(mktemp)"
trap 'rm -f "$PCRSIG"' EXIT
if ! objcopy -O binary --only-section=.pcrsig "$UKI" "$PCRSIG" 2>/dev/null || [[ ! -s "$PCRSIG" ]]; then
    echo "$UKI carries no .pcrsig section — it was built without a signed PCR" >&2
    echo "policy, and the enrolled token could never be satisfied. Check" >&2
    echo "[PCRSignature:initrd] in /etc/kernel/uki.conf, run 'doas uki-rebuild'," >&2
    echo "reboot, then re-run this." >&2
    exit 1
fi

# PCR 7  : Secure Boot policy (which keys are enrolled)
# PCR 11 : the UKI itself, bound by SIGNATURE rather than by value, so a
#          kernel update re-signs it and needs no re-enrollment
# PCR 15 : all-zero latch, booster extends it after unlocking so a second
#          "supplanted" volume cannot re-unseal the same key
# --wipe-slot=tpm2 makes this idempotent: re-running after a firmware update
# replaces the old token instead of stacking a second, stale one.
# --tpm2-signature= is systemd-cryptenroll's safety net: it replays the policy
# against the CURRENT PCR state before writing the slot and refuses if the
# combination would not actually unlock. Without it "no such verification is
# done" (systemd-cryptenroll(1)) — and the file it would otherwise look for,
# /run/systemd/tpm2-pcr-signature.json, only exists under a systemd initrd.
systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto \
    --tpm2-pcrs=7+15:sha256=0000000000000000000000000000000000000000000000000000000000000000 \
    --tpm2-public-key=/etc/kernel/pcr-public.pem --tpm2-public-key-pcrs=11 \
    --tpm2-signature="$PCRSIG" \
    "$LUKS_DEV"

echo "== enrolled tokens =="
cryptsetup luksDump "$LUKS_DEV" | grep -A2 -E "^Tokens:|systemd-tpm2" || true

echo
echo "Enrolled. The passphrase keyslot is untouched and remains your recovery"
echo "path. Reboot to confirm the disk unlocks with no prompt."
echo "If a firmware update ever breaks it: enter the passphrase and just"
echo "re-run this script — it wipes the old tpm2 slot before enrolling."
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
#
# NOT via arch-chroot: it bind-mounts the host's /etc/resolv.conf over the
# chroot's for the duration of each invocation, so replacing the file from
# inside fails with EBUSY ("Device or resource busy"). Outside the chroot the
# bind mount is gone and it is an ordinary file.
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
