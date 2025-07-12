#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

check_kvm_ok() {
    if command -v kvm-ok &>/dev/null; then
        kvm_ok_output=$(kvm-ok 2>&1)
        echo "$kvm_ok_output" | grep -q "KVM acceleration can be used"
        if [ $? -eq 0 ]; then
            echo "kvm-ok: KVM acceleration is available."
            return 0
        else
            echo "kvm-ok: KVM acceleration is NOT available."
            return 1
        fi
    else
        echo "kvm-ok command not found; skipping kvm-ok check."
        return 2
    fi
}

virt_type=$(hostnamectl | grep Virtualization | awk '{print $2}')

# Install CPU-Checker if not present
if ! command -v kvm-ok &>/dev/null; then
    apt install cpu-checker
    check_kvm_ok
    kvm_ok_status=$?
fi

echo $kvm_ok_status