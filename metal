#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

sudo -v

# Keep-alive: update existing `sudo` time stamp until `osxprep.sh` has finished
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

apt install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils openvswitch-switch dnsmasq -y
systemctl enable libvirtd
systemctl start libvirtd
systemctl enable openvswitch-switch
systemctl start openvswitch-switch

PRIMARY_IFACE=$(ip route | awk '/default/ {print $5; exit}' | grep -v '^docker\|^br\|^ovs')
echo "Primary interface detected: $PRIMARY_IFACE"

if ! ovs-vsctl br-exists br0; then
    ovs-vsctl add-br br0
    ip addr add 10.200.0.0/16 dev br0
    ip link set br0 up
fi

cat <<EOF >/etc/dnsmasq.d/ovsbr0.conf
interface=br0
dhcp-range=192.168.100.10,192.168.100.100,12h
EOF

systemctl restart dnsmasq

IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG="noble-server.img"
VM_DISK="noble-server-vm1.qcow2"

wget -O $IMG $IMG_URL
./generate-userdata

cat <<EOF >meta-data
instance-id: k3d-vm01
local-hostname: k3d-vm01
EOF

cloud-localds user-data.img user-data.yaml meta-data

qemu-img create -f qcow2 -b $IMG $VM_DISK 30G

virt-install \
  --name k3dnode1 \
  --ram 4096 \
  --vcpus 2 \
  --disk path=$VM_DISK,format=qcow2 \
  --disk path=user-data.img,device=cdrom \
  --os-type linux \
  --os-variant ubuntu22.04 \
  --network bridge=br0,model=virtio \
  --graphics none \
  --noautoconsole \
  --import