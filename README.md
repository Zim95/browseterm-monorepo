# BROWSETERM MONO REPO
This repository holds the complete browseterm project. This respository is a collection of all the other repositories that add up to become Browseterm.

To get start clone this repo:
```bash
$ git clone <>
```

**Table of Contents:**
----------------------
1. Cluster Setup
    1.1 Setting up the MultiPass Cluster
        1.1.1 Setting up Ubuntu VMs
        1.1.2 Setting up a Master Node
        1.1.3 Setting up a Worker Node
        1.1.4 Video Resource and Static IP
    1.2 Setting up our cluster with kubectl
        1.2.1 Setting up a new config
        1.2.2 Setting up an already existing config
    1.3 Setting up MetalLB for Ingress IP
    1.4 Setting up External NFS
        1.4.1 Setting up NFS on Mac
        1.4.2 Testing the NFS server with CLI
        1.4.3 Testing the NFS server with Kubernetes API
2. Deploying our MicroServices
    2.1 Deploying Container Maker
    2.2 Deploying Cert Manager
    2.3 Deploying Socket SSH (Only for development and testing purposes)
    2.4 Deploying Postgres HA Server
    2.5 Deploying Browseterm Server
3. Description of all the submodules
    3.1 Browseterm Dockerfiles
    3.2 Container Maker
    3.3 Socket SSH
    3.4 Cert Manager
    3.5 Browseterm Server
    3.6 PostgreSQL HA Server


# 1. Cluster Setup
The first step that we need to take is to setup our kubernetes cluster. We will NOT USE `minikube` or `kind` clusters. They have issues with DNS and we will get problems when setting up NFS for our cluster.

Rather, we will create virtual ubuntu machines using multipass and create kube nodes and agents. Multipass is a tool for running light weight minimal Ubuntu VMs on our machine. We can think of it as `Docker but only for Ubuntu VMs`.

In this section, we will create `Ubuntu VMs`. We will then add `k3s` (We will not use `kube-adm` for this because that requires a lot of setup) to setup our kubernetes cluster.

We will have one master and 3 worker nodes in our cluster.

## 1.1 Setting up the MultiPass Cluster
NOTE: This setup works on MacOS. This has not been tried in other development environments. Please adjust the code accordingly.

This will be our primary kubernetes cluster. 

