#!/bin/sh
# harden-ssh.sh: apply the SSH drop-in safely. Idempotent. Refuses to reload
# sshd unless $ADMIN_USER is in the sshusers group and has at least one
# authorized key, and unless sshd -t and sshd -T confirm the result. On any
# failed check the previous drop-in is restored, so a bad file is never left
# behind for the next boot to pick up.
#
# Usage: sudo ADMIN_USER=<name> ./harden-ssh.sh
set -eu

ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
SRC="$(dirname "$0")/10-hardening.conf"
DST=/etc/ssh/sshd_config.d/10-hardening.conf

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }
[ -n "$ADMIN_USER" ] || { echo "set ADMIN_USER=<account that must keep SSH access>"; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }

HOME_DIR=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
[ -n "$HOME_DIR" ] || { echo "no such user: $ADMIN_USER"; exit 1; }
# A key line may start with options such as from="..." before the key type.
if ! grep -qE '(^|[[:space:]])(ssh-(ed25519|rsa)|ecdsa-sha2-[a-z0-9]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/]' "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null; then
    echo "$ADMIN_USER has no key in $HOME_DIR/.ssh/authorized_keys; add one first (password login will be disabled)."
    exit 1
fi

getent group sshusers >/dev/null || groupadd sshusers
id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx sshusers || usermod -aG sshusers "$ADMIN_USER"

# Keep the previous drop-in (if any) so a failed check can put it back.
BACKUP=""
if [ -f "$DST" ]; then
    BACKUP=$(mktemp)
    cp -p "$DST" "$BACKUP"
fi
rollback() {
    if [ -n "$BACKUP" ]; then
        mv "$BACKUP" "$DST"
        echo "$1; previous $DST restored, sshd not reloaded"
    else
        rm -f "$DST"
        echo "$1; $DST removed, sshd not reloaded"
    fi
    exit 1
}

install -m 0644 -o root -g root "$SRC" "$DST"

# sshd uses the first value it reads and the drop-ins are read in name order,
# so another drop-in that sorts after ours cannot override it. Say so anyway.
for F in /etc/ssh/sshd_config.d/*.conf; do
    [ "$F" = "$DST" ] && continue
    grep -HEi '^\s*(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)' "$F" 2>/dev/null \
        | sed 's/^/note: also set in /' || true
done

sshd -t || rollback "sshd config test failed"

EFFECTIVE=$(sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|allowgroups) ' || true)
echo "$EFFECTIVE"
echo "$EFFECTIVE" | grep -q '^passwordauthentication no' || rollback "effective config still allows passwords"

[ -n "$BACKUP" ] && rm -f "$BACKUP"
# On Ubuntu 24.04 ssh.service is started by ssh.socket and may not be running;
# in that case the next connection starts it with the new config.
systemctl try-reload-or-restart ssh.service
echo "sshd reloaded. Keep this session open and test a NEW login for $ADMIN_USER before closing it."
