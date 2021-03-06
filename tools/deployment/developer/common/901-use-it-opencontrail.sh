#!/bin/bash

# Copyright 2017 The Openstack-Helm Authors.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
set -xe

export OS_CLOUD=openstack_helm

export OSH_EXT_NET_NAME="public"
export OSH_EXT_SUBNET_NAME="public-subnet"
export OSH_EXT_SUBNET="172.24.4.0/24"
export OSH_BR_EX_ADDR="172.24.4.1/24"
openstack stack create --wait \
  --parameter network_name=${OSH_EXT_NET_NAME} \
  --parameter subnet_name=${OSH_EXT_SUBNET_NAME} \
  --parameter subnet_cidr=${OSH_EXT_SUBNET} \
  --parameter subnet_gateway=${OSH_BR_EX_ADDR%/*} \
  -t ./tools/gate/files/heat-public-net-deployment-opencontrail.yaml \
  heat-public-net-deployment

export OSH_EXT_NET_NAME="public"
export OSH_VM_KEY_STACK="heat-vm-key"
export OSH_PRIVATE_SUBNET="10.0.0.0/24"

# NOTE(portdirect): We do this fancy, and seemingly pointless, footwork to get
# the full image name for the cirros Image without having to be explicit.
export IMAGE_NAME=$(openstack image show -f value -c name \
  $(openstack image list -f csv | awk -F ',' '{ print $2 "," $1 }' | \
    grep "^\"Cirros" | head -1 | awk -F ',' '{ print $2 }' | tr -d '"'))

# Setup SSH Keypair in Nova
mkdir -p ${HOME}/.ssh
openstack keypair create --private-key ${HOME}/.ssh/osh_key ${OSH_VM_KEY_STACK}
chmod 600 ${HOME}/.ssh/osh_key

openstack stack create --wait \
    --parameter public_net=${OSH_EXT_NET_NAME} \
    --parameter image="${IMAGE_NAME}" \
    --parameter ssh_key=${OSH_VM_KEY_STACK} \
    --parameter cidr=${OSH_PRIVATE_SUBNET} \
    -t ./tools/gate/files/heat-basic-vm-deployment.yaml \
    heat-basic-vm-deployment

FLOATING_IP=$(openstack stack output show \
    heat-basic-vm-deployment \
    floating_ip \
    -f value -c output_value)

# TODO: provision simple gateway to allow work with floating IP-s

# TODO: fix this in case of many VM-s/devices
if_name=$(ip link | grep -io "tap[0-9a-z-]*")
FLOATING_IP=$(curl -s http://127.0.0.1:8085/Snh_ItfReq?name=$if_name | sed 's/^.*<mdata_ip_addr.*>\([0-9\.]*\)<.mdata_ip_addr>.*$/\1/')

function wait_for_ssh_port {
  # Default wait timeout is 300 seconds
  set +x
  end=$(date +%s)
  if ! [ -z $2 ]; then
   end=$((end + $2))
  else
   end=$((end + 300))
  fi
  while true; do
      # Use Nmap as its the same on Ubuntu and RHEL family distros
      nmap -Pn -p22 $1 | awk '$1 ~ /22/ {print $2}' | grep -q 'open' && \
          break || true
      sleep 1
      now=$(date +%s)
      [ $now -gt $end ] && echo "Could not connect to $1 port 22 in time" && exit -1
  done
  set -x
}
wait_for_ssh_port $FLOATING_IP

# SSH into the VM and check it can reach the outside world
ssh-keyscan "$FLOATING_IP" >> ~/.ssh/known_hosts
# TODO: restore test for outside world
#ssh -i ${HOME}/.ssh/osh_key cirros@${FLOATING_IP} ping -q -c 1 -W 2 8.8.8.8

# Check the VM can reach the metadata server
ssh -i ${HOME}/.ssh/osh_key cirros@${FLOATING_IP} curl --verbose --connect-timeout 5 169.254.169.254
