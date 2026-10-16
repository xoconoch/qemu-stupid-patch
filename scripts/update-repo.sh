#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="repo"
DEB_FILE=""
CODENAME="stable"
SUITE="stable"
ORIGIN="qemu-patch"
LABEL="qemu-patch"
DESCRIPTION="Patched QEMU user emulation packages with 47-bit VA fix for ARM64"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)
            REPO_DIR="$2"
            shift 2
            ;;
        --deb)
            DEB_FILE="$2"
            shift 2
            ;;
        --codename)
            CODENAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [ -z "${DEB_FILE}" ] || [ ! -f "${DEB_FILE}" ]; then
    echo "Error: --deb <file.deb> is required and must exist."
    exit 1
fi

POOL_DIR="${REPO_DIR}/pool/main"
BINARY_DIR="${REPO_DIR}/dists/${CODENAME}/main/binary-arm64"
DIST_DIR="${REPO_DIR}/dists/${CODENAME}"

mkdir -p "${POOL_DIR}" "${BINARY_DIR}"

echo "==> Copying $(basename "${DEB_FILE}") into pool..."
cp "${DEB_FILE}" "${POOL_DIR}/"

echo "==> Generating Packages index..."
# Check for dpkg-scanpackages
if ! command -v dpkg-scanpackages >/dev/null 2>&1; then
    echo "dpkg-scanpackages not found, please install dpkg-dev (apt-get install -y dpkg-dev)"
    exit 1
fi

(
    cd "${REPO_DIR}"
    dpkg-scanpackages --arch arm64 pool/main /dev/null > "dists/${CODENAME}/main/binary-arm64/Packages"
)
gzip -9nc "${BINARY_DIR}/Packages" > "${BINARY_DIR}/Packages.gz"

echo "==> Generating Release file for dists/${CODENAME}..."
python3 - <<EOF
import os
import hashlib
import time

repo_dir = "${REPO_DIR}"
dist_dir = "${DIST_DIR}"
codename = "${CODENAME}"
suite = "${SUITE}"
origin = "${ORIGIN}"
label = "${LABEL}"
description = "${DESCRIPTION}"

files_to_hash = [
    "main/binary-arm64/Packages",
    "main/binary-arm64/Packages.gz"
]

date_str = time.strftime("%a, %d %b %Y %H:%M:%S UTC", time.gmtime())

lines = [
    f"Origin: {origin}",
    f"Label: {label}",
    f"Suite: {suite}",
    f"Codename: {codename}",
    f"Date: {date_str}",
    "Architectures: arm64",
    "Components: main",
    f"Description: {description}",
    "MD5Sum:"
]

for rel_path in files_to_hash:
    full_path = os.path.join(dist_dir, rel_path)
    if os.path.exists(full_path):
        with open(full_path, "rb") as f:
            content = f.read()
        md5 = hashlib.md5(content).hexdigest()
        lines.append(f" {md5} {len(content)} {rel_path}")

lines.append("SHA1:")
for rel_path in files_to_hash:
    full_path = os.path.join(dist_dir, rel_path)
    if os.path.exists(full_path):
        with open(full_path, "rb") as f:
            content = f.read()
        sha1 = hashlib.sha1(content).hexdigest()
        lines.append(f" {sha1} {len(content)} {rel_path}")

lines.append("SHA256:")
for rel_path in files_to_hash:
    full_path = os.path.join(dist_dir, rel_path)
    if os.path.exists(full_path):
        with open(full_path, "rb") as f:
            content = f.read()
        sha256 = hashlib.sha256(content).hexdigest()
        lines.append(f" {sha256} {len(content)} {rel_path}")

release_path = os.path.join(dist_dir, "Release")
with open(release_path, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"Generated {release_path}")
EOF

echo "==> Checking GPG signing..."
if gpg --list-secret-keys 2>/dev/null | grep -q 'sec'; then
    echo "Signing Release with GPG key..."
    rm -f "${DIST_DIR}/InRelease" "${DIST_DIR}/Release.gpg"

    # Generate InRelease (clearsigned)
    gpg --batch --yes --clearsign --armor \
        --output "${DIST_DIR}/InRelease" \
        "${DIST_DIR}/Release"

    # Generate Release.gpg (detached signature)
    gpg --batch --yes --detach-sign --armor \
        --output "${DIST_DIR}/Release.gpg" \
        "${DIST_DIR}/Release"

    # Export public key for repository consumers
    gpg --armor --export > "${REPO_DIR}/KEY.gpg"
    echo "Public key exported to ${REPO_DIR}/KEY.gpg"
else
    echo "WARNING: No GPG private key found in keyring. Skipping GPG signature."
    echo "Clients will require [trusted=yes] unless signed with InRelease."
fi

# Generate friendly index.html for the repository landing page
cat << 'EOF' > "${REPO_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Patched QEMU Debian Repository (ARM64)</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; line-height: 1.6; color: #24292e; background: #fafbfc; }
    h1 { border-bottom: 1px solid #e1e4e8; padding-bottom: 10px; }
    pre { background: #f6f8fa; border: 1px solid #e1e4e8; border-radius: 6px; padding: 16px; overflow-x: auto; font-size: 14px; }
    code { font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace; }
    .badge { display: inline-block; background: #0366d6; color: #fff; padding: 2px 8px; border-radius: 12px; font-size: 12px; font-weight: 600; }
  </style>
</head>
<body>
  <h1>Patched QEMU Debian Repository <span class="badge">ARM64</span></h1>
  <p>This repository provides patched static <code>qemu-user</code> builds for 64-bit ARM hosts with the default <code>guest_base = 0x800000000000</code> fix, resolving Rust/jemalloc/mimalloc segfaults in emulated x86_64 environments.</p>

  <h2>Installation on Debian / Ubuntu (ARM64)</h2>
  <pre><code># 1. Download and install repository GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://xoconoch.github.io/qemu-stupid-patch/KEY.gpg | sudo tee /etc/apt/keyrings/qemu-stupid-patch.gpg > /dev/null

# 2. Add repository source
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/qemu-stupid-patch.gpg] https://xoconoch.github.io/qemu-stupid-patch stable main" | sudo tee /etc/apt/sources.list.d/qemu-stupid-patch.list

# 3. Update package index and install / upgrade
sudo apt update
sudo apt install -y qemu-user-static</code></pre>
</body>
</html>
EOF

echo "==> Debian repository successfully updated in '${REPO_DIR}'!"
