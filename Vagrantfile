# -*- mode: ruby -*-
# vi: set ft=ruby :

# Load environment variables from .env file
def load_env
  env_file = File.join(File.dirname(__FILE__), '.env')
  if File.exist?(env_file)
    File.read(env_file).each_line do |line|
      next if line.strip.empty? || line.start_with?('#')
      key, value = line.chomp.split('=', 2)
      ENV[key] = value if key && value
    end
  end
end
load_env

# Box Configuration
USE_BOX = ENV['USE_BOX'] == 'true'
BOX_NAME = ENV['BOX_NAME'] || 'talos'
BOX_VERSION = ENV['BOX_VERSION'] || '1.12.6'

# Talos Disk Image Configuration
# ISO-based installation (traditional)
TALOS_IMAGE_URL = ENV['TALOS_IMAGE_URL'] || "https://github.com/siderolabs/talos/releases/download/#{BOX_VERSION}/metal-amd64.iso"
TALOS_IMAGE_PATH = ENV['TALOS_IMAGE_PATH'] || "./metal-amd64.iso"

# Raw disk image (faster provisioning)
USE_RAW_IMAGE = ENV['USE_RAW_IMAGE'] == 'true'
TALOS_RAW_IMAGE_URL = ENV['TALOS_RAW_IMAGE_URL'] || "https://github.com/siderolabs/talos/releases/download/#{BOX_VERSION}/metal-amd64.raw.zst"
TALOS_RAW_IMAGE_PATH = ENV['TALOS_RAW_IMAGE_PATH'] || "./metal-amd64.raw"
TALOS_RAW_IMAGE_COMPRESSED = ENV['TALOS_RAW_IMAGE_COMPRESSED'] || "./metal-amd64.raw.zst"

# MAC Address Configuration
MAC_PREFIX = ENV['MAC_PREFIX'] || "52:54:00:00:00"

# Ensure Talos image exists (if not using box or raw image)
if !USE_BOX && !USE_RAW_IMAGE && !File.exist?(TALOS_IMAGE_PATH)
  puts "Downloading Talos Linux ISO..."
  system("curl -L -o #{TALOS_IMAGE_PATH} #{TALOS_IMAGE_URL}") || system("wget -O #{TALOS_IMAGE_PATH} #{TALOS_IMAGE_URL}")
  unless File.exist?(TALOS_IMAGE_PATH)
    puts "Failed to download Talos ISO."
    exit 1
  end
  puts "Talos ISO download complete."
end

# Ensure raw image exists (if using raw image mode)
if USE_RAW_IMAGE && !File.exist?(TALOS_RAW_IMAGE_PATH)
  puts "Raw image mode enabled but raw image not found. Run: ./scripts/vms-startup.sh"
  puts "The startup script will download and decompress the raw image automatically."
end

# Function to configure a Talos VM
def configure_talos_vm(config, name, cpus, memory_mb, ip, mac_address, disk_size_gb = 5)
  config.vm.define name do |vm|
    vm.vm.hostname = name

    # Use box if configured
    if ENV['USE_BOX'] == 'true'
      vm.vm.box = ENV['BOX_NAME'] || 'talos'
    end

    # Network configuration based on forward mode
    # Bridge mode: connect directly to pre-created bridge (dnsmasq provides DHCP)
    # NAT mode: use libvirt network
    if ENV['FORWARD_MODE'] == 'bridge'
      # Bridge mode - connect directly to bridge interface
      vm.vm.network :private_network,
                    type: 'dhcp',
                    mac: mac_address,
                    libvirt__bridge: ENV['BRIDGE_NAME'] || 'cluster-bridge'
    else
      # NAT mode - use libvirt network
      vm.vm.network :private_network,
                    type: 'dhcp',
                    mac: mac_address,
                    libvirt__network_name: ENV['NETWORK_NAME'] || "cluster-talos-net"
    end

    # Libvirt provider configuration
    vm.vm.provider :libvirt do |domain|
      domain.driver = "qemu"
      domain.memory = memory_mb
      domain.cpus = cpus
      domain.boot 'hd'

      # Raw image mode - use pre-installed disk image
      # Vagrant will create the disk in the storage pool
      if ENV['USE_RAW_IMAGE'] == 'true'
        # CDROM with Talos ISO (boot first for installation)
        domain.storage :file,
                       device: :cdrom,
                       path: File.expand_path(ENV['TALOS_IMAGE_PATH'] || "./metal-amd64.iso")
        # For raw image mode, we create a volume from the raw image
        # The startup script handles creating CoW overlays in the pool
        domain.storage :file,
                       size: "#{disk_size_gb}G",
                       bus: 'virtio',
                       cache: 'none',
                       type: 'raw'
        # Boot order: CDROM first (for install), then disk (for normal operation)
        domain.boot 'cdrom'
        domain.boot 'hd'

      # ISO-based installation (traditional)
      elsif ENV['USE_BOX'] != 'true'
        # CDROM with Talos ISO (boot first for installation)
        domain.storage :file,
                       device: :cdrom,
                       path: File.expand_path(ENV['TALOS_IMAGE_PATH'] || "./metal-amd64.iso")
        # Persistent disk for Talos installation (boot second after install)
        domain.storage :file,
                       size: "#{disk_size_gb}G",
                       bus: 'virtio',
                       cache: 'none',
                       type: 'raw'
        # Boot order: CDROM first (for install), then disk (for normal operation)
        domain.boot 'cdrom'
        domain.boot 'hd'

      # Using Vagrant box
      else
        domain.storage :file,
                       size: "#{disk_size_gb}G",
                       bus: 'virtio',
                       cache: 'none'
        domain.boot 'hd'
      end
    end
  end
