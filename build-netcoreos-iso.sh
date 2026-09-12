#!/bin/bash
set -euo pipefail
LOCAL_REPO="/media/user/SC/localrepo"
OUTPUT_DIR="/media/user/SC/netcoreos-live"
NETCOREOS_DIR="$(dirname "$(realpath "$0")")"
WORK_DIR="/mnt/netcoreos-build"
ROOTFS="${WORK_DIR}/rootfs"
ISO_STAGE="${WORK_DIR}/iso"
ISO_NAME="netcoreos-trixie-amd64.iso"
DEBIAN_MIRROR="file://${LOCAL_REPO}"
DEBIAN_SUITE="trixie"
ARCH="amd64"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
[[ $EUID -ne 0 ]] && err "Must run as root: sudo bash $0"
step "Checking build dependencies"
MISSING=()
for dep in debootstrap mksquashfs xorriso grub-mkstandalone \
           grub-mkrescue mkfs.vfat dpkg-scanpackages apt-ftparchive; do
    command -v "$dep" &>/dev/null || MISSING+=("$dep")
done
dpkg -l grub-pc-bin      &>/dev/null || MISSING+=("grub-pc-bin")
dpkg -l grub-efi-amd64-bin &>/dev/null || MISSING+=("grub-efi-amd64-bin")
if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "Missing: ${MISSING[*]}"
    echo -e "Install with:"
    echo -e "  apt install debootstrap squashfs-tools xorriso grub-pc-bin \\"
    echo -e "              grub-efi-amd64-bin grub-common dosfstools dpkg-dev apt-utils"
    err "Install missing deps then re-run."
fi
log "All build dependencies present."
step "Checking NetCoreOS source files"
[[ -f "${NETCOREOS_DIR}/netcoreos.sh" ]]         || err "netcoreos.sh not found in ${NETCOREOS_DIR}"
[[ -f "${NETCOREOS_DIR}/netcoreos_webui.py" ]]   || err "netcoreos_webui.py not found in ${NETCOREOS_DIR}"
log "Found netcoreos.sh and netcoreos_webui.py"
step "Checking local .deb repository"
[[ -d "${LOCAL_REPO}" ]] || err "Local repo not found: ${LOCAL_REPO}"
REPO_BINDIR="${LOCAL_REPO}/dists/${DEBIAN_SUITE}/main/binary-${ARCH}"
REPO_RELEASE="${LOCAL_REPO}/dists/${DEBIAN_SUITE}/Release"
command -v dpkg-scanpackages &>/dev/null || err "dpkg-scanpackages not found. Install the dpkg-dev .deb package."
command -v apt-ftparchive &>/dev/null    || err "apt-ftparchive not found. Install the apt-utils .deb package."
DEB_COUNT=$(find "${LOCAL_REPO}" -name "*.deb" | wc -l)
(( DEB_COUNT == 0 )) && err "No .deb files found anywhere under ${LOCAL_REPO}"
mkdir -p "${REPO_BINDIR}"
( cd "${LOCAL_REPO}" && dpkg-scanpackages --arch "${ARCH}" . /dev/null 2>/dev/null ) \
    > "${REPO_BINDIR}/Packages"
[[ -s "${REPO_BINDIR}/Packages" ]] || err "Failed to generate Packages index (found ${DEB_COUNT} .deb files but scan produced nothing — check they're valid .deb packages)."
gzip -9k -f "${REPO_BINDIR}/Packages"
log "Packages index refreshed (${DEB_COUNT} .deb file(s) found) at ${REPO_BINDIR}"
rm -f "${REPO_RELEASE}" "${LOCAL_REPO}/dists/${DEBIAN_SUITE}/InRelease"
( cd "${LOCAL_REPO}" && apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="NetCoreOS" \
    -o APT::FTPArchive::Release::Label="NetCoreOS Local Repo" \
    -o APT::FTPArchive::Release::Suite="${DEBIAN_SUITE}" \
    -o APT::FTPArchive::Release::Codename="${DEBIAN_SUITE}" \
    -o APT::FTPArchive::Release::Architectures="${ARCH}" \
    -o APT::FTPArchive::Release::Components="main" \
    release "dists/${DEBIAN_SUITE}" ) \
    > "${REPO_RELEASE}"
grep -q "^Codename: ${DEBIAN_SUITE}$" "${REPO_RELEASE}" 2>/dev/null \
    || err "Generated Release file is missing Codename: ${DEBIAN_SUITE} — apt-ftparchive output looked wrong, check it manually: ${REPO_RELEASE}"
