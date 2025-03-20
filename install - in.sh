#!/bin/bash

# Kubernetes One-Click Installation Script - CentOS 7
# Uses Alibaba Cloud mirror sources and containerd as the container runtime

# Color codes for formatted output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No color

# Global variable initialization
NODE_TYPE=""
NODE_NUMBER=""
NODE_IP=""
IS_CONTAINER=0

# Log function, displays English messages only
log() {
    local level=$1
    local en_msg=$2
    local color=$NC

    case $level in
        "INFO")
            color=$GREEN
            ;;
        "WARN")
            color=$YELLOW
            ;;
        "ERROR")
            color=$RED
            ;;
    esac

    echo -e "${color}[$level] $en_msg${NC}"
}

# Error handling function
handle_error() {
    local exit_code=$1
    local error_msg=$2

    if [ $exit_code -ne 0 ]; then
        log "ERROR" "$error_msg"
        log "ERROR" "Installation failed! You can run '$0 cleanup' to remove installed components."
        exit $exit_code
    fi
}

# Soft error handling function - logs warning but does not exit
soft_error() {
    local exit_code=$1
    local warn_msg=$2

    if [ $exit_code -ne 0 ]; then
        log "WARN" "$warn_msg"
        return 1
    fi
    return 0
}

# Check if running inside a container
check_container() {
    # Check if running in a Docker container
    if [ -f /.dockerenv ] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        log "INFO" "Detected running in a container environment"
        IS_CONTAINER=1
    fi
}

# Check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi
}

# Detect IP address
detect_ip() {
    local ip=""
    
    # Ensure network tools are installed
    if ! command -v ip >/dev/null 2>&1; then
        log "INFO" "Installing network tools..."
        yum install -y iproute2 >/dev/null 2>&1 || yum install -y iproute >/dev/null 2>&1
    fi

    # Try multiple methods to detect IP
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' 2>/dev/null)
    fi
    
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1)
    fi
    
    if [ -z "$ip" ]; then
        # Last attempt using /proc/net/route
        ip=$(awk '$2 == "00000000" {print $1}' /proc/net/route 2>/dev/null | 
             xargs -I{} sh -c "ip addr show {} 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1" | 
             head -n 1)
    fi
    
    if [ -z "$ip" ]; then
        log "WARN" "Unable to automatically detect IP address, please enter manually:"
        read -r ip
    fi
    
    echo "$ip"
}

# Confirm node IP and type
confirm_node_ip() {
    NODE_IP=$(detect_ip)
    echo -e "${GREEN}Detected IP address: $NODE_IP${NC}"
    echo -e "${GREEN}Is this IP address correct? [Y/n]:${NC}"
    read -r confirm_ip
    
    if [[ $confirm_ip =~ ^[Nn]$ ]]; then
        echo -e "${GREEN}Please enter the correct IP address:${NC}"
        read -r NODE_IP
    fi
    
    log "INFO" "Will use IP: $NODE_IP"
}

# Update hosts file
update_hosts_file() {
    local ip=$1
    
    # Get current hostname without modifying it
    local current_hostname
    current_hostname=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "localhost")
    
    log "INFO" "Current hostname: $current_hostname (will not be modified)"
    
    # Update only the /etc/hosts file
    log "INFO" "Ensuring hostname is correctly mapped in /etc/hosts"
    
    # Check if hosts file exists, create it if not
    if [ ! -f /etc/hosts ]; then
        echo "127.0.0.1   localhost" > /etc/hosts
        log "INFO" "Created a new /etc/hosts file"
    fi
    
    # Check if the local IP entry already exists, add it if not
    if ! grep -q "$ip $current_hostname" /etc/hosts 2>/dev/null; then
        # Check if the IP exists with a different hostname
        if grep -q "^$ip" /etc/hosts; then
            # Update hostname if IP already exists
            sed -i "s/^$ip.*/$ip $current_hostname/" /etc/hosts
            log "INFO" "Updated IP $ip entry to $current_hostname in /etc/hosts"
        else
            # Add new entry if IP does not exist
            echo "$ip $current_hostname" >> /etc/hosts
            log "INFO" "Added IP $ip and hostname $current_hostname mapping to /etc/hosts"
        fi
    else
        log "INFO" "IP $ip is already correctly mapped to $current_hostname in /etc/hosts"
    fi
    
    # Display current hosts file
    log "INFO" "Contents of /etc/hosts file:"
    cat /etc/hosts 2>/dev/null || log "WARN" "Unable to read /etc/hosts file"
}

