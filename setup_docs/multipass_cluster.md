# Introduction
Here we will setup our kubernetes cluster by creating virtual ubuntu machines using multipass and create kube notes and agents. `minikube` or `kind` clusters have issues with DNS and we will get problems when setting up NFS for our cluster. This means mapping NFS is easier in the rancher ubuntu cluster.

In case of `minikube` and `kind`, the DNS will cause issues with NFS mapping. Also, High Availability clusters need atleast 3 nodes to achieve quorum. It is difficult to achieve that in `minikube` and `kind` clusters.

Multipass is a tool for running light weight minimal Ubuntu VMs on our machine. We can think of it as `Docker but only for Ubuntu VMs`.

In this section, we will create `Ubuntu VMs`. We will then add `k3s` (We will not use `kube-adm` for this because that requires a lot of setup) to setup our kubernetes cluster.

We will have one master and 3 worker nodes in our cluster.

# Table of contents:
1. Setting up the Multipass Cluster  
    1.1 Setting up Ubuntu VMs  
    1.2 Setting up the Master Node  
    1.3 Setting up a Worker Node  
    1.4 Video Resource and Static IP  
2. Setting up kubectl  
    2.1 Setting up a new config  
    2.2 Setting up an already existing config  
3. Setting up ingress with Metal LB  
    3.1 Setting up Ingress with Nginx Ingress Controller  
    3.2 Installing Metal LB  
4. Setting up NFS  
    4.1 Setting up NFS on Mac  
    4.2 Testing the NFS server with CLI  
    4.3 Setting up our development environment  


## 1. Setting up the MultiPass Cluster
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

### 1.1 Setting up Ubuntu VMs
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

### 1.2 Setting up the Master Node
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

### 1.3 Setting up a Worker Node
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


### 1.4 Video Resource and Static IP
We can refer to this video for the setup: https://www.youtube.com/watch?v=NZTQ8zdN6PY
At the end of this video, we get to see how static IPs are important for this cluster setup and what to do if the IP addresses change. We can follow that.


## 2. Setting up Kubectl
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

### 2.1 Setting up a new config.
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

### 2.2 Setting up an already existing config
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
    ```bash
    $ kubectl config use-context multipass-cluster
    ```

7. Now you are in the cluster. You can call it whatever you want. I call it multipass-cluster.


## 3. Setting up ingress with Metal LB
How ingresses work in kubernetes is, you need an actual ingress controller like traefik or nginx. We are going to use ingress-nginx. Then you have ingress rules that will write rules to the ingress nginx.

In this section, we are going to install the ingress controller to facilitate creating ingresses in our cluster.

Next, We need external IP. When we're on the cloud it happens automatically, but in our case, we need something to facilitate external IP assignment. To do this we will install MetalLB. So every time we create a LoadBalancer, we get an external IP for it.

### 3.1 Setting up Ingress with Nginx Ingress Controller
We are going to setup the ingress controller.

1. If you don't already have helm installed, do the following:
    ```bash
    $ brew update
    $ brew install helm
    ```
    Once done, verify the installation:
    ```bash
    $ helm version
    ```
    You should see something like this:
    ```bash
    version.BuildInfo{Version:"v3.15.2", GitCommit:"1a500d5625419a524fdae4b33de351cc4f58ec35", GitTreeState:"clean", GoVersion:"go1.22.4"}
    ```

2. Install the ingress controller using `helm`.
    ```bash
    $ helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace ingress-nginx --create-namespace
    ```
    This will install the ingress controller in the `ingress-nginx` namespace.

    Test this by checking both pods and services:
    ```bash
    $ kubectl get pods -n ingress-nginx
    $ kubectl get services -n ingress-nginx
    ```
    For pods, you should see:
    ```bash
    NAME                                        READY   STATUS    RESTARTS   AGE
    ingress-nginx-controller-6885cfc548-c67zz   1/1     Running   0          149m
    ```
    For services you should see:
    ```bash
    NAME                                 TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
    ingress-nginx-controller             LoadBalancer   10.43.125.107   <pending>     80:30442/TCP,443:30842/TCP   150m
    ingress-nginx-controller-admission   ClusterIP      10.43.227.192   <none>        443/TCP                      150m
    ```
    As you can see, the `ingress-nginx-controller` shows a pending external ip. This is because external ip cannot be assigned yet. For that we need to install MetalLB.


### 3.2 Installing Metal LB
Here we will install metal lb for external ip address provisioning.

1. First, lets install metal lb.
    ```bash
    $ kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
    ```

2. Wait for metal lb to be ready.
    ```bash
    $ kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=90s
    ```

    Wait for these lines to appear:
    ```bash
    pod/controller-5cbffbc46b-z7vgw condition met
    pod/speaker-92skh condition met
    pod/speaker-k5tkl condition met
    pod/speaker-kb4dl condition met
    pod/speaker-xx8gr condition met
    ```

