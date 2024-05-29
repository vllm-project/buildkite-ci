#!/bin/bash
set -eu -o pipefail

# nvidia driver
sudo yum install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r) dkms

sudo yum install -y pkgconfig libglvnd-devel

DRIVER_CUDA_124="https://us.download.nvidia.com/tesla/550.54.15/NVIDIA-Linux-x86_64-550.54.15.run"

curl -Lsf -o cuda_toolkit.run "${DRIVER_CUDA_124}"
sudo dnf install -y kernel-modules-extra
sudo sh cuda_toolkit.run --silent --dkms
rm cuda_toolkit.run

# nvidia container toolkit
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
sudo yum install -y nvidia-container-toolkit
sudo yum install -y nvidia-container-runtime

sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker


sudo cp /tmp/conf/docker-daemon.json /etc/docker/daemon.json