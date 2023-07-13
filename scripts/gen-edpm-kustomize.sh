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
EOF

if [ -n "$BGP" ]; then
cat <<EOF >>kustomization.yaml
        - name: BgpNet1
          subnetName: subnet1
          fixedIP: 100.65.1.6
        - name: BgpNet2
          subnetName: subnet1
          fixedIP: 100.64.1.6
        - name: BgpMainNet
          subnetName: subnet1
          fixedIP: 172.30.1.2
        - name: BgpMainNet6
          subnetName: subnet1
          fixedIP: f00d:f00d:f00d:f00d:f00d:f00d:f00d:0012
EOF
fi

cat <<EOF >>kustomization.yaml
    - op: add
      path: /spec/services/0
      value: repo-setup
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/timesync_ntp_servers
      value:
        - {hostname: ${EDPM_NTP_SERVER}}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/neutron_public_interface_name
      value: ${EDPM_NETWORK_INTERFACE_NAME}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/registry_url
      value: ${EDPM_REGISTRY_URL}
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/image_prefix
      value: ${EDPM_CONTAINER_PREFIX}
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
EOF

if [ -n "$BGP" ]; then
cat <<EOF >>kustomization.yaml
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bridge_mappings
      value: ['bgp:br-provider']
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bgp_agent_expose_tenant_networks
      value: true
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bgp_agent_ovn_external_nics
      value: ['eth1', 'eth2']
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bgp_agent_ovn_peer_ips
      value: ['100.64.1.5', '100.65.1.5']
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bgp_agent_driver
      value: nb_ovn_bgp_driver
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bgp_agent_exposing_method
      value: ovn
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bgp_agent_provider_networks_pool_prefixes
      value: '172.16.0.0/16'
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_ovn_bgp_agent_ovn_routing
      value: true
EOF
fi

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
EOF
if [ -n "$BGP" ]; then
cat <<EOF >>kustomization.yaml
    - op: replace
      path: /spec/nodes/edpm-compute-${INDEX}/ansible/ansibleVars/edpm_ovn_bgp_agent_ovn_peer_ips
      value: ['100.64.$((1+${INDEX})).5', '100.65.$((1+${INDEX})).5']
EOF
fi
cat <<EOF >>kustomization.yaml
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
EOF
if [ -n "$BGP" ]; then
cat <<EOF >>kustomization.yaml
        - name: BgpNet1
          subnetName: subnet$((1+${INDEX}))
          fixedIP: 100.65.$((1+${INDEX})).6
        - name: BgpNet2
          subnetName: subnet$((1+${INDEX}))
          fixedIP: 100.64.$((1+${INDEX})).6
        - name: BgpMainNet
          subnetName: subnet$((1+${INDEX}))
          fixedIP: 172.30.$((1+${INDEX})).2
        - name: BgpMainNet6
          subnetName: subnet$((1+${INDEX}))
          fixedIP: 172.30.$((1+${INDEX})).2
          fixedIP: f00d:f00d:f00d:f00d:f00d:f00d:f00d:00$((1+${INDEX}))2
EOF
fi
    done
fi

cat <<EOF >>kustomization.yaml
    - op: replace
      path: /spec/nodeTemplate/ansible/ansibleVars/edpm_network_config_template
      value: |
        ---
        {% set mtu_list = [ctlplane_mtu] %}
        {% for network in role_networks %}
        {{ mtu_list.append(lookup('vars', networks_lower[network] ~ '_mtu')) }}
        {%- endfor %}
        {% set min_viable_mtu = mtu_list | max %}
        network_config:
        - type: interface
          name: nic1
          mtu: {{ ctlplane_mtu }}
          dns_servers: {{ ctlplane_dns_nameservers }}
          domain: {{ dns_search_domains }}
          use_dhcp: false
          addresses:
          - ip_netmask: {{ ctlplane_ip }}/{{ ctlplane_subnet_cidr }}
        {% for network in role_networks %}
        {% if lookup('vars', networks_lower[network] ~ '_vlan_id', default='') %}
        - type: vlan
          device: nic1
          mtu: {{ lookup('vars', networks_lower[network] ~ '_mtu') }}
          vlan_id: {{ lookup('vars', networks_lower[network] ~ '_vlan_id') }}
          addresses:
          - ip_netmask:
              {{ lookup('vars', networks_lower[network] ~ '_ip') }}/{{ lookup('vars', networks_lower[network] ~ '_cidr') }}
          routes: {{ lookup('vars', networks_lower[network] ~ '_host_routes') }}
        {% endif %}
        {%- endfor %}
        - type: ovs_bridge
          name: br-provider
          use_dhcp: false
        - type: ovs_bridge
          name: {{ neutron_physical_bridge_name }}
          mtu: {{ min_viable_mtu }}
          use_dhcp: false
          addresses:
          - ip_netmask: {{ lookup('vars', 'bgp_net1_ip') }}/30
          members:
          - type: interface
            name: nic2
            mtu: {{ min_viable_mtu }}
            # force the MAC address of the bridge to this interface
            primary: true
        - type: ovs_bridge
          name: {{ neutron_physical_bridge_name }}-2
          mtu: {{ min_viable_mtu }}
          use_dhcp: false
          addresses:
          - ip_netmask: {{ lookup('vars', 'bgp_net2_ip') }}/30
          members:
          - type: interface
            name: nic3
            mtu: {{ min_viable_mtu }}
            # force the MAC address of the bridge to this interface
            primary: true
        - type: interface
          name: lo
          addresses:
          - ip_netmask: {{ lookup('vars', 'bgp_main_net_ip') }}/32
          - ip_netmask: {{ lookup('vars', 'bgp_main_net6_ip') }}/128
EOF

kustomization_add_resources

popd
