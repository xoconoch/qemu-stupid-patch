#!/usr/bin/env bash
set -euo pipefail

# Configuration
QEMU_VERSION="${QEMU_VERSION:-v10.0.4}"
PKG_NAME="${PKG_NAME:-qemu-user-static}"
RAW_VER="${QEMU_VERSION#v}"
PKG_VERSION="${PKG_VERSION:-2:${RAW_VER}-1+guestbase}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/build-workspace}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"

echo "================================================================="
echo " Building Patched QEMU x86_64 Debian Package"
echo " Target QEMU Version: ${QEMU_VERSION}"
echo " Package Name:        ${PKG_NAME}"
echo " Package Version:     ${PKG_VERSION}"
echo " Working Directory:   ${WORK_DIR}"
echo "================================================================="

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# 1. Install build dependencies if requested
if [ "${INSTALL_DEPS}" = "1" ]; then
    echo "==> [1/5] Checking / installing build dependencies..."
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        SUDO=""
    fi
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y --no-install-recommends \
        git build-essential python3 ninja-build pkg-config \
        libglib2.0-dev libpixman-1-dev
fi

# 2. Clone QEMU source if not present
echo "==> [2/5] Fetching QEMU source (${QEMU_VERSION})..."
if [ ! -d "qemu" ]; then
    git clone --depth 1 --branch "${QEMU_VERSION}" https://gitlab.com/qemu-project/qemu.git qemu
fi

cd qemu

# Reset any changes in working tree to ensure clean patch application
git checkout -f linux-user/main.c 2>/dev/null || true

# 3. Apply the guest_base patch
echo "==> [3/5] Applying default guest_base patch..."
python3 -c '
with open("linux-user/main.c", "r") as f:
    code = f.read()

target = "optind = parse_args(argc, argv);"
patch = """optind = parse_args(argc, argv);

#if defined(TARGET_X86_64)
    if (!have_guest_base && !reserved_va) {
        guest_base = 0x800000000000ULL;
        have_guest_base = true;
    }
#endif"""

if "#if defined(TARGET_X86_64)" not in code:
    assert target in code, "Target anchor string not found in linux-user/main.c"
    code = code.replace(target, patch, 1)
    with open("linux-user/main.c", "w") as f:
        f.write(code)
    print("Patch successfully applied to linux-user/main.c")
else:
    print("Patch already present in linux-user/main.c")
'

# 4. Configure and compile static user binary
echo "==> [4/5] Configuring and compiling static qemu-x86_64 binary..."
./configure --target-list=x86_64-linux-user --static --disable-system --disable-tools
ninja -C build qemu-x86_64
cd ..

# 5. Assemble Debian package
echo "==> [5/5] Packaging into Debian (.deb) package..."
PKG_ROOT="${WORK_DIR}/pkg-root"
rm -rf "${PKG_ROOT}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/bin"
mkdir -p "${PKG_ROOT}/usr/libexec/qemu-binfmt"
mkdir -p "${PKG_ROOT}/usr/lib/binfmt.d"

# Copy binary & create compatibility symlinks
cp qemu/build/qemu-x86_64 "${PKG_ROOT}/usr/bin/qemu-x86_64"
chmod 755 "${PKG_ROOT}/usr/bin/qemu-x86_64"

ln -s qemu-x86_64 "${PKG_ROOT}/usr/bin/qemu-x86_64-static"
ln -s ../../bin/qemu-x86_64 "${PKG_ROOT}/usr/libexec/qemu-binfmt/x86_64-binfmt-P"

# systemd-binfmt configuration file (flags: POCF)
cat << 'EOF' > "${PKG_ROOT}/usr/lib/binfmt.d/qemu-x86_64.conf"
:qemu-x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/libexec/qemu-binfmt/x86_64-binfmt-P:POCF
EOF

# Package metadata with epoch 2 to supersede upstream distro packages (which use epoch 1)
if [ "${PKG_NAME}" = "qemu-user-static" ]; then
    PROVIDES="qemu-user, qemu-user-binfmt, qemu-user-x86-64-patched"
    CONFLICTS="qemu-user, qemu-user-binfmt"
    REPLACES="qemu-user, qemu-user-binfmt"
else
    PROVIDES="qemu-user, qemu-user-static, qemu-user-binfmt"
    CONFLICTS="qemu-user, qemu-user-static, qemu-user-binfmt"
    REPLACES="qemu-user, qemu-user-static, qemu-user-binfmt"
fi

cat << EOF > "${PKG_ROOT}/DEBIAN/control"
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Architecture: arm64
Maintainer: Custom Build <local@localhost>
Provides: ${PROVIDES}
Conflicts: ${CONFLICTS}
Replaces: ${REPLACES}
Section: otherosfs
Priority: optional
Description: Patched static QEMU x86_64 emulator with 0x800000000000 guest_base default and systemd-binfmt integration
EOF

# postinst: clear old kernel binfmt cache and restart systemd-binfmt
cat << 'EOF' > "${PKG_ROOT}/DEBIAN/postinst"
#!/bin/sh
set -e
if [ -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
    echo -1 > /proc/sys/fs/binfmt_misc/qemu-x86_64 2>/dev/null || true
fi
systemctl restart systemd-binfmt 2>/dev/null || true
exit 0
EOF
chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# prerm: unregister from kernel binfmt on package removal
cat << 'EOF' > "${PKG_ROOT}/DEBIAN/prerm"
#!/bin/sh
set -e
if [ -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ]; then
    echo -1 > /proc/sys/fs/binfmt_misc/qemu-x86_64 2>/dev/null || true
fi
exit 0
EOF
chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

# Build final deb package (strip epoch from deb filename per Debian standards)
CLEAN_VERSION="${PKG_VERSION#*:}"
OUTPUT_DEB="${SCRIPT_DIR}/${PKG_NAME}_${CLEAN_VERSION}_arm64.deb"
dpkg-deb --build "${PKG_ROOT}" "${OUTPUT_DEB}"

# Create backward-compatibility symlink
ln -sf "$(basename "${OUTPUT_DEB}")" "${SCRIPT_DIR}/qemu-user-x86-64-patched_arm64.deb"

echo "OUTPUT_DEB=${OUTPUT_DEB}" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true

echo ""
echo "================================================================="
echo " Package successfully built at:"
echo " ${OUTPUT_DEB}"
echo "================================================================="
