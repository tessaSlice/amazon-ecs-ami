#!/usr/bin/env bash
set -ex

# DCGM is not available in air-gapped (ADC/ISO) regions
if [ -n "$AIR_GAPPED" ]; then
    echo "Air-gapped region, skipping DCGM installation"
    exit 0
fi

# The dcgm-init binary (and its systemd unit) ships in the amazon-ecs-init RPM,
# which is installed earlier in the build. Older RPMs don't include it yet, so
# skip DCGM setup entirely until the binary is present (mirrors AIR_GAPPED).
# Note: the binary lives in /usr/libexec, which is not on $PATH, so this checks
# the install path directly rather than using `command -v`/`which`.
if [ ! -f /usr/libexec/dcgm-init ]; then
    echo "dcgm-init binary not found, skipping DCGM installation"
    exit 0
fi

### Determine DCGM version ###
# The exact version is determined by the security check script
# (check-update-security.sh) as the highest version available in the AL2023
# repo within the pinned major, and tracked in the NVIDIA_DRIVER_VERSION file.
DCGM_FULL_VERSION=$(grep "^dcgm_version_al2023" /tmp/NVIDIA_DRIVER_VERSION | awk -F'"' '{print $2}')
if [[ -z $DCGM_FULL_VERSION ]]; then
    echo "ERROR: Could not read dcgm_version_al2023 from /tmp/NVIDIA_DRIVER_VERSION"
    exit 1
fi

# The DCGM package name embeds the major (e.g. datacenter-gpu-manager-4-core),
# so derive it from the tracked full version rather than passing it in
# separately. This keeps a single source of truth (NVIDIA_DRIVER_VERSION) and
# makes major/full-version drift structurally impossible. The producer
# (check-update-security.sh) already guarantees the tracked version is within
# the pinned major via its repoquery filter.
DCGM_MAJOR="${DCGM_FULL_VERSION%%.*}"
echo "Using DCGM version: ${DCGM_FULL_VERSION}"

### Install DCGM core package (provides nv-hostengine and libdcgm.so)
# Pin the exact version rather than letting dnf resolve the newest within the
# major, so the installed version always matches what NVIDIA_DRIVER_VERSION
# records. The version suffix attaches to the full package name, so the major
# stays part of the name and the tracked version appends after it. The epoch is
# deliberately omitted: the bare version resolves correctly and hardcoding the
# current epoch (1:) would break if it is ever bumped upstream.
sudo dnf install -y "datacenter-gpu-manager-${DCGM_MAJOR}-core-${DCGM_FULL_VERSION}"

### Lock DCGM packages to prevent automatic updates
sudo dnf versionlock 'datacenter-gpu-manager*'

### Override nvidia-dcgm to use Unix domain socket instead of TCP
sudo mkdir -p /etc/systemd/system/nvidia-dcgm.service.d
sudo tee /etc/systemd/system/nvidia-dcgm.service.d/override.conf <<'EOF'
[Unit]
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
ExecStartPre=/usr/bin/mkdir -p /var/log/ecs
ExecStart=
ExecStart=/usr/bin/nv-hostengine -n --service-account nvidia-dcgm --domain-socket /run/nvidia-dcgm/nv-hostengine -f /var/log/ecs/nv-hostengine.log
RuntimeDirectory=nvidia-dcgm
RuntimeDirectoryMode=0755
EOF
sudo systemctl daemon-reload

### Configure log rotation for DCGM logs
sudo tee /etc/logrotate.d/nv-hostengine <<'EOF'
/var/log/ecs/nv-hostengine.log {
    size 5M
    rotate 1
    missingok
    notifempty
    copytruncate
}
EOF

### Enable DCGM and dcgm-init services
sudo systemctl enable nvidia-dcgm
sudo systemctl enable dcgm-init
