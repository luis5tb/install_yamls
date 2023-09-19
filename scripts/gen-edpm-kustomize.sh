#!/bin/bash
#
# Copyright 2023 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
set -ex

# expect that the common.sh is in the same dir as the calling script
SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. ${SCRIPTPATH}/common.sh --source-only

if [ -z "$NAMESPACE" ]; then
    echo "Please set NAMESPACE"; exit 1
fi

if [ -z "$KIND" ]; then
    echo "Please set SERVICE"; exit 1
fi

if [ -z "$DEPLOY_DIR" ]; then
    echo "Please set DEPLOY_DIR"; exit 1
fi

NAME=${KIND,,}

if [ ! -d ${DEPLOY_DIR} ]; then
    mkdir -p ${DEPLOY_DIR}
fi

pushd ${DEPLOY_DIR}

cat <<EOF >kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
namespace: ${NAMESPACE}
patches:
- target:
    kind: ${KIND}
  patch: |-
    - op: replace
      path: /spec/deployStrategy/deploy
      value: true
    - op: replace
      path: /spec/preProvisioned
      value: true
    - op: replace
      path: /spec/nodes/edpm-compute-0/ansible/ansibleHost
      value: ${EDPM_COMPUTE_IP}
    - op: remove
      path: /spec/nodes/edpm-compute-0/ansible/ansibleVars
    - op: replace
      path: /spec/nodes/edpm-compute-0/networks
      value:
        - name: CtlPlane
          subnetName: subnet1
          defaultRoute: true
          fixedIP: ${EDPM_COMPUTE_IP}
        - name: InternalApi
          subnetName: subnet1
        - name: Storage
          subnetName: subnet1
        - name: Tenant
          subnetName: subnet1
        - name: BgpNet1
          subnetName: subnet1
        - name: BgpNet2
          subnetName: subnet1
    - op: add
      path: /spec/services/0
      value: repo-setup
    - op: add
      path: /spec/services/4
      value: install-frr
    - op: add
      path: /spec/services/5
      value: install-ovn-bgp-agent
    - op: add
      path: /spec/services/7
      value: configure-frr
    - op: add
      path: /spec/services/8
      value: configure-ovn-bgp-agent
    - op: add
      path: /spec/services/10
      value: run-frr
    - op: add
      path: /spec/services/13
      value: run-ovn-bgp-agent
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_chrony_ntp_servers
      value:
        - ${EDPM_CHRONY_NTP_SERVER}
    - op: add
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_network_config_template
      value: ${EDPM_NETWORK_CONFIG_TEMPLATE}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/neutron_public_interface_name
      value: ${EDPM_NETWORK_INTERFACE_NAME}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/registry_url
      value: ${EDPM_REGISTRY_URL}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/image_tag
      value: ${EDPM_CONTAINER_TAG}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_sshd_allowed_ranges
      value: ${EDPM_SSHD_ALLOWED_RANGES}
    - op: add
      path: /spec/env/0
      value: {"name": "ANSIBLE_CALLBACKS_ENABLED", "value": "profile_tasks"}
    - op: replace
      path: /spec/nodeTemplate/ansibleSSHPrivateKeySecret
      value: ${EDPM_ANSIBLE_SECRET}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleUser
      value: ${EDPM_ANSIBLE_USER:-"cloud-admin"}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_frr_bgp_uplinks
      value: ['nic2', 'nic3']
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bgp_agent_expose_tenant_networks
      value: true
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_frr_bgp_neighbor_password
      value: f00barZ
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bridge_mappings
      value: ['provider1:br-ex', 'provider2:br-vlan']
EOF
if oc get pvc ansible-ee-logs -n ${NAMESPACE} 2>&1 1>/dev/null; then
cat <<EOF >>kustomization.yaml
    - op: replace
      path: /spec/nodeTemplate/extraMounts
      value:
        - extraVolType: Logs
          volumes:
          - name: ansible-logs
            persistentVolumeClaim:
              claimName: ansible-ee-logs
          mounts:
          - name: ansible-logs
            mountPath: "/runner/artifacts"
EOF
fi
if [ "$EDPM_TOTAL_NODES" -gt 1 ]; then
    for INDEX in $(seq 1 $((${EDPM_TOTAL_NODES} -1))) ; do
cat <<EOF >>kustomization.yaml
    - op: copy
      from: /spec/nodes/edpm-compute-0
      path: /spec/nodes/edpm-compute-${INDEX}
    - op: replace
      path: /spec/nodes/edpm-compute-${INDEX}/ansible/ansibleHost
      value: 192.168.122.$((100+${INDEX}))
    - op: replace
      path: /spec/nodes/edpm-compute-${INDEX}/hostName
      value: edpm-compute-${INDEX}
    - op: add
      path: /spec/nodes/edpm-compute-${INDEX}/networks
      value:
        - name: CtlPlane
          subnetName: subnet1
          defaultRoute: true
          fixedIP: 192.168.122.$((100+${INDEX}))
        - name: InternalApi
          subnetName: subnet1
        - name: Storage
          subnetName: subnet1
        - name: Tenant
          subnetName: subnet1
        - name: BgpNet1
          subnetName: subnet1
          fixedIP: 100.65.$((1+${INDEX})).6
        - name: BgpNet2
          subnetName: subnet1
          fixedIP: 100.64.0.6
EOF
    done
fi

# This is not working
#cat <<EOF >>kustomization.yaml
#    - op: replace
#      path: /spec/roles/edpm-compute/nodeTemplate/networkConfig
#      value:
#        template: |
#          ---
#          network_config:
#          - type: interface
#            name: nic1
#            mtu: {{ lookup('vars', 'ctlplane_mtu') }}
#            dns_servers: {{ lookup('vars', 'ctlplane_dns_nameservers') }}
#            domain: {{ lookup('vars', 'dns_search_domains') }}
#            routes: {{ lookup('vars', 'ctlplane_host_routes') }}
#            use_dhcp: false
#            addresses:
#            - ip_netmask: {{ lookup('vars', 'ctlplane_ip') }}/{{ lookup('vars', 'ctlplane_subnet_cidr') }}
#          {% for network in lookup('vars', 'role_networks') %}
#          - type: vlan
#            device: nic1
#            mtu: {{ lookup('vars', networks_lower[network] ~ '_mtu') }}
#            vlan_id: {{ lookup('vars', networks_lower[network] ~ '_vlan_id') }}
#            addresses:
#            - ip_netmask: {{ lookup('vars', networks_lower[network] ~ '_ip') }}/{{ lookup('vars', networks_lower[network] ~ '_cidr') }}
#            routes: {{ lookup('vars', networks_lower[network] ~ '_host_routes') }}
#          {% endfor %}
#          - type: ovs_bridge
#            name: {{ lookup('vars', 'neutron_physical_bridge_name') }}
#            use_dhcp: false
#          - type: ovs_bridge
#            name: br-vlan
#            use_dhcp: false
#EOF

kustomization_add_resources

popd
