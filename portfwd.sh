#!/bin/bash

# Terminal 1 - browseterm-server
kubectl port-forward -n browseterm-new --address 192.168.0.1 svc/browseterm-server-development-service 9999:9999 &

# Terminal 2 - socket-ssh  
kubectl port-forward -n browseterm-new --address 192.168.0.2 svc/socket-ssh-service 8000:8000 &

wait