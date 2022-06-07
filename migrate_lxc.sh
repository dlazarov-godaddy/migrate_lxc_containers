# migrate_outmxs
Script to migrate outmx lxc containers from one host to another

Create a file called servers in the same directory where this script is executed. In the "servers" put the FDQNs of the outmxs you want to migrate

For example

root@mail-lxc-002-lds]# cat servers
outmx-229.london.gridhost.co.uk
outmx-300.london.gridhost.co.uk

Then pass this file to the script at the terminal as a command line argument along with the IP address of the OLD LXC Physical host where you want to migrate from



The script will require you to copy and paste the root pass multiple times  for every single loop iteration through out then end of its execution . Storing passwords in variables  is considered insecure and it's not encouraged, but you cuold set up SSH Public authenitcation between the nodes for migration purposes. If you do so please make sure you clean up after yourself.


