# Bootc Examples

This repo contains some examples of how someone can use bootable containers to deploy a wide
variety of applications. The base images in this repo are based off the [Fedora bootc image](https://quay.io/repository/fedora/fedora-bootc?tab=tags). All images come with `distrobox`, `cloud-init`, and `cockpit`.

The `Containerfile` contains multiple stages that can be used to get exactly the software you need. See [Multi-stage Builds](https://docs.docker.com/build/building/multi-stage/) documentation for more information on how this works. For this repo, the image tag is spec

## Nginx
This runs as a quadlet and is configured by the `nginx.conf` which is placed in the `/etc/nginx` folder.

## Pihole
This quadlet will work out of the box but because there's no way to include secrets as part of the quadlet definition you will have to `podman exec` into the pod and change the password manually by running `pihole -a -p` to set a password. This is a one time operation.

## K3S Server
This image runs k3s as a server with a pre-specified token that comes from CICD variables.

## K3S Agent
This image runs a k3s agent and gets pointed at a specific IP address of the server/control plane node. Also uses the pre-specified token from CICD variables.