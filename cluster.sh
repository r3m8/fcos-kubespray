#!/bin/bash

# Variables for Debian 13 with libvirt stack
SCRIPT_NAME=$(basename "$0")
USER="uni"
STATE_LOCK_FILE="/var/lib/libvirt/conf/k8s-cluster-state.lock"
KUBESPRAY_DIR="/home/$USER/fcos/kubespray"
INVENTORY_DIR="${KUBESPRAY_DIR}/inventory/mycluster"
INVENTORY_FILE="${INVENTORY_DIR}/inventory.ini"

usage() {
    echo "Usage: $SCRIPT_NAME {create|delete|deploy}"
    echo "  create - Create Kubernetes cluster VMs"
    echo "  delete - Delete all VMs created by this script"
    echo "  deploy - Deploy Kubernetes using Kubespray"
    exit 1
}

if [ $# -eq 0 ]; then
    usage
fi

MODE=$1

# VM variables
STREAM=stable # Fedora CoreOS flavor
IMAGE=/var/lib/libvirt/images/fedora-coreos-42.20250914.3.0-qemu.x86_64.qcow2 # You need to download this manually
network=hpcvg0 # This network isn't automatically created
interface=enp1s0 # Adjust the interface if needed
ip_base="10.230.9" # CIDR of VMs
ip_start=11
gateway=10.230.9.1
dns=1.1.1.1
subnet_mask=24
ssh_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIRVkwktzS1+6dWwKRanRGU+ANjtgR5WIRu9e5sNCqgP" # You need to generate this key
SSH_USER="ansibleUser"

# Function to wait for SSH connectivity
wait_for_ssh() {
    local ip=$1
    local max_attempts=60
    local attempt=0
    
    echo "  Waiting for SSH on ${ip}..."
    
    while [ $attempt -lt $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ${SSH_USER}@${ip} "echo SSH ready" &> /dev/null; then
            echo "  ✓ SSH connection successful to ${ip}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    
    echo "  ✗ Failed to establish SSH connection to ${ip} after ${max_attempts} attempts"
    return 1
}

create_cluster() {
    # Initialize state lock file
    echo "# Kubernetes Cluster State Lock File" | sudo tee "${STATE_LOCK_FILE}" > /dev/null
    echo "# Created: $(date)" | sudo tee -a "${STATE_LOCK_FILE}" > /dev/null
    echo "" | sudo tee -a "${STATE_LOCK_FILE}" > /dev/null

    # Create Control Plane Nodes
    echo "Creating Control Plane nodes..."

    for i in {1..3}; do
        VM_NAME="k8s-control-plane-${i}"
        VCPUS="2"
        RAM_MB="4096"
        DISK_GB="30"
        
        # Calculate IP address
        ip_offset=$((ip_start + i - 1))
        ip_address="${ip_base}.${ip_offset}"
        
        # Butane and Ignition config paths
        BUTANE_CONFIG="/var/lib/libvirt/conf/${VM_NAME}.bu"
        IGNITION_CONFIG="/var/lib/libvirt/conf/${VM_NAME}.ign"
        
        # Generate Butane config with Python installation and sudo nopasswd
        sudo tee "${BUTANE_CONFIG}" > /dev/null <<EOF
variant: fcos
version: 1.6.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ${ssh_key}
    - name: ${SSH_USER}
      groups:
        - wheel
      ssh_authorized_keys:
        - ${ssh_key}
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
          address1=${ip_address}/${subnet_mask},${gateway}
          dns=${dns};
          method=manual
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: ${VM_NAME}
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
        
        echo "Generating Ignition config for ${VM_NAME} with IP ${ip_address}"
        sudo podman run --interactive --rm quay.io/coreos/butane:release --pretty --strict < "${BUTANE_CONFIG}" | sudo tee "${IGNITION_CONFIG}" > /dev/null
        
        # Create VM
        IGNITION_DEVICE_ARG=(--qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_CONFIG}")
        
        sudo virt-install --connect="qemu:///system" --name="${VM_NAME}" --vcpus="${VCPUS}" --memory="${RAM_MB}" \
            --os-variant="fedora-coreos-$STREAM" --import --graphics=none \
            --noautoconsole \
            --disk="size=${DISK_GB},backing_store=${IMAGE}" \
            --network network=$network "${IGNITION_DEVICE_ARG[@]}"
        
        # Save VM info to state lock file
        DISK_PATH=$(sudo virsh domblklist "${VM_NAME}" --details | grep disk | awk '{print $4}')
        echo "VM_NAME=${VM_NAME}|DISK_PATH=${DISK_PATH}|IP=${ip_address}|TYPE=control-plane" | sudo tee -a "${STATE_LOCK_FILE}" > /dev/null
        
        echo "Created ${VM_NAME} with IP ${ip_address}"
    done

    # Create Worker Nodes
    echo "Creating Worker nodes..."

    for i in {1..3}; do
        VM_NAME="k8s-worker-${i}"
        VCPUS="2"
        RAM_MB="4096"
        DISK_GB="100"
        
        # Calculate IP address (continue from control plane IPs)
        ip_offset=$((ip_start + 3 + i - 1))
        ip_address="${ip_base}.${ip_offset}"
        
        # Butane and Ignition config paths
        BUTANE_CONFIG="/var/lib/libvirt/conf/${VM_NAME}.bu"
        IGNITION_CONFIG="/var/lib/libvirt/conf/${VM_NAME}.ign"
        
        # Generate Butane config with Python installation and sudo nopasswd
        sudo tee "${BUTANE_CONFIG}" > /dev/null <<EOF
variant: fcos
version: 1.6.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ${ssh_key}
    - name: ${SSH_USER}
      groups:
        - wheel
      ssh_authorized_keys:
        - ${ssh_key}
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
          address1=${ip_address}/${subnet_mask},${gateway}
          dns=${dns};
          method=manual
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: ${VM_NAME}
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
        
        echo "Generating Ignition config for ${VM_NAME} with IP ${ip_address}"
        sudo podman run --interactive --rm quay.io/coreos/butane:release --pretty --strict < "${BUTANE_CONFIG}" | sudo tee "${IGNITION_CONFIG}" > /dev/null
        
        # Create VM
        IGNITION_DEVICE_ARG=(--qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_CONFIG}")
        
        sudo virt-install --connect="qemu:///system" --name="${VM_NAME}" --vcpus="${VCPUS}" --memory="${RAM_MB}" \
            --os-variant="fedora-coreos-$STREAM" --import --graphics=none \
            --noautoconsole \
            --disk="size=${DISK_GB},backing_store=${IMAGE}" \
            --network network=$network "${IGNITION_DEVICE_ARG[@]}"
        
        # Save VM info to state lock file
        DISK_PATH=$(sudo virsh domblklist "${VM_NAME}" --details | grep disk | awk '{print $4}')
        echo "VM_NAME=${VM_NAME}|DISK_PATH=${DISK_PATH}|IP=${ip_address}|TYPE=worker" | sudo tee -a "${STATE_LOCK_FILE}" > /dev/null
        
        echo "Created ${VM_NAME} with IP ${ip_address}"
    done

    echo ""
    echo "All machines created successfully!"
    echo ""
    echo "IP Address allocation:"
    echo "Control Planes: 10.230.9.11-13"
    echo "Workers: 10.230.9.14-16"
    echo ""
    echo "State file saved to: ${STATE_LOCK_FILE}"
    echo ""
    echo "NOTE: Python3 installation will happen automatically on first boot."
    echo "This may take 2-3 minutes per node."
    echo ""

    echo ""
    echo "=========================================="
    echo "Testing SSH connectivity to ALL nodes..."
    echo "=========================================="
    echo ""

    # Test SSH connectivity to all nodes
    all_ssh_success=true
    declare -a failed_nodes
    declare -a vm_ips
    declare -a vm_names
    declare -a vm_types
    
    # First, collect all VM information with proper pipe delimiter parsing
    while IFS= read -r vm_line; do
        # Skip comment lines and empty lines
        [[ "$vm_line" =~ ^#.*$ ]] && continue
        [[ -z "$vm_line" ]] && continue
        
        # Parse each pipe-delimited field
        IFS='|' read -ra FIELDS <<< "$vm_line"
        
        vm_name=""
        vm_ip=""
        vm_type=""
        
        for field in "${FIELDS[@]}"; do
            case "$field" in
                VM_NAME=*)
                    vm_name="${field#VM_NAME=}"
                    ;;
                IP=*)
                    vm_ip="${field#IP=}"
                    ;;
                TYPE=*)
                    vm_type="${field#TYPE=}"
                    ;;
            esac
        done
        
        # Store the parsed information
        if [[ -n "$vm_name" && -n "$vm_ip" && -n "$vm_type" ]]; then
            vm_names+=("$vm_name")
            vm_ips+=("$vm_ip")
            vm_types+=("$vm_type")
        fi
        
    done < <(sudo cat "${STATE_LOCK_FILE}")
    
    # Display total count
    total_nodes=${#vm_names[@]}
    echo "Found ${total_nodes} nodes to test"
    echo ""
    
    # Now test SSH for each collected VM
    for i in "${!vm_names[@]}"; do
        node_num=$((i + 1))
        echo "[${node_num}/${total_nodes}] Testing ${vm_types[$i]} node: ${vm_names[$i]} (${vm_ips[$i]})"
        
        if ! wait_for_ssh "${vm_ips[$i]}"; then
            all_ssh_success=false
            failed_nodes+=("${vm_names[$i]} (${vm_ips[$i]})")
        fi
        
        echo ""
    done
    
    echo "=========================================="
    
    if [ "$all_ssh_success" = true ]; then
        echo "✓ All ${total_nodes} nodes are accessible via SSH as ${SSH_USER}"
        echo "=========================================="
        echo ""
        echo "Cluster is ready for Kubespray deployment!"
        echo "Run: $SCRIPT_NAME deploy"
        exit 0
    else
        echo "✗ SSH connectivity test FAILED for the following nodes:"
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

deploy_kubespray() {
    echo "=========================================="
    echo "Deploying Kubernetes with Kubespray"
    echo "=========================================="
    echo ""
    
    # Check if state lock file exists
    if [ ! -f "${STATE_LOCK_FILE}" ]; then
        echo "Error: State lock file not found at ${STATE_LOCK_FILE}"
        echo "Please run '$SCRIPT_NAME create' first to create the cluster VMs."
        exit 1
    fi
    
    # Check if kubespray directory exists
    if [ ! -d "${KUBESPRAY_DIR}" ]; then
        echo "Error: Kubespray directory not found at ${KUBESPRAY_DIR}"
        echo "Please clone kubespray repository first."
        exit 1
    fi

    if [ ! -d "${INVENTORY_DIR}" ]; then
        echo "Error: Kubespray cluster directory not found at ${INVENTORY_DIR}"
        echo "Please create the folder or copy inventory/sample/ first."
        exit 1
    fi
    
    echo "Step 1: Generating Ansible inventory from state lock file..."
    echo ""
    
    # Initialize inventory file
    cat > "${INVENTORY_FILE}" <<'EOF'
# This inventory describes a HA topology with stacked etcd (== same nodes as control plane)
# and 3 worker nodes
# See https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html
# for tips on building your inventory

# Configure 'ip' variable to bind kubernetes services on a different ip than the default iface
# We should set etcd_member_name for etcd cluster. The node that are not etcd members do not need to set the value,
# or can set the empty string value.
[kube_control_plane]
EOF
    
    # Parse control plane nodes
    declare -a control_plane_nodes
    declare -a worker_nodes
    
    while IFS= read -r vm_line; do
        # Skip comment lines and empty lines
        [[ "$vm_line" =~ ^#.*$ ]] && continue
        [[ -z "$vm_line" ]] && continue
        
        # Parse each pipe-delimited field
        IFS='|' read -ra FIELDS <<< "$vm_line"
        
        vm_name=""
        vm_ip=""
        vm_type=""
        
        for field in "${FIELDS[@]}"; do
            case "$field" in
                VM_NAME=*)
                    vm_name="${field#VM_NAME=}"
                    ;;
                IP=*)
                    vm_ip="${field#IP=}"
                    ;;
                TYPE=*)
                    vm_type="${field#TYPE=}"
                    ;;
            esac
        done
        
        if [[ -n "$vm_name" && -n "$vm_ip" && -n "$vm_type" ]]; then
            if [[ "$vm_type" == "control-plane" ]]; then
                control_plane_nodes+=("${vm_name}|${vm_ip}")
            elif [[ "$vm_type" == "worker" ]]; then
                worker_nodes+=("${vm_name}|${vm_ip}")
            fi
        fi
        
    done < <(sudo cat "${STATE_LOCK_FILE}")
    
    # Add control plane nodes to inventory
    etcd_counter=1
    for node_info in "${control_plane_nodes[@]}"; do
        node_name=$(echo "$node_info" | cut -d'|' -f1)
        node_ip=$(echo "$node_info" | cut -d'|' -f2)
        echo "${node_name} ansible_host=${node_ip} ansible_user=${SSH_USER} etcd_member_name=etcd${etcd_counter}" >> "${INVENTORY_FILE}"
        etcd_counter=$((etcd_counter + 1))
    done
    
    # Add etcd section
    cat >> "${INVENTORY_FILE}" <<'EOF'

[etcd:children]
kube_control_plane

[kube_node]
EOF
    
    # Add worker nodes to inventory
    for node_info in "${worker_nodes[@]}"; do
        node_name=$(echo "$node_info" | cut -d'|' -f1)
        node_ip=$(echo "$node_info" | cut -d'|' -f2)
        echo "${node_name} ansible_host=${node_ip} ansible_user=${SSH_USER}" >> "${INVENTORY_FILE}"
    done
    
    # Add k8s_cluster group
    cat >> "${INVENTORY_FILE}" <<'EOF'

[k8s_cluster:children]
kube_control_plane
kube_node
EOF
    
    echo "✓ Inventory file generated at: ${INVENTORY_FILE}"
    echo ""
    echo "Inventory contents:"
    echo "-------------------"
    cat "${INVENTORY_FILE}"
    echo "-------------------"
    echo ""
    
    # Change to kubespray directory
    cd "${KUBESPRAY_DIR}" || exit 1
    
    # Check if venv exists
    if [ ! -d ".venv" ]; then
        echo "Error: Python virtual environment not found at ${KUBESPRAY_DIR}/.venv"
        echo "Please set up kubespray first (pip install -r requirements.txt)"
        exit 1
    fi
    
    echo "Step 2: Activating Python virtual environment..."
    source .venv/bin/activate
    echo "✓ Virtual environment activated"
    echo ""
    
    echo "Step 3: Verifying Python installation on all nodes..."
    echo ""
    
    # Verify Python is installed on all nodes
    declare -a all_ips
    for node_info in "${control_plane_nodes[@]}" "${worker_nodes[@]}"; do
        node_ip=$(echo "$node_info" | cut -d'|' -f2)
        all_ips+=("$node_ip")
    done
    
    python_check_failed=false
    for ip in "${all_ips[@]}"; do
        echo -n "Checking Python on ${ip}... "
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${SSH_USER}@${ip} "which python3" &> /dev/null; then
            echo "✓"
        else
            echo "✗ Python not found"
            python_check_failed=true
        fi
    done
    echo ""
    
    if [ "$python_check_failed" = true ]; then
        echo "✗ Python is not installed on some nodes"
        echo "Please wait a few more minutes for rpm-ostree to complete, then try again"
        deactivate
        exit 1
    fi
    
    echo "Step 4: Testing Ansible connectivity to all nodes..."
    echo ""
    
    if ansible -i "${INVENTORY_FILE}" -m ping all; then
        echo ""
        echo "✓ All nodes are reachable via Ansible"
        echo ""
    else
        echo ""
        echo "✗ Ansible connectivity test failed"
        echo "Please check your SSH keys and network configuration"
        deactivate
        exit 1
    fi
    
    echo "Step 5: Deploying Kubernetes cluster with Kubespray..."
    echo "This may take 15-30 minutes depending on your system..."
    echo ""
    
    if ansible-playbook -i "${INVENTORY_FILE}" cluster.yml \
        -b -v --private-key=~/.ssh/id_rsa; then
        echo ""
        echo "=========================================="
        echo "✓ Kubernetes cluster deployed successfully!"
        echo "=========================================="
        echo ""
        echo "To access your cluster:"
        echo "1. SSH to a control plane node: ssh ${SSH_USER}@${control_plane_nodes[0]##*|}"
        echo "2. Create .kube folder: mkdir .kube"
	echo "3. Copy kubeconfig: sudo cp /etc/kubernetes/admin.conf ~/.kube/config"
	echo "4. Set permissions: sudo chown ansibleUser .kube/config"
        echo "5. Run: kubectl get nodes"
        echo ""
    else
        echo ""
        echo "✗ Kubernetes deployment failed"
        echo "Check the Ansible output above for errors"
        deactivate
        exit 1
    fi
    
    deactivate
}

delete_cluster() {
    if [ ! -f "${STATE_LOCK_FILE}" ]; then
        echo "Error: State lock file not found at ${STATE_LOCK_FILE}"
        echo "No cluster to delete or file has been moved."
        exit 1
    fi

    echo "Reading cluster state from ${STATE_LOCK_FILE}"
    echo ""
    
    # Read and process each VM from state file
    while IFS='|' read -r vm_entry; do
        # Skip comment lines and empty lines
        [[ "$vm_entry" =~ ^#.*$ ]] && continue
        [[ -z "$vm_entry" ]] && continue
        
        # Parse the entry
        VM_NAME=$(echo "$vm_entry" | cut -d'|' -f1 | cut -d'=' -f2)
        DISK_PATH=$(echo "$vm_entry" | cut -d'|' -f2 | cut -d'=' -f2)
        IP=$(echo "$vm_entry" | cut -d'|' -f3 | cut -d'=' -f2)
        TYPE=$(echo "$vm_entry" | cut -d'|' -f4 | cut -d'=' -f2)
        
        echo "Deleting ${TYPE} VM: ${VM_NAME} (IP: ${IP})"
        
        # Check if VM exists
        if sudo virsh list --all | grep -q "${VM_NAME}"; then
            # Destroy (force stop) the VM if running
            if sudo virsh list --state-running | grep -q "${VM_NAME}"; then
                echo "  Stopping ${VM_NAME}..."
                sudo virsh destroy "${VM_NAME}" 2>/dev/null
            fi
            
            # Undefine the VM and remove associated storage
            echo "  Removing VM definition and storage for ${VM_NAME}..."
            sudo virsh undefine "${VM_NAME}" --remove-all-storage 2>/dev/null
            
            # Additional cleanup: Remove disk if it still exists
            if [ -n "${DISK_PATH}" ] && sudo [ -f "${DISK_PATH}" ]; then
                echo "  Removing remaining disk: ${DISK_PATH}"
                sudo rm -f "${DISK_PATH}"
            fi
            
            # Remove Butane and Ignition configs
            BUTANE_CONFIG="/var/lib/libvirt/conf/${VM_NAME}.bu"
            IGNITION_CONFIG="/var/lib/libvirt/conf/${VM_NAME}.ign"
            
            sudo [ -f "${BUTANE_CONFIG}" ] && sudo rm -f "${BUTANE_CONFIG}"
            sudo [ -f "${IGNITION_CONFIG}" ] && sudo rm -f "${IGNITION_CONFIG}"
            
            echo "  ${VM_NAME} deleted successfully"
        else
            echo "  ${VM_NAME} not found (may have been manually deleted)"
        fi
        echo ""
        
    done < <(sudo cat "${STATE_LOCK_FILE}")
    
    # Remove state lock file
    echo "Removing state lock file..."
    sudo rm -f "${STATE_LOCK_FILE}"
    
    # Remove inventory file if it exists
    if [ -f "${INVENTORY_FILE}" ]; then
        echo "Removing Ansible inventory file..."
        rm -f "${INVENTORY_FILE}"
    fi
    
    echo "Cluster deletion completed!"
}

# Main execution
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
        echo "Error: Invalid mode '$MODE'"
        usage
        ;;
esac

