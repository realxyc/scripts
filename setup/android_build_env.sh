#!/usr/bin/env bash
# Copyright (C) 2018 Harsh 'MSF Jarvis' Shandilya
# Copyright (C) 2018 Akhil Narang
# SPDX-License-Identifier: GPL-3.0-only
# Script to setup an AOSP Build environment on Ubuntu

# Catch errors in pipes
set -o pipefail

# Track errors
ERRORS=()

run() {
    local desc="$1"
    shift
    echo -e "\n>>> $desc"
    if ! "$@"; then
        ERRORS+=("FAILED: $desc")
        echo "ERROR: '$desc' failed! Continuing..."
        return 1
    fi
    echo "OK: $desc"
}

LATEST_MAKE_VERSION="4.3"
UBUNTU_20_PACKAGES="libncurses5 curl python-is-python3"
UBUNTU_24_26_PACKAGES="python-is-python3 python3-pyelftools curl"
DEBIAN_10_PACKAGES="libncurses5"
DEBIAN_11_PACKAGES="libncurses5"
PACKAGES=""

run "Install software-properties-common" sudo apt install software-properties-common -y

# Clean up broken OpenJDK PPAs that cause 404 errors on newer Ubuntu releases
run "Clean broken PPAs" sudo rm -f /etc/apt/sources.list.d/*openjdk*.list
run "Update apt" sudo apt update

# lsb-core removed in Ubuntu 24.04+, use lsb-release instead
run "Install lsb-release" sudo apt install lsb-release -y
LSB_RELEASE="$(lsb_release -d | cut -d ':' -f 2 | sed -e 's/^[[:space:]]*//')"
echo "Detected OS: ${LSB_RELEASE}"

if [[ ${LSB_RELEASE} =~ "Ubuntu 24" || ${LSB_RELEASE} =~ "Ubuntu 26" ]]; then
    PACKAGES="${UBUNTU_24_26_PACKAGES}"
elif [[ ${LSB_RELEASE} =~ "Ubuntu 20" || ${LSB_RELEASE} =~ "Ubuntu 21" || ${LSB_RELEASE} =~ "Ubuntu 22" || ${LSB_RELEASE} =~ 'Pop!_OS 2' ]]; then
    PACKAGES="${UBUNTU_20_PACKAGES}"
elif [[ ${LSB_RELEASE} =~ "Debian GNU/Linux 10" ]]; then
    PACKAGES="${DEBIAN_10_PACKAGES}"
elif [[ ${LSB_RELEASE} =~ "Debian GNU/Linux 11" ]]; then
    PACKAGES="${DEBIAN_11_PACKAGES}"
fi

# Added libxml2-dev alongside libxml2-utils to replace the deprecated libxml2 package
run "Install build dependencies" sudo DEBIAN_FRONTEND=noninteractive \
    apt install \
    adb autoconf automake axel bc bison build-essential \
    ccache clang cmake curl expat fastboot flex g++ \
    g++-multilib gawk gcc gcc-multilib git git-lfs gnupg gperf \
    htop imagemagick lib32ncurses-dev lib32z1-dev libc6-dev libcap-dev \
    libexpat1-dev libgmp-dev '^liblz4-.*' '^liblzma.*' libmpc-dev libmpfr-dev libncurses-dev \
    libsdl1.2-dev libssl-dev libtool libxml2-dev libxml2-utils '^lzma.*' lzop \
    maven ncftp patch patchelf pkg-config pngcrush \
    pngquant python3 python3-pyelftools re2c schedtool squashfs-tools subversion \
    texinfo unzip xsltproc zip zlib1g-dev lzip \
    libxml-simple-perl libswitch-perl apt-utils rsync \
    openjdk-21-jdk \
    libelf-dev \
    ${PACKAGES} -y

# Initialize git-lfs
echo -e "\n>>> Initializing Git LFS"
if git lfs install; then
    echo "OK: Git LFS initialized"
else
    ERRORS+=("FAILED: Git LFS initialization")
    echo "ERROR: Git LFS initialization failed!"
fi

# GitHub CLI
echo -e "\n>>> Installing GitHub CLI"
if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
   sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
   sudo apt update && \
   sudo apt install -y gh; then
    echo "OK: GitHub CLI installed"
else
    ERRORS+=("FAILED: GitHub CLI installation")
    echo "ERROR: GitHub CLI installation failed!"
fi

# udev rules
echo -e "\n>>> Setting up udev rules for adb"
if sudo curl --create-dirs -L -o /etc/udev/rules.d/51-android.rules \
    https://raw.githubusercontent.com/M0Rf30/android-udev-rules/master/51-android.rules && \
   sudo chmod 644 /etc/udev/rules.d/51-android.rules && \
   sudo chown root /etc/udev/rules.d/51-android.rules; then
    echo "OK: udev rules installed"
    # systemd may not be available in WSL
    if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null; then
        sudo systemctl restart udev
    else
        echo "systemd not available, skipping udev restart (normal in WSL)"
        sudo udevadm control --reload-rules 2>/dev/null || true
    fi
else
    ERRORS+=("FAILED: udev rules setup")
    echo "ERROR: udev rules setup failed!"
fi

# make version check
if [[ "$(command -v make)" ]]; then
    makeversion="$(make -v | head -1 | awk '{print $3}')"
    if [[ ${makeversion} != "${LATEST_MAKE_VERSION}" ]]; then
        echo "Installing make ${LATEST_MAKE_VERSION} instead of ${makeversion}"
        if ! bash "$(dirname "$0")"/make.sh "${LATEST_MAKE_VERSION}"; then
            ERRORS+=("FAILED: make ${LATEST_MAKE_VERSION} installation")
            echo "ERROR: make installation failed!"
        fi
    else
        echo "OK: make ${makeversion} already up to date"
    fi
fi

# repo tool
echo -e "\n>>> Installing repo"
if sudo curl --create-dirs -L -o /usr/local/bin/repo \
    https://storage.googleapis.com/git-repo-downloads/repo && \
   sudo chmod a+rx /usr/local/bin/repo; then
    echo "OK: repo installed"
else
    ERRORS+=("FAILED: repo installation")
    echo "ERROR: repo installation failed!"
fi

# Legacy ncurses libraries
echo -e "\n>>> Installing legacy ncurses libraries (libtinfo5, libncurses5, libncurses6)"
if sudo apt install -y libncurses6 && \
   wget -q http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2_amd64.deb && \
   wget -q http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libncurses5_6.3-2_amd64.deb && \
   sudo dpkg -i libtinfo5_6.3-2_amd64.deb libncurses5_6.3-2_amd64.deb; then
    echo "OK: Legacy ncurses libraries installed"
else
    ERRORS+=("FAILED: Legacy ncurses libraries")
    echo "ERROR: Legacy ncurses installation failed!"
fi
rm -f libtinfo5_6.3-2_amd64.deb libncurses5_6.3-2_amd64.deb

# Final summary
echo -e "\n==============================="
if [ ${#ERRORS[@]} -eq 0 ]; then
    echo "✓ Setup complete! No errors."
else
    echo "✗ Setup completed WITH ERRORS:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    echo ""
    echo "Please fix the above errors before building!"
    exit 1
fi
echo "==============================="
