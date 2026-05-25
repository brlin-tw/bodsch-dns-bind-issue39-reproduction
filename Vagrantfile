# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Single-VM Vagrant testing environment for reproducing the BIND dynamic-zone
# "journal out of sync with zone" load failure with the upstream
# bodsch.dns.bind role.  Self-contained: not derived from the parent project's
# Vagrantfile/inventory/playbooks.
#
# Copyright 2026 Buo-ren Lin (OSSII) <buoren.lin@ossii.com.tw>
# SPDX-License-Identifier: AGPL-3.0-or-later

Vagrant.configure("2") do |config|
  config.vm.box = "bento/debian-12"

  # The reproduction drives Ansible from the host; the guest needs nothing
  # synced in.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.define "repro-primary" do |primary|
    primary.vm.hostname = "bind-stale-journal-repro"

    # .30 to avoid colliding with the parent project's .11-.15 VMs if they are
    # also running on the 192.168.56.0/24 host-only network.
    primary.vm.network "private_network", ip: "192.168.56.30"

    primary.vm.provider "virtualbox" do |vb|
      vb.name = "bind-stale-journal-repro"
      vb.cpus = 2
      vb.memory = "1024"
      vb.default_nic_type = "virtio"
    end
  end
end
