# Bootc Examples - K3s

This image is very simple as all it does is install K3s into your image and enable the systemd service. As part of the install we grab the installation script and pass several arguements to it:

- `INSTALL_K3S_SKIP_ENABLE` - Due to the fact that we are installing this at build time rather than on a live host we don't want the script to attempt to enable and start the service it creates as it will fail. Instead we will manually enable the service but not start it so that way on boot it will start correctly.
- `INSTALL_K3S_SKIP_SELINUX_RPM` - Typically during an install on a system with SELINUX the k3s script will attempt to install packages related to making sure the correct SELINUX policies are set and the required packages such as `container-selinux`. These already come baked into the base fedora bootc base image so we dont need to install them.
- `INSTALL_K3S_SELINUX_WARN` - If we do get SELINUX errors I want to be warned about them in the logs rather than break k3s.

For any other configuration options you would like to pass to K3s, it is expected you will put those in the [/etc/rancher/k3s/config.yaml](https://docs.k3s.io/installation/configuration#configuration-file) file and place this file onto your server wheter that's baking it into your downstream image or using some tool to like Ansible to place the file there during server provisioning.