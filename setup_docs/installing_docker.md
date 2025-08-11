1. Remove old installation:
    ```bash
    apt-get remove docker docker-engine docker.io containerd runc
    ```

2. Setup Docker Repo
    ```bash
    apt-get update
    ```
    This will update apt-get repositories.

    ```bash
    apt-get install \
    ca-certificates \
    curl \
    gnupg \
    lsb-release
    ```
    This will install all required tools to install docker.

    ```bash
    mkdir -p /etc/apt/keyrings
    ```
    ```bash
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    ```
    This will install the docker gpg (IDK what that is).

    ```bash
    echo \
    "deb [arch=$(dpkg --print-architecture) \
    signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    ```
    This adds the repository in apt-get.

3. Now update and install docker:
    ```bash
    apt-get update
    ```
    This will add the new repositories for docker that were installed earlier.

    ```bash
    apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ```
    This installs all docker related applications.

4. Check the version:
    ```bash
    docker --version
    dockerd --version
    ```