#!/bin/bash

# Author: Maximilian Hristache
# License: MIT 
#
# This script can be used to retrieve information about the physical
# network devices which are installed in your system.
#
# Note: the script will not print info about virtual devices which are
#       not attached to a PCI device (e.g. veth interfaces)
#
# Currently, for each network device it outputs:
#   - the PCI ID
#   - the interface name
#   - the NUMA node
#   - the interface speed
#   - the interface driver
#
# Note: If NUMA support is not enabled, it will output either 
#   '-1' (The system does not support NUMA)
#   '-'  (There is no NUMA information provided for the device)
#
# When executed in a network namespace, it will print only the physical
# network devices which are attached to that network namespace.


path_basename ()
{
    # same role as python's os.path.basename, e.g.:
    # for input '/foo/bar' witll return 'bar'
    # input:
    #   - $1: the path
    echo ${1##*/}
}


get_intf_name_and_type_from_pci_id ()
{
    # fetch the interface name, type and other details for a device using the PCI device id
    # input:
    # - $1: the PCI device ID, e.g. 0000:42:00.1
    #
    # output: type:if_name:driver:status:numa_node
    #   examples: 
    #    - net:eth0:igb:down:0
    #    - uio:uio0:igb_uio:up:1

    BASE_PATH="/sys/bus/pci/devices/$1/"

    # the script might be running while inside a network name space only
    # in this case it will not show the correct information
    # as sysfs for the namespace migh not be mounted
    # so we try to mount sysfs and use it if mounting worked
    MNT=`mktemp -d`
    mount -t sysfs none $MNT 2> /dev/null
    if [ $? -eq 0 ]; then
        if [ -d "$MNT/bus/pci/devices/$1/" ]; then
            BASE_PATH="$MNT/bus/pci/devices/$1/"
        fi
        trap 'umount $MNT' EXIT
    fi


    DRIVER=$(readlink $BASE_PATH/driver)
    NUMA_FILE="${BASE_PATH}/numa_node"

    # the numa_node file might not exist (e.g. for virtio interfaces)
    if [ -f $NUMA_FILE ]; then
        NUMA=$(cat $NUMA_FILE 2> /dev/null)
    else
        NUMA="-"
    fi

    # look for 'net' (regular) device type
    if [ -d "$BASE_PATH/net/" ]; then
        IF_TYPE="net"

    # look for dpdk interface (uio)
    elif [ -d "$BASE_PATH/uio/" ]; then
        IF_TYPE="uio"

    # check if it's a virtio device (virtual interface in a VM)
    else
        VIRTIO_INTF=$(ls $BASE_PATH | grep "^virtio")

        if [ $? -eq 1 ]; then

            # something went wrong and we could not find a virtio
            echo "-:-:$(path_basename $DRIVER):-:$NUMA"
            return 0

        else
            BASE_PATH="${BASE_PATH}/$VIRTIO_INTF/"

            # look for 'net' (regular) device type
            if [ -d "$BASE_PATH/net/" ]; then
                IF_TYPE="net"
        
            # look for dpdk interface (uio)
            elif [ -d "$BASE_PATH/uio/" ]; then
                IF_TYPE="uio"

            fi
        fi
    fi

    IF_NAME=$(ls $BASE_PATH/$IF_TYPE/)

    # the name of the interface is not present if the device does not belong to the current netns
    # so return an arror so that the caller can ignore this interface
    if [ -z $IF_NAME ]; then
        return 1
    fi

    if [ -f "$BASE_PATH/$IF_TYPE/$IF_NAME/carrier" ]; then

        # the carrier file is not readable if the interface is not enabled
        CARRIER=$(cat $BASE_PATH/$IF_TYPE/$IF_NAME/carrier 2> /dev/null)

        if [ ! $? -eq 0 ]; then
            STATE="admin_down"
        elif [ $CARRIER == 0 ]; then
            STATE="no_carrier"
        elif [ $CARRIER == 1 ]; then
            STATE="has_carrier"
        else
            STATE="unhandled"
        fi

    else
        STATE="n/a"
    fi

    echo "$IF_TYPE:$IF_NAME:$(path_basename $DRIVER):$STATE:$NUMA"

}



# find the PCI devices for the network cards
ETH_PCI_DEVS=$(lspci -Dvmmn | grep -B 1 "Class:.*0200$" | grep -v "Class:" | awk '{print $2}')

printf "\n%-13s | %-15s | %-4s | %-11s | %-5s | %-16s\n" "pci_device_id" "if_name" "numa" "carrier" "speed" "driver"
echo '-----------------------------------------------------------------------'

for dev in $ETH_PCI_DEVS; do
    TYPE_AND_NAME_RAW=$(get_intf_name_and_type_from_pci_id $dev)
    if [ $? -ne 0 ]; then
        continue
    fi

    # continue if the the device type and name could be retrieved
    if [ $? -eq 0 ]; then
        IFS=':' read -ra TYPE_AND_NAME <<< "$TYPE_AND_NAME_RAW"

        IF_TYPE=${TYPE_AND_NAME[0]}
        IF_NAME=${TYPE_AND_NAME[1]}
        DRIVER=${TYPE_AND_NAME[2]}
        STATE=${TYPE_AND_NAME[3]}
        NUMA=${TYPE_AND_NAME[4]}
    
        # if the NUMA info was not included in the output, try to find it using /sys/class
        if [ $NUMA == "-" ]; then
            # the file where we should find the NUMA info
            NUMA_FILE="/sys/class/$IF_TYPE/$IF_NAME/device/numa_node"
    
            # the numa_node file might not exist (e.g. for virtio interfaces)
            if [ -f $NUMA_FILE ]; then
                NUMA=$(cat $NUMA_FILE 2> /dev/null)
            else
                NUMA="-"
            fi
        fi

        # the file where we should find speed information
        SPEED_FILE="/sys/class/$IF_TYPE/$IF_NAME/speed"

        if [ -f $SPEED_FILE ]; then
            RAW_SPEED=$(cat $SPEED_FILE 2> /dev/null)
            
            if [ ! $? -eq 0 ]; then
                SPEED="-"
            else
                if [ $RAW_SPEED == -1 ]; then
                    SPEED="-"
                elif [ $RAW_SPEED -lt 1000 ]; then
                    SPEED="${RAW_SPEED}M"
                else
                    SPEED="$((RAW_SPEED / 1000))G"
                fi
            fi
        else
            SPEED="-"
        fi

        printf "%-13s | %-15s | %-4s | %-11s | %-5s | %-16s\n" $dev $IF_NAME $NUMA $STATE $SPEED $DRIVER
    fi
done

echo ""
