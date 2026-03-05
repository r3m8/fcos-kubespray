#!/bin/bash

# =============================================================================
# Kubernetes Cluster Deployment Script with Fedora CoreOS
# =============================================================================
# This script creates a Kubernetes cluster using Fedora CoreOS VMs via libvirt
# Topology: 2 networks × 3 VMs (control plane + worker combined) = 6 VMs total
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION VARIABLES - Modify these to customize your deployment
# =============================================================================

# Script metadata
SCRIPT_NAME=$(basename "$0")
USER="uni"

# Paths
STATE_LOCK_FILE="/var/lib/libvirt/conf/k8s-cluster-state.lock"
KUBESPRAY_DIR="/home/$USER/fcos/kubespray"
INVENTORY_DIR="${KUBESPRAY_DIR}/inventory/mycluster"
INVENTORY_FILE="${INVENTORY_DIR}/inventory.ini"
LIBVIRT_IMAGES_DIR="/var/lib/libvirt/images"
CONF_DIR="/var/lib/libvirt/conf"

# Fedora CoreOS Image
FCOS_IMAGE_NAME="fedora-coreos-43.20260217.3.1-qemu.x86_64.qcow2"
FCOS_IMAGE="${LIBVIRT_IMAGES_DIR}/${FCOS_IMAGE_NAME}"
FCOS_STREAM="stable"

# Network Configuration
NETWORK_1_NAME="k8s-net-1"
NETWORK_2_NAME="k8s-net-2"
NETWORK_1_CIDR="10.235.1.0/24"
NETWORK_2_CIDR="10.235.2.0/24"
NETWORK_1_GATEWAY="10.235.1.1"
NETWORK_2_GATEWAY="10.235.2.1"
NETWORK_1_DNS="1.1.1.1"
NETWORK_2_DNS="1.1.1.1"
NETWORK_INTERFACE="enp1s0"

# VM Configuration
VMS_PER_NETWORK=3
VM_RAM_MB=10240          # 10GB RAM
VM_VCPUS=8               # 8 vCPUs
VM_MAIN_DISK_GB=50       # Main disk for FCOS
VM_EXTRA_DISK_GB=100     # Additional disk for storage
VM_NAME_PREFIX="k8s-node"

# IP Configuration
NETWORK_1_IP_BASE="10.235.1"
NETWORK_2_IP_BASE="10.235.2"
IP_START=11              # First VM will get .11

# SSH Configuration
SSH_USER="ansibleUser"
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIRVkwktzS1+6dWwKRanRGU+ANjtgR5WIRu9e5sNCqgP"
SSH_PRIVATE_KEY="${HOME}/.ssh/id_rsa"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

usage() {
    echo "Usage: $SCRIPT_NAME {create|delete|deploy}"
    echo "  create - Create Kubernetes cluster VMs and networks"
    echo "  delete - Delete all VMs and networks created by this script"
    echo "  deploy - Deploy Kubernetes using Kubespray"
    exit 1
}

log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[✓] $1"
}

log_error() {
    echo "[✗] $1" >&2
}

log_warn() {
    echo "[!] $1"
}

