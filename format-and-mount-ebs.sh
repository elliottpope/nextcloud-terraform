#!/bin/bash

device_name=$1
mount_point=$2

sudo mkdir -p "${mount_point}"

sudo mkfs.ext4 "${device_name}"
uuid=$(sudo blkid | grep /dev/nvme1n1 | awk -FUUID= '{print $2}' | awk -F\" '{print $2}')
echo "UUID=${uuid} /home/ubuntu/data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a 

df | grep "${mount_point}"

sudo mkdir -p "${mount_point}/nextcloud"
sudo mkdir -p "${mount_point}/certbot/{conf,www}"
sudo chown -R ubuntu:ubuntu "${mount_point}"
