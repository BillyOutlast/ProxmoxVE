#!/usr/bin/env bash

# Copyright (c) 2021-2026 tteck
# Author: tteck | Co-Author: havardthom | Co-Author: Slaviša Arežina (tremor021)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://openwebui.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  ffmpeg \
  zstd
msg_ok "Installed Dependencies"

setup_hwaccel

PYTHON_VERSION="3.12" setup_uv

msg_info "Installing Open WebUI"
$STD uv tool install --python 3.12 --constraint <(echo "numba>=0.60") open-webui[all]
msg_ok "Installed Open WebUI"

read -r -p "${TAB3}Would you like to add Ollama? <y/N> " prompt
if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
  echo
  echo "${TAB3}Choose the GPU backend for Ollama:"
  echo "${TAB3}[1]-CPU only  [2]-Intel  [3]-AMD (ROCm)"
  read -rp "${TAB3}Enter your choice [1-3] (default: 2): " ollama_gpu_choice
  ollama_gpu_choice=${ollama_gpu_choice:-2}
  case "$ollama_gpu_choice" in
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
    curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key | gpg --dearmor -o /usr/share/keyrings/intel-graphics.gpg 2>/dev/null || true
    cat <<EOF >/etc/apt/sources.list.d/intel-gpu.sources
Types: deb
URIs: https://repositories.intel.com/gpu/ubuntu
Suites: jammy
Components: client
Architectures: amd64 i386
Signed-By: /usr/share/keyrings/intel-graphics.gpg
EOF
    curl -fsSL https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | gpg --dearmor -o /usr/share/keyrings/oneapi-archive-keyring.gpg 2>/dev/null || true
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
    $STD apt install -y --no-install-recommends intel-basekit-2024.1 2>/dev/null || true
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

  msg_info "Installing Ollama"
  OLLAMA_RELEASE=$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest | grep "tag_name" | awk -F '"' '{print $4}')
  curl -fsSLO -C - https://github.com/ollama/ollama/releases/download/"${OLLAMA_RELEASE}"/ollama-linux-amd64.tar.zst
  tar --zstd -C /usr -xf ollama-linux-amd64.tar.zst
  rm -rf ollama-linux-amd64.tar.zst

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
ExecStart=/usr/bin/ollama serve
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
  echo "ENABLE_OLLAMA_API=true" >/root/.env
  msg_ok "Installed Ollama"
fi

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/open-webui.service
[Unit]
Description=Open WebUI Service
After=network.target

[Service]
Type=simple
EnvironmentFile=-/root/.env
Environment=DATA_DIR=/root/.open-webui
ExecStart=/root/.local/bin/open-webui serve
WorkingDirectory=/root
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now open-webui
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
