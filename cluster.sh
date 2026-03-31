#!/bin/bash

# =============================================================================
# Kubernetes Cluster Deployment Script - Multi-Cluster Edition
# =============================================================================
# Deploys 2 independent Kubernetes clusters in parallel
# Each cluster: 3 VMs (control plane + worker) on separate networks
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION VARIABLES
# =============================================================================

SCRIPT_NAME=$(basename "$0")
USER="uni"

# Paths
LIBVIRT_IMAGES_DIR="/var/lib/libvirt/images"
CONF_DIR="/var/lib/libvirt/conf"
KUBESPRAY_DIR="/home/$USER/fcos/kubespray"

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

# Cluster 1 Configuration
CLUSTER_1_NAME="cluster-1"
CLUSTER_1_PREFIX="k8s-c1"
CLUSTER_1_STATE="${CONF_DIR}/k8s-cluster-1-state.lock"
CLUSTER_1_INVENTORY_DIR="${KUBESPRAY_DIR}/inventory/${CLUSTER_1_NAME}"
CLUSTER_1_INVENTORY="${CLUSTER_1_INVENTORY_DIR}/inventory.ini"
CLUSTER_1_NETWORK="${NETWORK_1_NAME}"
CLUSTER_1_GATEWAY="${NETWORK_1_GATEWAY}"
CLUSTER_1_DNS="${NETWORK_1_DNS}"
CLUSTER_1_IP_BASE="10.235.1"

# Cluster 2 Configuration
CLUSTER_2_NAME="cluster-2"
CLUSTER_2_PREFIX="k8s-c2"
CLUSTER_2_STATE="${CONF_DIR}/k8s-cluster-2-state.lock"
CLUSTER_2_INVENTORY_DIR="${KUBESPRAY_DIR}/inventory/${CLUSTER_2_NAME}"
CLUSTER_2_INVENTORY="${CLUSTER_2_INVENTORY_DIR}/inventory.ini"
CLUSTER_2_NETWORK="${NETWORK_2_NAME}"
CLUSTER_2_GATEWAY="${NETWORK_2_GATEWAY}"
CLUSTER_2_DNS="${NETWORK_2_DNS}"
CLUSTER_2_IP_BASE="10.235.2"

# VM Configuration
VMS_PER_CLUSTER=3
VM_RAM_MB=10240
VM_VCPUS=8
VM_MAIN_DISK_GB=50
VM_EXTRA_DISK_GB=100
IP_START=11

# SSH Configuration
SSH_USER="ansibleUser"
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIRVkwktzS1+6dWwKRanRGU+ANjtgR5WIRu9e5sNCqgP"
SSH_PRIVATE_KEY="${HOME}/.ssh/id_rsa"

# Target cluster (empty = all, 1 = cluster-1, 2 = cluster-2)
TARGET_CLUSTER=""

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

