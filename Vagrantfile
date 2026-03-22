# -*- mode: ruby -*-
# vi: set ft=ruby :

# Load environment variables from .env file
def load_env
  # Load environment variables from .env file
  # This enables static IP configuration via the .env file
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

# Talos Disk Image Configuration
TALOS_IMAGE_URL = ENV['TALOS_IMAGE_URL'] || "https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso"
TALOS_IMAGE_PATH = ENV['TALOS_IMAGE_PATH'] || "./metal-amd64.iso"

# MAC Address Configuration
MAC_PREFIX = ENV['MAC_PREFIX'] || "52:54:00:00:00"

# Ensure Talos image exists (host-level operation)
unless File.exist?(TALOS_IMAGE_PATH)
  puts "Downloading Talos Linux Raw Image..."
  # Try curl first, fallback to wget
  system("curl -L -o #{TALOS_IMAGE_PATH} #{TALOS_IMAGE_URL}") || system("wget -O #{TALOS_IMAGE_PATH} #{TALOS_IMAGE_URL}")
  unless File.exist?(TALOS_IMAGE_PATH)
    puts "Failed to download Talos image. Please check your internet connection and try again."
    exit 1
  end
  puts "Talos image download complete."
end

# Function to configure a Talos VM (eliminates duplication)
def configure_talos_vm(config, name, cpus, memory_mb, ip, mac_address)
  config.vm.define name do |vm|
    vm.vm.hostname = name

    # Private network (shared across all VMs) - ONLY network interface
    vm.vm.network :private_network,
                  type: 'dhcp',
                  mac: mac_address,
                  libvirt__network_name: ENV['NETWORK_NAME'] || "cluster-talos-net",
                  libvirt__management_network_disabled: true

    # Libvirt provider configuration
    vm.vm.provider :libvirt do |domain|
      domain.driver = "qemu"
      domain.memory = memory_mb
      domain.cpus = cpus
      # Boot from Talos image
      domain.storage :file,
                     device: :cdrom,
                     path: File.expand_path(ENV['TALOS_IMAGE_PATH'] || "./metal-amd64.iso")
      domain.boot 'cdrom'
      domain.boot 'hd'
      # Persistent disk - stored in libvirt pool, preserved by using 'halt' not 'destroy'
      domain.storage :file, size: '5G', bus: 'virtio', cache: 'none'
    end
  end
end

Vagrant.configure("2") do |config|
  # Master Node configuration
  # Static IP from .env file (MASTER_IP=10.0.0.10) via DHCP reservation
  # MAC address: ${MAC_PREFIX}:01
  master_mac = "#{MAC_PREFIX}:01"
  configure_talos_vm(config,
                     ENV['MASTER_NAME'] || "talos-master",
                     (ENV['MASTER_CPUS'] || 4).to_i,
                     (ENV['MASTER_MEMORY'] || 4096).to_i,
                     ENV['MASTER_IP'] || "10.0.0.10",
                     master_mac)

  # Worker Nodes configuration
  # Static IP base from .env file (WORKER_IP_BASE=10.0.0.11)
  # Workers will have IPs: 10.0.0.11, 10.0.0.12, etc.
  # MAC addresses: ${MAC_PREFIX}:0b, ${MAC_PREFIX}:0c, etc. (hex 11, 12...)
  worker_name_prefix = ENV['WORKER_NAME_PREFIX'] || "talos-worker-"
  worker_count = (ENV['WORKER_COUNT'] || 2).to_i
  worker_ip_base = ENV['WORKER_IP_BASE'] || "10.0.0.11"
  worker_cpus = (ENV['WORKER_CPUS'] || 1).to_i
  worker_memory = (ENV['WORKER_MEMORY'] || 2048).to_i

  # Parse the base IP to generate sequential IPs for worker nodes
  ip_parts = worker_ip_base.split('.')
  last_octet = ip_parts[3].to_i

  worker_count.times do |i|
    name = "#{worker_name_prefix}#{i+1}"
    ip = "#{ip_parts[0]}.#{ip_parts[1]}.#{ip_parts[2]}.#{last_octet + i}"
    # Worker MAC: 10 + (i+1) in hex = 0b, 0c, 0d, etc.
    worker_mac_suffix = "%02x" % (11 + i)
    worker_mac = "#{MAC_PREFIX}:#{worker_mac_suffix}"
    configure_talos_vm(config, name, worker_cpus, worker_memory, ip, worker_mac)
  end

  # Global libvirt settings
  config.vm.provider :libvirt do |libvirt|
    libvirt.connect_via_ssh = false
    libvirt.storage_pool_name = ENV['STORAGE_POOL'] || "default"
    libvirt.uri = ENV['LIBVIRT_URI'] || "qemu:///system"
  end
end
