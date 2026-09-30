# Self-hosted ISO-builder runner VM (T1: scaffolding, plan-only proof).
# No apply yet: cloud-init does not exist until T2, so there is
# nothing to boot. Token variable is declared (T3) but unused here.
#
# Provider schema note: 0.9.x is attribute-style (os/devices maps,
# memory in KiB, capacity in bytes) per upstream v0.9.9 examples and
# docs, not the pre-0.9 nested-block style.

terraform {
  required_version = ">= 1.5"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# Dedicated NAT network. The host reaches guests directly (host is
# the gateway), so operator SSH needs no port forward; the guest
# takes DHCP from the range below and T3's runbook resolves it via
# `virsh domifaddr`. Off-host high-port DNAT lands in T3, when the
# address is owned by cloud-init (T2) instead of DHCP.
resource "libvirt_network" "runner" {
  name = "shopno-runner"

  forward = {
    mode = "nat"
  }

  ips = [
    {
      address = "192.168.124.1"
      prefix  = 24
      dhcp = {
        ranges = [
          {
            start = "192.168.124.100"
            end   = "192.168.124.200"
          }
        ]
      }
    }
  ]
}

# Pristine stock Debian trixie cloud image, pinned URL + checksum
# (see variables.tf). Never written to directly: the boot disk below
# overlays it, so T5's destroy/apply re-clones from a clean base.
resource "libvirt_volume" "base" {
  name = "debian-13-genericcloud-amd64.qcow2"
  pool = var.storage_pool

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = var.image_url
    }
  }
}

# Locked 60 GB disk on the iso pool: T0 measured the default pool at
# 41 GB free, which does not fit.
resource "libvirt_volume" "runner" {
  name     = "shopno-iso-builder.qcow2"
  pool     = var.storage_pool
  capacity = var.disk_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.base.path
    format = {
      type = "qcow2"
    }
  }
}

# Locked shape: 8 vCPU / 16 GB RAM / 60 GB disk.
# T2 adds the cloud-init cdrom disk here; until then this is a
# defined domain over an unprovisioned disk (plan-only, never
# applied). Memory is KiB in the 0.9 schema (16 GiB = 16777216).
resource "libvirt_domain" "runner" {
  name   = "shopno-iso-builder"
  vcpu   = var.vcpu
  memory = var.memory_kib
  type   = "kvm"

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.runner.pool
            volume = libvirt_volume.runner.name
          }
        }
        target = {
          bus = "virtio"
          dev = "vda"
        }
        driver = {
          type = "qcow2"
        }
      }
    ]

    interfaces = [
      {
        type  = "network"
        model = { type = "virtio" }
        source = {
          network = {
            network = libvirt_network.runner.name
          }
        }
      }
    ]

    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      }
    ]
  }

  running = true
}

output "vm_name" {
  value = libvirt_domain.runner.name
}

output "ssh" {
  value = "virsh domifaddr shopno-iso-builder  # guest IP (T2 adds user)"
}
