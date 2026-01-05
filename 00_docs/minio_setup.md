# MinIO setup
MinIO will be our S3 inside kubernetes. Here we will set it up.

## Installation.
1. Add the helm repository.
    ```bash
    $ helm repo add bitnami https://charts.bitnami.com/bitnami
    ```
  
2. Install MinIo.
    ```bash
    $ helm install minio bitnami/minio \
        --set auth.rootUser=minio \
        --set auth.rootPassword=minio123 \
        --namespace minio --create-namespace
    ```
  
3. Create MinIO secrets.
    ```bash
    $ kubectl create secret generic minio-creds \
        --from-literal=accesskey=<anystringvalue> --from-literal=secretkey=<anystringvalue> -n minio
    ```
  
4. 