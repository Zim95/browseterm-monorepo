#!/bin/bash

# Terminal 1 - browseterm-server
kubectl port-forward -n browseterm --address 192.168.0.3 svc/browseterm-server-development-service 9999:9999 &

# Terminal 2 - socket-ssh (with debug port 9229)
kubectl port-forward -n browseterm --address 192.168.0.4 svc/socket-ssh-development-service 8000:8000 &

# Grafana - log UI (observability namespace). localhost only; it's a dev tool, no hostname needed.
#   -> http://localhost:3000  (admin/admin)   Only forwards if the observability stack is deployed.
kubectl port-forward -n observability svc/grafana 3000:3000 &

# Loki - direct API (usually queried through Grafana; handy for /ready and /loki/api/v1/*).
kubectl port-forward -n observability svc/loki 3100:3100 &

wait