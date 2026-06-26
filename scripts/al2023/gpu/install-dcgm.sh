#!/usr/bin/env bash
set -ex

### Determine DCGM version ###
# The exact version is determined by the security check script
# (check-update-security.sh) as the highest version available in the AL2023
# repo within the pinned major, and tracked in the NVIDIA_DRIVER_VERSION file.
DCGM_FULL_VERSION=$(grep "^dcgm_version_al2023" /tmp/NVIDIA_DRIVER_VERSION | awk -F'"' '{print $2}')
if [[ -z $DCGM_FULL_VERSION ]]; then
    echo "ERROR: Could not read dcgm_version_al2023 from /tmp/NVIDIA_DRIVER_VERSION"
    exit 1
fi
echo "Using DCGM version: ${DCGM_FULL_VERSION}"

### Install DCGM core package (provides nv-hostengine and libdcgm.so)
sudo dnf install -y "datacenter-gpu-manager-${DCGM_VERSION}-core-${DCGM_FULL_VERSION}"

### Lock DCGM packages to prevent updates that could break the libdcgm.so ABI
sudo dnf versionlock 'datacenter-gpu-manager*'

### Override nvidia-dcgm to use Unix domain socket instead of TCP
sudo mkdir -p /etc/systemd/system/nvidia-dcgm.service.d
sudo tee /etc/systemd/system/nvidia-dcgm.service.d/override.conf <<'EOF'
[Unit]
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
ExecStart=
ExecStart=/usr/bin/nv-hostengine -n --service-account nvidia-dcgm --domain-socket /run/nvidia-dcgm/nv-hostengine
RuntimeDirectory=nvidia-dcgm
RuntimeDirectoryMode=0755
EOF
sudo systemctl daemon-reload

### Enable DCGM and dcgm-init services
sudo systemctl enable nvidia-dcgm
sudo systemctl enable dcgm-init
