#!/bin/bash

# Terminal 1 - browseterm-server
kubectl port-forward -n browseterm --address 192.168.0.3 svc/browseterm-server-development-service 9999:9999 &

# Terminal 2 - socket-ssh (with debug port 9229)
kubectl port-forward -n browseterm --address 192.168.0.4 svc/socket-ssh-development-service 8000:8000 &

wait