#!/bin/bash
# The script takes three command line arguments and options. These are containers list, bridge interface for the container and IP address of the old host.
# It uses container FDQNs(don't need to be working FDQNS) in the list of servers.
# Always execute this script from the new lxc host only,e.g from the one  you want to migrate to.
# For example how to execute this script
# ./migrate1.sh -f containers -b br0  -s 31.170.120.248

# Prevent manipulation of the input field separator
IFS='
        '
# Ensure that secure search path is inherited by sub-processes
OLDPATH="$PATH"

PATH=/bin:/usr/bin:/usr/sbin
export PATH

# Variables start here
# Directory where the container data is
LXC_SOURCE_DIR="/virt"
# Partition where the containers data is
DISK_PARTITION="/"
EXIT_STATUS='0'
LOG_OUTPUT="outmx_migration.log"

# Functions start here

# Gives users instructions
usage() {
  # Display the usage and exit.
  echo "Usage: ${0} servers  IP address of old lxc host " >&2
  echo "  -f  FILE   Use FILE for the list of servers. Default: ${CONTAINER_LIST}." >&2
  echo "  -b  BRIDGE Use bridge interface for the containeer : ${BRIDGE}." >&2
  echo "  -s  SERVER Use the IP address of the old lxc host where data is migrated from: $LXC_OLD_HOST" >&2
  echo '             Run this script as root. ' >&2
  echo "             Make sure you run this script from the new lxc host where containers need to be migrated."
  exit 1
}

# Echos Message to output
func_echo_message () {
  local message="$@"
  echo
  echo "$message"
  echo
}

# Dump  the xml config from the old host

func_dump_config () {

  lxc_container="$@"
  get_bridge=$(virsh --connect lxc:/// dumpxml "$lxc_container" | sed "/mac address/d;/uuid/d;s/ id='[0-9]*'//g" > /tmp/"$lxc_container".xml )
}

# Rsyncs the container xml config

func_rsync_config () {

  func_echo_message "Rsync the xml config for $lxc_container"
  rsync  $OLD_LXC_HOST:/tmp/"$lxc_container".xml  /tmp/"$lxc_container".xml;
  [ ! -f /tmp/"$lxc_container".xml ] &&
  echo "Failed to rsync the xml config file for $lxc_container to $HOSTNAME" &&
  exit 2
}

# Gets lxc host bridge interface

func_get_host_bridge () {
  get_bridge=$( ip a | grep -wo "${BRIDGE}" | sort | uniq | sort  )  &&
  echo $get_bridge ||
  echo "Couldn't get $BRIDGE from the config for $lxc_container" && exit 3
}

# Gets container bridge from config if not passed at argument

func_get_container_bridge () {
    get_bridge=$(grep -Ewo '[br0-9]{3,5}'  /tmp/"${lxc_container}".xml | tail -n 1)  &&
    bridge=( ${get_bridge} )
    echo $bridge ||
    echo "Couldn't get $BRIDGE from the config for $lxc_container" && exit 4
}

#  Makes sure the bridge interfaces matches

func_compare_bridges () {
  [[ ! $host_bridge ==  $container_bridge ]] &&
  sed -i "s/$container_bridge/$host_bridge/" /tmp/"${lxc_container}.xml" ||
  echo "Failed to add the $host_bridge to the $lxc_container.xml file" && exit 5
}

#  Defines the container

func_define_container () {

  virsh --connect lxc:/// define /tmp/"${lxc_container}.xml"
}

# Rsyncs the container data

func_rsync_container () {

  func_echo_message "Rsyncing container: $lxc_container from $OLD_LXC_HOST to $HOSTNAME. This may take a while"
  rsync -a $OLD_LXC_HOST:$LXC_SOURCE_DIR/$lxc_container $LXC_SOURCE_DIR/  >/dev/null
  [[ ! -d $LXC_SOURCE_DIR/$lxc_container   ]] &&
  echo "Failed to rsync $lxc_container to $HOSTNAME. "  && exit 6
}

# Stops the container on the old host

func_stop_container () {

  lxc_container="$@"
  LXC_SOURECE_DIR="$@"
  virsh --connect lxc:/// destroy $lxc_container ; mv "$LXC_SOURCE_DIR"/"$lxc_container"{,_migrated}

}

# Starts container on the the new host

func_start_container () {

  virsh --connect lxc:/// start $lxc_container &&
  echo
  echo "Successfully migrated $lxc_container from $OLD_LXC_HOST to $HOSTNAME" >> $LOG_OUTPUT 2>&1  ||
  echo "Failed to start $lxc_container from $OLD_LXC_HOST to $HOSTNAME" >> $LOG_OUTPUT 2>&1
  echo
}

# Caller to pass the functions to the old host over SSH

func_caller () {

  local function="$1"
  ssh root@$OLD_LXC_HOST "$(typeset -f $function);  $function "
  SSH_EXIT_STATUS="${?}"

# Capture any non-zero exist status from the SSH_COMMAND
  [[ "${SSH_EXIT_STATUS}" -ne 0 ]] &&
  EXIT_STATUS="${SSH_EXIT_STATUS}"
  echo "The caller ssh execution on host "${OLD_LXC_HOST}" has failed for $lxc_container ." >&2
}

# Script main body starts here

# Make sure the script is executed as root

[[ "${UID}" -ne 0 ]] &&
echo 'Execute this script as root.' >&2 &&
usage

# Parse command line arguments
while getopts :f:b:s: OPTION
do
case ${OPTION} in
 f) CONTAINER_LIST="${OPTARG}" ;;
 b) BRIDGE="${OPTARG}" ;;
 s) OLD_LXC_HOST="${OPTARG}" ;;
 *) usage ;;
 esac
done

shift "$(( OPTIND - 4 ))"

# If the user doesn't supply 3 options and 3 arguments, give them help.

[[  "${#}" -lt 3  ]] && usage

# Make sure the CONTAINER_LIST file exists.

[[ ! -e "${CONTAINER_LIST}" ]] &&
echo "Cannot open server list file ${CONTAINER_LIST}." &&
exit6

# Check disk space on new host

disk_used_percent=$(df  $DISK_PARTITION  |  tr "\n" ' ' | awk '{print $12}' | grep -oE [0-9]+  )
if [[ $disk_used_percent -gt 75 ]]
then
  echo "Warning Disk is getting too full"
elif  [[ $disk_used_percent -gt 90 ]]
then
  echo "Disk utilization on $HOSTNAME is already greater than $disk_used_percent%"  >> $LOG_OUTPUT 2>&1
  exit 7
fi

# Iterate through the containers

for lxc_container in $(cat ${CONTAINER_LIST}); do

  # Dump and rsync xml config file

  func_caller "func_dump_config $lxc_container" >&2
  func_rsync_config  >&2

  # Store the functions output in new variables for comparison

  host_bridge=( $(func_get_host_bridge) )
  container_bridge=( $(func_get_container_bridge) )
  func_compare_bridges  >&2

  # Rsync the actual data, define and start the container

  func_rsync_container   >&2
  func_define_container   >&2

  # Stop container on old host

  func_caller "func_stop_container "$lxc_container""  >&2

  # Start container  on new host

  func_start_container  >&2

done

exit ${EXIT_STATUS}
