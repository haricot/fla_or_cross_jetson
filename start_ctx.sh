#!/usr/bin/env bash
#sudo pacman -S nfs-utils rpcbind
#sudo systemctl enable --now rpcbind.service nfs-server.service
#sudo systemctl start docker

sudo pacman -S --needed nfs-utils rpcbind networkmanager
sudo systemctl enable --now NetworkManager rpcbind.service nfs-server.service

sudo modprobe usbnet
sudo modprobe rndis_host
sudo modprobe cdc_ether

sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=0

sudo exportfs -rav
showmount -e localhost


#sudo nmcli connection down "Jetson-USB" || true
