# qemu-stupid-patch

Patched static `qemu-user` (`arm64`) with default `guest_base = 0x800000000000` to prevent x86_64 emulation segfaults (`SIGSEGV` / target signal 11) with Rust, `uv`, Nix, DuckDB, jemalloc, and mimalloc on 48-bit VA ARM64 hosts.

Packages are published with Epoch 2 (`2:*-1+guestbase`) to automatically take precedence over upstream distribution packages (`1:*`).

## Install (Debian / Ubuntu ARM64)

```bash
# 1. Add repository signing key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://xoconoch.github.io/qemu-stupid-patch/KEY.gpg \
  | sudo tee /etc/apt/keyrings/qemu-stupid-patch.gpg > /dev/null

# 2. Add APT repository
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/qemu-stupid-patch.gpg] https://xoconoch.github.io/qemu-stupid-patch stable main" \
  | sudo tee /etc/apt/sources.list.d/qemu-stupid-patch.list

# 3. Install / Upgrade
sudo apt update
sudo apt install -y qemu-user-static
```

## Verify

Run an x86_64 container with jemalloc (`uv`):

```bash
docker run --rm --platform=linux/amd64 ubuntu:24.04 bash -c '
  apt-get update && apt-get install -y curl
  curl -fsSL https://astral.sh/uv/install.sh | sh
  ~/.local/bin/uv --version
'
```

## Revert

```bash
sudo rm -f /etc/apt/sources.list.d/qemu-stupid-patch.list /etc/apt/keyrings/qemu-stupid-patch.gpg
echo -1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-x86_64 2>/dev/null || true
sudo apt update
sudo apt install --reinstall -y qemu-user-static
sudo systemctl restart systemd-binfmt
```
