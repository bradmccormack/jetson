#!/usr/bin/env bash

# Installs Docker compose on the Nano
sudo apt update
sudo apt install libgcc-7-dev libssl-dev libffi-dev python-dev -y
sudo -H pip install docker-compose
sudo apt autoremove -y