# Function to wait for SSH connectivity
wait_for_ssh() {
    local ip=$1
    local max_attempts=60
    local attempt=0
    
    log_info "Waiting for SSH on ${ip}..."
    
    while [ $attempt -lt $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ${SSH_USER}@${ip} "echo SSH ready" &> /dev/null; then
            log_success "SSH connection successful to ${ip}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    
    log_error "Failed to establish SSH connection to ${ip} after ${max_attempts} attempts"
    return 1
}

# =============================================================================
# NETWORK MANAGEMENT
# =============================================================================

create_network_xml() {
    local name=$1
    local gateway=$2
    
    cat <<EOF
<network>
  <name>${name}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr-${name}' stp='on' delay='0'/>
  <dns enable='no'/>
  <ip address='${gateway}' netmask='255.255.255.0'/>
</network>
EOF
}

create_networks() {
    log_info "Creating libvirt networks..."
    
    # Ensure conf directory exists
    sudo mkdir -p "${CONF_DIR}"
    
    # Network 1
    if sudo virsh net-list --all | grep -q "${NETWORK_1_NAME}"; then
        log_warn "Network ${NETWORK_1_NAME} already exists, skipping creation"
    else
        log_info "Creating network ${NETWORK_1_NAME} (${NETWORK_1_CIDR})"
        local net1_xml="${CONF_DIR}/${NETWORK_1_NAME}.xml"
        create_network_xml "${NETWORK_1_NAME}" "${NETWORK_1_GATEWAY}" | sudo tee "${net1_xml}" > /dev/null
        sudo virsh net-define "${net1_xml}"
        sudo virsh net-autostart "${NETWORK_1_NAME}"
        sudo virsh net-start "${NETWORK_1_NAME}"
        log_success "Network ${NETWORK_1_NAME} created and started"
    fi
    
    # Network 2
    if sudo virsh net-list --all | grep -q "${NETWORK_2_NAME}"; then
        log_warn "Network ${NETWORK_2_NAME} already exists, skipping creation"
    else
        log_info "Creating network ${NETWORK_2_NAME} (${NETWORK_2_CIDR})"
        local net2_xml="${CONF_DIR}/${NETWORK_2_NAME}.xml"
        create_network_xml "${NETWORK_2_NAME}" "${NETWORK_2_GATEWAY}" | sudo tee "${net2_xml}" > /dev/null
        sudo virsh net-define "${net2_xml}"
        sudo virsh net-autostart "${NETWORK_2_NAME}"
        sudo virsh net-start "${NETWORK_2_NAME}"
        log_success "Network ${NETWORK_2_NAME} created and started"
    fi
}

delete_networks() {
    log_info "Deleting libvirt networks..."
    
    # Network 1
    if sudo virsh net-list --all | grep -q "${NETWORK_1_NAME}"; then
        log_info "Stopping and deleting network ${NETWORK_1_NAME}"
        sudo virsh net-destroy "${NETWORK_1_NAME}" 2>/dev/null || true
        sudo virsh net-undefine "${NETWORK_1_NAME}"
        log_success "Network ${NETWORK_1_NAME} deleted"
    fi
    
    # Network 2
    if sudo virsh net-list --all | grep -q "${NETWORK_2_NAME}"; then
        log_info "Stopping and deleting network ${NETWORK_2_NAME}"
        sudo virsh net-destroy "${NETWORK_2_NAME}" 2>/dev/null || true
        sudo virsh net-undefine "${NETWORK_2_NAME}"
        log_success "Network ${NETWORK_2_NAME} deleted"
    fi
    
    # Cleanup network XML files
    sudo rm -f "${CONF_DIR}/${NETWORK_1_NAME}.xml"
    sudo rm -f "${CONF_DIR}/${NETWORK_2_NAME}.xml"
}

# =============================================================================
# BUTANE/IGNITION CONFIGURATION GENERATION
# =============================================================================

generate_butane_config() {
    local vm_name=$1
    local ip_address=$2
    local gateway=$3
    local dns=$4
    local interface=$5
    
    cat <<EOF
variant: fcos
version: 1.6.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ${SSH_KEY}
    - name: ${SSH_USER}
      groups:
        - wheel
      ssh_authorized_keys:
        - ${SSH_KEY}
storage:
  files:
    - path: /etc/NetworkManager/system-connections/${interface}.nmconnection
      mode: 0600
      contents:
        inline: |
          [connection]
          id=${interface}
          type=ethernet
          interface-name=${interface}
          
          [ipv4]
          address1=${ip_address}/24,${gateway}
          dns=${dns};
          method=manual
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: ${vm_name}
    - path: /etc/sudoers.d/wheel-nopasswd
      mode: 0440
      contents:
        inline: |
          %wheel ALL=(ALL) NOPASSWD: ALL
systemd:
  units:
    - name: install-python.service
      enabled: true
      contents: |
        [Unit]
        Description=Layer Python3 and dependencies for Ansible
        Wants=network-online.target
        After=network-online.target
        Before=zincati.service
        ConditionPathExists=!/var/lib/python-installed
        
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/bin/rpm-ostree install --apply-live --allow-inactive python3 python3-pip python3-libselinux
        ExecStart=/usr/bin/touch /var/lib/python-installed
        
        [Install]
        WantedBy=multi-user.target
EOF
}

# =============================================================================
# VM CREATION
# =============================================================================

create_vm() {
    local vm_name=$1
    local network_name=$2
    local ip_address=$3
    local gateway=$4
    local dns=$5
    local vm_index=$6
    local network_index=$7
    
    log_info "Creating VM ${vm_name} on network ${network_name} with IP ${ip_address}"
    
    # Paths for configs
    local butane_config="${CONF_DIR}/${vm_name}.bu"
    local ignition_config="${CONF_DIR}/${vm_name}.ign"
    local extra_disk_path="${LIBVIRT_IMAGES_DIR}/${vm_name}-extra.qcow2"
    
    # Generate Butane config
    generate_butane_config "${vm_name}" "${ip_address}" "${gateway}" "${dns}" "${NETWORK_INTERFACE}" | sudo tee "${butane_config}" > /dev/null
    
    # Convert Butane to Ignition
    log_info "Generating Ignition config for ${vm_name}"
    sudo podman run --interactive --rm quay.io/coreos/butane:release --pretty --strict < "${butane_config}" | sudo tee "${ignition_config}" > /dev/null
    
    # Create extra disk
    log_info "Creating extra disk (${VM_EXTRA_DISK_GB}GB) for ${vm_name}"
    sudo qemu-img create -f qcow2 "${extra_disk_path}" "${VM_EXTRA_DISK_GB}G"
    
    # Create VM with virt-install
    local ignition_device_arg="--qemu-commandline=-fw_cfg name=opt/com.coreos/config,file=${ignition_config}"
    
    sudo virt-install \
        --connect="qemu:///system" \
        --name="${vm_name}" \
        --vcpus="${VM_VCPUS}" \
        --memory="${VM_RAM_MB}" \
        --os-variant="fedora-coreos-${FCOS_STREAM}" \
        --import \
        --graphics=none \
        --noautoconsole \
        --disk="size=${VM_MAIN_DISK_GB},backing_store=${FCOS_IMAGE}" \
        --disk="path=${extra_disk_path},format=qcow2" \
        --network network="${network_name}" \
        "${ignition_device_arg}"
    
    # Get disk path for state file
    local main_disk_path
    main_disk_path=$(sudo virsh domblklist "${vm_name}" --details | grep "vda\|sda\|hda" | awk '{print $4}' || echo "")
    
    # Save VM info to state lock file
    echo "VM_NAME=${vm_name}|MAIN_DISK=${main_disk_path}|EXTRA_DISK=${extra_disk_path}|IP=${ip_address}|NETWORK=${network_name}|NETWORK_INDEX=${network_index}|VM_INDEX=${vm_index}" | sudo tee -a "${STATE_LOCK_FILE}" > /dev/null
    
    log_success "Created ${vm_name} with IP ${ip_address}"
}

create_cluster() {
    log_info "Starting Kubernetes cluster creation..."
    log_info "Topology: 2 networks × ${VMS_PER_NETWORK} VMs = $((2 * VMS_PER_NETWORK)) VMs total"
    log_info "Each VM: ${VM_VCPUS} vCPUs, ${VM_RAM_MB}MB RAM, ${VM_MAIN_DISK_GB}GB + ${VM_EXTRA_DISK_GB}GB disks"
    
    # Check if FCOS image exists
    if [ ! -f "${FCOS_IMAGE}"; then
        log_error "Fedora CoreOS image not found at ${FCOS_IMAGE}"
        log_info "Please download the image first:"
        log_info "  wget -P ${LIBVIRT_IMAGES_DIR} https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/43.20260217.3.1/x86_64/${FCOS_IMAGE_NAME}"
        exit 1
    fi
    
    # Create networks
    create_networks
    
    # Initialize state lock file
    echo "# Kubernetes Cluster State Lock File" | sudo tee "${STATE_LOCK_FILE}" > /dev/null
    echo "# Created: $(date)" | sudo tee -a "${STATE_LOCK_FILE}" > /dev/null
    echo "# Topology: 2 networks × ${VMS_PER_NETWORK} VMs (control plane + worker)" | sudo tee -a "${STATE_LOCK_FILE}" > /dev/null
    echo "" | sudo tee -a "${STATE_LOCK_FILE}" > /dev/null
    
    # Create VMs for Network 1
    log_info "Creating VMs for Network 1 (${NETWORK_1_NAME})..."
    for i in $(seq 1 ${VMS_PER_NETWORK}); do
        local vm_name="${VM_NAME_PREFIX}-n1-${i}"
        local ip_offset=$((IP_START + i - 1))
        local ip_address="${NETWORK_1_IP_BASE}.${ip_offset}"
        
        create_vm "${vm_name}" "${NETWORK_1_NAME}" "${ip_address}" "${NETWORK_1_GATEWAY}" "${NETWORK_1_DNS}" "$i" "1"
    done
    
    # Create VMs for Network 2
    log_info "Creating VMs for Network 2 (${NETWORK_2_NAME})..."
    for i in $(seq 1 ${VMS_PER_NETWORK}); do
        local vm_name="${VM_NAME_PREFIX}-n2-${i}"
        local ip_offset=$((IP_START + i - 1))
        local ip_address="${NETWORK_2_IP_BASE}.${ip_offset}"
        
        create_vm "${vm_name}" "${NETWORK_2_NAME}" "${ip_address}" "${NETWORK_2_GATEWAY}" "${NETWORK_2_DNS}" "$i" "2"
    done
    
    echo ""
    log_success "All VMs created successfully!"
    echo ""
    echo "=========================================="
    echo "Cluster Summary:"
    echo "=========================================="
    echo "Network 1 (${NETWORK_1_NAME}): ${NETWORK_1_CIDR}"
    for i in $(seq 1 ${VMS_PER_NETWORK}); do
        local ip="${NETWORK_1_IP_BASE}.$((IP_START + i - 1))"
        echo "  - ${VM_NAME_PREFIX}-n1-${i}: ${ip} (Control Plane + Worker)"
    done
    echo ""
    echo "Network 2 (${NETWORK_2_NAME}): ${NETWORK_2_CIDR}"
    for i in $(seq 1 ${VMS_PER_NETWORK}); do
        local ip="${NETWORK_2_IP_BASE}.$((IP_START + i - 1))"
        echo "  - ${VM_NAME_PREFIX}-n2-${i}: ${ip} (Control Plane + Worker)"
    done
    echo ""
    echo "VM Specifications:"
    echo "  - RAM: ${VM_RAM_MB}MB (${VM_RAM_MB} / 1024 GB)"
    echo "  - vCPUs: ${VM_VCPUS}"
    echo "  - Main Disk: ${VM_MAIN_DISK_GB}GB"
    echo "  - Extra Disk: ${VM_EXTRA_DISK_GB}GB"
    echo ""
    echo "State file saved to: ${STATE_LOCK_FILE}"
    echo ""
    echo "NOTE: Python3 installation will happen automatically on first boot."
    echo "This may take 2-3 minutes per node."
    echo ""
    
    # Test SSH connectivity
    test_ssh_connectivity
}

# =============================================================================
# SSH CONNECTIVITY TEST
# =============================================================================

test_ssh_connectivity() {
    echo ""
    echo "=========================================="
    echo "Testing SSH connectivity to ALL nodes..."
    echo "=========================================="
    echo ""
    
    declare -a vm_ips
    declare -a vm_names
    
    # Collect all VM information
    while IFS= read -r vm_line; do
        [[ "$vm_line" =~ ^#.*$ ]] && continue
        [[ -z "$vm_line" ]] && continue
        
        IFS='|' read -ra FIELDS <<< "$vm_line"
        
        local vm_name=""
        local vm_ip=""
        
        for field in "${FIELDS[@]}"; do
            case "$field" in
                VM_NAME=*) vm_name="${field#VM_NAME=}" ;;
                IP=*) vm_ip="${field#IP=}" ;;
            esac
        done
        
        if [[ -n "$vm_name" && -n "$vm_ip" ]]; then
            vm_names+=("$vm_name")
            vm_ips+=("$vm_ip")
        fi
    done < <(sudo cat "${STATE_LOCK_FILE}")
    
    local total_nodes=${#vm_names[@]}
    log_info "Found ${total_nodes} nodes to test"
    echo ""
    
    local all_ssh_success=true
    declare -a failed_nodes
    
    for i in "${!vm_names[@]}"; do
        local node_num=$((i + 1))
        echo "[${node_num}/${total_nodes}] Testing ${vm_names[$i]} (${vm_ips[$i]})"
        
        if ! wait_for_ssh "${vm_ips[$i]}"; then
            all_ssh_success=false
            failed_nodes+=("${vm_names[$i]} (${vm_ips[$i]})")
        fi
        echo ""
    done
    
    echo "=========================================="
    
    if [ "$all_ssh_success" = true ]; then
        log_success "All ${total_nodes} nodes are accessible via SSH as ${SSH_USER}"
        echo "=========================================="
        echo ""
        log_success "Cluster is ready for Kubespray deployment!"
        echo "Run: $SCRIPT_NAME deploy"
        exit 0
    else
        log_error "SSH connectivity test FAILED for the following nodes:"
        echo ""
        for failed_node in "${failed_nodes[@]}"; do
            echo "  - ${failed_node}"
        done
        echo ""
        echo "Total: ${#failed_nodes[@]} out of ${total_nodes} nodes failed"
        echo "=========================================="
        exit 1
    fi
}

# =============================================================================
# KUBESPRAY DEPLOYMENT
# =============================================================================

deploy_kubespray() {
    echo "=========================================="
    echo "Deploying Kubernetes with Kubespray"
    echo "=========================================="
    echo ""
    
    # Check prerequisites
    if [ ! -f "${STATE_LOCK_FILE}" ]; then
        log_error "State lock file not found at ${STATE_LOCK_FILE}"
        log_info "Please run '$SCRIPT_NAME create' first to create the cluster VMs."
        exit 1
    fi
    
    if [ ! -d "${KUBESPRAY_DIR}" ]; then
        log_error "Kubespray directory not found at ${KUBESPRAY_DIR}"
        log_info "Please clone kubespray repository first."
        exit 1
    fi

    if [ ! -d "${INVENTORY_DIR}" ]; then
        log_error "Kubespray cluster directory not found at ${INVENTORY_DIR}"
        log_info "Please create the folder or copy inventory/sample/ first."
        exit 1
    fi
    
    log_info "Step 1: Generating Ansible inventory from state lock file..."
    echo ""
    
    # Parse all nodes from state file
    declare -a all_nodes
    
    while IFS= read -r vm_line; do
        [[ "$vm_line" =~ ^#.*$ ]] && continue
        [[ -z "$vm_line" ]] && continue
        
        IFS='|' read -ra FIELDS <<< "$vm_line"
        
        local vm_name=""
        local vm_ip=""
        local network_index=""
        local vm_index=""
        
        for field in "${FIELDS[@]}"; do
            case "$field" in
                VM_NAME=*) vm_name="${field#VM_NAME=}" ;;
                IP=*) vm_ip="${field#IP=}" ;;
                NETWORK_INDEX=*) network_index="${field#NETWORK_INDEX=}" ;;
                VM_INDEX=*) vm_index="${field#VM_INDEX=}" ;;
            esac
        done
        
        if [[ -n "$vm_name" && -n "$vm_ip" && -n "$network_index" && -n "$vm_index" ]]; then
            all_nodes+=("${vm_name}|${vm_ip}|${network_index}|${vm_index}")
        fi
    done < <(sudo cat "${STATE_LOCK_FILE}")
    
    # Generate inventory file
    # All nodes are both control plane and workers (combined topology)
    cat > "${INVENTORY_FILE}" <<EOF
# Kubernetes Cluster Inventory
# Topology: 2 networks × ${VMS_PER_NETWORK} nodes (combined control plane + worker)
# Generated: $(date)

[kube_control_plane]
EOF

    # Add all nodes as control planes with etcd member names
    local etcd_counter=1
    for node_info in "${all_nodes[@]}"; do
        local node_name=$(echo "$node_info" | cut -d'|' -f1)
        local node_ip=$(echo "$node_info" | cut -d'|' -f2)
        echo "${node_name} ansible_host=${node_ip} ansible_user=${SSH_USER} etcd_member_name=etcd${etcd_counter}" >> "${INVENTORY_FILE}"
        etcd_counter=$((etcd_counter + 1))
    done
    
    # Add etcd section (same as control plane)
    cat >> "${INVENTORY_FILE}" <<EOF

[etcd:children]
kube_control_plane

[kube_node]
EOF

    # Add all nodes as workers
    for node_info in "${all_nodes[@]}"; do
        local node_name=$(echo "$node_info" | cut -d'|' -f1)
        local node_ip=$(echo "$node_info" | cut -d'|' -f2)
        echo "${node_name} ansible_host=${node_ip} ansible_user=${SSH_USER}" >> "${INVENTORY_FILE}"
    done
    
    # Add k8s_cluster group
    cat >> "${INVENTORY_FILE}" <<EOF

[k8s_cluster:children]
kube_control_plane
kube_node
EOF
    
    log_success "Inventory file generated at: ${INVENTORY_FILE}"
    echo ""
    echo "Inventory contents:"
    echo "-------------------"
    cat "${INVENTORY_FILE}"
    echo "-------------------"
    echo ""
    
    # Change to kubespray directory
    cd "${KUBESPRAY_DIR}" || exit 1
    
    # Check virtual environment
    if [ ! -d ".venv" ]; then
        log_error "Python virtual environment not found at ${KUBESPRAY_DIR}/.venv"
        log_info "Please set up kubespray first (pip install -r requirements.txt)"
        exit 1
    fi
    
    log_info "Step 2: Activating Python virtual environment..."
    source .venv/bin/activate
    log_success "Virtual environment activated"
    echo ""
    
    log_info "Step 3: Verifying Python installation on all nodes..."
    echo ""
    
    # Verify Python is installed
    local python_check_failed=false
    for node_info in "${all_nodes[@]}"; do
        local node_ip=$(echo "$node_info" | cut -d'|' -f2)
        echo -n "Checking Python on ${node_ip}... "
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${SSH_USER}@${node_ip} "which python3" &> /dev/null; then
            echo "✓"
        else
            echo "✗ Python not found"
            python_check_failed=true
        fi
    done
    echo ""
    
    if [ "$python_check_failed" = true ]; then
        log_error "Python is not installed on some nodes"
        log_info "Please wait a few more minutes for rpm-ostree to complete, then try again"
        deactivate
        exit 1
    fi
    
    log_info "Step 4: Testing Ansible connectivity to all nodes..."
    echo ""
    
    if ansible -i "${INVENTORY_FILE}" -m ping all; then
        echo ""
        log_success "All nodes are reachable via Ansible"
        echo ""
    else
        echo ""
        log_error "Ansible connectivity test failed"
        log_info "Please check your SSH keys and network configuration"
        deactivate
        exit 1
    fi
    
    log_info "Step 5: Deploying Kubernetes cluster with Kubespray..."
    log_info "This may take 15-30 minutes depending on your system..."
    echo ""
    
    if ansible-playbook -i "${INVENTORY_FILE}" cluster.yml \
        -b -v --private-key="${SSH_PRIVATE_KEY}"; then
        echo ""
        echo "=========================================="
        log_success "Kubernetes cluster deployed successfully!"
        echo "=========================================="
        echo ""
        log_info "To access your cluster:"
        local first_node_ip=$(echo "${all_nodes[0]}" | cut -d'|' -f2)
        echo "1. SSH to a control plane node: ssh ${SSH_USER}@${first_node_ip}"
        echo "2. Create .kube folder: mkdir ~/.kube"
        echo "3. Copy kubeconfig: sudo cp /etc/kubernetes/admin.conf ~/.kube/config"
        echo "4. Set permissions: sudo chown ${SSH_USER}:${SSH_USER} ~/.kube/config"
        echo "5. Run: kubectl get nodes"
        echo ""
    else
        echo ""
        log_error "Kubernetes deployment failed"
        log_info "Check the Ansible output above for errors"
        deactivate
        exit 1
    fi
    
    deactivate
}

# =============================================================================
# CLUSTER DELETION
# =============================================================================

delete_cluster() {
    if [ ! -f "${STATE_LOCK_FILE}" ]; then
        log_error "State lock file not found at ${STATE_LOCK_FILE}"
        log_info "No cluster to delete or file has been moved."
        exit 1
    fi

    log_info "Reading cluster state from ${STATE_LOCK_FILE}"
    echo ""
    
    # Read and delete each VM
    while IFS='|' read -r vm_entry; do
        [[ "$vm_entry" =~ ^#.*$ ]] && continue
        [[ -z "$vm_entry" ]] && continue
        
        local vm_name=""
        local main_disk=""
        local extra_disk=""
        
        IFS='|' read -ra FIELDS <<< "$vm_entry"
        for field in "${FIELDS[@]}"; do
            case "$field" in
                VM_NAME=*) vm_name="${field#VM_NAME=}" ;;
                MAIN_DISK=*) main_disk="${field#MAIN_DISK=}" ;;
                EXTRA_DISK=*) extra_disk="${field#EXTRA_DISK=}" ;;
            esac
        done
        
        if [ -z "$vm_name" ]; then
            continue
        fi
        
        log_info "Deleting VM: ${vm_name}"
        
        # Check if VM exists
        if sudo virsh list --all | grep -q "${vm_name}"; then
            # Stop VM if running
            if sudo virsh list --state-running | grep -q "${vm_name}"; then
                log_info "  Stopping ${vm_name}..."
                sudo virsh destroy "${vm_name}" 2>/dev/null || true
            fi
            
            # Undefine VM and remove storage
            log_info "  Removing VM definition and storage..."
            sudo virsh undefine "${vm_name}" --remove-all-storage 2>/dev/null || true
            
            log_success "  ${vm_name} deleted"
        else
            log_warn "  ${vm_name} not found (may have been manually deleted)"
        fi
        
        # Remove extra disk if it still exists
        if [ -n "${extra_disk}" ] && sudo [ -f "${extra_disk}" ]; then
            log_info "  Removing extra disk: ${extra_disk}"
            sudo rm -f "${extra_disk}"
        fi
        
        # Remove config files
        local butane_config="${CONF_DIR}/${vm_name}.bu"
        local ignition_config="${CONF_DIR}/${vm_name}.ign"
        sudo rm -f "${butane_config}" "${ignition_config}"
        
        echo ""
        
    done < <(sudo cat "${STATE_LOCK_FILE}")
    
    # Delete networks
    delete_networks
    
    # Remove state lock file
    log_info "Removing state lock file..."
    sudo rm -f "${STATE_LOCK_FILE}"
    
    # Remove inventory file if it exists
    if [ -f "${INVENTORY_FILE}" ]; then
        log_info "Removing Ansible inventory file..."
        rm -f "${INVENTORY_FILE}"
    fi
    
    log_success "Cluster deletion completed!"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

if [ $# -eq 0 ]; then
    usage
fi

MODE=$1

case "$MODE" in
    create)
        create_cluster
        ;;
    delete)
        delete_cluster
        ;;
    deploy)
        deploy_kubespray
        ;;
    *)
        log_error "Invalid mode '$MODE'"
        usage
        ;;
esac
