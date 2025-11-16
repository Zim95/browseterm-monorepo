# BROWSETERM

Browseterm is a project that allows users to run linux containers in the browser. The user can create and run different linux terminals and interact with them in the browser. Look at the demo:
<add a gif>

Payment plans:
--------------
1. Free Plan:  Default subscription model. 1 Container, 1 CPU, 1 GB Memory.  
2. Basic Plan: 100 INR. 5 Containers, 1 CPU, 1 GB Memory.  
3. Pro Plan:   700 INR. 30 Containers, 12 CPU, 12 GB Memory.  

This repository holds the complete browseterm project. This respository is a collection of all the other repositories that add up to become Browseterm.

Here are all the services that browseterm has:
1. Browseterm-Dockerfiles:
    - This is the blueprint of our terminals.  
    - Holds our 
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
