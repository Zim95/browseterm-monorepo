# BROWSETERM

<!-- Dynamic Repository Stats -->
![GitHub repo size](https://img.shields.io/github/repo-size/Zim95/browseterm-monorepo?style=for-the-badge)
![GitHub last commit](https://img.shields.io/github/last-commit/Zim95/browseterm-monorepo?style=for-the-badge)
![GitHub issues](https://img.shields.io/github/issues/Zim95/browseterm-monorepo?style=for-the-badge)
![License](https://img.shields.io/github/license/Zim95/browseterm-monorepo?style=for-the-badge)

Browseterm is a project that allows users to run linux containers in the browser. The user can create and run different linux terminals and interact with them in the browser. Look at the demo:
<add a gif>

Payment plans:
--------------
1. Free tier: One container per user.
2. Developer tier: Unlimited containers.
3. Enterprise tier: Unlimited containers. Grow storage size and memory size. (Coming soon later).

This repository holds the complete browseterm project. This respository is a collection of all the other repositories that add up to become Browseterm.

## 🛠️ Technology Stack

| Service | Primary Languages | Description |
|---------|------------------|-------------|
| **cert-manager** | ![Python](https://img.shields.io/badge/Python-62.6%25-3776AB?style=flat-square) ![YAML](https://img.shields.io/badge/YAML-16.1%25-cb171e?style=flat-square) ![Shell](https://img.shields.io/badge/Shell-12.4%25-89e051?style=flat-square) | Certificate management service |
| **container-maker-spec** | ![Python](https://img.shields.io/badge/Python-76.9%25-3776AB?style=flat-square) ![Protocol Buffer](https://img.shields.io/badge/Protocol%20Buffer-19.5%25-4285F4?style=flat-square) ![TOML](https://img.shields.io/badge/TOML-3.6%25-9c4221?style=flat-square) | gRPC service definitions and generated code |
| **socket-ssh** | ![JSON](https://img.shields.io/badge/JSON-78.6%25-292929?style=flat-square) ![JavaScript](https://img.shields.io/badge/JavaScript-17.5%25-F7DF1E?style=flat-square) ![Shell](https://img.shields.io/badge/Shell-1.9%25-89e051?style=flat-square) | WebSocket server for SSH connections |

Here are all the services that browseterm has:
1. Browseterm-Dockerfiles:
    This repo is the holder of the dockerfiles used for our linux images.
    It also holds builds the sidecar image that will be used for our images.
2. Cert Manager:
    Responsible for managing certificates for all our microservices. Refreshes certificates every Sunday.
    NOTE: Needs a sidecar to create new deployments of the containers once the certificates have been refreshed.
3. Container Maker:
    Responsible for managing containers in the kubernetes cluster. Create, Get, List, Delete containers in the kubernetes cluster.
4. Socket SSH:
    The websocket interface for containers created by the user. This will be dynamically created by our system when user connects to the container from the UI. However, we deploy a development instance for testing the code. The image is then pushed and is created dynamically as required by teh system.
5. Postgres HA Cluster:
    Our database. Prioritizes consistency since we have a lot of payment data. A combination of: ETCD, Patroni, HAProxy, Postgres Cluster, PGBackRest.
6. Redis Cluster:
    The redis cluster holds our auth data and also works as our cache.
7. Payment service:
    Our payment handlers.
8. Browseterm server:
    - Renders templates.
    - Handles Authentication.
    - Acts like an API Gateway.

## 🛠️ Technology Stack

| Service | Primary Languages | Description |
|---------|------------------|-------------|
| **cert-manager** | ![Python](https://img.shields.io/badge/Python-62.6%25-3776AB?style=flat-square) ![YAML](https://img.shields.io/badge/YAML-18.7%25-cb171e?style=flat-square) ![Shell](https://img.shields.io/badge/Shell-13.7%25-89e051?style=flat-square) | Certificate management service |
| **container-maker-spec** | ![Python](https://img.shields.io/badge/Python-76.9%25-3776AB?style=flat-square) ![Protocol Buffer](https://img.shields.io/badge/Protocol Buffer-19.5%25-4285F4?style=flat-square) ![TOML](https://img.shields.io/badge/TOML-3.6%25-9c4221?style=flat-square) | gRPC service definitions and generated code |
| **socket-ssh** | ![JSON](https://img.shields.io/badge/JSON-78.6%25-292929?style=flat-square) ![JavaScript](https://img.shields.io/badge/JavaScript-17.5%25-F7DF1E?style=flat-square) ![Shell](https://img.shields.io/badge/Shell-1.9%25-89e051?style=flat-square) | WebSocket server for SSH connections |

To get started, clone this repo:
```bash
$ git clone --recurse-submodules https://github.com/Zim95/browseterm-monorepo
```

In case you forget to include submodules:
```bash
$ git submodule update --init --recursive
```

# Setting up our microservices.

## License

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See the [LICENSE](LICENSE) file for details.

### What this means:
- ✅ You can use, modify, and distribute this software
- ✅ You must provide source code for any modifications
- ⚠️ **Network use is distribution** - If you run this software on a server that users interact with over a network, you must provide the source code to those users
- ✅ Perfect for open-source SaaS projects that want to prevent proprietary forks

For commercial licensing options, please contact [your-email@example.com].
