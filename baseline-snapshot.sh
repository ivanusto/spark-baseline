#!/bin/sh
# baseline-snapshot.sh: capture the describable state of a DGX Spark (or any
# Ubuntu-based GPU node) into a directory of plain text files, one per topic,
# so two snapshots can be compared with diff -r.
#
# Usage:  baseline-snapshot.sh [OUT_DIR]
#         default OUT_DIR is ./baseline/<hostname>/<UTC timestamp>
#
# No root required for most sections; sections that need root (sshd -T,
# sudoers, ufw rules) are attempted with sudo -n and skipped with a note if
# sudo would prompt. Nothing is modified. Every command is wrapped so a missing
# tool produces a one-line note instead of a failure.
#
# Output is kept stable on purpose: no timestamps, PIDs, inodes or usage
# figures inside the topic files, so that diff shows configuration drift and
# not the passage of time. The capture time lives in 99-summary.txt only.
set -u

HOST=$(hostname -s 2>/dev/null || hostname)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="${1:-./baseline/$HOST/$STAMP}"
mkdir -p "$OUT" || exit 1

# Packages that section 4 of the write-up pins with apt-mark hold: the driver
# branch, the kernel and its prebuilt modules, CUDA and NCCL, docker and the
# NVIDIA container toolkit, and the RDMA user space plus NIC firmware manager.
# Replace 580 with your driver branch.
PIN_RE='^(linux-(image|headers|modules|modules-nvidia-[0-9]+-open|modules-nvidia-fs|tools)-.*nvidia|linux-nvidia-|(lib)?nvidia-.*-580|xserver-xorg-video-nvidia-580|cuda-|libnccl|docker-|containerd|nvidia-container-toolkit|rdma-core|ibverbs-|libibverbs|librdmacm|rdmacm-utils|libibmad|libibumad|perftest|nvidia-spark-mlnx-firmware-manager)'

# run <file> <command...>: capture stdout+stderr, note missing commands.
run() {
    F="$OUT/$1"; shift
    if command -v "$1" >/dev/null 2>&1; then
        "$@" > "$F" 2>&1 || echo "[exit $?]" >> "$F"
    else
        echo "[missing: $1]" > "$F"
    fi
}

# sudo_run: same, via sudo -n (never prompts). Skipped if sudo needs a password.
sudo_run() {
    F="$OUT/$1"; shift
    if sudo -n true 2>/dev/null; then
        # shellcheck disable=SC2024 # the redirect is meant to run as the user
        sudo -n "$@" > "$F" 2>&1 || echo "[exit $?]" >> "$F"
    else
        echo "[skipped: sudo would prompt]" > "$F"
    fi
}