log "Release file refreshed (matching current Packages) at ${REPO_RELEASE}"
log "Local repo OK: ${LOCAL_REPO}"
step "Preparing build workspace"
if [[ -d "${WORK_DIR}" ]]; then
    warn "Cleaning previous build at ${WORK_DIR}..."
    for MP in "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev/pts" "${ROOTFS}/dev"; do
        mountpoint -q "$MP" && umount -lf "$MP" 2>/dev/null || true
    done
    if mountpoint -q "${WORK_DIR}"; then
        find "${WORK_DIR:?}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    else
        rm -rf "${WORK_DIR}"
    fi
fi
mkdir -p "${ROOTFS}" "${ISO_STAGE}/live" "${ISO_STAGE}/boot/grub" "${OUTPUT_DIR}"
log "Build workspace: ${WORK_DIR}"
step "STEP 1 / 7  —  Bootstrapping Debian ${DEBIAN_SUITE} (${ARCH})"
log "This may take a few minutes..."
INCLUDE_PKGS="linux-image-amd64,live-boot,live-boot-initramfs-tools,\
initramfs-tools,systemd,systemd-sysv,dbus,bash,coreutils,util-linux,\
iproute2,iptables,nftables,bridge-utils,dnsmasq,tcpdump,ethtool,\
net-tools,iputils-ping,traceroute,curl,wget,ca-certificates,\
python3,python3-minimal,iw,wireless-tools,wpasupplicant,\
openssh-server,vim,nano,less,grep,sed,gawk,procps,psmisc,\
htop,lsof,pcp,nmap,iperf3,wireguard,wireguard-tools,\
mstpd,keepalived,frr,frr-pythontools,vlan,\
ebtables,arptables,ipset,conntrack,\
whois,strongswan,chrony,\
kmod,pciutils,usbutils,hdparm,smartmontools,\
tar,gzip,bzip2,xz-utils,zip,unzip,\
parted,e2fsprogs,ncurses-bin,\
sudo,passwd,adduser,login,\
grub-pc,grub-efi-amd64,grub-common,efibootmgr,\
locales,tzdata,console-setup"
log "Checking that every explicitly-listed package has a real .deb file in the local repo..."
PKGS_INDEX="${REPO_BINDIR}/Packages"
MISSING_PKGS=()
IFS=',' read -ra WANT_PKGS <<< "$(echo "$INCLUDE_PKGS" | tr -d '\n\\')"
for PKG in "${WANT_PKGS[@]}"; do
    PKG="$(echo "$PKG" | xargs)"
    [[ -z "$PKG" ]] && continue
    FN=$(awk -v p="$PKG" '
        $0 == "Package: " p { found=1 }
        found && /^Filename:/ { print $2; exit }
        /^$/ { found=0 }
    ' "$PKGS_INDEX")
    if [[ -z "$FN" ]]; then
        MISSING_PKGS+=("$PKG (no Packages entry)")
    elif [[ ! -f "${LOCAL_REPO}/${FN}" ]]; then
        MISSING_PKGS+=("$PKG (indexed but file missing: ${FN})")
    fi
done
if (( ${#MISSING_PKGS[@]} > 0 )); then
    warn "The following packages are not usable from ${LOCAL_REPO}:"
    for M in "${MISSING_PKGS[@]}"; do echo "    - $M"; done
    err "Add the missing .deb file(s) above to ${LOCAL_REPO} (any subfolder is fine), then re-run this script."
fi
log "All explicitly-listed packages are present. (Note: this does not check transitive dependencies — if debootstrap still reports 'Couldn't find these debs' for OTHER package names below, those are dependencies pulled in automatically; add those .deb files too and re-run.)"
debootstrap \
    --arch="${ARCH}" \
    --include="${INCLUDE_PKGS}" \
    --no-check-gpg \
    "${DEBIAN_SUITE}" \
    "${ROOTFS}" \
    "${DEBIAN_MIRROR}" \
    || err "debootstrap failed. Check your local repo and mirror path."
log "Bootstrap complete."
step "STEP 2 / 7  —  Configuring rootfs"
mount --bind /dev     "${ROOTFS}/dev"
mount --bind /dev/pts "${ROOTFS}/dev/pts"
mount -t proc  proc   "${ROOTFS}/proc"
mount -t sysfs sysfs  "${ROOTFS}/sys"
cat > "${ROOTFS}/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${ROOTFS}/usr/sbin/policy-rc.d"
echo "netcoreos" > "${ROOTFS}/etc/hostname"
cat > "${ROOTFS}/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   netcoreos
::1         localhost ip6-localhost ip6-loopback
EOF
chroot "${ROOTFS}" /bin/bash -c "
    echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8
" 2>/dev/null || warn "locale-gen skipped (may not be available)"
chroot "${ROOTFS}" /bin/bash -c "
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    echo 'UTC' > /etc/timezone
" 2>/dev/null || true
chroot "${ROOTFS}" /bin/bash -c "echo 'root:ncos' | chpasswd" 2>/dev/null || warn "Failed to set root password."
cat > "${ROOTFS}/etc/fstab" << 'EOF'
tmpfs   /var/tmp  tmpfs   defaults,noatime    0  0
EOF
# /tmp is intentionally NOT listed here: systemd already provides its own
# tmp.mount for /tmp by default, and also listing it in /etc/fstab causes
# systemd-fstab-generator to report a duplicate-entry warning at boot.
log "Base configuration done."
step "STEP 3 / 7  —  Installing NetCoreOS"
mkdir -p "${ROOTFS}/opt/netcoreos"
install -m 755 "${NETCOREOS_DIR}/netcoreos.sh"       "${ROOTFS}/opt/netcoreos/netcoreos.sh"
install -m 755 "${NETCOREOS_DIR}/netcoreos_webui.py" "${ROOTFS}/opt/netcoreos/netcoreos_webui.py"
ln -sf /opt/netcoreos/netcoreos.sh "${ROOTFS}/usr/local/bin/netcoreos"
mkdir -p "${ROOTFS}/var/lib/netcoreos"
mkdir -p "${ROOTFS}/etc/systemd/system"
for T in tty1 tty2 tty3 tty4 tty5 tty6; do
    mkdir -p "${ROOTFS}/etc/systemd/system/getty@${T}.service.d"
    cat > "${ROOTFS}/etc/systemd/system/getty@${T}.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
EOF
done
cat > "${ROOTFS}/root/.bash_profile" << 'EOF'
CURRENT_TTY="$(tty 2>/dev/null)"
if [[ "$CURRENT_TTY" =~ ^/dev/tty[1-6]$ ]] || [[ -n "$SSH_CONNECTION" ]]; then
    while true; do
        /opt/netcoreos/netcoreos.sh
        EXIT_CODE=$?
        echo "$(date '+%Y-%m-%d %H:%M:%S') netcoreos.sh exited with code ${EXIT_CODE} on ${CURRENT_TTY}" \
            >> /var/lib/netcoreos/crash.log 2>/dev/null
        sleep 1
    done
fi
EOF
cat > "${ROOTFS}/etc/motd" << 'EOF'

  NetCoreOS — Network Control OS
  Type 'netcoreos' to launch, or it starts automatically.

EOF
log "NetCoreOS installed to /opt/netcoreos"
step "STEP 4 / 7  —  Configuring networking & kernel modules"
cat > "${ROOTFS}/etc/modules-load.d/netcoreos.conf" << 'EOF'
8021q
bonding
bridge
vxlan
ip_tables
ip6_tables
iptable_nat
iptable_filter
nf_conntrack
ebtables
wireguard
dummy
tun
EOF
cat > "${ROOTFS}/etc/sysctl.d/99-netcoreos.conf" << 'EOF'
net.ipv4.ip_forward=0
net.ipv6.conf.all.forwarding=0
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.core.netdev_max_backlog=5000
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.neigh.default.gc_thresh1=512
net.ipv4.neigh.default.gc_thresh2=1024
net.ipv4.neigh.default.gc_thresh3=2048
vm.swappiness=10
EOF
chroot "${ROOTFS}" /bin/bash -c "
    systemctl disable systemd-networkd 2>/dev/null || true
    systemctl disable NetworkManager  2>/dev/null || true
    systemctl disable wpa_supplicant  2>/dev/null || true
" 2>/dev/null || true
chroot "${ROOTFS}" /bin/bash -c "systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true"
if grep -q '^PermitRootLogin' "${ROOTFS}/etc/ssh/sshd_config" 2>/dev/null; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "${ROOTFS}/etc/ssh/sshd_config"
elif grep -q '^#PermitRootLogin' "${ROOTFS}/etc/ssh/sshd_config" 2>/dev/null; then
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "${ROOTFS}/etc/ssh/sshd_config"
else
    echo "PermitRootLogin yes" >> "${ROOTFS}/etc/ssh/sshd_config"
fi
log "SSH enabled, root password login allowed."
log "Network configuration done."
step "STEP 5 / 7  —  Rebuilding initramfs with live-boot"
mkdir -p "${ROOTFS}/etc/live"
cat > "${ROOTFS}/etc/live/config.conf" << 'EOF'
LIVE_USERNAME="root"
LIVE_USER_FULLNAME="NetCoreOS"
LIVE_USER_DEFAULT_GROUPS="audio cdrom dip floppy video plugdev netdev sudo"
LIVE_LOCALES="en_US.UTF-8"
LIVE_TIMEZONE="UTC"
LIVE_KEYBOARD_LAYOUTS="us"
LIVE_BOOT_APPEND="quiet splash"
EOF
cat >> "${ROOTFS}/etc/initramfs-tools/modules" << 'EOF'
loop
squashfs
overlay
isofs
sr_mod
cdrom
usb-storage
ahci
ata_piix
EOF
sed -i 's/^MODULES=.*/MODULES=most/' "${ROOTFS}/etc/initramfs-tools/initramfs.conf" 2>/dev/null || \
    echo 'MODULES=most' >> "${ROOTFS}/etc/initramfs-tools/initramfs.conf"
KERNEL_VER=$(ls "${ROOTFS}/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
if [[ -z "$KERNEL_VER" ]]; then
    err "No kernel found in rootfs. Check debootstrap package list."
fi
log "Found kernel: ${KERNEL_VER}"
chroot "${ROOTFS}" /bin/bash -c "
    update-initramfs -u -k '${KERNEL_VER}' 2>&1 | tail -5
" || warn "initramfs update had warnings (may be OK)"
log "Initramfs rebuilt."
step "STEP 6 / 7  —  Building squashfs filesystem"
for MP in "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev/pts" "${ROOTFS}/dev"; do
    mountpoint -q "$MP" && umount -lf "$MP" 2>/dev/null || true
done
rm -f "${ROOTFS}/usr/sbin/policy-rc.d"
chroot "${ROOTFS}" /bin/bash -c "
    apt-get clean 2>/dev/null || true
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb 2>/dev/null || true
    find /var/log -type f -delete 2>/dev/null || true
    rm -rf /tmp/* 2>/dev/null || true
" 2>/dev/null || true
for D in proc sys dev; do
    mkdir -p "${ROOTFS}/${D}"
done
log "Compressing rootfs to squashfs (this takes a while)..."
mksquashfs "${ROOTFS}" "${ISO_STAGE}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -no-progress \
    -wildcards \
    -e "proc/*" \
    -e "sys/*" \
    -e "dev/*" \
    2>/dev/null
SQFS_SIZE=$(du -sh "${ISO_STAGE}/live/filesystem.squashfs" | awk '{print $1}')
log "squashfs created: ${SQFS_SIZE}"
cp "${ROOTFS}/boot/vmlinuz-${KERNEL_VER}"     "${ISO_STAGE}/live/vmlinuz"
cp "${ROOTFS}/boot/initrd.img-${KERNEL_VER}"  "${ISO_STAGE}/live/initrd.img"
log "Kernel and initrd copied."
step "STEP 7 / 7  —  Building bootable ISO with GRUB (EFI + BIOS hybrid)"
cat > "${ISO_STAGE}/boot/grub/grub.cfg" << 'GRUBCFG'
set default=0
set timeout=3
set timeout_style=menu
terminal_input  console
terminal_output console
set gfxpayload=keep
set color_normal=cyan/black
set color_highlight=black/cyan
search --no-floppy --set=root --file /live/vmlinuz

menuentry "NetCoreOS — Network Control OS" --class netcoreos --class os {
    echo "  Loading NetCoreOS..."
    linux   /live/vmlinuz \
            boot=live \
            components \
            quiet \
            console=tty1 \
            systemd.unit=multi-user.target \
            rd.systemd.show_status=false
    echo "  Loading initrd..."
    initrd  /live/initrd.img
}

menuentry "NetCoreOS — Persistent Mode (saves changes)" --class netcoreos {
    echo "  Loading NetCoreOS with persistence..."
    linux   /live/vmlinuz \
            boot=live \
            components \
            quiet \
            console=tty1 \
            systemd.unit=multi-user.target \
            rd.systemd.show_status=false \
            persistence \
            persistence-encryption=none
    echo "  Loading initrd..."
    initrd  /live/initrd.img
}

menuentry "NetCoreOS — Verbose Boot (debug)" --class netcoreos {
    linux   /live/vmlinuz \
            boot=live \
            components \
            console=tty1 \
            systemd.unit=multi-user.target
    initrd  /live/initrd.img
}

menuentry "NetCoreOS — Memory Test (memtest86+)" --class memtest {
    linux16 /boot/memtest86+.bin
}

menuentry "Reboot" --class reboot {
    reboot
}

menuentry "Power Off" --class shutdown {
    halt
}
GRUBCFG
mkdir -p "${ISO_STAGE}/EFI/boot"
EFI_IMG="${ISO_STAGE}/boot/grub/efi.img"
dd if=/dev/zero of="${EFI_IMG}" bs=1M count=16 2>/dev/null
mkfs.vfat "${EFI_IMG}" >/dev/null
mmd -i "${EFI_IMG}" EFI EFI/BOOT >/dev/null 2>&1 || true
grub-mkstandalone \
    --format=x86_64-efi \
    --output="${WORK_DIR}/bootx64.efi" \
    --modules="part_gpt part_msdos fat iso9660 linux normal \
               configfile loopback chain halt reboot memdisk \
               test all_video font gfxterm gfxterm_background \
               gfxterm_menu echo sleep png jpeg \
               search search_fs_file search_fs_uuid search_label" \
    --locales="" \
    --themes="" \
    "boot/grub/grub.cfg=${ISO_STAGE}/boot/grub/grub.cfg" \
    2>/dev/null || warn "grub-mkstandalone EFI had warnings"
mcopy -i "${EFI_IMG}" "${WORK_DIR}/bootx64.efi" "::EFI/BOOT/bootx64.efi" 2>/dev/null || {
    mkdir -p "${WORK_DIR}/efi-mnt"
    mount -o loop "${EFI_IMG}" "${WORK_DIR}/efi-mnt" 2>/dev/null && {
        mkdir -p "${WORK_DIR}/efi-mnt/EFI/BOOT"
        cp "${WORK_DIR}/bootx64.efi" "${WORK_DIR}/efi-mnt/EFI/BOOT/"
        umount "${WORK_DIR}/efi-mnt"
    } || warn "EFI image population failed — EFI boot may not work"
}
mkdir -p "${ISO_STAGE}/EFI/BOOT"
cp "${WORK_DIR}/bootx64.efi" "${ISO_STAGE}/EFI/BOOT/bootx64.efi" 2>/dev/null || true
log "EFI boot image built."
grub-mkstandalone \
    --format=i386-pc \
    --output="${WORK_DIR}/core.img" \
    --modules="biosdisk part_msdos part_gpt iso9660 linux \
               normal configfile loopback chain halt reboot \
               memdisk test echo sleep all_video font gfxterm \
               search search_fs_file search_fs_uuid search_label" \
    --locales="" \
    --themes="" \
    "boot/grub/grub.cfg=${ISO_STAGE}/boot/grub/grub.cfg" \
    2>/dev/null || warn "grub-mkstandalone BIOS had warnings"
cat /usr/lib/grub/i386-pc/cdboot.img "${WORK_DIR}/core.img" \
    > "${ISO_STAGE}/boot/grub/bios.img" 2>/dev/null || \
    warn "Could not find cdboot.img — BIOS El Torito boot may not work"
log "BIOS boot image built."
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME}"
log "Assembling final ISO: ${ISO_PATH}"
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "NETCOREOS" \
    -preparer "NetCoreOS Build" \
    -appid "NetCoreOS Live" \
    -publisher "NetCoreOS" \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-catalog boot/grub/boot.cat \
    -b boot/grub/bios.img \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -isohybrid-apm-hfsplus \
    -o "${ISO_PATH}" \
    "${ISO_STAGE}" \
    2>/dev/null
isohybrid --uefi "${ISO_PATH}" 2>/dev/null || \
    isohybrid "${ISO_PATH}" 2>/dev/null || \
    warn "isohybrid not available — USB dd boot may need manual setup"
ISO_SIZE=$(du -sh "${ISO_PATH}" 2>/dev/null | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║          NetCoreOS ISO Build Complete!           ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ISO   : ${CYAN}${ISO_PATH}${NC}"
echo -e "  Size  : ${BOLD}${ISO_SIZE}${NC}"
echo -e "  Kernel: ${KERNEL_VER}"
echo ""
echo -e "${BOLD}Flash to USB:${NC}"
echo -e "  sudo dd if=${ISO_PATH} of=/dev/sdX bs=4M status=progress oflag=sync"
echo -e "  (replace /dev/sdX with your USB device)"
