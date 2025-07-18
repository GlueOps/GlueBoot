#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

sudo -v

# Keep-alive: update existing `sudo` time stamp until `osxprep.sh` has finished
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

apt install qemu-kvm iptables-persistent libvirt-daemon-system libvirt-clients bridge-utils openvswitch-switch virtinst dnsmasq cloud-image-utils cloud-utils -y
systemctl enable libvirtd
systemctl start libvirtd
systemctl enable openvswitch-switch
systemctl start openvswitch-switch

PRIMARY_IFACE=$(ip route | awk '/default/ {print $5; exit}' | grep -v '^docker\|^br\|^ovs')
echo "Primary interface detected: $PRIMARY_IFACE"
LAN_SUBNET=10.200.0.0/16
LAN_START_IP=10.200.0.10
LAN_END_IP=10.200.255.200

if ! ovs-vsctl br-exists br0; then
    ovs-vsctl add-br br0
    ip addr add $LAN_SUBNET dev br0
    ip link set br0 up
fi

cat <<EOF >/etc/dnsmasq.d/ovsbr0.conf
interface=br0
dhcp-range=$LAN_START_IP,$LAN_END_IP,12h
dhcp-option=6,8.8.8.8,1.1.1.1
EOF

systemctl restart dnsmasq

IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG="$PWD/noble-server.img"

wget -O $IMG $IMG_URL
./generate-userdata

cat <<EOF >meta-data
instance-id: k3d-vm01
local-hostname: k3d-vm01
EOF

cloud-localds user-data.img user-data.yaml meta-data

mkdir -p /var/lib/libvirt/images/myvms
mv noble-server.img user-data.img /var/lib/libvirt/images/myvms/
chmod 644 /var/lib/libvirt/images/myvms/*
chmod 755 /var/lib/libvirt/images/myvms

cd /var/lib/libvirt/images/myvms

IMG="$PWD/noble-server.img"
VM_DISK="$PWD/noble-server-vm1.qcow2"

qemu-img create -f qcow2 -F qcow2 -b "$IMG" "$VM_DISK" 30G


virt-install \
  --name k3dnode1 \
  --ram 4096 \
  --vcpus 2 \
  --cpu kvm64 \
  --disk path=/var/lib/libvirt/images/myvms/noble-server-vm1.qcow2,format=qcow2 \
  --disk path=/var/lib/libvirt/images/myvms/user-data.img,device=cdrom \
  --os-variant ubuntu22.04 \
  --network bridge=br0,model=virtio,virtualport_type=openvswitch \
  --graphics none \
  --noautoconsole \
  --channel unix,mode=bind,target_type=virtio,name=org.qemu.guest_agent.0 \
  --import


sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
iptables -t nat -A POSTROUTING -s $LAN_SUBNET -o $PRIMARY_IFACE -j MASQUERADE
iptables -A FORWARD -j ACCEPT

cat <<EOF >/etc/netplan/99-ovsbr0.yaml
network:
  version: 2
  bridges:
    br0:
      addresses: [10.200.0.1/16]
      parameters:
        stp: false
      interfaces: []
      dhcp4: no
EOF

chmod 0600 /etc/netplan/99-ovsbr0.yaml
netplan apply

netfilter-persistent save