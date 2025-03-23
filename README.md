# Bootc Examples

This repo contains some examples of how someone can use bootable containers to deploy a wide
variety of applications. The base images in this repo are based off the [Fedora bootc image](https://quay.io/repository/fedora/fedora-bootc?tab=tags). All images come with `distrobox`, `cloud-init`, and `cockpit`.

The `Containerfile` contains multiple stages that can be used to get exactly the software you need. See [Multi-stage Builds](https://docs.docker.com/build/building/multi-stage/) documentation for more information on how this works. For this repo, the image tag is spec

## Nginx
This runs as a quadlet and is configured by the `nginx.conf` which is placed in the `/etc/nginx` folder.

## Pihole
This quadlet will work out of the box but because there's no way to include secrets as part of the quadlet definition you will have to `podman exec` into the pod and change the password manually by running `pihole -a -p` to set a password. This is a one time operation.

## K3S Server
This image runs k3s as a server with a pre-specified token that comes from CICD variables. As part of the install we grab the installation script and pass several arguements to it:

- `K3S_TOKEN` - The shared secret that will allow agents to join the cluster.
- `INSTALL_K3S_SKIP_ENABLE` - Due to the fact that we are installing this at build time rather than on a live host we don't want the script to attempt to enable and start the service it creates as it will fail. Instead we will manually enable the service but not start it so that way on boot it will start correctly.
- `INSTALL_K3S_SKIP_SELINUX_RPM` - Typically during an install on a system with SELINUX the k3s script will attempt to install packages related to making sure the correct SELINUX policies are set and the required packages such as `container-selinux`. These already come baked into the base fedora bootc base image so we dont need to install them.
- `INSTALL_K3S_SELINUX_WARN` - If we do get SELINUX errors I want to be warned about them in the logs rather than break k3s.

## K3S Agent
This image runs a k3s agent and gets pointed at a specific IP address of the server/control plane node. Also uses the pre-specified token from CICD variables. As part of the install we grab the installation script and pass several arguements to it:

- `K3S_URL` - Used to tell the agent where the control plane is to connect to. Needed for all k3s agent installs. 
- `K3S_TOKEN` - The shared secret that will allow the agent to join the cluster.
- `INSTALL_K3S_SKIP_ENABLE` - Due to the fact that we are installing this at build time rather than on a live host we don't want the script to attempt to enable and start the service it creates as it will fail. Instead we will manually enable the service but not start it so that way on boot it will start correctly.
- `INSTALL_K3S_SKIP_SELINUX_RPM` - Typically during an install on a system with SELINUX the k3s script will attempt to install packages related to making sure the correct SELINUX policies are set and the required packages such as `container-selinux`. These already come baked into the base fedora bootc base image so we dont need to install them.
- `INSTALL_K3S_SELINUX_WARN` - If we do get SELINUX errors I want to be warned about them in the logs rather than break k3s.