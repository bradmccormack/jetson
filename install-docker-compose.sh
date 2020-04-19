#!/usr/bin/env bash

# Installs Docker compose on the Nano
sudo apt update
sudo apt install libgcc-7-dev libssl-dev libffi-dev python-dev -y
sudo -H pip install docker-compose urllib3
sudo apt autoremove -y
