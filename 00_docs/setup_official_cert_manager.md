# Official Cert Manager Setup for Ingress
Our microservices have their own `cert-manager`. But we also need the official cert manager for browser related communication. This section talks about that very thing.

# Steps to setup cert manager
- Install `cert-manager`:
    ```bash
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
    ```
  
- Wait for the certificates to be ready:
    ```bash
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
    ```
    You should see something like this:
    ```bash
    pod/cert-manager-6878879496-c82c9 condition met
    pod/cert-manager-cainjector-6874c5dd77-4htrh condition met
    pod/cert-manager-webhook-7d595f4899-75mpl condition met
    ```
  
- 