# ---------------------------------------------------------------- identity
{
    echo "hostname=$(hostname)"
    echo "kernel=$(uname -r)"
    echo "arch=$(uname -m)"
    [ -f /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
    # The serial number is masked: snapshots are meant to go into git.
    [ -f /etc/dgx-release ] && sed -e 's/^\(DGX_SERIAL_NUMBER=\).*/\1"<masked>"/' -e 's/^/dgx-release: /' /etc/dgx-release
    [ -r /sys/class/dmi/id/product_name ] && echo "product=$(cat /sys/class/dmi/id/product_name)"
    [ -r /sys/class/dmi/id/bios_version ] && echo "bios=$(cat /sys/class/dmi/id/bios_version)"
} > "$OUT/00-identity.txt" 2>/dev/null

# ---------------------------------------------------------------- gpu / driver
# Settings only; plain nvidia-smi prints temperatures and processes, which
# would make every diff noisy.
run 10-nvidia-smi.txt nvidia-smi --query-gpu=name,pci.bus_id,persistence_mode,compute_mode,power.default_limit,power.limit,clocks.max.graphics,clocks.max.memory,mig.mode.current --format=csv
run 11-nvidia-driver.txt nvidia-smi --query-gpu=name,driver_version,vbios_version,compute_cap --format=csv
# nvcc is often only in /usr/local/cuda/bin, which a non-login shell lacks
if command -v nvcc >/dev/null 2>&1; then run 12-nvcc.txt nvcc --version
else run 12-nvcc.txt /usr/local/cuda/bin/nvcc --version; fi
if [ -r /proc/driver/nvidia/version ]; then
    cp /proc/driver/nvidia/version "$OUT/13-nvrm-version.txt"
else
    echo "[missing: /proc/driver/nvidia/version]" > "$OUT/13-nvrm-version.txt"
fi

# ---------------------------------------------------------------- packages
# shellcheck disable=SC2016 # dpkg format string, not shell
run 20-dpkg-all.txt dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n'
# shellcheck disable=SC2016
dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 2>/dev/null \
    | awk -F'\t' '$1 ~ /^ii/ {print $2"\t"$3}' | grep -E "$PIN_RE" \
    > "$OUT/21-dpkg-pinned-candidates.txt"
run 22-apt-hold.txt apt-mark showhold
cat /etc/apt/sources.list /etc/apt/sources.list.d/* > "$OUT/23-apt-sources.txt" 2>/dev/null
{
    dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' unattended-upgrades 2>&1
    cat /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/50unattended-upgrades 2>&1
} > "$OUT/24-unattended.txt"

# ---------------------------------------------------------------- accounts / access
awk -F: '$3 >= 1000 && $3 < 65534 {print $1":"$3":"$4":"$7}' /etc/passwd > "$OUT/30-users.txt"
getent group sudo docker adm sshusers 2>/dev/null > "$OUT/31-privileged-groups.txt"
awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | while IFS= read -r U; do
    H=$(getent passwd "$U" | cut -d: -f6)
    if [ -r "$H/.ssh/authorized_keys" ]; then
        # key type + comment only, options and key material are left out
        echo "== $U"
        grep -oE '(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+( .*)?$' "$H/.ssh/authorized_keys" \
            | awk '{c=""; for (i = 3; i <= NF; i++) c = c (i > 3 ? " " : "") $i; print $1, c}'
    fi
done > "$OUT/32-authorized-keys.txt" 2>/dev/null
sudo_run 33-sshd-effective.txt sshd -T
# Content hashes, readable without root, so drift in sshd config shows up
# even when 33 was skipped.
sha256sum /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* > "$OUT/34-sshd-dropins.txt" 2>&1
sudo_run 35-sudoers.txt sh -c 'cat /etc/sudoers; ls -1 /etc/sudoers.d; cat /etc/sudoers.d/*'

# ---------------------------------------------------------------- network
run 40-ip-addr.txt ip -brief addr
run 41-ip-route.txt ip route
run 42-ip-link.txt ip -details link
for I in /sys/class/net/*; do
    N=$(basename "$I"); [ "$N" = lo ] && continue
    [ -e "$I/device" ] || continue   # physical NICs only, skip bridges and veths
    D=$(ethtool -i "$N" 2>/dev/null | awk -F': ' '$1=="driver"{d=$2} $1=="firmware-version"{f=$2} END{print "driver=" d " firmware=" f}')
    echo "$N speed=$(cat "$I/speed" 2>/dev/null) mtu=$(cat "$I/mtu" 2>/dev/null) state=$(cat "$I/operstate" 2>/dev/null) $D"
done > "$OUT/43-link-speed.txt"
run 44-rdma.txt rdma link
if sudo -n true 2>/dev/null; then
    run 45-ufw.txt sudo -n ufw status verbose
else
    { echo "[skipped: sudo would prompt]"; grep -H '^ENABLED' /etc/ufw/ufw.conf 2>&1; } > "$OUT/45-ufw.txt"
fi
# ports from the ephemeral range (NCCL, ray, debuggers) are left out
run 46-listening.txt sh -c "ss -tulnH | awk '{n = split(\$5, a, \":\"); if (a[n] + 0 < 32768) print}' | sort"
run 47-resolv.txt sh -c 'resolvectl status | sed -n "1,/^\$/p"; resolvectl dns | grep -v ": *\$"'
run 48-timesync.txt timedatectl show-timesync --property=NTP --property=FallbackNTPServers --property=SystemNTPServers --property=LinkNTPServers

# ---------------------------------------------------------------- storage
run 50-lsblk.txt lsblk -e 7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL   # -e 7: no snap loop devices
run 51-df.txt df -hT --output=source,fstype,size,target
[ -f /etc/fstab ] && cp /etc/fstab "$OUT/52-fstab.txt"
run 53-nfs-mounts.txt sh -c 'findmnt -t nfs,nfs4 -o TARGET,SOURCE,OPTIONS | sed "s/clientaddr=[^,]*,//"'
run 54-swap.txt sh -c 'swapon --show=NAME,TYPE,SIZE,PRIO; cat /proc/sys/vm/swappiness'

# ---------------------------------------------------------------- services / containers
run 60-services-enabled.txt sh -c 'systemctl list-unit-files --state=enabled --no-pager --no-legend | grep -v "^snap-.*\.mount "'
run 61-services-running.txt systemctl list-units --type=service --state=running --no-pager --no-legend --plain
# shellcheck disable=SC2016 # Go template, not shell
run 62-docker-info.txt docker info --format 'server={{.ServerVersion}} storage={{.Driver}} cgroup={{.CgroupDriver}} v{{.CgroupVersion}} default_runtime={{.DefaultRuntime}} runtimes={{range $k, $v := .Runtimes}}{{$k}} {{end}}'
run 63-docker-images.txt sh -c "docker images --digests --format '{{.Repository}}:{{.Tag}}\t{{.Digest}}' | sort"
run 64-docker-ps.txt sh -c "docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.State}}' | sort"
run 65-crontab.txt crontab -l
run 66-sysctl.txt sh -c 'sysctl vm.swappiness vm.overcommit_memory kernel.panic net.core.rmem_max net.core.wmem_max 2>/dev/null'

# ---------------------------------------------------------------- summary
{
    echo "snapshot: $OUT"
    echo "captured_utc=$STAMP"
    echo "files: $(find "$OUT" -type f ! -name 99-summary.txt | wc -l) (+ this summary)"
    grep -l 'missing:\|skipped:' "$OUT"/* 2>/dev/null | sed 's/^/incomplete: /'
} > "$OUT/99-summary.txt"
cat "$OUT/99-summary.txt"
