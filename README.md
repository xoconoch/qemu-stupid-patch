# Patched QEMU User Emulation for ARM64 Hosts (47-bit x86_64 Fix)

A standalone, reproducible Debian package build for `qemu-x86_64` that fixes segmentation faults (`SIGSEGV` / target signal 11) when emulating `x86_64` binaries on `arm64` Linux hosts (such as Raspberry Pi, RK3588, Apple Silicon VMs, and Graviton).

---

## The Problem & Context

When running x86_64 binaries—specifically those built with modern Rust (`rustc`), tools like [`uv`](https://github.com/astral-sh/uv), [`duckdb`](https://github.com/duckdb/duckdb), or the Nix package manager—inside Docker containers or Nix builds on an ARM64 host, programs immediately crash:

```text
qemu: uncaught target signal 11 (Segmentation fault) - core dumped
Segmentation fault
```

This bug is tracked across multiple upstream projects:
* **QEMU Issue:** [qemu-project/qemu#3130](https://gitlab.com/qemu-project/qemu/-/issues/3130) (*"Rust segfaults with arm64 host emulating amd64 through docker"*)
* **Astral uv Issue:** [astral-sh/uv#16024](https://github.com/astral-sh/uv/issues/16024) (*"Segfault on amd64 under QEMU"*)
* **Rust Issue:** [rust-lang/rust#147026](https://github.com/rust-lang/rust/issues/147026)
* **Nix Issue:** [NixOS/nix#16184](https://github.com/NixOS/nix/issues/16184) (*"nix 2.35.1 amd64 segfault under arm64 qemu unless QEMU_GUEST_BASE overridden"*)

---

## Technical Root Cause

1. **The 47-bit x86_64 Virtual Address Guarantee:**  
   On native x86_64 Linux (with 4-level or 5-level paging), the kernel guarantees that standard `mmap(NULL, ...)` allocations without an explicit hint $\ge 2^{47}$ always allocate memory within the lower canonical half ($[0, 2^{47})$, i.e., addresses $< \text{0x800000000000}$).
   
   Runtimes and memory allocators—notably **jemalloc** (Rust, uv, DuckDB) and **mimalloc** (Nix 2.35+)—exploit this guarantee to pack metadata into pointer tags or compress pointers using sign extension from bit 47:
   ```c
   q = (char *)((intptr_t)((uintptr_t)p << 16) >> 16);
   ```

2. **The ARM64 Host Virtual Address Mismatch:**  
   Modern 64-bit ARM Linux distributions (Debian, Ubuntu) configure kernels with `CONFIG_ARM64_VA_BITS=48`, granting user space a full 48-bit address space ($[0, 2^{48})$).  
   In QEMU user-mode emulation without a custom guest base, `guest_base == 0`. Target `mmap` calls pass directly to the host kernel, which frequently returns memory addresses $\ge 2^{47}$ (where bit 47 is set to 1).

3. **The Crash:**  
   When jemalloc or mimalloc sign-extends bit 47, an address like `0x0000800012345000` is transformed into `0xffff800012345000` (a non-canonical or kernel space address). Attempting to dereference this pointer triggers an immediate hardware `SIGSEGV` (signal 11).

---

## Why Other Workarounds Fall Short

* **Environment Variable (`QEMU_GUEST_BASE=0x800000000000`):**  
  While exporting this variable works for manual CLI invocations:
  * In **Nix cross-compilation**, injecting environment variables into derivations alters the derivation inputs and busts binary caches.
  * In **Docker / CI (Forgejo, GitHub Actions)**, Docker does not support injecting global default environment variables into arbitrary containers via `daemon.json`. Requiring every container or workflow to define custom `ENV` is brittle.
* **Kernel `binfmt_misc` Shell Wrappers:**  
  Linux `binfmt_misc` only accepts an absolute binary path without flags or environment variables. Using a shell script wrapper (e.g. `#!/bin/sh`) registered with the `F` (fix-binary) flag fails inside container mount namespaces with `ENOENT` ("No such file or directory") because minimal containers (e.g., `scratch`, Alpine) do not have host paths or the host interpreter mounted.

---

## What This Repository Does

This repository patches QEMU's `linux-user/main.c` so that when emulating `x86_64` on a 64-bit host, `guest_base` defaults to `0x800000000000` ($2^{47}$) if not explicitly overridden by `-B` or `-R`:

```c
#if defined(TARGET_X86_64)
    if (!have_guest_base && !reserved_va) {
        guest_base = 0x800000000000ULL;
        have_guest_base = true;
    }
#endif
```

Setting `guest_base = 0x800000000000`:
* Shifts the guest address mapping: $\text{Host Address} = \text{Guest Address} + 2^{47}$, safely within the host's 48-bit VA space.
* Directs QEMU to allocate guest VMAs internally starting from `TASK_UNMAPPED_BASE`, guaranteeing that all guest virtual addresses returned to guest programs strictly satisfy $< 2^{47}$ (bit 47 is always 0).
* Requires **zero configuration** inside Docker containers, Forgejo CI runners, or Nix builds.

The build script compiles a fully static `qemu-x86_64` binary and packages it into a Debian `.deb` bundle complete with `systemd-binfmt` integration.

---

## Debian / Ubuntu APT Repository (Recommended)

This repository maintains an automated, signed APT repository hosted on GitHub Pages for ARM64 (`arm64`).

The package is published under the standard package name `qemu-user-static` with **Epoch 2** (e.g. `2:10.0.4-1+guestbase`). Because official Debian and Ubuntu packages use Epoch 1 (`1:...`), adding this repository guarantees that `apt upgrade` or `apt install qemu-user-static` will cleanly install and maintain the patched version over the official distribution package.

### 1. Add Repository to Debian / Ubuntu

Run the following on your ARM64 Debian/Ubuntu machine:

```bash
# 1. Create keyrings directory
sudo install -m 0755 -d /etc/apt/keyrings

# 2. Download and install the repository signing key
# (Replace <username> and <repo> with your GitHub repository coordinates)
curl -fsSL https://<username>.github.io/<repo>/KEY.gpg | sudo tee /etc/apt/keyrings/qemu-patch.gpg > /dev/null

# 3. Add the APT source
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/qemu-patch.gpg] https://<username>.github.io/<repo> stable main" \
  | sudo tee /etc/apt/sources.list.d/qemu-patch.list

# 4. Update index and install/upgrade
sudo apt update
sudo apt install -y qemu-user-static
```

---

## Automated GitHub Actions Pipeline

The workflow in `.github/workflows/build.yml` runs on an ARM64 GitHub runner:
* **Nightly Upstream Check (02:00 UTC):** Queries GitLab / GitHub for the latest stable QEMU release. If a new release is detected, it automatically compiles the `.deb`, updates the APT repository indexes (`Packages.gz`, `Release`, `InRelease`), signs them with GPG, and pushes them to the `gh-pages` branch.
* **Manual / On Push:** Builds automatically on pushes to `main` or via manual `workflow_dispatch` trigger.

### Setting Up the Repository (For Maintainers)

1. **Enable GitHub Pages:**
   * Go to **Settings** > **Pages** in your GitHub repository.
   * Under **Build and deployment**, select **Deploy from a branch**.
   * Select branch: `gh-pages`, folder: `/ (root)`.
2. **Configure Workflow Permissions:**
   * Go to **Settings** > **Actions** > **General** > **Workflow permissions**.
   * Select **Read and write permissions** so the workflow can push to `gh-pages`.
3. **Configure GPG Signing (Recommended):**
   * Generate a GPG key locally:
     ```bash
     gpg --quick-generate-key "qemu-patch <qemu-patch@localhost>" default default never
     ```
   * Export the private key as base64:
     ```bash
     gpg --armor --export-secret-keys "qemu-patch" | base64 -w 0
     ```
   * In GitHub, navigate to **Settings** > **Secrets and variables** > **Actions** and add:
     * `GPG_PRIVATE_KEY`: The base64 output above.
     * `GPG_PASSPHRASE`: Passphrase if set (leave empty if none).

---

## Manual / Local Build

If building locally on an ARM64 machine:

```bash
chmod +x build-deb.sh
./build-deb.sh
```

You can customize the target QEMU version or package name:

```bash
QEMU_VERSION=v10.1.0 ./build-deb.sh
```

Install the generated `.deb` package manually:

```bash
sudo dpkg -i qemu-user-static_*_arm64.deb
```

The package's `postinst` script automatically clears cached `binfmt_misc` kernel entries and restarts `systemd-binfmt`.

---

## Verification

### 1. Check Kernel binfmt Registration

```bash
cat /proc/sys/fs/binfmt_misc/qemu-x86_64
```
Ensure it reports `enabled`, points to `/usr/libexec/qemu-binfmt/x86_64-binfmt-P`, and includes `flags: POCF`.

### 2. Test in Docker (without any environment variables)

```bash
docker run --rm --platform=linux/amd64 ubuntu:24.04 bash -c '
  apt-get update && apt-get install -y curl
  curl -fsSL https://astral.sh/uv/install.sh | sh
  ~/.local/bin/uv --version
'
```

If it prints the `uv` version without crashing, the fix is working transparently across all containers.

---

## How to Revert (When Upstream Fixes the Bug)

Once QEMU upstream merges a native fix and Debian packages it, you can cleanly remove this custom package and return to official distribution packages:

```bash
# 1. Remove the repository list
sudo rm -f /etc/apt/sources.list.d/qemu-patch.list /etc/apt/keyrings/qemu-patch.gpg

# 2. Unregister the binfmt handler from kernel memory
echo -1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-x86_64 2>/dev/null || true

# 3. Purge the custom package
sudo dpkg --purge qemu-user-static

# 4. Reinstall standard Debian packages
sudo apt update
sudo apt install -y qemu-user-static

# 5. Restart systemd-binfmt
sudo systemctl restart systemd-binfmt
```
