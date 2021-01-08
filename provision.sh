#!/bin/bash

# This script is intended to be called during Vagrant provisioning
# by CodeOcean and should not be called individually.

#### DOCKERCONTAINERPOOL INSTALL ####
cd /home/vagrant/dockercontainerpool

# use the same config files as in codeocean
cp ../codeocean/config/database.yml config/database.yml
cp ../codeocean/config/docker.yml.erb config/docker.yml.erb

# use the example config file
cp config/mnemosyne.yml.example config/mnemosyne.yml

# install dependencies
bundle install