end

Vagrant.configure("2") do |config|
  # Master Node configuration
  # Static IP from .env file (MASTER_IP=10.0.0.10) via DHCP reservation
  # MAC address: ${MAC_PREFIX}:01
  master_mac = "#{MAC_PREFIX}:01"
  master_disk = (ENV['MASTER_DISK'] || 5).to_i
  configure_talos_vm(config,
                     ENV['MASTER_NAME'] || "talos-master",
                     (ENV['MASTER_CPUS'] || 4).to_i,
                     (ENV['MASTER_MEMORY'] || 4096).to_i,
                     ENV['MASTER_IP'] || "10.0.0.10",
                     master_mac,
                     master_disk)

  # Worker Nodes configuration
  # Static IP base from .env file (WORKER_IP_BASE=10.0.0.11)
  # Workers will have IPs: 10.0.0.11, 10.0.0.12, etc.
  # MAC addresses: ${MAC_PREFIX}:0b, ${MAC_PREFIX}:0c, etc. (hex 11, 12...)
  worker_name_prefix = ENV['WORKER_NAME_PREFIX'] || "talos-worker-"
  worker_count = (ENV['WORKER_COUNT'] || 2).to_i
  worker_ip_base = ENV['WORKER_IP_BASE'] || "10.0.0.11"
  worker_cpus = (ENV['WORKER_CPUS'] || 1).to_i
  worker_memory = (ENV['WORKER_MEMORY'] || 2048).to_i
  worker_disk = (ENV['WORKER_DISK'] || 5).to_i

  # Parse the base IP to generate sequential IPs for worker nodes
  ip_parts = worker_ip_base.split('.')
  last_octet = ip_parts[3].to_i

  worker_count.times do |i|
    name = "#{worker_name_prefix}#{i+1}"
    ip = "#{ip_parts[0]}.#{ip_parts[1]}.#{ip_parts[2]}.#{last_octet + i}"
    # Worker MAC: 10 + (i+1) in hex = 0b, 0c, 0d, etc.
    worker_mac_suffix = "%02x" % (11 + i)
    worker_mac = "#{MAC_PREFIX}:#{worker_mac_suffix}"
    configure_talos_vm(config, name, worker_cpus, worker_memory, ip, worker_mac, worker_disk)
  end

  # Global libvirt settings
  config.vm.provider :libvirt do |libvirt|
    libvirt.connect_via_ssh = false
    libvirt.storage_pool_name = ENV['STORAGE_POOL'] || "default"
    libvirt.uri = ENV['LIBVIRT_URI'] || "qemu:///system"
    
    # Session mode uses user-local storage by default
    if ENV['LIBVIRT_URI'] == "qemu:///session"
      # Session mode: use user's local libvirt storage
      libvirt.storage_pool_name = ENV['STORAGE_POOL'] || "default"
    end
  end
end
