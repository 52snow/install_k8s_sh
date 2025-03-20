#!/bin/bash

# Kubernetes一键安装脚本 - CentOS 7
# 使用阿里云镜像源和containerd作为容器运行时

# 颜色代码，用于格式化输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# 全局变量初始化
NODE_TYPE=""
NODE_NUMBER=""
NODE_IP=""
IS_CONTAINER=0

# 日志函数，只显示中文消息
log() {
    local level=$1
    local cn_msg=$2
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

    echo -e "${color}[$level] $cn_msg${NC}"
}

# 错误处理函数
handle_error() {
    local exit_code=$1
    local error_msg=$2

    if [ $exit_code -ne 0 ]; then
        log "ERROR" "$error_msg"
        log "ERROR" "安装失败！您可以运行 '$0 cleanup' 来清理已安装的组件。"
        exit $exit_code
    fi
}

# 软错误处理函数 - 记录警告但不退出
soft_error() {
    local exit_code=$1
    local warn_msg=$2

    if [ $exit_code -ne 0 ]; then
        log "WARN" "$warn_msg"
        return 1
    fi
    return 0
}

# 检查是否在容器中运行
check_container() {
    # 检查是否在Docker容器中
    if [ -f /.dockerenv ] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        log "INFO" "检测到在容器环境中运行"
        IS_CONTAINER=1
    fi
}

# 检查是否以root用户运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log "ERROR" "此脚本必须以root身份运行"
        exit 1
    fi
}

# 检测IP地址
detect_ip() {
    local ip=""
    
    # 确保网络工具已安装
    if ! command -v ip >/dev/null 2>&1; then
        log "INFO" "正在安装网络工具..."
        yum install -y iproute2 >/dev/null 2>&1 || yum install -y iproute >/dev/null 2>&1
    fi

    # 尝试多种方法检测IP
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
        # 最后尝试从/proc/net/route获取
        ip=$(awk '$2 == "00000000" {print $1}' /proc/net/route 2>/dev/null | 
             xargs -I{} sh -c "ip addr show {} 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1" | 
             head -n 1)
    fi
    
    if [ -z "$ip" ]; then
        log "WARN" "无法自动检测IP地址，请手动输入："
        read -r ip
    fi
    
    echo "$ip"
}

# 节点IP和类型确认函数
confirm_node_ip() {
    NODE_IP=$(detect_ip)
    echo -e "${GREEN}检测到的IP地址: $NODE_IP${NC}"
    echo -e "${GREEN}这个IP地址正确吗? [Y/n]:${NC}"
    read -r confirm_ip
    
    if [[ $confirm_ip =~ ^[Nn]$ ]]; then
        echo -e "${GREEN}请输入正确的IP地址:${NC}"
        read -r NODE_IP
    fi
    
    log "INFO" "将使用IP: $NODE_IP"
}

# 更新hosts文件
update_hosts_file() {
    local ip=$1
    
    # 获取当前主机名，不修改它
    local current_hostname
    current_hostname=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "localhost")
    
    log "INFO" "当前主机名: $current_hostname (将不会修改)"
    
    # 仅更新 /etc/hosts 文件
    log "INFO" "正在确保主机名在/etc/hosts文件中正确映射"
    
    # 检查hosts文件是否存在，不存在则创建
    if [ ! -f /etc/hosts ]; then
        echo "127.0.0.1   localhost" > /etc/hosts
        log "INFO" "创建了新的/etc/hosts文件"
    fi
    
    # 检查是否已存在本机IP的记录，如果没有则添加
    if ! grep -q "$ip $current_hostname" /etc/hosts 2>/dev/null; then
        # 检查是否已存在本机IP的其他记录
        if grep -q "^$ip" /etc/hosts; then
            # 如果IP已存在但主机名不匹配，则更新主机名
            sed -i "s/^$ip.*/$ip $current_hostname/" /etc/hosts
            log "INFO" "更新了/etc/hosts中IP $ip 的记录为 $current_hostname"
        else
            # 如果IP不存在，则添加新记录
            echo "$ip $current_hostname" >> /etc/hosts
            log "INFO" "添加了IP $ip 和主机名 $current_hostname 的映射到/etc/hosts"
        fi
    else
        log "INFO" "IP $ip 已经在/etc/hosts中正确映射到 $current_hostname"
    fi
    
    # 显示当前hosts文件
    log "INFO" "/etc/hosts文件内容:"
    cat /etc/hosts 2>/dev/null || log "WARN" "无法读取/etc/hosts文件"
}

