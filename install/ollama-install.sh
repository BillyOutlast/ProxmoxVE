#!/usr/bin/env bash

# Copyright (c) 2021-2026 tteck
# Author: havardthom | Co-Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://ollama.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential \
  pkg-config \
  zstd
msg_ok "Installed Dependencies"

setup_hwaccel

echo
echo "${TAB3}Choose the GPU backend for Ollama:"
echo "${TAB3}[1]-CPU only  [2]-Intel  [3]-AMD (ROCm)"
read -rp "${TAB3}Enter your choice [1-3] (default: 2): " gpu_choice
gpu_choice=${gpu_choice:-2}
case "$gpu_choice" in
1)
  ollama_gpu_backend="cpu"
  ;;
2)
  ollama_gpu_backend="intel"
  ;;
3)
  ollama_gpu_backend="rocm"
  ;;
*)
  ollama_gpu_backend="intel"
  echo "${TAB3}Invalid choice. Defaulting to Intel."
  ;;
esac

if [[ "${ollama_gpu_backend}" == "intel" ]]; then
  msg_info "Setting up Intel® Repositories"
  mkdir -p /usr/share/keyrings
  curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key | gpg --dearmor -o /usr/share/keyrings/intel-graphics.gpg
  cat <<EOF >/etc/apt/sources.list.d/intel-gpu.sources
Types: deb
URIs: https://repositories.intel.com/gpu/ubuntu
Suites: jammy
Components: client
Architectures: amd64 i386
Signed-By: /usr/share/keyrings/intel-graphics.gpg
EOF
  curl -fsSL https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | gpg --dearmor -o /usr/share/keyrings/oneapi-archive-keyring.gpg
  cat <<EOF >/etc/apt/sources.list.d/oneAPI.sources
Types: deb
URIs: https://apt.repos.intel.com/oneapi
Suites: all
Components: main
Signed-By: /usr/share/keyrings/oneapi-archive-keyring.gpg
EOF
  $STD apt update
  msg_ok "Set up Intel® Repositories"

  msg_info "Installing Intel® Level Zero"
  # Debian 13+ has newer Level Zero packages in system repos that conflict with Intel repo packages
  if is_debian && [[ "$(get_os_version_major)" -ge 13 ]]; then
    # Use system packages on Debian 13+ (avoid conflicts with libze1)
    $STD apt -y install libze1 libze-dev intel-level-zero-gpu 2>/dev/null || {
      msg_warn "Failed to install some Level Zero packages, continuing anyway"
    }
  else
    # Use Intel repository packages for older systems
    $STD apt -y install intel-level-zero-gpu level-zero level-zero-dev 2>/dev/null || {
      msg_warn "Failed to install Intel Level Zero packages, continuing anyway"
    }
  fi
  msg_ok "Installed Intel® Level Zero"

  msg_info "Installing Intel® oneAPI Base Toolkit (Patience)"
  $STD apt install -y --no-install-recommends intel-basekit-2024.1
  msg_ok "Installed Intel® oneAPI Base Toolkit"
elif [[ "${ollama_gpu_backend}" == "rocm" ]]; then
  if ! is_ubuntu; then
    msg_error "AMD ROCm package-manager install in this script currently supports Ubuntu 22.04/24.04 only"
    exit 1
  fi

  ROCM_VERSION="7.2"
  UBUNTU_CODENAME="$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release)"
  if [[ "${UBUNTU_CODENAME}" != "jammy" && "${UBUNTU_CODENAME}" != "noble" ]]; then
    msg_error "Unsupported Ubuntu codename for ROCm repository: ${UBUNTU_CODENAME}"
    exit 1
  fi

  msg_info "Setting up AMD ROCm Repositories"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg
  cat <<EOF >/etc/apt/sources.list.d/rocm.list
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${UBUNTU_CODENAME} main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/${ROCM_VERSION}/ubuntu ${UBUNTU_CODENAME} main
EOF
  cat <<EOF >/etc/apt/preferences.d/rocm-pin-600
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF
  $STD apt update
  msg_ok "Set up AMD ROCm Repositories"

  msg_info "Installing AMD ROCm"
  $STD apt install -y rocm rocminfo
  msg_ok "Installed AMD ROCm"
fi

msg_info "Installing Ollama (Patience)"
RELEASE=$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest | grep "tag_name" | awk -F '"' '{print $4}')
OLLAMA_INSTALL_DIR="/usr/local/lib/ollama"
BINDIR="/usr/local/bin"
mkdir -p $OLLAMA_INSTALL_DIR
OLLAMA_URL="https://github.com/ollama/ollama/releases/download/${RELEASE}/ollama-linux-amd64.tar.zst"
TMP_TAR="/tmp/ollama.tar.zst"
echo -e "\n"
if curl -fL# -C - -o "$TMP_TAR" "$OLLAMA_URL"; then
  if tar --zstd -xf "$TMP_TAR" -C "$OLLAMA_INSTALL_DIR"; then
    ln -sf "$OLLAMA_INSTALL_DIR/bin/ollama" "$BINDIR/ollama"
    echo "${RELEASE}" >/opt/Ollama_version.txt
    msg_ok "Installed Ollama ${RELEASE}"
  else
    msg_error "Extraction failed – archive corrupt or incomplete"
    exit 1
  fi
else
  msg_error "Download failed – $OLLAMA_URL not reachable"
  exit 1
fi

msg_info "Creating ollama User and Group"
if ! id ollama >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin -U -m -d /usr/share/ollama ollama
fi
$STD usermod -aG render ollama || true
$STD usermod -aG video ollama || true
$STD usermod -aG ollama $(id -u -n)
msg_ok "Created ollama User and adjusted Groups"

msg_info "Creating Service"
OLLAMA_GPU_ENV=""
if [[ "${ollama_gpu_backend}" == "intel" ]]; then
  OLLAMA_GPU_ENV=$'Environment=OLLAMA_INTEL_GPU=true\nEnvironment=SYCL_CACHE_PERSISTENT=1\nEnvironment=ZES_ENABLE_SYSMAN=1'
elif [[ "${ollama_gpu_backend}" == "rocm" ]]; then
  OLLAMA_GPU_ENV="Environment=OLLAMA_LLM_LIBRARY=rocm"
fi
cat <<EOF >/etc/systemd/system/ollama.service
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/ollama serve
Environment=HOME=$HOME
Environment=OLLAMA_HOST=0.0.0.0
Environment=OLLAMA_NUM_GPU=999
$OLLAMA_GPU_ENV
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now ollama
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
