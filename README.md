# spark-baseline

Describe the state of a DGX Spark (or any Ubuntu-based GPU node) as plain text, harden SSH without locking yourself out, and diff two nodes or two dates.

| File | What it does |
|---|---|
| `baseline-snapshot.sh` | Writes 37 text files (identity, driver, packages, holds, accounts, sshd config, network, storage, services, containers) plus `99-summary.txt` to `baseline/<host>/<timestamp>/`. Modifies nothing. Root not required: `33-sshd-effective`, `35-sudoers` and the ufw rules in `45-ufw` need root and are skipped with a note when `sudo -n` would prompt. |
| `10-hardening.conf` | sshd drop-in: keys only, no root, `AllowGroups sshusers`, no agent/X11 forwarding, local TCP forwarding only. |
| `harden-ssh.sh` | Installs the drop-in. Refuses to reload sshd unless `ADMIN_USER` is in `sshusers` and has an authorized key, and unless `sshd -t` and `sshd -T` confirm passwords are off. On a failed check the previous drop-in is restored. |

```sh
./baseline-snapshot.sh                       # -> baseline/<host>/<utc>/
sudo ADMIN_USER=$USER ./harden-ssh.sh        # keep the session open, test a new login
diff -r baseline/spark-a/<t> baseline/spark-b/<t> | less   # two nodes
diff -r baseline/spark-a/<t1> baseline/spark-a/<t2>         # drift over time
cut -f1 baseline/<host>/<t>/21-dpkg-pinned-candidates.txt | xargs sudo apt-mark hold
```

`62-docker-info.txt` records `/etc/docker/daemon.json` as well, since settings such as `default-cgroupns-mode` do not appear in `docker info`.

Topic files hold no timestamps, PIDs, ephemeral ports or usage figures, so a diff shows configuration drift rather than the passage of time. Expected differences between two nodes: `00-identity.txt` (hostname, factory image), `40` to `42` (addresses, routes, MACs), `52-fstab.txt` (disk UUIDs), and `32-authorized-keys.txt` if keys differ. Anything else is drift to explain.

The DGX serial number is masked in `00-identity.txt`, and `32-authorized-keys.txt` keeps only key type and comment. Snapshots still contain account names and LAN addresses, so keep them in a private repository.

`AllowTcpForwarding local` keeps `ssh -L` working, which DGX Dashboard needs: it listens on `127.0.0.1:11000` only, so it is reached with `ssh -L 11000:localhost:11000 <node>` and a browser on `http://localhost:11000` (NVIDIA Sync and VS Code Remote-SSH use the same mechanism). Remote forwarding (`ssh -R`) stays off.

Before updating through DGX Dashboard, run `apt-mark unhold` on the pinned packages: Dashboard upgrades through aptdaemon, and a held package is kept back, which can leave a node half updated. Update both nodes in the same window, then diff `10` to `13`, `21` and the `DGX_OTA_VERSION` lines of `00` in the two new snapshots; they must match before the pair goes back into service.

`PIN_RE` at the top of `baseline-snapshot.sh` names the packages worth holding (driver branch 580, kernel and its prebuilt NVIDIA modules, CUDA and NCCL, docker and the NVIDIA container toolkit, RDMA user space, NIC firmware manager). Change `580` if your driver branch differs. Do not hold every `nvidia-*` package on DGX OS: many of them are OS configuration packages (repository keys, OTA checks) and holding them blocks updates.

Tested on DGX OS 7.6.0 (Ubuntu 24.04.5, OpenSSH 9.6p1). `harden-ssh.sh` was exercised in an Ubuntu 24.04 container with the same OpenSSH build.

Apache-2.0.
