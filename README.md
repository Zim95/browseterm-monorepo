# BROWSETERM

Browseterm is a project that allows users to run linux containers in the browser. The user can create and run different linux terminals and interact with them in the browser. Look at the demo:
<add a gif>

Payment plans:
--------------
1. Free Plan:  Default subscription model. 1 Container, 1 CPU, 1 GB Memory.  
2. Basic Plan: 100 INR. 5 Containers, 1 CPU, 1 GB Memory.  
3. Pro Plan:   500 INR. 30 Containers, 12 CPU, 12 GB Memory.  

This repository holds the complete browseterm project. This respository is a collection of all the other repositories that add up to become Browseterm.

# MicroServices:
Here are all the services that browseterm has:  
**1. PostgresHA:**  
    **Type:** MicroService.  
    **Description:** Our database. Prioritizes consistency since we have a lot of payment data. A combination of: ETCD, Patroni, HAProxy, Postgres Cluster, PGBackRest.  

**2. BrowsetermDB:**  
    **Type:** Python Library for Database and Migrations.  
    **Description:** Contains database models, operations on top of models (CRUD), database event listener, Migrations manager.  
    **NOTE:** Need to run migrations once the database is setup.  

**3. CertManager:**  
    **Type:** MicroService (CronJob).  
    **Description:** Manage certificates and rollout new deployments for microservices. Can create job on the fly. Can also be invoked by other services for custom certificate creation.  
  
**4. Socket-SSH:**  
    **Type:** Docker Image.  
    **Description:** The socket interface to our linux containers. Used by front-end to stream SSH data.  
  
**5. Browseterm-Dockerfiles:**  
    **Type:** Docker Image(s).  
    **Description:** There are multiple images to build here:  
        - **Linux Images:** These are our linux images. Right now, we only have ubuntu.  
        - **Status Sidecar:** This is the status sidecar. We need to build this image to update status of our containers. This will act as the status monitor sidecar container.  
        - **Snapshot Sidecar:** This is the snapshot sidecar. We need to build this image to create a snapshot image of our containers. This will act as the snapshot sidecar container.  
  
**6. Redis HA:**  
    **Type:** MicroService.  
    **Description:** This is our Redis server. Used for Cache and Auth State Management.  
  
**7. Container Maker Spec:**  
    **Type:** Python Library (GRPC).  
    **Description:** This is the GRPC library that is used to communicate with our other microservice called `container-maker`.  
  

# Getting Started
To get started, clone this repo:
```bash
$ git clone --recurse-submodules https://github.com/Zim95/browseterm-monorepo
```
  
In case you forget to include submodules:
```bash
$ git submodule update --init --recursive
```
  
# Setting up our MicroServices.
1. First, we need to setup our cluster. We need to install MetalLB. This is for external IP addresses. Check out `00_docs/metallb_setup.md` to learn more.  
  
2. Next, create the namespace for your cluster.
    ```bash
    $ kubectl create namespace <namespace>
    ```  
  
3. We will need to setup our postgres database. Clone the `postgres_ha` repository and create the single instance postgres instance. This is the repository: `https://github.com/Zim95/postgres_ha`. You can follow the `README` for the setup.  
  
4. Next, we will need to setup our database and tables along with default subscription types and images. For this we need to setup `browseterm-db`. This is the repository: `https://github.com/Zim95/browseterm-db`. You can follow the `README` for the setup.  
  
5. Now, we need to setup our certificate manager. The repository to do this is `cert-manager`. Here is the link: `https://github.com/Zim95/cert-manager`. You can follow the `README` for the setup.  
  
    However, there are a few details to note:  
    - Build the image:
        ```bash
        make prod_build
        ```
    - Deploy the cron job:
        ```bash
        make prod_setup
        ```
    - Immediately create the certificates. Normally, they are created every Sunday. So, we need to create one immediately:  
        ```bash
        kubectl create job --from=cronjob/cert-manager cert-manager-job -n <namespace>
        ```
        This will create a Job and create the necessary certificates immediately.  
  
6. Next, lets set-up our `socket-ssh` docker image. We actually only need to build an image for this one. But it is recommended, to deploy the dev version and run tests, so that you know things are working as they should. This is the link to the repository: `https://github.com/Zim95/socket-ssh`. You can go through the `README`.  
    - First, build the prod image.  
    - Then, build the dev image and run dev setup.  
    - Go inside, the dev pod, hit `npm install` and then run `npm run test`.  
    - This makes sure the code is working fine.  
  
7. Next, we will build another docker image `browseterm-dockerfiles`. These are the images that will be used by our linux containers. This is the repository: `https://github.com/Zim95/browseterm-dockerfiles`. You can follow the `README` to understand the setup. Simply clone the repo, go inside it and hit `make build_all`.  

8. Next, we will setup our Redis Server. We use this for Auth State Management and as our Cache. This is the repository: `https://github.com/Zim95/redis_ha`. For this repo, you can go to the `README`, but only look at the `env.mk` file. DO NOT go through the setup. Just hit `make dev_redis_single_setup`.  

9. Next, we will clone the `container-maker-spec` repository. This is our GRPC python package. We don't need to build it. But, we do need to run the builder once we are done with making changes. Go to the `README` file and checkout `How to make it installable from git` section. Here is the link to the repository: `https://github.com/Zim95/container-maker-spec`.
  

# Working with submodules:  
1. Adding a submodule:  
    ```bash
    $ git submodule add <repository_url> <path>
    $ git add .gitmodules <path>
    $ git commit -m "Add submodule <name>"
    $ git push origin
    ```
  
2. Removing a submodule:  
    ```bash
    $ git submodule deinit -f -- <path>
    $ git rm -f <path>
    $ rm -rf .git/modules/<path>
    $ git commit -m "Remove submodule <name>"
    $ git push origin
    ```
  
3. Updating submodules to their latest commit:  
    ```bash
    $ git submodule update --init --remote --merge --recursive
    $ git add <path> # or `git add .` to add all changed submodule pointers
    $ git commit -m "Update submodules to latest remote commits"
    $ git push origin
    ```
  
## License
This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See the [LICENSE](LICENSE) file for details.

### What this means:
- ✅ You can use, modify, and distribute this software.
- ✅ You must provide source code for any modifications.
- ⚠️ **Network use is distribution** - If you run this software on a server that users interact with over a network, you must provide the source code to those users.
- ✅ Perfect for open-source SaaS projects that want to prevent proprietary forks.
  
For commercial licensing options, please contact [shresthanamah@gmail.com].
