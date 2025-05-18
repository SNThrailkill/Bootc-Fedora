# Bootc Examples - K3s - Day 2

This folder contains an example of how you could potentially provision AND configure a K3s cluster in a Day 2 manner. If you want to learn about the differences between Day 0, Day 1, and Day 2 operations then check out [this blog](https://octopus.com/blog/difference-between-day-0-1-2-operations).

In this example, the images built have no opinions or configurations to them. The `K3S_TOKEN` & `K3S_URL` must be passed into the host during initial boot using a tool like `cloud-init`, `kickstart`, etc. 
This can be done by adding the values to the `/etc/systemd/system/k3s.service.env` file. For example: `echo "K3S_TOKEN=${K3S_TOKEN}" > /etc/systemd/system/k3s.service.env`.

The idea here is that since the single K3s binary can run in a `server` or `agent` node we will have the admistrator decide how this node should run during initial setup. [See here for examples from K3s documentation](https://docs.k3s.io/installation/configuration). 
To see an example `cloud-init` configuration see [this file](./cloud-init.yaml).

## K3S Node

- `INSTALL_K3S_SKIP_ENABLE` - Due to the fact that we are installing this at build time rather than on a live host we don't want the script to attempt to enable and start the service it creates as it will fail. Instead we will manually enable the service but not start it so that way on boot it will start correctly.
- `INSTALL_K3S_SKIP_SELINUX_RPM` - Typically during an install on a system with SELINUX the k3s script will attempt to install packages related to making sure the correct SELINUX policies are set and the required packages such as `container-selinux`. These already come baked into the base fedora bootc base image so we dont need to install them.
- `INSTALL_K3S_SELINUX_WARN` - If we do get SELINUX errors I want to be warned about them in the logs rather than break k3s.