# System preparation
prepare_system() {
    log "INFO" "Preparing system..."
    
    # Check if running in a container
    if [ $IS_CONTAINER -eq 1 ]; then
        log "INFO" "Running in a container, skipping some system configuration steps"
    fi
    
    # Disable SELinux
    if command -v getenforce >/dev/null 2>&1; then
        if [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
            setenforce 0 2>/dev/null || true
            if [ -f /etc/selinux/config ]; then
                sed -i 's/^SELINUX=enforcing$/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true
            fi
            log "INFO" "SELinux has been disabled"
        else
            log "INFO" "SELinux is already disabled"
        fi
    else
        log "INFO" "SELinux tools not detected, skipping SELinux configuration"
    fi
    
    # Disable swap
    if [ -f /etc/fstab ]; then
        if grep -q "swap" /etc/fstab; then
            sed -i '/swap/d' /etc/fstab 2>/dev/null || true
            log "INFO" "Removed swap configuration from fstab"
        fi
    else
        log "INFO" "No /etc/fstab found, skipping swap configuration"
    fi
    
    if command -v swapon >/dev/null 2>&1; then
        if swapon -s 2>/dev/null | grep -q "partition"; then
            swapoff -a 2>/dev/null || true
            log "INFO" "Swap has been disabled"
        else
            log "INFO" "Swap is already disabled"
        fi
    fi
    
    # Skip kernel modules and sysctl configuration if in a container
    if [ $IS_CONTAINER -eq 1 ]; then
        log "INFO" "Skipping kernel modules and sysctl configuration in container environment"
        return 0
    fi
    
    # Configure iptables to see bridged traffic
    mkdir -p /etc/modules-load.d/ 2>/dev/null || true
    
    if [ -d /etc/modules-load.d ]; then
        cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF
        
        # Attempt to load modules, but do not fail on error
        modprobe overlay 2>/dev/null || log "WARN" "Unable to load overlay module, continuing"
        modprobe br_netfilter 2>/dev/null || log "WARN" "Unable to load br_netfilter module, continuing"
    else
        log "WARN" "Directory /etc/modules-load.d does not exist, skipping module configuration"
    fi
    
    # Set necessary sysctl parameters
    mkdir -p /etc/sysctl.d/ 2>/dev/null || true
    
    if [ -d /etc/sysctl.d ]; then
        cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
        
        # Attempt to apply sysctl settings, but do not fail on error
        sysctl --system 2>/dev/null || log "WARN" "Failed to apply sysctl parameters, continuing"
    else
        log "WARN" "Directory /etc/sysctl.d does not exist, skipping sysctl configuration"
    fi
    
    log "INFO" "System preparation completed"
}

# Configure Alibaba Cloud repositories
configure_repositories() {
    log "INFO" "Checking repository configuration..."
    
    # Check if kubernetes.repo is already configured with Alibaba Cloud
    if [ -f /etc/yum.repos.d/kubernetes.repo ] && grep -q "mirrors.aliyun.com/kubernetes" /etc/yum.repos.d/kubernetes.repo; then
        log "INFO" "Kubernetes Alibaba Cloud repository is already configured"
        kubernetes_repo_configured=true
    else
        kubernetes_repo_configured=false
    fi
    
    # Check if docker-ce.repo is already configured with Alibaba Cloud
    if [ -f /etc/yum.repos.d/docker-ce.repo ] && grep -q "mirrors.aliyun.com/docker-ce" /etc/yum.repos.d/docker-ce.repo; then
        log "INFO" "Docker CE Alibaba Cloud repository is already configured"
        docker_repo_configured=true
    else
        docker_repo_configured=false
    fi
    
    # Skip if all repositories are already configured
    if $kubernetes_repo_configured && $docker_repo_configured; then
        log "INFO" "All repositories are already configured, skipping configuration"
        return 0
    fi
    
    log "INFO" "Configuring repositories..."
    
    # Backup existing repo files
    if [ ! -d "/etc/yum.repos.d/backup" ]; then
        mkdir -p /etc/yum.repos.d/backup
        mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
        log "INFO" "Backed up existing repository files"
    fi
    
    # Add Alibaba Cloud base repository
    cat > /etc/yum.repos.d/CentOS-Base.repo << 'EOF'
# CentOS-Base.repo
#
# The mirror system uses the connecting IP address of the client and the
# update status of each mirror to pick mirrors that are updated to and
# geographically close to the client.  You should use this for CentOS updates
# unless you are manually picking other mirrors.
#
# If the mirrorlist= does not work for you, as a fall back you can try the
# remarked out baseurl= line instead.
#
#

[base]
name=CentOS-$releasever - Base - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

#released updates
[updates]
name=CentOS-$releasever - Updates - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

#additional packages that may be useful
[extras]
name=CentOS-$releasever - Extras - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

#additional packages that extend functionality of existing packages
[centosplus]
name=CentOS-$releasever - Plus - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/$releasever/centosplus/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
EOF
    
    # Add Docker CE repository (for containerd)
    cat > /etc/yum.repos.d/docker-ce.repo << 'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF
    
    # Add Kubernetes repository
    cat > /etc/yum.repos.d/kubernetes.repo << 'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
    
    # Clean and refresh yum cache
    yum clean all
    yum makecache
    if [ $? -ne 0 ]; then
        log "WARN" "Failed to refresh repository cache, but installation will continue"
    else
        log "INFO" "Repository configuration completed successfully"
    fi
    
    return 0
}

# Install required packages
install_required_packages() {
    log "INFO" "Installing required packages..."
    
    # Ensure iproute2 is installed first (for IP detection)
    if ! command -v ip >/dev/null 2>&1; then
        yum install -y iproute2 >/dev/null 2>&1 || yum install -y iproute >/dev/null 2>&1
        if ! command -v ip >/dev/null 2>&1; then
            log "WARN" "Could not install iproute2/iproute package"
        fi
    fi
    
    # Install basic tools in batches to reduce failure risk
    log "INFO" "Installing essential network tools..."
    yum install -y curl wget iputils net-tools
    soft_error $? "Some network tools installation failed, continuing"
    
    log "INFO" "Installing system utilities..."
    yum install -y yum-utils device-mapper-persistent-data lvm2
    soft_error $? "Some system utilities installation failed, continuing"
    
    log "INFO" "Installing additional Kubernetes dependencies..."
    yum install -y socat conntrack ipvsadm ipset jq sysstat iptables-services
    soft_error $? "Some Kubernetes dependencies installation failed, continuing"
    
    log "INFO" "Basic tools installation completed"
}

# Install and configure containerd
install_containerd() {
    log "INFO" "Checking containerd installation status..."
    
    # Check if containerd is already installed and running
    if command -v containerd >/dev/null 2>&1 && systemctl is-active --quiet containerd 2>/dev/null; then
        log "INFO" "Containerd is already installed and running, skipping installation"
        return 0
    elif command -v containerd >/dev/null 2>&1; then
        log "INFO" "Containerd is installed but not running, attempting to start service"
        systemctl start containerd 2>/dev/null || true
        if systemctl is-active --quiet containerd 2>/dev/null; then
            log "INFO" "Containerd service started successfully"
            return 0
        else
            log "WARN" "Containerd service could not start, attempting reconfiguration"
        fi
    else
        log "INFO" "Installing containerd..."
    fi
    
    # Install containerd from Docker CE repository
    yum install -y containerd.io
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to install containerd"
        return 1
    fi
    
    # Create default configuration
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml >/dev/null
    
    # Configure containerd to use Alibaba Cloud mirror
    sed -i 's|https://registry-1.docker.io|https://registry.cn-hangzhou.aliyuncs.com|g' /etc/containerd/config.toml
    
    # Configure systemd cgroup driver
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # Enable and start containerd
    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd
    
    if systemctl is-active --quiet containerd; then
        log "INFO" "Containerd installation and configuration completed successfully"
        return 0
    else
        log "ERROR" "Failed to start containerd"
        return 1
    fi
}

# Install and configure crictl
install_crictl() {
    log "INFO" "Checking crictl installation status..."
    
    # Check if crictl is already installed
    if command -v crictl >/dev/null 2>&1; then
        log "INFO" "crictl is already installed, skipping installation"
        
        # Check if already configured
        if [ -f /etc/crictl.yaml ]; then
            log "INFO" "crictl is already configured"
            return 0
        else
            log "INFO" "crictl is not configured, creating configuration file"
        fi
    else
        log "INFO" "Installing crictl..."
        
        # Install crictl by downloading from GitHub
        CRICTL_VERSION="v1.28.0"
        wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-amd64.tar.gz -O /tmp/crictl.tar.gz
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to download crictl"
            return 1
        fi
        
        tar -zxf /tmp/crictl.tar.gz -C /usr/local/bin
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to extract crictl"
            return 1
        fi
        
        rm -f /tmp/crictl.tar.gz
    fi
    
    # Default configuration for crictl to use containerd
    cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
    
    log "INFO" "crictl installation and configuration completed successfully"
    return 0
}

# Install Kubernetes components
install_kubernetes() {
    log "INFO" "Checking Kubernetes components installation status..."
    
    # Check if kubeadm is already installed
    if command -v kubeadm >/dev/null 2>&1 && command -v kubelet >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
        local installed_version=$(kubeadm version -o short 2>/dev/null)
        log "INFO" "Kubernetes components are already installed, version: $installed_version"
        
        # Check if kubelet is configured
        if [ -f /etc/sysconfig/kubelet ]; then
            log "INFO" "kubelet is already configured"
            
            # Ensure kubelet service is enabled
            systemctl enable kubelet 2>/dev/null || true
            
            # Check if kubelet is running
            if systemctl is-active --quiet kubelet 2>/dev/null; then
                log "INFO" "kubelet service is running"
            else
                log "INFO" "kubelet service is not running, it will start automatically after cluster initialization"
            fi
            
            return 0
        else
            log "INFO" "kubelet is not configured, creating configuration file"
        fi
    else
        log "INFO" "Installing Kubernetes components..."
        
        # Check available versions
        local kube_version=""
        log "INFO" "Available Kubernetes versions:"
        yum list --showduplicates kubeadm --disableexcludes=kubernetes | grep kubeadm || true
        
        log "INFO" "Which Kubernetes version would you like to install? (e.g., 1.28.0, press Enter for latest)"
        read -r kube_version
        
        local version_flag=""
        if [ -n "$kube_version" ]; then
            version_flag="-${kube_version}"
        fi
        
        # Install Kubernetes components
        yum install -y kubelet${version_flag} kubeadm${version_flag} kubectl${version_flag} --disableexcludes=kubernetes
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to install Kubernetes components"
            return 1
        fi
    fi
    
    # Enable kubelet
    systemctl enable kubelet
    
    # Create kubelet configuration
    cat > /etc/sysconfig/kubelet << EOF
KUBELET_EXTRA_ARGS="--cgroup-driver=systemd --container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
    
    # Restart kubelet
    systemctl daemon-reload
    systemctl restart kubelet 2>/dev/null || true
    
    log "INFO" "Kubernetes components installation and configuration completed successfully"
    return 0
}

# Initialize Kubernetes master node
init_kubernetes_master() {
    local ip=$1
    
    # Check if already initialized
    if [ -f /etc/kubernetes/admin.conf ]; then
        log "INFO" "Kubernetes cluster already initialized, skipping initialization steps"
        
        # Check cluster status
        if systemctl is-active --quiet kubelet && kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes &>/dev/null; then
            log "INFO" "Kubernetes cluster is running"
            
            # Check if CNI is installed
            if kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system | grep -i calico &>/dev/null; then
                log "INFO" "Calico CNI is already installed"
            else
                log "INFO" "No CNI plugin detected, attempting to install Calico..."
                install_cni
            fi
            
            # Set up kubectl configuration
            setup_kubectl_config
            
            return 0
        else
            log "WARN" "Kubernetes configuration detected but cluster may not be healthy, resetting and reinitializing"
            kubeadm reset -f || true
        fi
    fi
    
    log "INFO" "Initializing Kubernetes master node..."
    
    # Create kubeadm configuration file - do not specify node name, use current hostname
    cat > /tmp/kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $ip
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
imageRepository: registry.cn-hangzhou.aliyuncs.com/google_containers
EOF
    
    # Pull required images first
    log "INFO" "Pulling required images..."
    kubeadm config images pull --config /tmp/kubeadm-config.yaml
    if [ $? -ne 0 ]; then
        log "WARN" "Failed to pull Kubernetes images, attempting to continue..."
    fi
    
    # Initialize cluster
    log "INFO" "Initializing Kubernetes cluster..."
    kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to initialize Kubernetes master node"
        exit 1
    fi
    
    # Set up kubectl configuration
    setup_kubectl_config
    
    # Install CNI plugin
    install_cni
    
    log "INFO" "Kubernetes master node initialized successfully"
}

# Set up kubectl configuration
setup_kubectl_config() {
    # Set up kubectl for root user
    if [ -f /etc/kubernetes/admin.conf ]; then
        mkdir -p /root/.kube
        cp -f /etc/kubernetes/admin.conf /root/.kube/config
        chown $(id -u):$(id -g) /root/.kube/config
        log "INFO" "kubectl configured for root user"
        
        # Optionally set up kubectl for non-root user
        echo -e "${GREEN}Would you like to set up kubectl for a non-root user? (y/n)${NC}"
        read -r nonroot_setup
        
        if [[ $nonroot_setup =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Please enter the username:${NC}"
            read -r nonroot_user
            
            if id "$nonroot_user" >/dev/null 2>&1; then
                mkdir -p /home/$nonroot_user/.kube
                cp -f /etc/kubernetes/admin.conf /home/$nonroot_user/.kube/config
                chown -R $nonroot_user:$nonroot_user /home/$nonroot_user/.kube
                log "INFO" "kubectl configured for user $nonroot_user"
            else
                log "WARN" "User $nonroot_user does not exist"
            fi
        fi
    else
        log "WARN" "admin.conf file not found, unable to configure kubectl"
    fi
}

# Join Kubernetes cluster as a worker node
join_kubernetes_node() {
    log "INFO" "Preparing to join Kubernetes cluster..."
    
    # Check if already joined
    if [ -f /etc/kubernetes/kubelet.conf ]; then
        log "INFO" "This node may already be part of a cluster"
        
        # Check if kubelet is running
        if systemctl is-active --quiet kubelet; then
            log "INFO" "kubelet service is running, node is already in cluster"
            return 0
        else
            log "WARN" "kubelet service is not running, resetting and rejoining cluster"
            kubeadm reset -f || true
        fi
    fi
    
    log "INFO" "Please enter the kubeadm join command from the master node:"
    read -r join_command
    
    # Execute join command
    log "INFO" "Executing join command: $join_command"
    eval "$join_command"
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to join Kubernetes cluster"
        exit 1
    fi
    
    log "INFO" "Node successfully joined the cluster"
}

# Install CNI plugin (Calico)
install_cni() {
    log "INFO" "Installing CNI plugin (Calico)..."
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calico.yaml
    if [ $? -ne 0 ]; then
        log "WARN" "Failed to install Calico CNI, you need to install a network plugin manually"
    else
        log "INFO" "Calico CNI installed successfully"
    fi
}

# Verify installation
verify_installation() {
    log "INFO" "Verifying installation..."
    
    # Check if kubelet is running
    if systemctl status kubelet >/dev/null 2>&1; then
        log "INFO" "Kubelet service is running"
    else
        log "WARN" "Kubelet service is not running properly, please check"
    fi
    
    # For master node, check cluster status
    if [ "$NODE_TYPE" == "master" ]; then
        log "INFO" "Waiting for nodes to be ready (this may take a few minutes)..."
        
        # Wait for nodes to be ready (up to 5 minutes)
        for i in {1..30}; do
            if kubectl get nodes 2>/dev/null | grep " Ready " >/dev/null; then
                break
            fi
            log "INFO" "Waiting for nodes to be ready...($i/30)"
            sleep 10
        done
        
        # Final check
        if kubectl get nodes 2>/dev/null | grep " Ready " >/dev/null; then
            log "INFO" "Kubernetes cluster is running normally"
        else
            log "WARN" "Nodes are not yet in Ready state, please check with 'kubectl get nodes'"
        fi
        
        # Check pods in kube-system namespace
        log "INFO" "Kubernetes system pod status:"
        kubectl get pods -n kube-system 2>/dev/null || log "WARN" "Unable to retrieve system pod status"
    fi
    
    log "INFO" "Kubernetes installation verification completed"
}

# Display completion message
display_completion() {
    local hostname=$(hostname)
    log "INFO" "Kubernetes installation completed successfully!"
    
    if [ "$NODE_TYPE" == "master" ]; then
        log "INFO" "Kubernetes master node is running at https://$NODE_IP:6443"
        log "INFO" "Using current hostname '$hostname' as master node name"
        log "INFO" "To add worker nodes to the cluster, run the following command on each node:"
        kubeadm token create --print-join-command 2>/dev/null || log "WARN" "Unable to create join token"
        
        log "INFO" "To use kubectl, run:"
        log "INFO" "export KUBECONFIG=/etc/kubernetes/admin.conf"
        log "INFO" "Or copy /etc/kubernetes/admin.conf to ~/.kube/config"
    else
        log "INFO" "This node has joined the Kubernetes cluster"
        log "INFO" "Using current hostname '$hostname' as worker node name"
    fi
    
    log "INFO" "To check cluster status, run on the master node: kubectl get nodes"
    log "INFO" "If you need to clean up the installation, run '$0 cleanup'"
}

# Cleanup function
cleanup() {
    log "INFO" "Cleaning up Kubernetes installation..."
    
    # Stop services
    log "INFO" "Stopping related services..."
    systemctl stop kubelet 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true
    
    # Reset kubeadm - attempt normal reset first
    if command -v kubeadm >/dev/null 2>&1; then
        log "INFO" "Resetting Kubernetes cluster configuration..."
        kubeadm reset -f 2>/dev/null || true
    fi
    
    # Remove all Kubernetes configuration files
    log "INFO" "Removing Kubernetes configuration files..."
    rm -rf /etc/kubernetes/* 2>/dev/null || true
    rm -rf /tmp/kubeadm* 2>/dev/null || true
    
    # Remove all kubeconfig files
    rm -rf /root/.kube 2>/dev/null || true
    find /home -name ".kube" -type d -exec rm -rf {} \; 2>/dev/null || true
    
    # Ask if installed packages should be removed
    echo -e "${GREEN}Would you like to remove installed packages? (y/n)${NC}"
    read -r remove_packages
    
    if [[ $remove_packages =~ ^[Yy]$ ]]; then
        log "INFO" "Removing packages..."
        yum remove -y kubeadm kubectl kubelet kubernetes-cni containerd.io 2>/dev/null || true
        yum autoremove -y 2>/dev/null || true
        log "INFO" "Packages have been removed"
    fi
    
    # Clean up directories
    log "INFO" "Cleaning up system files..."
    rm -rf /var/lib/kubelet/ 2>/dev/null || true
    rm -rf /var/lib/etcd/ 2>/dev/null || true
    rm -rf /var/lib/containerd/ 2>/dev/null || true
    rm -rf /etc/cni/net.d 2>/dev/null || true
    rm -rf /opt/cni/bin 2>/dev/null || true
    rm -rf /var/run/kubernetes 2>/dev/null || true
    rm -rf /etc/containerd/ 2>/dev/null || true
    rm -f /etc/crictl.yaml 2>/dev/null || true
    
    # Remove cni0 bridge
    if ip link show cni0 >/dev/null 2>&1; then
        log "INFO" "Removing cni0 bridge..."
        ip link delete cni0 2>/dev/null || true
    fi
    
    # Remove flannel.1 bridge
    if ip link show flannel.1 >/dev/null 2>&1; then
        log "INFO" "Removing flannel.1 bridge..."
        ip link delete flannel.1 2>/dev/null || true
    fi
    
    # Remove other CNI network devices
    for dev in $(ip -o link show | grep -E 'cali|vxlan|tunl|veth' | awk -F': ' '{print $2}' | cut -d@ -f1 2>/dev/null); do
        log "INFO" "Removing network device: $dev"
        ip link delete $dev 2>/dev/null || true
    done
    
    # Remove configuration files
    rm -f /etc/sysconfig/kubelet 2>/dev/null || true
    rm -f /etc/modules-load.d/k8s.conf 2>/dev/null || true
    rm -f /etc/sysctl.d/k8s.conf 2>/dev/null || true
    
    # Restore original repositories if backups exist
    if [ -d "/etc/yum.repos.d/backup" ] && [ -n "$(ls -A /etc/yum.repos.d/backup/ 2>/dev/null)" ]; then
        log "INFO" "Restoring original repositories..."
        rm -f /etc/yum.repos.d/*.repo 2>/dev/null || true
        cp /etc/yum.repos.d/backup/* /etc/yum.repos.d/ 2>/dev/null || true
        log "INFO" "Original repository files have been restored"
    fi
    
    # Restart Docker service (if present)
    if systemctl list-unit-files | grep -q docker; then
        log "INFO" "Restarting Docker service..."
        systemctl restart docker 2>/dev/null || true
    fi
    
    # Clean yum cache
    log "INFO" "Cleaning YUM cache..."
    yum clean all 2>/dev/null || true
    
    # Clear iptables rules
    log "INFO" "Clearing iptables rules..."
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -t mangle -X 2>/dev/null || true
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    
    log "INFO" "Cleanup completed! System restored to pre-Kubernetes installation state"
    
    # Ensure immediate exit after cleanup
    exit 0
}

# Main function
main() {
    # Check if cleanup is requested
    if [ "$1" == "cleanup" ]; then
        cleanup  # cleanup function will exit internally
    fi
    
    # Check if script is running as root
    check_root
    
    # Check if running in a container
    check_container
    
    # Welcome message
    log "INFO" "Kubernetes installation script started"
    
    # Detect and confirm IP
    NODE_IP=$(detect_ip)
    log "INFO" "Detected IP address: $NODE_IP"
    echo -e "${GREEN}Is this IP address correct? [Y/n]:${NC}"
    read -r confirm_ip
    
    if [[ $confirm_ip =~ ^[Nn]$ ]]; then
        echo -e "${GREEN}Please enter the correct IP address:${NC}"
        read -r NODE_IP
    fi
    
    # Ensure IP address and current hostname are mapped in hosts file
    update_hosts_file "$NODE_IP"
    
    log "INFO" "Installing basic components, please wait..."
    
    # Install and configure basic components
    prepare_system
    configure_repositories
    install_required_packages
    install_containerd
    install_crictl
    install_kubernetes
    
    log "INFO" "Basic components installation completed"
    
    # Select node type after installing basic components
    while true; do
        echo -e "${GREEN}Please select node type [1-2]:${NC}"
        echo "1) Master node - executes kubeadm init"
        echo "2) Worker node - executes kubeadm join"
        read -r choice
        
        case $choice in
            1)
                NODE_TYPE="master"
                log "INFO" "You selected master node, proceeding with initialization"
                init_kubernetes_master "$NODE_IP"
                break
                ;;
            2)
                NODE_TYPE="node"
                log "INFO" "You selected worker node, proceeding with joining cluster"
                join_kubernetes_node
                break
                ;;
            *)
                log "WARN" "Invalid choice, please try again"
                ;;
        esac
    done
    
    # Verify installation
    verify_installation
    
    # Display completion message
    display_completion
}

# Execute main function with all parameters
main "$@"