# Setting up Ingress with Nginx Ingress Controller
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


### Installing Metal LB
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