# 系统准备
prepare_system() {
    log "INFO" "正在准备系统..."
    
    # 检查是否在容器中运行
    if [ $IS_CONTAINER -eq 1 ]; then
        log "INFO" "在容器中运行，跳过一些系统配置步骤"
    fi
    
    # 禁用SELinux
    if command -v getenforce >/dev/null 2>&1; then
        if [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
            setenforce 0 2>/dev/null || true
            if [ -f /etc/selinux/config ]; then
                sed -i 's/^SELINUX=enforcing$/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true
            fi
            log "INFO" "SELinux已禁用"
        else
            log "INFO" "SELinux已经被禁用"
        fi
    else
        log "INFO" "未检测到SELinux工具，跳过SELinux配置"
    fi
    
    # 禁用swap
    if [ -f /etc/fstab ]; then
        if grep -q "swap" /etc/fstab; then
            sed -i '/swap/d' /etc/fstab 2>/dev/null || true
            log "INFO" "从fstab中移除了swap配置"
        fi
    else
        log "INFO" "未找到/etc/fstab，跳过swap配置"
    fi
    
    if command -v swapon >/dev/null 2>&1; then
        if swapon -s 2>/dev/null | grep -q "partition"; then
            swapoff -a 2>/dev/null || true
            log "INFO" "Swap已禁用"
        else
            log "INFO" "Swap已经被禁用"
        fi
    fi
    
    # 如果在容器中，跳过内核模块和sysctl配置
    if [ $IS_CONTAINER -eq 1 ]; then
        log "INFO" "在容器环境中跳过内核模块和sysctl配置"
        return 0
    fi
    
    # 设置iptables查看桥接流量
    mkdir -p /etc/modules-load.d/ 2>/dev/null || true
    
    if [ -d /etc/modules-load.d ]; then
        cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF
        
        # 尝试加载模块，但不强制退出
        modprobe overlay 2>/dev/null || log "WARN" "无法加载overlay模块，继续执行"
        modprobe br_netfilter 2>/dev/null || log "WARN" "无法加载br_netfilter模块，继续执行"
    else
        log "WARN" "/etc/modules-load.d目录不存在，跳过模块配置"
    fi
    
    # 设置必要的sysctl参数
    mkdir -p /etc/sysctl.d/ 2>/dev/null || true
    
    if [ -d /etc/sysctl.d ]; then
        cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
        
        # 尝试应用sysctl设置，但不强制退出
        sysctl --system 2>/dev/null || log "WARN" "应用sysctl参数失败，继续执行"
    else
        log "WARN" "/etc/sysctl.d目录不存在，跳过sysctl配置"
    fi
    
    log "INFO" "系统准备完成"
}

# 配置阿里云软件源
configure_repositories() {
    log "INFO" "检查软件源配置..."
    
    # 检查kubernetes.repo是否已配置阿里云源
    if [ -f /etc/yum.repos.d/kubernetes.repo ] && grep -q "mirrors.aliyun.com/kubernetes" /etc/yum.repos.d/kubernetes.repo; then
        log "INFO" "Kubernetes阿里云软件源已配置"
        kubernetes_repo_configured=true
    else
        kubernetes_repo_configured=false
    fi
    
    # 检查docker-ce.repo是否已配置阿里云源
    if [ -f /etc/yum.repos.d/docker-ce.repo ] && grep -q "mirrors.aliyun.com/docker-ce" /etc/yum.repos.d/docker-ce.repo; then
        log "INFO" "Docker CE阿里云软件源已配置"
        docker_repo_configured=true
    else
        docker_repo_configured=false
    fi
    
    # 如果所有软件源都已配置，则跳过
    if $kubernetes_repo_configured && $docker_repo_configured; then
        log "INFO" "所有软件源已配置，跳过配置"
        return 0
    fi
    
    log "INFO" "正在配置软件源..."
    
    # 备份现有的repo文件
    if [ ! -d "/etc/yum.repos.d/backup" ]; then
        mkdir -p /etc/yum.repos.d/backup
        mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
        log "INFO" "已备份现有的软件源文件"
    fi
    
    # 添加阿里云基础软件源
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
    
    # 添加Docker CE软件源(用于containerd)
    cat > /etc/yum.repos.d/docker-ce.repo << 'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF
    
    # 添加Kubernetes软件源
    cat > /etc/yum.repos.d/kubernetes.repo << 'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
    
    # 清理并刷新yum缓存
    yum clean all
    yum makecache
    if [ $? -ne 0 ]; then
        log "WARN" "刷新软件源缓存失败，但将继续安装"
    else
        log "INFO" "软件源配置成功"
    fi
    
    return 0
}

# 安装必要的软件包
install_required_packages() {
    log "INFO" "Installing required packages..." "正在安装所需的软件包..."
    
    # 首先确保iproute2已安装（用于IP检测）
    if ! command -v ip >/dev/null 2>&1; then
        yum install -y iproute2 >/dev/null 2>&1 || yum install -y iproute >/dev/null 2>&1
        if ! command -v ip >/dev/null 2>&1; then
            log "WARN" "Could not install iproute2/iproute package" "无法安装iproute2/iproute软件包"
        fi
    fi
    
    # 安装基本工具 - 分批安装以降低失败风险
    log "INFO" "Installing essential network tools..." "正在安装基本网络工具..."
    yum install -y curl wget iputils net-tools
    soft_error $? "Some network tools installation failed, continuing" "部分网络工具安装失败，继续安装"
    
    log "INFO" "Installing system utilities..." "正在安装系统工具..."
    yum install -y yum-utils device-mapper-persistent-data lvm2
    soft_error $? "Some system utilities installation failed, continuing" "部分系统工具安装失败，继续安装"
    
    log "INFO" "Installing additional Kubernetes dependencies..." "正在安装Kubernetes附加依赖..."
    yum install -y socat conntrack ipvsadm ipset jq sysstat iptables-services
    soft_error $? "Some Kubernetes dependencies installation failed, continuing" "部分Kubernetes依赖安装失败，继续安装"
    
    log "INFO" "Basic tools installation completed" "基本工具安装完成"
}

# 安装和配置containerd
install_containerd() {
    log "INFO" "检查containerd安装状态..."
    
    # 检查containerd是否已安装
    if command -v containerd >/dev/null 2>&1 && systemctl is-active --quiet containerd 2>/dev/null; then
        log "INFO" "Containerd已安装并正在运行，跳过安装"
        return 0
    elif command -v containerd >/dev/null 2>&1; then
        log "INFO" "Containerd已安装但未运行，尝试启动服务"
        systemctl start containerd 2>/dev/null || true
        if systemctl is-active --quiet containerd 2>/dev/null; then
            log "INFO" "Containerd服务已成功启动"
            return 0
        else
            log "WARN" "Containerd服务无法启动，将尝试重新配置"
        fi
    else
        log "INFO" "正在安装containerd..."
    fi
    
    # 从Docker CE软件源安装containerd
    yum install -y containerd.io
    if [ $? -ne 0 ]; then
        log "ERROR" "安装containerd失败"
        return 1
    fi
    
    # 创建默认配置
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml >/dev/null
    
    # 配置containerd使用阿里云镜像源
    sed -i 's|https://registry-1.docker.io|https://registry.cn-hangzhou.aliyuncs.com|g' /etc/containerd/config.toml
    
    # 配置systemd cgroup驱动
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # 启用并启动containerd
    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd
    
    if systemctl is-active --quiet containerd; then
        log "INFO" "Containerd安装和配置成功"
        return 0
    else
        log "ERROR" "启动containerd失败"
        return 1
    fi
}

# 安装和配置crictl
install_crictl() {
    log "INFO" "检查crictl安装状态..."
    
    # 检查crictl是否已安装
    if command -v crictl >/dev/null 2>&1; then
        log "INFO" "crictl已安装，跳过安装"
        
        # 检查是否已配置
        if [ -f /etc/crictl.yaml ]; then
            log "INFO" "crictl已配置"
            return 0
        else
            log "INFO" "crictl未配置，正在创建配置文件"
        fi
    else
        log "INFO" "正在安装crictl..."
        
        # 使用直接从GitHub下载的方式安装crictl
        CRICTL_VERSION="v1.28.0"
        wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-amd64.tar.gz -O /tmp/crictl.tar.gz
        if [ $? -ne 0 ]; then
            log "ERROR" "下载crictl失败"
            return 1
        fi
        
        tar -zxf /tmp/crictl.tar.gz -C /usr/local/bin
        if [ $? -ne 0 ]; then
            log "ERROR" "解压crictl失败"
            return 1
        fi
        
        rm -f /tmp/crictl.tar.gz
    fi
    
    # 默认配置crictl使用containerd
    cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
    
    log "INFO" "crictl安装和配置成功"
    return 0
}

# 安装Kubernetes组件
install_kubernetes() {
    log "INFO" "检查Kubernetes组件安装状态..."
    
    # 检查kubeadm是否已安装
    if command -v kubeadm >/dev/null 2>&1 && command -v kubelet >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
        local installed_version=$(kubeadm version -o short 2>/dev/null)
        log "INFO" "Kubernetes组件已安装，版本: $installed_version"
        
        # 检查kubelet是否已配置
        if [ -f /etc/sysconfig/kubelet ]; then
            log "INFO" "kubelet已配置"
            
            # 确保kubelet服务已启用
            systemctl enable kubelet 2>/dev/null || true
            
            # 检查kubelet是否正在运行
            if systemctl is-active --quiet kubelet 2>/dev/null; then
                log "INFO" "kubelet服务正在运行"
            else
                log "INFO" "kubelet服务未运行，将在集群初始化后自动启动"
            fi
            
            return 0
        else
            log "INFO" "kubelet未配置，正在创建配置文件"
        fi
    else
        log "INFO" "正在安装Kubernetes组件..."
        
        # 检查可用版本
        local kube_version=""
        log "INFO" "可用的Kubernetes版本:"
        yum list --showduplicates kubeadm --disableexcludes=kubernetes | grep kubeadm || true
        
        log "INFO" "您想安装哪个Kubernetes版本？(例如1.28.0，回车键选择最新版)"
        read -r kube_version
        
        local version_flag=""
        if [ -n "$kube_version" ]; then
            version_flag="-${kube_version}"
        fi
        
        # 安装Kubernetes组件
        yum install -y kubelet${version_flag} kubeadm${version_flag} kubectl${version_flag} --disableexcludes=kubernetes
        if [ $? -ne 0 ]; then
            log "ERROR" "安装Kubernetes组件失败"
            return 1
        fi
    fi
    
    # 启用kubelet
    systemctl enable kubelet
    
    # 创建kubelet配置
    cat > /etc/sysconfig/kubelet << EOF
KUBELET_EXTRA_ARGS="--cgroup-driver=systemd --container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
    
    # 重启kubelet
    systemctl daemon-reload
    systemctl restart kubelet 2>/dev/null || true
    
    log "INFO" "Kubernetes组件安装和配置成功"
    return 0
}

# 初始化Kubernetes主节点
init_kubernetes_master() {
    local ip=$1
    
    # 检查是否已经初始化
    if [ -f /etc/kubernetes/admin.conf ]; then
        log "INFO" "检测到Kubernetes集群已初始化，跳过初始化步骤"
        
        # 检查集群状态
        if systemctl is-active --quiet kubelet && kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes &>/dev/null; then
            log "INFO" "Kubernetes集群正在运行"
            
            # 检查CNI是否已安装
            if kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system | grep -i calico &>/dev/null; then
                log "INFO" "Calico CNI已安装"
            else
                log "INFO" "未检测到CNI插件，尝试安装Calico..."
                install_cni
            fi
            
            # 设置kubectl配置
            setup_kubectl_config
            
            return 0
        else
            log "WARN" "检测到Kubernetes配置但集群可能不正常，尝试重置并重新初始化"
            kubeadm reset -f || true
        fi
    fi
    
    log "INFO" "正在初始化Kubernetes主节点..."
    
    # 创建kubeadm配置文件 - 不指定节点名称，使用当前主机名
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
    
    # 先拉取所需的镜像
    log "INFO" "正在拉取所需的镜像..."
    kubeadm config images pull --config /tmp/kubeadm-config.yaml
    if [ $? -ne 0 ]; then
        log "WARN" "拉取Kubernetes镜像失败，尝试继续..."
    fi
    
    # 初始化集群
    log "INFO" "正在初始化Kubernetes集群..."
    kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs
    if [ $? -ne 0 ]; then
        log "ERROR" "初始化Kubernetes主节点失败"
        exit 1
    fi
    
    # 设置kubectl配置
    setup_kubectl_config
    
    # 安装CNI插件
    install_cni
    
    log "INFO" "Kubernetes主节点初始化成功"
}

# 设置kubectl配置
setup_kubectl_config() {
    # 为root用户设置kubectl
    if [ -f /etc/kubernetes/admin.conf ]; then
        mkdir -p /root/.kube
        cp -f /etc/kubernetes/admin.conf /root/.kube/config
        chown $(id -u):$(id -g) /root/.kube/config
        log "INFO" "已为root用户配置kubectl"
        
        # 如果需要，也为非root用户设置kubectl
        echo -e "${GREEN}是否为非root用户设置kubectl？(y/n)${NC}"
        read -r nonroot_setup
        
        if [[ $nonroot_setup =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}请输入用户名:${NC}"
            read -r nonroot_user
            
            if id "$nonroot_user" >/dev/null 2>&1; then
                mkdir -p /home/$nonroot_user/.kube
                cp -f /etc/kubernetes/admin.conf /home/$nonroot_user/.kube/config
                chown -R $nonroot_user:$nonroot_user /home/$nonroot_user/.kube
                log "INFO" "已为用户$nonroot_user配置kubectl"
            else
                log "WARN" "用户$nonroot_user不存在"
            fi
        fi
    else
        log "WARN" "找不到admin.conf文件，无法配置kubectl"
    fi
}

# 加入Kubernetes集群作为工作节点
join_kubernetes_node() {
    log "INFO" "准备加入Kubernetes集群..."
    
    # 检查是否已经加入集群
    if [ -f /etc/kubernetes/kubelet.conf ]; then
        log "INFO" "检测到此节点可能已加入集群"
        
        # 检查kubelet是否正在运行
        if systemctl is-active --quiet kubelet; then
            log "INFO" "kubelet服务正在运行，已加入集群"
            return 0
        else
            log "WARN" "kubelet服务未运行，将重置并重新加入集群"
            kubeadm reset -f || true
        fi
    fi
    
    log "INFO" "请输入来自主节点的kubeadm join命令："
    read -r join_command
    
    # 执行join命令
    log "INFO" "执行加入命令: $join_command"
    eval "$join_command"
    if [ $? -ne 0 ]; then
        log "ERROR" "加入Kubernetes集群失败"
        exit 1
    fi
    
    log "INFO" "节点成功加入集群"
}
    
    # 为root用户设置kubectl
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config
    chown $(id -u):$(id -g) /root/.kube/config
    
    # 如果需要，也为非root用户设置kubectl
    echo -e "${GREEN}是否为非root用户设置kubectl？(y/n)${NC}"
    local setup_nonroot
    read -r setup_nonroot
    
    if [[ $setup_nonroot =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}请输入用户名:${NC}"
        local username
        read -r username
        
        if id "$username" >/dev/null 2>&1; then
            mkdir -p /home/$username/.kube
            cp -f /etc/kubernetes/admin.conf /home/$username/.kube/config
            chown -R $username:$username /home/$username/.kube
            log "INFO" "已为用户$username配置kubectl"
        else
            log "WARN" "用户$username不存在"
        fi
    fi
    
    # 安装CNI插件(Calico)
    log "INFO" "正在安装CNI插件(Calico)..."
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calico.yaml
    if [ $? -ne 0 ]; then
        log "WARN" "安装Calico CNI失败，您需要手动安装网络插件"
    else
        log "INFO" "Calico CNI安装成功"
    fi
    
    log "INFO" "Kubernetes主节点初始化成功"
    
    # 显示加入命令
    log "INFO" "要添加工作节点，请使用以下命令："
    kubeadm token create --print-join-command
}

# 配置工作节点
configure_worker_node() {
    log "INFO" "准备加入Kubernetes集群..."
    log "INFO" "请输入来自主节点的kubeadm join命令："
    local join_command
    read -r join_command
    
    # 执行join命令 - 不修改命令，使用默认主机名
    log "INFO" "执行加入命令: $join_command"
    eval "$join_command"
    if [ $? -ne 0 ]; then
        log "ERROR" "加入Kubernetes集群失败"
        exit 1
    fi
    
    log "INFO" "节点成功加入集群"
}

# 验证安装
verify_installation() {
    log "INFO" "正在验证安装..."
    
    # 检查kubelet是否运行
    if systemctl status kubelet >/dev/null 2>&1; then
        log "INFO" "Kubelet服务正在运行"
    else
        log "WARN" "Kubelet服务未正常运行，请检查"
    fi
    
    # 对于主节点，检查集群状态
    if [ "$NODE_TYPE" == "master" ]; then
        log "INFO" "等待节点就绪（这可能需要几分钟时间）..."
        
        # 等待节点就绪(最多5分钟)
        for i in {1..30}; do
            if kubectl get nodes 2>/dev/null | grep " Ready " >/dev/null; then
                break
            fi
            log "INFO" "等待节点就绪...($i/30)"
            sleep 10
        done
        
        # 最终检查
        if kubectl get nodes 2>/dev/null | grep " Ready " >/dev/null; then
            log "INFO" "Kubernetes集群正常运行"
        else
            log "WARN" "节点尚未处于Ready状态，请使用'kubectl get nodes'检查"
        fi
        
        # 检查kube-system命名空间中运行的Pod
        log "INFO" "Kubernetes系统Pod状态:"
        kubectl get pods -n kube-system 2>/dev/null || log "WARN" "无法获取系统Pod状态"
    fi
    
    log "INFO" "Kubernetes安装验证完成"
}

# 显示完成消息
display_completion() {
    local hostname=$(hostname)
    log "INFO" "Kubernetes安装成功完成！"
    
    if [ "$NODE_TYPE" == "master" ]; then
        log "INFO" "Kubernetes主节点运行在https://$NODE_IP:6443"
        log "INFO" "以当前主机名 '$hostname' 作为主节点名"
        log "INFO" "要向集群添加工作节点，请在每个节点上运行以下命令："
        kubeadm token create --print-join-command 2>/dev/null || log "WARN" "无法创建加入令牌"
        
        log "INFO" "要使用kubectl，请运行："
        log "INFO" "export KUBECONFIG=/etc/kubernetes/admin.conf"
        log "INFO" "或者复制/etc/kubernetes/admin.conf到~/.kube/config"
    else
        log "INFO" "此节点已加入Kubernetes集群"
        log "INFO" "以当前主机名 '$hostname' 作为工作节点名"
    fi
    
    log "INFO" "如需检查集群状态，可在主节点上运行: kubectl get nodes"
    log "INFO" "如果需要清理安装，请运行'$0 cleanup'"
}

# 清理函数
cleanup() {
    log "INFO" "正在清理Kubernetes安装..."
    
    # 停止服务
    log "INFO" "停止相关服务..."
    systemctl stop kubelet 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true
    
    # 重置kubeadm - 首先尝试正常重置
    if command -v kubeadm >/dev/null 2>&1; then
        log "INFO" "重置Kubernetes集群配置..."
        kubeadm reset -f 2>/dev/null || true
    fi
    
    # 删除所有kubernetes配置文件
    log "INFO" "删除Kubernetes配置文件..."
    rm -rf /etc/kubernetes/* 2>/dev/null || true
    rm -rf /tmp/kubeadm* 2>/dev/null || true
    
    # 删除所有kubeconfig文件
    rm -rf /root/.kube 2>/dev/null || true
    find /home -name ".kube" -type d -exec rm -rf {} \; 2>/dev/null || true
    
    # 询问是否删除已安装软件包
    echo -e "${GREEN}是否要删除已安装的软件包? (y/n)${NC}"
    read -r remove_packages
    
    if [[ $remove_packages =~ ^[Yy]$ ]]; then
        log "INFO" "正在删除软件包..."
        yum remove -y kubeadm kubectl kubelet kubernetes-cni containerd.io 2>/dev/null || true
        yum autoremove -y 2>/dev/null || true
        log "INFO" "软件包已删除"
    fi
    
    # 清理目录
    log "INFO" "正在清理系统文件..."
    rm -rf /var/lib/kubelet/ 2>/dev/null || true
    rm -rf /var/lib/etcd/ 2>/dev/null || true
    rm -rf /var/lib/containerd/ 2>/dev/null || true
    rm -rf /etc/cni/net.d 2>/dev/null || true
    rm -rf /opt/cni/bin 2>/dev/null || true
    rm -rf /var/run/kubernetes 2>/dev/null || true
    rm -rf /etc/containerd/ 2>/dev/null || true
    rm -f /etc/crictl.yaml 2>/dev/null || true
    
    # 删除cni0网桥
    if ip link show cni0 >/dev/null 2>&1; then
        log "INFO" "删除cni0网桥..."
        ip link delete cni0 2>/dev/null || true
    fi
    
    # 删除flannel.1网桥
    if ip link show flannel.1 >/dev/null 2>&1; then
        log "INFO" "删除flannel.1网桥..."
        ip link delete flannel.1 2>/dev/null || true
    fi
    
    # 删除其他CNI网络设备
    for dev in $(ip -o link show | grep -E 'cali|vxlan|tunl|veth' | awk -F': ' '{print $2}' | cut -d@ -f1 2>/dev/null); do
        log "INFO" "删除网络设备: $dev"
        ip link delete $dev 2>/dev/null || true
    done
    
    # 删除配置文件
    rm -f /etc/sysconfig/kubelet 2>/dev/null || true
    rm -f /etc/modules-load.d/k8s.conf 2>/dev/null || true
    rm -f /etc/sysctl.d/k8s.conf 2>/dev/null || true
    
    # 如果存在备份，则恢复原始软件源
    if [ -d "/etc/yum.repos.d/backup" ] && [ -n "$(ls -A /etc/yum.repos.d/backup/ 2>/dev/null)" ]; then
        log "INFO" "恢复原始软件源..."
        rm -f /etc/yum.repos.d/*.repo 2>/dev/null || true
        cp /etc/yum.repos.d/backup/* /etc/yum.repos.d/ 2>/dev/null || true
        log "INFO" "已恢复原始的软件源文件"
    fi
    
    # 重启docker服务(如果存在)
    if systemctl list-unit-files | grep -q docker; then
        log "INFO" "重启Docker服务..."
        systemctl restart docker 2>/dev/null || true
    fi
    
    # 清理yum缓存
    log "INFO" "清理YUM缓存..."
    yum clean all 2>/dev/null || true
    
    # 清理iptables规则
    log "INFO" "清理iptables规则..."
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -t mangle -X 2>/dev/null || true
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    
    log "INFO" "清理完成！系统已恢复到Kubernetes安装前的状态"
    
    # 确保清理后立即退出
    exit 0
}

# 主函数
main() {
    # 检查是否请求清理
    if [ "$1" == "cleanup" ]; then
        cleanup  # cleanup函数内部会执行exit
    fi
    
    # 检查脚本是否以root身份运行
    check_root
    
    # 检查是否在容器中运行
    check_container
    
    # 欢迎消息
    log "INFO" "Kubernetes安装脚本已启动"
    
    # 检测并确认IP
    NODE_IP=$(detect_ip)
    log "INFO" "检测到的IP地址: $NODE_IP"
    echo -e "${GREEN}这个IP地址正确吗? [Y/n]:${NC}"
    read -r confirm_ip
    
    if [[ $confirm_ip =~ ^[Nn]$ ]]; then
        echo -e "${GREEN}请输入正确的IP地址:${NC}"
        read -r NODE_IP
    fi
    
    # 确保IP地址和当前主机名在hosts文件中映射
    update_hosts_file "$NODE_IP"
    
    log "INFO" "正在安装基础组件，请稍候..."
    
    # 安装和配置基础组件
    prepare_system
    configure_repositories
    install_required_packages
    install_containerd
    install_crictl
    install_kubernetes
    
    log "INFO" "基础组件安装完成"
    
    # 安装完基础组件后选择节点类型
    while true; do
        echo -e "${GREEN}请选择节点类型 [1-2]:${NC}"
        echo "1) 主节点 (master) - 执行kubeadm init"
        echo "2) 工作节点 (node) - 执行kubeadm join"
        read -r choice
        
        case $choice in
            1)
                NODE_TYPE="master"
                log "INFO" "您选择了主节点，将执行初始化"
                init_kubernetes_master "$NODE_IP"
                break
                ;;
            2)
                NODE_TYPE="node"
                log "INFO" "您选择了工作节点，将执行加入集群"
                join_kubernetes_node
                break
                ;;
            *)
                log "WARN" "无效选择，请重新输入"
                ;;
        esac
    done
    
    # 验证安装
    verify_installation
    
    # 显示完成消息
    display_completion
}
    
    # 设置主机名
    set_hostname "$node_type"
    
    # 安装和配置组件
    prepare_system
    configure_repositories
    install_required_packages
    install_containerd
    install_crictl
    install_kubernetes
    
    # 初始化或加入集群
    if [ "$node_type" == "master" ]; then
        init_kubernetes_master "$node_type" "$ip"
    else
        configure_worker_node "$node_type"
    fi
    
    # 验证安装
    verify_installation "$node_type"
    
    # 显示完成消息
    display_completion "$node_type" "$ip"
}

# 执行主函数并传递所有参数
main "$@"