1. Make sure you have `homebrew` installed. Visit: [Homebrew official site](https://brew.sh/) to install homebrew.

2. Next install `multipass` using homebrew.
    ```bash
    $ brew update
    $ brew install --cask multipass
    ```

3. Check if `multipass` has been installed:
    ```bash
    $ multipass --version
    ```
    You should see something like this:
    ```bash
    multipass   1.15.1+mac
    multipassd  1.15.1+mac
    ```

### 1.1.1 Setting up Ubuntu VMs
Launching a VM is easy. Just do this:
```bash
$ multipass launch --name <name> --cpus 2 --mem 2G --disk 10G
```

This will create a VM with the name. You can view it with this command:
```bash
$ multipass list
```

You should see something like this:
```bash
Name               State             IPv4             Image
<name>             Running           192.168.xx.x     Ubuntu 24.04 LTS
```

### 1.1.2 Setting up the Master Node
Lets launch a VM, install k3s and set it up to be the master node.

1. Launch a VM:
    ```bash
    $ multipass launch --name k3s-node --cpus 2 --mem 2G --disk 10G
    ```

2. Once done we should see it in `multipass list`.
    ```bash
    $ multipass list

    Name                    State             IPv4             Image
    k3s-node                Running           192.168.64.2     Ubuntu 24.04 LTS
    ```
    NOTE THIS IPADDRESS NOW: `192.168.64.2`.

3. Now let's enter into the node.
    ```bash
    $ multipass shell k3s-node
    ```

4. Once inside, we will install k3s.
    ```bash
    $ curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.5+k3s1" sh -
    ```
    This will install K3s with the specified version.

5. Then we can check if it works.
    ```bash
    $ sudo kubectl get nodes
    ```
    We should see this:
    ```bash
    NAME          STATUS   ROLES                  AGE     VERSION
    k3s-node      Ready    control-plane,master   5h31m   v1.32.5+k3s1
    ```
6. We now need the token of this node.
    ```bash
    $ sudo cat /var/lib/rancher/k3s/server/node-token
    ```
    We should see something like this:
    ```bash
    <token>::server:<hash>
    ```

7. Note the IP Address and this token. We will need it while creating worker nodes.

### 1.1.3 Setting up a Worker Node
Lets launch a VM, install k3s, install k3s agent, pass the IP Adress and token.

1. Launch a VM:
    ```bash
    $ multipass launch --name k3s-agent-1 --cpus 2 --mem 2G --disk 10G
    ```

2. Once done, we should see it in `multipass list`.
    ```bash
    $ sudo kubectl get nodes
    ```
    We should see this:
    ```bash
    multipass list
    Name                    State             IPv4             Image
    k3s-agent-1             Running           192.168.64.3     Ubuntu 24.04 LTS

    k3s-node                Running           192.168.64.2     Ubuntu 24.04 LTS
                                              10.42.0.0
                                              10.42.0.1
    ```

3. Enter into the VM:
    ```bash
    $ mutlipass shell k3s-agent-1
    ```

4. Once inside, we will install k3s, k3s agent, pass the IP Adress and token of the master node.
    ```bash
    $ curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.5+k3s1" INSTALL_K3S_EXEC="agent --server <IPAddress>:6443 --token <token>::server:<hash>" sh -
    ```
    This will connect this node to the master node as a worker node.

5. Now if you go to another terminal and hit `multipass list`, you will see an IP has been assigned to our worker node.
    ```bash
    $ multipass list

    Name                    State             IPv4             Image
    k3s-agent-1             Running           192.168.64.3     Ubuntu 24.04 LTS
                                              10.42.1.0
                                              10.42.1.1
    k3s-node                Running           192.168.64.2     Ubuntu 24.04 LTS
                                              10.42.0.0
                                              10.42.0.1
    ```

6. If things go wrong and the command gets stuck, You can check the logs.
    In another terminal enter inside the same worker node:
    ```bash
    $ multipass shell k3s-agent-1
    ```
    Once inside hit:
    ```bash
    sudo journalctl -u k3s-agent -f
    ```
    NOTE: `journalctl` holds the logs for all services in `systemd`. When we want to run daemon processes in the background, for example, `mongod`, `dockerd`, etc, we register them in `systemctl`. Then we start them from `systemctl`. All the logs for `systemctl` can be found in `journalctl`.

7. Repeat the steps and create two more worker nodes. In the end our setup should look like this:
    ```bash
    $ multipass list

    Name                    State             IPv4             Image
    k3s-agent-1             Running           192.168.64.3     Ubuntu 24.04 LTS
                                              10.42.1.0
                                              10.42.1.1
    k3s-agent-2             Running           192.168.64.4     Ubuntu 24.04 LTS
                                              10.42.2.0
                                              10.42.2.1
    k3s-agent-3             Running           192.168.64.5     Ubuntu 24.04 LTS
                                              10.42.3.0
                                              10.42.3.1
    k3s-node                Running           192.168.64.2     Ubuntu 24.04 LTS
                                              10.42.0.0
                                              10.42.0.1

    ```
    Our cluster is ready.


### 1.1.4 Video Resource and Static IP
We can refer to this video for the setup: https://www.youtube.com/watch?v=NZTQ8zdN6PY
At the end of this video, we get to see how static IPs are important for this cluster setup and what to do if the IP addresses change. We can follow that.


## 1.2 Setting up Kubectl
1. Make sure `kubectl` is installed and functional. If you don't have it then do this:
    ```bash
    $ brew install kubectl
    ```
    Check if it worked.
    ```bash
    $ kubectl version --client
    ```
    You should see something like this:
    ```bash
    Client Version: v1.32.0
    Kustomize Version: v5.5.0
    ```

2. First of all we need to get the `cluster info`. To do this, go inside the master node:
    ```bash
    $ multipass shell k3s-node
    ```

3. Once inside type this:
    ```bash
    $ sudo cat /etc/rancher/k3s/k3s.yaml
    ```
    You should see something like this:
    ```yaml
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: <cert-authority-data>
        server: https://127.0.0.1:6443
    name: default
    contexts:
    - context:
        cluster: default
        user: default
    name: default
    current-context: default
    kind: Config
    preferences: {}
    users:
    - name: default
    user:
        client-certificate-data: <client-certificate-token>
        client-key-data: <client-key-token>
    ```

3. First, copy this yaml somewhere and paste it.

4. Once done, we need to change the ip address of the server. First check the ip address of the master node.
    ```bash
    $ multipass list
    ```
    The IPADDRESS of the master node is needed.

    Replace the IPADDRESS in the yaml. So we should see something like this:
    ```yaml
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: <cert-authority-data>
        server: https://<IPADDRESS OF MASTER NODE>:6443
    name: default
    contexts:
    - context:
        cluster: default
        user: default
    name: default
    current-context: default
    kind: Config
    preferences: {}
    users:
    - name: default
    user:
        client-certificate-data: <client-certificate-token>
        client-key-data: <client-key-token>
    ```

5. Next change the names from `default` to `multipass-cluster`:
    ```yaml
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: <cert-authority-data>
        server: https://<IPADDRESS OF MASTER NODE>:6443
    name: multipass-cluster
    contexts:
    - context:
        cluster: multipass-cluster
        user: multipass-cluster
    name: multipass-cluster
    current-context: multipass-cluster
    kind: Config
    preferences: {}
    users:
    - name: multipass-cluster
    user:
        client-certificate-data: <client-certificate-token>
        client-key-data: <client-key-token>
    ```

### 1.2.1 Setting up a new config.
If you DO NOT HAVE AN EXISTING kubernetes config file, follow this guide.

1. To know if you have the kubernetes config file, type this:
    ```bash
    $ cat ~/.kube/config
    ```
    If this file exists, then you already have some kubernetes clusters setup. Follow the next guide.

2. If not, create this file.
    ```bash
    touch ~/.kube/config
    ```
    Paste the entire YAML to this file.

3. The `current-context` field determines which kubernetes cluster you are working on.

4. Every new cluster you add to kubernetes has its own set of contexts. You can switch between kubernetes clusters by simply switching contexts.

5. A few context commands:
    ```bash
    $ kubectl config current-context  # to see the current context
    $ kubectl config use-context <context-name>  # to switch to another context
    $ kubectl config get-contexts -o name  # list the names of all the contexts.
    ```

### 1.2.2 Setting up an already existing config
If you already have an existing kubernetes cluster, you should have a kube config file.

1. To know if you have the kubernetes config file, type this:
    ```bash
    $ cat ~/.kube/config
    ```
    If this file exists, then follow the other steps.

2. Open your `~/.kube/config` file.

3. Add this to the clusters section:
    ```yaml
    - cluster:
        certificate-authority-data: <cert-authority-data>
        server: https://<IPADDRESS OF MASTER NODE>:6443
    name: multipass-cluster
    ```

4. Add this to the contexts section:
    ```yaml
    - context:
        cluster: multipass-cluster
        user: multipass-cluster
    name: multipass-cluster
    ```

5. Add this to the users section:
    ```yaml
    - name: multipass-cluster
    user:
        client-certificate-data: <client-certificate-token>
        client-key-data: <client-key-token>
    ```

6. Now just switch to this context.
    ```
    $ kubectl config use-context multipass-cluster
    ```

7. Now you are in the cluster. You can call it whatever you want. I call it multipass-cluster.


## 1.4 Setting up NFS
Here we will be setting up NFS server on our Mac, then mount to it from within the kubernetes cluster. Mounting will be done with CLI tools as well as Python Code by creating Persistent Volumes and Persistent Volume Claims.

### 1.4.1 Setting up NFS on Mac
There were a lot of issues but we will not cover those here, we will only put what worked in here for documentation purposes.
We already have an NFS server on a Mac, we only need to configure it.

1. We need to create a directory where the files will be stored.
    ```bash
    $ mkdir -p /User/Shared/<nfs-directory>
    ```
    Then change the owner to yourself
    ```bash
    $ sudo chown -R $(whoami) /User/Shared/<nfs-directory>
    ```

2. Next, we will need to create an export rule that accepts requests from IPAddresses to this directory. All of these rules are stored in the `/etc/exports` file. We need to edit that file.
    ```bash
    sudo vim /etc/exports
    ```
    Here we will need to add this line
    ```
    /Users/Shared/nfs-share-container-maker -alldirs -mapall=<userid>:<usergroup> <ip-k3s-node> <ip-k3s-agent-1> <ip-k3s-agent-1> <ip-k3s-agent-1>
    ```
    We need to add the IP addresses of our multipass nodes, so that we allow requests from our cluster to this NFS Server.
    We can get the ips using `multipass list`. The ips are the ones that start have this format `192.168.xx.x`.
    You can check the user id with `id -u` and user group with `id -g`.

3. After this, save the file and restart the nfs server.
    ```bash
    sudo nfsd restart
    ```

    Then type this command:
    ```bash
    sudo nfsd checkexports
    ```
    This command should output nothing. You should not get any errors upon hitting this command, if you do, you need to resolve those. An example error I got was:
    ```
    getaddrinfo() failed for 192.168.64.*
    exports:1: couldn't get address for host: 192.168.64.*
    exports:1: no valid hosts found for export
    ```
    This was because I did not set the IP addresses correctly. Mac NFS does not support wildcards or special characters, every IP address had to be completely added. After that I got no errors.
    This command should then printed nothing, which meant it worked.

    Then hit this command:
    ```bash
    showmount -e localhost
    ```
    This should show our rule:
    ```bash
    Exports list on localhost:
    /Users/Shared/nfs-share-container-maker 192.168.64.2 192.168.64.3 192.168.64.4 192.168.64.5
    ```
    If it doesn't show this, you need to resolve it. This rule should show up as our exports rule. It only works after that.

### 1.4.2 Testing the NFS server with CLI
Here we will create a dummy Kubernetes Pod and then try to mount to our external NFS from there.

1. Start a dummy pod.
    ```bash
    kubectl run nfs-test \
    --rm -it --restart=Never \
    --image=alpine \
    --overrides='
    {
        "spec": {
            "hostNetwork": true,
            "containers": [{
            "name": "nfs",
            "image": "alpine",
            "stdin": true,
            "tty": true,
            "securityContext": {
                "privileged": true
            },
            "command": ["/bin/sh"]
            }]
        }
    }'
    If you don't see a command prompt, try pressing enter.
    / #
    ```
    Wait for some time until you see the command prompt, or like the instruction says, press enter.

2. Then add `nfs-utils`.
    ```bash
    apk add nfs-utils
    ```

3. Create the directory that will be mounted to the NFS.
    ```bash
    mkdir /mnt/nfs
    ```

4. Mount to the NFS. We have a lot of other options to do this but none of them work. Only this works:
    ```bash
    mount -o vers=3,nolock <MACIP>:/Users/Shared/nfs-share-container-maker /mnt/nfs
    ```
    To the MACIP: `ipconfig getifaddr en0`
    If you get Permission denied, try checking your firewall. NFS server listens on some ports. These ports might have been blocked by the firewall. Or you might be trying some incorrect protocol.

### 1.4.3 Testing the NFS server with Kubernetes API
