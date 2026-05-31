#!/usr/bin/env bash
#sudo pacman -S nfs-utils rpcbind
#sudo systemctl enable --now rpcbind.service nfs-server.service
#sudo systemctl start docker

# Set VOLUME to your persistent data directory
VOLUME=${VOLUME:-.}

sudo mkdir -p "${VOLUME}"/downloads/Linux_for_Tegra/tools/kernel_flash/images
sudo mkdir -p "${VOLUME}"/downloads/Linux_for_Tegra/tools/kernel_flash/tmp

sudo chmod 755 "${VOLUME}"/downloads/Linux_for_Tegra/rootfs
sudo chown root:root "${VOLUME}"/downloads/Linux_for_Tegra/rootfs
sudo chmod 755 "${VOLUME}"/downloads/Linux_for_Tegra/tools/kernel_flash/images
sudo chown root:root "${VOLUME}"/downloads/Linux_for_Tegra/tools/kernel_flash/images
sudo chmod 755 "${VOLUME}"/downloads/Linux_for_Tegra/tools/kernel_flash/tmp
sudo chown root:root "${VOLUME}"/downloads/Linux_for_Tegra/tools/kernel_flash/tmp

sudo tee /etc/exports.d/nvidia-initrd-flash.exports >/dev/null <<'EOF'
${VOLUME}/downloads/Linux_for_Tegra/rootfs *(rw,nohide,insecure,no_subtree_check,async,no_root_squash)
${VOLUME}/downloads/Linux_for_Tegra/tools/kernel_flash/images *(rw,nohide,insecure,no_subtree_check,async,no_root_squash)
${VOLUME}/downloads/Linux_for_Tegra/tools/kernel_flash/tmp *(rw,nohide,insecure,no_subtree_check,async,no_root_squash)
EOF

sudo exportfs -rav
showmount -e localhost


lsmod |  grep usbnet
lsmod |  grep rndis_host
lsmod |  grep cdc_ether

sudo modprobe usbnet
sudo modprobe rndis_host
sudo modprobe cdc_ether
