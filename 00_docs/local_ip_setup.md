# Local Cluster IP setup
Here we are going to setup our IP addresses for portforwarding.

# Create the IP Addresses on your machine
- First we need to create the IP addresses on our machine.
    ```bash
    $ sudo ifconfig lo0 alias 192.168.0.3
    $ sudo ifconfig lo0 alias 192.168.0.4
    ```
    This will create IP addresses for you.
  
- Next we need to check if they were actually created or not.
    ```bash
    $ ifconfig lo0
    ```
    You should see these two lines in the output:
    ```bash
    inet 192.168.0.3 netmask 0xffffff00
	inet 192.168.0.4 netmask 0xffffff00
    ```
  
- Now, we need to map these IP addresses to a host. To do that, we are going to modify `/etc/hosts`.
    ```
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##

    127.0.0.1       localhost
    255.255.255.255 broadcasthost
    ::1             localhost
    192.168.0.3     browseterm.local.com
    192.168.0.4     socketssh.local
    ```
    Copy this into your `/etc/hosts` file.
  
- Now using `browseterm.local.com` will map to `192.168.0.3` and `socketssh.local` will map to `192.168.0.4`.

# Port-Forwarding our services
- Now, we need to portforward our services to these ip addresses.
  
- We have a `portfwd.sh` file that does that for us.
  
- But if you want to do it yourself, this is the command.
    ```bash
    kubectl port-forward -n <namespace> --address <ipaddress> svc/<servicename> hostport:serviceport
    ```
  
- However, you can just do:
    ```bash
    $ chmod +x portfwd.sh
    $ ./portfwd.sh
    ```
  
- This will port forward your services.
