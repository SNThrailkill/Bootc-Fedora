# Bootc Examples

This repo contains some examples of how someone can use bootable containers to deploy a wide variety of applications. 
The base images in this repo are based off the [Fedora bootc image](https://quay.io/repository/fedora/fedora-bootc?tab=tags). 
All images come with `distrobox`, `cloud-init`, and `cockpit`. 
These images assume you are using `cloud-init`, `kickstart`, or similar tool to provision your hosts with things like desired hostnames, IP addresses, etc during initial boot.

The `Containerfile` contains multiple stages that can be used to get exactly the software you need. See [Multi-stage Builds](https://docs.docker.com/build/building/multi-stage/) documentation for more information on how this works. For this repo, the image tag is spec

## Nginx
This runs as a quadlet and is configured by the `nginx.conf` which is placed in the `/etc/nginx` folder.

## Pihole
This quadlet will work out of the box but because there's no way to include secrets as part of the quadlet definition you will have to `podman exec` into the pod and change the password manually by running `pihole -a -p` to set a password. This is a one time operation.

## K3S
This folder contains two different paradigms for deploying a K3s cluster with both `server` and `agent` nodes. Meant to be installed on a server that will act as a Kubernetes host. 