usage() {
    echo "Usage: $SCRIPT_NAME {create|delete|deploy} [--cluster 1|2]"
    echo ""
    echo "Commands:"
    echo "  create  - Create Kubernetes cluster VMs and networks"
    echo "  delete  - Delete all VMs and networks created by this script"
    echo "  deploy  - Deploy Kubernetes using Kubespray"
    echo ""
    echo "Options:"
    echo "  --cluster 1|2  - Target only cluster 1 or 2 (default: both)"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME create              # Create both clusters"
    echo "  $SCRIPT_NAME create --cluster 1  # Create only cluster 1"
    echo "  $SCRIPT_NAME deploy              # Deploy both clusters"
    echo "  $SCRIPT_NAME deploy --cluster 2  # Deploy only cluster 2"
    echo "  $SCRIPT_NAME delete              # Delete both clusters"
    echo "  $SCRIPT_NAME delete --cluster 1  # Delete only cluster 1"
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

log_cluster() {
    local cluster=$1
    local message=$2
    echo "[CLUSTER-$cluster] $message"
}

parse_args() {
    if [ $# -eq 0 ]; then
        usage
    fi
    
    MODE=$1
    shift
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster)
                if [ -n "${2:-}" ] && [[ "$2" =~ ^[12]$ ]]; then
                    TARGET_CLUSTER="$2"
                    shift 2
                else
                    log_error "--cluster requires argument 1 or 2"
                    exit 1
                fi
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

wait_for_ssh() {
    local ip=$1
    local max_attempts=60
    local attempt=0
    
    log_info "Waiting for SSH on ${ip}..."
    
    while [ $attempt -lt $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ${SSH_USER}@${ip} "echo SSH ready" &> /dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    
    return 1
}

# =============================================================================
# DEPENDENCIES
# =============================================================================

install_dependencies() {
    log_info "Checking and installing dependencies..."
    
    sudo apt-get update
    
    local packages="git libvirt-daemon libvirt-clients sudo podman virt-install qemu-utils python3.13-venv"
    
    for pkg in $packages; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            log_success "$pkg is already installed"
        else
            log_info "Installing $pkg..."
            sudo apt-get install -y "$pkg"
        fi
    done
    
    sudo systemctl enable libvirtd
    sudo systemctl start libvirtd
    
    log_success "All dependencies installed"
}

fix_apparmor() {
    log_info "Applying AppArmor fix for libvirt..."
    
    local apparmor_file="/etc/apparmor.d/abstractions/libvirt-qemu"
    
    if ! command -v aa-status &> /dev/null; then
        log_warn "AppArmor not found, skipping fix"
        return 0
    fi
    
    if grep -q "/var/lib/libvirt/conf/" "$apparmor_file" 2>/dev/null; then
        log_info "AppArmor rules already applied"
        return 0
    fi
    
    log_info "Adding AppArmor rules for /var/lib/libvirt/conf/"
    sudo cp "$apparmor_file" "${apparmor_file}.backup.$(date +%Y%m%d%H%M%S)"
    
    if grep -q "^[[:space:]]*}$" "$apparmor_file"; then
        sudo sed -i '/^[[:space:]]*}$/i\  /var/lib/libvirt/conf/ r,' "$apparmor_file"
        sudo sed -i '/^[[:space:]]*}$/i\  /var/lib/libvirt/conf/** r,' "$apparmor_file"
    else
        echo "  /var/lib/libvirt/conf/ r," | sudo tee -a "$apparmor_file" > /dev/null
        echo "  /var/lib/libvirt/conf/** r," | sudo tee -a "$apparmor_file" > /dev/null
    fi
    
    sudo apparmor_parser -r "$apparmor_file" || {
        log_error "Failed to reload AppArmor profile"
        local backup_file
        backup_file=$(ls -t "${apparmor_file}.backup."* 2>/dev/null | head -1)
        if [ -n "$backup_file" ]; then
            sudo cp "$backup_file" "$apparmor_file"
        fi
        return 1
    }
    
    log_success "AppArmor fix applied successfully"
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
    sudo mkdir -p "${CONF_DIR}"
    
    # Network 1
    if [ -z "$TARGET_CLUSTER" ] || [ "$TARGET_CLUSTER" == "1" ]; then
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
    fi
    
    # Network 2
    if [ -z "$TARGET_CLUSTER" ] || [ "$TARGET_CLUSTER" == "2" ]; then
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
    fi
}

delete_networks() {
    log_info "Deleting libvirt networks..."
    
    # Network 1
    if [ -z "$TARGET_CLUSTER" ] || [ "$TARGET_CLUSTER" == "1" ]; then
        if sudo virsh net-list --all | grep -q "${NETWORK_1_NAME}"; then
            log_info "Stopping and deleting network ${NETWORK_1_NAME}"
            sudo virsh net-destroy "${NETWORK_1_NAME}" 2>/dev/null || true
            sudo virsh net-undefine "${NETWORK_1_NAME}"
            log_success "Network ${NETWORK_1_NAME} deleted"
        fi
    fi
    
    # Network 2
    if [ -z "$TARGET_CLUSTER" ] || [ "$TARGET_CLUSTER" == "2" ]; then
        if sudo virsh net-list --all | grep -q "${NETWORK_2_NAME}"; then
            log_info "Stopping and deleting network ${NETWORK_2_NAME}"
            sudo virsh net-destroy "${NETWORK_2_NAME}" 2>/dev/null || true
            sudo virsh net-undefine "${NETWORK_2_NAME}"
            log_success "Network ${NETWORK_2_NAME} deleted"
        fi
    fi
    
    sudo rm -f "${CONF_DIR}/${NETWORK_1_NAME}.xml"
    sudo rm -f "${CONF_DIR}/${NETWORK_2_NAME}.xml"
}

# =============================================================================
# BUTANE/IGNITION CONFIGURATION
# =============================================================================

generate_butane_config() {
    local vm_name=$1
    local ip_address=$2
    local gateway=$3
    local dns=$4
    
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
    - path: /etc/NetworkManager/system-connections/${NETWORK_INTERFACE}.nmconnection
      mode: 0600
      contents:
        inline: |
          [connection]
          id=${NETWORK_INTERFACE}
          type=ethernet
          interface-name=${NETWORK_INTERFACE}
          
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
    local cluster_id=$6
    local vm_index=$7
    
    log_info "[Cluster $cluster_id] Creating VM ${vm_name} (${ip_address})"
    
    local butane_config="${CONF_DIR}/${vm_name}.bu"
    local ignition_config="${CONF_DIR}/${vm_name}.ign"
    local extra_disk_path="${LIBVIRT_IMAGES_DIR}/${vm_name}-extra.qcow2"
    
    # Generate configs
    generate_butane_config "${vm_name}" "${ip_address}" "${gateway}" "${dns}" | sudo tee "${butane_config}" > /dev/null
    sudo chown libvirt-qemu:libvirt-qemu "${butane_config}"
    sudo chmod 644 "${butane_config}"
    
    sudo podman run --interactive --rm quay.io/coreos/butane:release --pretty --strict < "${butane_config}" | sudo tee "${ignition_config}" > /dev/null
    sudo chown libvirt-qemu:libvirt-qemu "${ignition_config}"
    sudo chmod 644 "${ignition_config}"
    
    # Create extra disk
    sudo qemu-img create -f qcow2 "${extra_disk_path}" "${VM_EXTRA_DISK_GB}G"
    
    # Create VM
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
        "${ignition_device_arg}" &> /dev/null
    
    local main_disk_path
    main_disk_path=$(sudo virsh domblklist "${vm_name}" --details | grep "vda\|sda\|hda" | awk '{print $4}' || echo "")
    
    echo "VM_NAME=${vm_name}|MAIN_DISK=${main_disk_path}|EXTRA_DISK=${extra_disk_path}|IP=${ip_address}|CLUSTER=${cluster_id}|VM_INDEX=${vm_index}" | sudo tee -a "${STATE_FILE}" > /dev/null
    
    log_success "[Cluster $cluster_id] Created ${vm_name}"
}

create_cluster_vms() {
    local cluster_id=$1
    local prefix=$2
    local network=$3
    local gateway=$4
    local dns=$5
    local ip_base=$6
    local state_file=$7
    
    export STATE_FILE="$state_file"
    
    # Initialize state file
    echo "# Cluster ${cluster_id} State File" | sudo tee "${state_file}" > /dev/null
    echo "# Created: $(date)" | sudo tee -a "${state_file}" > /dev/null
    echo "" | sudo tee -a "${state_file}" > /dev/null
    
    for i in $(seq 1 ${VMS_PER_CLUSTER}); do
        local vm_name="${prefix}-n${i}"
        local ip_offset=$((IP_START + i - 1))
        local ip_address="${ip_base}.${ip_offset}"
        
        create_vm "${vm_name}" "${network}" "${ip_address}" "${gateway}" "${dns}" "$cluster_id" "$i"
    done
    
    log_success "[Cluster $cluster_id] All VMs created"
}

create_cluster() {
    log_info "Starting multi-cluster creation..."
    log_info "Target: ${TARGET_CLUSTER:-both clusters}"
    
    install_dependencies
    fix_apparmor
    
    if [ ! -f "${FCOS_IMAGE}" ]; then
        log_error "Fedora CoreOS image not found at ${FCOS_IMAGE}"
        log_info "Please download: wget -P ${LIBVIRT_IMAGES_DIR} https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/43.20260217.3.1/x86_64/${FCOS_IMAGE_NAME}"
        exit 1
    fi
    
    create_networks
    
    # Create clusters in parallel
    if [ -z "$TARGET_CLUSTER" ]; then
        log_info "Creating both clusters in parallel..."
        create_cluster_vms 1 "${CLUSTER_1_PREFIX}" "${CLUSTER_1_NETWORK}" "${CLUSTER_1_GATEWAY}" "${CLUSTER_1_DNS}" "${CLUSTER_1_IP_BASE}" "${CLUSTER_1_STATE}" &
        local pid1=$!
        
        create_cluster_vms 2 "${CLUSTER_2_PREFIX}" "${CLUSTER_2_NETWORK}" "${CLUSTER_2_GATEWAY}" "${CLUSTER_2_DNS}" "${CLUSTER_2_IP_BASE}" "${CLUSTER_2_STATE}" &
        local pid2=$!
        
        wait $pid1 || log_error "Cluster 1 creation failed"
        wait $pid2 || log_error "Cluster 2 creation failed"
        
    elif [ "$TARGET_CLUSTER" == "1" ]; then
        create_cluster_vms 1 "${CLUSTER_1_PREFIX}" "${CLUSTER_1_NETWORK}" "${CLUSTER_1_GATEWAY}" "${CLUSTER_1_DNS}" "${CLUSTER_1_IP_BASE}" "${CLUSTER_1_STATE}"
    elif [ "$TARGET_CLUSTER" == "2" ]; then
        create_cluster_vms 2 "${CLUSTER_2_PREFIX}" "${CLUSTER_2_NETWORK}" "${CLUSTER_2_GATEWAY}" "${CLUSTER_2_DNS}" "${CLUSTER_2_IP_BASE}" "${CLUSTER_2_STATE}"
    fi
    
    echo ""
    log_success "Cluster creation completed!"
    echo ""
    echo "=========================================="
    echo "Cluster 1 (${CLUSTER_1_NAME}): ${NETWORK_1_CIDR}"
    for i in $(seq 1 ${VMS_PER_CLUSTER}); do
        echo "  - ${CLUSTER_1_PREFIX}-n${i}: ${CLUSTER_1_IP_BASE}.$((IP_START + i - 1))"
    done
    echo ""
    echo "Cluster 2 (${CLUSTER_2_NAME}): ${NETWORK_2_CIDR}"
    for i in $(seq 1 ${VMS_PER_CLUSTER}); do
        echo "  - ${CLUSTER_2_PREFIX}-n${i}: ${CLUSTER_2_IP_BASE}.$((IP_START + i - 1))"
    done
    echo "=========================================="
    echo ""
    
    # Test SSH
    test_ssh_clusters
}

# =============================================================================
# SSH TESTING
# =============================================================================

test_ssh_clusters() {
    echo ""
    echo "=========================================="
    echo "Testing SSH connectivity..."
    echo "=========================================="
    echo ""
    
    local all_success=true
    local failed_nodes=()
    
    if [ -z "$TARGET_CLUSTER" ] || [ "$TARGET_CLUSTER" == "1" ]; then
        log_info "Testing Cluster 1..."
        for i in $(seq 1 ${VMS_PER_CLUSTER}); do
            local ip="${CLUSTER_1_IP_BASE}.$((IP_START + i - 1))"
            if ! wait_for_ssh "$ip"; then
                all_success=false
                failed_nodes+=("Cluster 1 - ${CLUSTER_1_PREFIX}-n${i} ($ip)")
            fi
        done
    fi
    
    if [ -z "$TARGET_CLUSTER" ] || [ "$TARGET_CLUSTER" == "2" ]; then
        log_info "Testing Cluster 2..."
        for i in $(seq 1 ${VMS_PER_CLUSTER}); do
            local ip="${CLUSTER_2_IP_BASE}.$((IP_START + i - 1))"
            if ! wait_for_ssh "$ip"; then
                all_success=false
                failed_nodes+=("Cluster 2 - ${CLUSTER_2_PREFIX}-n${i} ($ip)")
            fi
        done
    fi
    
    if [ "$all_success" = true ]; then
        log_success "All nodes are accessible via SSH"
        echo ""
        log_success "Clusters are ready for deployment!"
        echo "Run: $SCRIPT_NAME deploy${TARGET_CLUSTER:+ --cluster $TARGET_CLUSTER}"
    else
        log_error "SSH test failed for:"
        for node in "${failed_nodes[@]}"; do
            echo "  - ${node}"
        done
        exit 1
    fi
}

# =============================================================================
# KUBESPRAY DEPLOYMENT
# =============================================================================

generate_inventory() {
    local cluster_id=$1
    local prefix=$2
    local inventory_file=$3
    local state_file=$4
    local inventory_dir=$(dirname "$inventory_file")
    
    # Create inventory directory
    mkdir -p "$inventory_dir"
    
    # Parse nodes from state file
    declare -a nodes
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
            nodes+=("${vm_name}|${vm_ip}")
        fi
    done < <(sudo cat "$state_file")
    
    # Generate inventory
    cat > "$inventory_file" <<EOF
# Kubernetes Cluster ${cluster_id} Inventory
# Generated: $(date)

[kube_control_plane]
EOF

    local etcd_counter=1
    for node_info in "${nodes[@]}"; do
        local node_name=$(echo "$node_info" | cut -d'|' -f1)
        local node_ip=$(echo "$node_info" | cut -d'|' -f2)
        echo "${node_name} ansible_host=${node_ip} ansible_user=${SSH_USER} etcd_member_name=etcd${etcd_counter}" >> "$inventory_file"
        etcd_counter=$((etcd_counter + 1))
    done
    
    cat >> "$inventory_file" <<EOF

[etcd:children]
kube_control_plane

[kube_node]
EOF

    for node_info in "${nodes[@]}"; do
        local node_name=$(echo "$node_info" | cut -d'|' -f1)
        local node_ip=$(echo "$node_info" | cut -d'|' -f2)
        echo "${node_name} ansible_host=${node_ip} ansible_user=${SSH_USER}" >> "$inventory_file"
    done
    
    cat >> "$inventory_file" <<EOF

[k8s_cluster:children]
kube_control_plane
kube_node
EOF

    log_success "[Cluster $cluster_id] Inventory generated: $inventory_file"
}

deploy_single_cluster() {
    local cluster_id=$1
    local prefix=$2
    local inventory_file=$3
    local state_file=$4
    local inventory_dir=$(dirname "$inventory_file")
    
    log_info "[Cluster $cluster_id] Starting deployment..."
    
    if [ ! -f "$state_file" ]; then
        log_error "[Cluster $cluster_id] State file not found: $state_file"
        return 1
    fi
    
    if [ ! -d "${KUBESPRAY_DIR}" ]; then
        log_error "Kubespray directory not found: ${KUBESPRAY_DIR}"
        return 1
    fi
    
    # Generate inventory
    generate_inventory "$cluster_id" "$prefix" "$inventory_file" "$state_file"
    
    # Create venv if needed
    cd "${KUBESPRAY_DIR}" || return 1
    
    if [ ! -d ".venv" ]; then
        log_error "[Cluster $cluster_id] Python virtual environment not found"
        return 1
    fi
    
    source .venv/bin/activate
    
    # Test Ansible connectivity
    log_info "[Cluster $cluster_id] Testing Ansible connectivity..."
    if ! ansible -i "$inventory_file" -m ping all; then
        log_error "[Cluster $cluster_id] Ansible connectivity test failed"
        deactivate
        return 1
    fi
    
    # Deploy
    log_info "[Cluster $cluster_id] Deploying Kubernetes..."
    if ansible-playbook -i "$inventory_file" cluster.yml -b -v --private-key="${SSH_PRIVATE_KEY}"; then
        log_success "[Cluster $cluster_id] Kubernetes deployed successfully!"
        local first_ip=$(grep "ansible_host" "$inventory_file" | head -1 | sed 's/.*ansible_host=\([^ ]*\).*/\1/')
        echo ""
        log_info "[Cluster $cluster_id] To access:"
        echo "  ssh ${SSH_USER}@${first_ip}"
        echo "  mkdir ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config"
        deactivate
        return 0
    else
        log_error "[Cluster $cluster_id] Deployment failed"
        deactivate
        return 1
    fi
}

deploy_clusters() {
    log_info "Starting Kubernetes deployment..."
    log_info "Target: ${TARGET_CLUSTER:-both clusters}"
    
    if [ -z "$TARGET_CLUSTER" ]; then
        log_info "Deploying both clusters in parallel..."
        deploy_single_cluster 1 "${CLUSTER_1_PREFIX}" "${CLUSTER_1_INVENTORY}" "${CLUSTER_1_STATE}" &
        local pid1=$!
        
        deploy_single_cluster 2 "${CLUSTER_2_PREFIX}" "${CLUSTER_2_INVENTORY}" "${CLUSTER_2_STATE}" &
        local pid2=$!
        
        wait $pid1
        local status1=$?
        wait $pid2
        local status2=$?
        
        if [ $status1 -eq 0 ] && [ $status2 -eq 0 ]; then
            log_success "Both clusters deployed successfully!"
        else
            [ $status1 -ne 0 ] && log_error "Cluster 1 deployment failed"
            [ $status2 -ne 0 ] && log_error "Cluster 2 deployment failed"
            exit 1
        fi
        
    elif [ "$TARGET_CLUSTER" == "1" ]; then
        deploy_single_cluster 1 "${CLUSTER_1_PREFIX}" "${CLUSTER_1_INVENTORY}" "${CLUSTER_1_STATE}"
        
    elif [ "$TARGET_CLUSTER" == "2" ]; then
        deploy_single_cluster 2 "${CLUSTER_2_PREFIX}" "${CLUSTER_2_INVENTORY}" "${CLUSTER_2_STATE}"
    fi
}

# =============================================================================
# CLUSTER DELETION
# =============================================================================

delete_single_cluster() {
    local cluster_id=$1
    local state_file=$2
    local inventory_file=$3
    
    log_info "[Cluster $cluster_id] Deleting VMs..."
    
    # Delete VMs from state file
    if [ -f "$state_file" ]; then
        while IFS='|' read -r vm_entry; do
            [[ "$vm_entry" =~ ^#.*$ ]] && continue
            [[ -z "$vm_entry" ]] && continue
            
            local vm_name=""
            local extra_disk=""
            
            IFS='|' read -ra FIELDS <<< "$vm_entry"
            for field in "${FIELDS[@]}"; do
                case "$field" in
                    VM_NAME=*) vm_name="${field#VM_NAME=}" ;;
                    EXTRA_DISK=*) extra_disk="${field#EXTRA_DISK=}" ;;
                esac
            done
            
            if [ -n "$vm_name" ]; then
                if sudo virsh list --all | grep -q "${vm_name}"; then
                    log_info "[Cluster $cluster_id] Deleting VM ${vm_name}"
                    sudo virsh destroy "${vm_name}" 2>/dev/null || true
                    sudo virsh undefine "${vm_name}" --remove-all-storage 2>/dev/null || true
                    
                    # Clean up extra disk if still exists
                    if [ -n "${extra_disk}" ] && sudo [ -f "${extra_disk}" ]; then
                        sudo rm -f "${extra_disk}"
                    fi
                fi
                
                # Clean up config files
                sudo rm -f "${CONF_DIR}/${vm_name}.bu"
                sudo rm -f "${CONF_DIR}/${vm_name}.ign"
            fi
        done < <(sudo cat "$state_file")
        
        # Remove state file
        sudo rm -f "$state_file"
    fi
    
    # Remove inventory
    rm -f "$inventory_file"
    
    log_success "[Cluster $cluster_id] Deleted"
}

delete_cluster() {
    log_info "Starting cluster deletion..."
    log_info "Target: ${TARGET_CLUSTER:-both clusters}"
    
    # STEP 1: Delete VMs first (before networks!)
    if [ -z "$TARGET_CLUSTER" ] || [ "$TARGET_CLUSTER" == "1" ]; then
        delete_single_cluster 1 "${CLUSTER_1_STATE}" "${CLUSTER_1_INVENTORY}"
    fi
    
    if [ -z "$TARGET_CLUSTER" ] || [ "$TARGET_CLUSTER" == "2" ]; then
        delete_single_cluster 2 "${CLUSTER_2_STATE}" "${CLUSTER_2_INVENTORY}"
    fi
    
    # STEP 2: Delete networks (only after all VMs are gone)
    delete_networks
    
    log_success "Cluster deletion completed!"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

parse_args "$@"

case "$MODE" in
    create)
        create_cluster
        ;;
    delete)
        delete_cluster
        ;;
    deploy)
        deploy_clusters
        ;;
    *)
        log_error "Invalid mode '$MODE'"
        usage
        ;;
esac