3. Next, we need to create an IP Address pool. Adjust the IP range according to the IP of our nodes `192.168.64.x`:
    ```bash
    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.64.200-192.168.64.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF
    ```
    You should see this:
    ```bash
    ipaddresspool.metallb.io/first-pool created
    l2advertisement.metallb.io/l2advertisement created
    ```

    Now check the ingress controller, it should get an external ip.

    ```bash
    $ kubectl get services -n ingress-nginx
    ```
    You should see:
    ```bash
    NAME                                 TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)                      AGE
    ingress-nginx-controller             LoadBalancer   10.43.125.107   192.168.64.200   80:30442/TCP,443:30842/TCP   172m
    ingress-nginx-controller-admission   ClusterIP      10.43.227.192   <none>           443/TCP                      172m
    ```
    As you can see, the controller now has an external IP. So our metal Lb has been setup.

## 4 Setting up NFS
Here we will be setting up NFS server on our Mac, then mount to it from within the kubernetes cluster. Mounting will be done with CLI tools as well as Python Code by creating Persistent Volumes and Persistent Volume Claims.

### 4.1 Setting up NFS on Mac
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

### 4.2 Testing the NFS server with CLI
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

5. After the mount you can try creating a file in your `/mnt/nfs` directory. That file should show up in `/Users/Shared/<nfs-directory>`.
    ```bash
    echo "test from pvc" > /mnt/nfs/hello.txt
    ```
    This file will exist in `/mnt/nfs` as well as in `/Users/Shared/<nfs-directory>`. The contents will be "test from pvc".
    Try deleting the pod and create a new one, as soon as you create the pod, this file will be available in that pod.

### 4.3 Setting up our Development Environment
1. We would like to make changes locally and have that reflected inside the Pod.
    - In docker, we can do this using the `-v` flag. This would map our local directory a directory in the pod. This is what it looks like:
        ```
        local machine -> docker container
        ```

    - If we use `kind` or `minikube` with docker desktop, we can do this using `HostPath` volume map. This is because the node for our `kind` or `minikube` cluster is our machine. `HostPath` maps to the path in the node. So we can directly map our working directory to the pod using `HostPath` volume type.
        ```
        local machine -> kind cluster
        ```

    - When using a `multipass`, we create a virtual machine. The nodes are in the virtual machine. `HostPath` maps to the path in the node which is the VM. Our local directory is not inside the VM, so the changes we make locally will not be reflected inside the pod.

    - To do that, we need to map our local working directory to our `VM` through the `NFS` that we just installed. Then we can map the mapped directory in the `HostPath` in the Pod. So its like:
        ```
        local machine -> VM path -> Multipass Cluster
        ```

2. First we create an export rule for our working directory. I like to create a rule for the entire project directory that I have. Open `/etc/exports` on your local MAC and add this line.
    ```text
    <path/to/project> -alldirs -mapall=501:20 192.168.64.2 192.168.64.3 192.168.64.4 192.168.64.5
    ```
    We can get the ip addresses using `multipass list`.
    This makes our project directory shareable via NFS.

3. Now enter into each of the nodes in the cluster, and install nfs common tools.
    ```bash
    multipass shell <machine>
    ```
    Once inside, install nfs common tools.
    ```bash
    sudo apt update && sudo apt install nfs-common -y
    ```
    This will let you use nfs tools.
    Our resources might be deployed on any of the nodes. So we need to use NFS mounting from whichever node our resources are scheduled in.

4. Next, lets mount our projects directory in all of the nodes, so that the project directory is available in all nodes.
    Go inside each node and create a directory where the project directory is mapped.
    ```bash
    multipass shell <node>
    ```
    Create a the directory that will be mounted to the project directory:
    ```bash
    mkdir /mnt/<directory>
    ```
    The
    ```bash
    sudo mount -t nfs -o vers=3,nolock 192.168.1.2:<path/to/project> /mnt/<directory>
    ```
    Next, we can use the created directory `/mnt/<directory>`, as our working directory.

5. Problem with the mount:
    - When you mount the directory on our MAC to the VM. Things work.
    - When your laptop sleeps, reboots, or disconnects from the network, the mount on the nodes breaks.
    - This causes:
        - Pods that rely on that mount to fail.
        - Hanging shells (because the filesystem access blocks).
        - Crashes or unresponsive containers.
    - So every time the laptop sleeps, we need to re-setup everything.

5. Unmount
    ```bash
    sudo umount -l /mnt/projects
    ```

6. We can also make things a little easier by:
    - Installing an NFS server on the VM master node.
    - Mapping the directory from our host machine to the master node.
        localMachine(NFSServer) -> VMPath (MasterNode-NFSClient)
    - Then use the server on the Masternode to map to the worker nodes.
        localMachine(NFSServer) -> VMPath(MasterNode-NFSClient)
        VMPath(MasterNode-NFSServer) -> Worker1(NFSClient)
        VMPath(MasterNode-NFSServer) -> Worker2(NFSClient)
        VMPath(MasterNode-NFSServer) -> Worker3(NFSClient)
    - This way we have a single point of failure. The only connection that we need to keep maintaining is this: `localMachine(NFSServer) -> VMPath(MasterNode-NFSClient)` one.
    - However, if the computer sleeps, even this connection gets removed and as a consequence the same results appear again.
        - Pods that rely on that mount to fail.
        - Hanging shells (because the filesystem access blocks).
        - Crashes or unresponsive containers.
    - So this setup is okay for testing HA deployments and all but not so ideal for development.

7. This cluster also has no internet access. Because of which, we will be unable to work with the internet. Enabling that is also a pain and we haven't figured that out yet. Will add more updates once figured out.
