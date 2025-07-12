#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

apt update && apt upgrade -y
apt install curl wget git -y

git clone https://github.com/DragonDevCC/GlueBoot.git

bash GlueBoot/preflight.sh



