# Bootc Examples - K3s - Day 1

This folder contains an example of how you could potentially provision AND configure a K3s cluster in a Day 1 manner. If you want to learn about the differences between Day 0, Day 1, and Day 2 operations then check out [this blog](https://octopus.com/blog/difference-between-day-0-1-2-operations).

In this example, the images built are already configured for a specific master node or load balancer IP -- `10.0.1.100`. If you were to setup your networking so that this IP is for the master node and deployed this image it should "Just Work". I was able to stand up several clusters using this method. I like this approach because everything is thought of and handled as part of the K3s install process and images come ready for immediate deployment with no other configuration required. The disadvantage with this approach is that it does not scale well with multiple clusters. You would need to make multiple `Contailerfile`s for each cluster you want to provision.

Another way of using this is to pass in the master node or load balancer IP as a `build-arg` during image build time. This would allow a single `Containerfile` to be used for multiple images. This could work if you had a pattern of 1 image per host. 

## K3S Server
This image runs k3s as a server with a pre-specified token that comes from CICD variables. As part of the install we grab the installation script and pass several arguements to it:

- `K3S_TOKEN` - This should be set as a `secret` in your repo's configuration. The shared secret that will allow agents to join the cluster.
- `INSTALL_K3S_SKIP_ENABLE` - Due to the fact that we are installing this at build time rather than on a live host we don't want the script to attempt to enable and start the service it creates as it will fail. Instead we will manually enable the service but not start it so that way on boot it will start correctly.
- `INSTALL_K3S_SKIP_SELINUX_RPM` - Typically during an install on a system with SELINUX the k3s script will attempt to install packages related to making sure the correct SELINUX policies are set and the required packages such as `container-selinux`. These already come baked into the base fedora bootc base image so we dont need to install them.
- `INSTALL_K3S_SELINUX_WARN` - If we do get SELINUX errors I want to be warned about them in the logs rather than break k3s.

## K3S Agent
This image runs a k3s agent and gets pointed at a specific IP address of the server/control plane node. Also uses the pre-specified token from CICD variables. As part of the install we grab the installation script and pass several arguements to it:

- `K3S_URL` - Used to tell the agent where the control plane is to connect to. Needed for all k3s agent installs. 
- `K3S_TOKEN` - This should be set as a `secret` in your repo's configuration. The shared secret that will allow the agent to join the cluster.
- `INSTALL_K3S_SKIP_ENABLE` - Due to the fact that we are installing this at build time rather than on a live host we don't want the script to attempt to enable and start the service it creates as it will fail. Instead we will manually enable the service but not start it so that way on boot it will start correctly.
- `INSTALL_K3S_SKIP_SELINUX_RPM` - Typically during an install on a system with SELINUX the k3s script will attempt to install packages related to making sure the correct SELINUX policies are set and the required packages such as `container-selinux`. These already come baked into the base fedora bootc base image so we dont need to install them.
- `INSTALL_K3S_SELINUX_WARN` - If we do get SELINUX errors I want to be warned about them in the logs rather than break k3s.