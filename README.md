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

# Getting Started
To get started, clone this repo:
```bash
$ git clone --recurse-submodules https://github.com/Zim95/browseterm-monorepo
```
  
In case you forget to include submodules:
```bash
$ git submodule update --init --recursive
```
  
# Setting up our microservices.
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
        kubectl create job --from=cronjob/<your-cronjob-name> cert-manager-job -n <namespace>
        ```
        This will create a Job and create the necessary certificates immediately.  

## License
This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See the [LICENSE](LICENSE) file for details.

### What this means:
- ✅ You can use, modify, and distribute this software.
- ✅ You must provide source code for any modifications.
- ⚠️ **Network use is distribution** - If you run this software on a server that users interact with over a network, you must provide the source code to those users.
- ✅ Perfect for open-source SaaS projects that want to prevent proprietary forks.
  
For commercial licensing options, please contact [shresthanamah@gmail.com].
