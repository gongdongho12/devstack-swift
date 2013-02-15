#!/usr/bin/env bash

# ``stack-swift.sh`` is an OpenStack Swift installation.

#### Created by 2012.11.09 NaleeJang 

# This script allows you to specify configuration options of what git
# repositories to use, enabled services, various passwords.

# Keep track of the devstack directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Import common functions
source $TOP_DIR/functions

# Determine what system we are running on.  This provides ``os_VENDOR``,
# ``os_RELEASE``, ``os_UPDATE``, ``os_PACKAGE``, ``os_CODENAME``
# and ``DISTRO``
GetDistro


# Settings
# ========

# ``stack.sh`` is customizable through setting environment variables.  If you
# want to override a setting you can set and export it::
#
#     export MYSQL_PASSWORD=anothersecret
#     ./stack.sh
#
# You can also pass options on a single line ``MYSQL_PASSWORD=simple ./stack.sh``
#
# Additionally, you can put any local variables into a ``localrc`` file::
#
#     MYSQL_PASSWORD=anothersecret
#     MYSQL_USER=hellaroot
#
# We try to have sensible defaults, so you should be able to run ``./stack.sh``
# in most cases.  ``localrc`` is not distributed with DevStack and will never
# be overwritten by a DevStack update.
#
# DevStack distributes ``stackrc`` which contains locations for the OpenStack
# repositories and branches to configure.  ``stackrc`` sources ``localrc`` to
# allow you to safely override those settings.

if [[ ! -r $TOP_DIR/stackrc ]]; then
    echo "ERROR: missing $TOP_DIR/stackrc - did you grab more than just stack.sh?"
    exit 1
fi
source $TOP_DIR/stackrc


# Proxy Settings
# --------------

# HTTP and HTTPS proxy servers are supported via the usual environment variables [1]
# ``http_proxy``, ``https_proxy`` and ``no_proxy``. They can be set in
# ``localrc`` if necessary or on the command line::
#
# [1] http://www.w3.org/Daemon/User/Proxies/ProxyClients.html
#
#     http_proxy=http://proxy.example.com:3128/ no_proxy=repo.example.net ./stack.sh

if [[ -n "$http_proxy" ]]; then
    export http_proxy=$http_proxy
fi
if [[ -n "$https_proxy" ]]; then
    export https_proxy=$https_proxy
fi
if [[ -n "$no_proxy" ]]; then
    export no_proxy=$no_proxy
fi

# Destination path for installation ``DEST``
DEST=${DEST:-/opt/stack}


# Sanity Check
# ============

# Warn users who aren't on an explicitly supported distro, but allow them to
# override check and attempt installation with ``FORCE=yes ./stack``
if [[ ! ${DISTRO} =~ (oneiric|precise|quantal|f16|f17) ]]; then
    echo "WARNING: this script has not been tested on $DISTRO"
    if [[ "$FORCE" != "yes" ]]; then
        echo "If you wish to run this script anyway run with FORCE=yes"
        exit 1
    fi
fi

# Disallow qpid on oneiric
if [ "${DISTRO}" = "oneiric" ] && is_service_enabled qpid ; then
    # Qpid was introduced in precise
    echo "You must use Ubuntu Precise or newer for Qpid support."
    exit 1
fi

# ``stack.sh`` keeps function libraries here
# Make sure ``$TOP_DIR/lib`` directory is present
if [ ! -d $TOP_DIR/lib ]; then
    echo "ERROR: missing devstack/lib"
    exit 1
fi

# ``stack.sh`` keeps the list of ``apt`` and ``rpm`` dependencies and config
# templates and other useful files in the ``files`` subdirectory
FILES=$TOP_DIR/files
if [ ! -d $FILES ]; then
    echo "ERROR: missing devstack/files"
    exit 1
fi

SCREEN_NAME=${SCREEN_NAME:-stack_swift}
# Check to see if we are already running DevStack
if type -p screen >/dev/null && screen -ls | egrep -q "[0-9].$SCREEN_NAME"; then
    echo "You are already running a stack.sh session."
    echo "To rejoin this session type 'screen -x stack'."
    echo "To destroy this session, type './unstack.sh'."
    exit 1
fi

# Set up logging level
VERBOSE=$(trueorfalse True $VERBOSE)

# Create the destination directory and ensure it is writable by the user
sudo mkdir -p $DEST
if [ ! -w $DEST ]; then
    sudo chown `whoami` $DEST
fi

# Set ``OFFLINE`` to ``True`` to configure ``stack.sh`` to run cleanly without
# Internet access. ``stack.sh`` must have been previously run with Internet
# access to install prerequisites and fetch repositories.
OFFLINE=`trueorfalse False $OFFLINE`

# Set ``ERROR_ON_CLONE`` to ``True`` to configure ``stack.sh`` to exit if
# the destination git repository does not exist during the ``git_clone``
# operation.
ERROR_ON_CLONE=`trueorfalse False $ERROR_ON_CLONE`

# Destination path for service data
DATA_DIR=${DATA_DIR:-${DEST}/data}
sudo mkdir -p $DATA_DIR
sudo chown `whoami` $DATA_DIR


# Common Configuration
# ====================

# Find the interface used for the default route
HOST_IP_IFACE=${HOST_IP_IFACE:-$(ip route | sed -n '/^default/{ s/.*dev \(\w\+\)\s\+.*/\1/; p; }')}
# Search for an IP unless an explicit is set by ``HOST_IP`` environment variable
if [ -z "$HOST_IP" -o "$HOST_IP" == "dhcp" ]; then
    HOST_IP=""
    HOST_IPS=`LC_ALL=C ip -f inet addr show ${HOST_IP_IFACE} | awk '/inet/ {split($2,parts,"/");  print parts[1]}'`
    for IP in $HOST_IPS; do
        # Attempt to filter out IP addresses that are part of the fixed and
        # floating range. Note that this method only works if the ``netaddr``
        # python library is installed. If it is not installed, an error
        # will be printed and the first IP from the interface will be used.
        # If that is not correct set ``HOST_IP`` in ``localrc`` to the correct
        # address.
        if ! (address_in_net $IP $FIXED_RANGE || address_in_net $IP $FLOATING_RANGE); then
            HOST_IP=$IP
            break;
        fi
    done
    if [ "$HOST_IP" == "" ]; then
        echo "Could not determine host ip address."
        echo "Either localrc specified dhcp on ${HOST_IP_IFACE} or defaulted"
        exit 1
    fi
fi

# Allow the use of an alternate hostname (such as localhost/127.0.0.1) for service endpoints.
SERVICE_HOST=${SERVICE_HOST:-$HOST_IP}

# Configure services to use syslog instead of writing to individual log files
SYSLOG=`trueorfalse False $SYSLOG`
SYSLOG_HOST=${SYSLOG_HOST:-$HOST_IP}
SYSLOG_PORT=${SYSLOG_PORT:-516}

# Use color for logging output (only available if syslog is not used)
LOG_COLOR=`trueorfalse True $LOG_COLOR`

# Service startup timeout
SERVICE_TIMEOUT=${SERVICE_TIMEOUT:-60}


# Configure Projects
# ==================

# Get project function libraries
source $TOP_DIR/lib/keystone

# Set the destination directories for OpenStack projects
SWIFT_DIR=$DEST/swift
SWIFTCLIENT_DIR=$DEST/python-swiftclient

# Generic helper to configure passwords
function read_password {
    XTRACE=$(set +o | grep xtrace)
    set +o xtrace
    var=$1; msg=$2
    pw=${!var}

    localrc=$TOP_DIR/localrc

    # If the password is not defined yet, proceed to prompt user for a password.
    if [ ! $pw ]; then
        # If there is no localrc file, create one
        if [ ! -e $localrc ]; then
            touch $localrc
        fi

        # Presumably if we got this far it can only be that our localrc is missing
        # the required password.  Prompt user for a password and write to localrc.
        echo ''
        echo '################################################################################'
        echo $msg
        echo '################################################################################'
        echo "This value will be written to your localrc file so you don't have to enter it "
        echo "again.  Use only alphanumeric characters."
        echo "If you leave this blank, a random default value will be used."
        pw=" "
        while true; do
            echo "Enter a password now:"
            read -e $var
            pw=${!var}
            [[ "$pw" = "`echo $pw | tr -cd [:alnum:]`" ]] && break
            echo "Invalid chars in password.  Try again:"
        done
        if [ ! $pw ]; then
            pw=`openssl rand -hex 10`
        fi
        eval "$var=$pw"
        echo "$var=$pw" >> $localrc
    fi
    $XTRACE
}


# MySQL & (RabbitMQ or Qpid)
# --------------------------

# We configure Nova, Horizon, Glance and Keystone to use MySQL as their
# database server.  While they share a single server, each has their own
# database and tables.

# By default this script will install and configure MySQL.  If you want to
# use an existing server, you can pass in the user/password/host parameters.
# You will need to send the same ``MYSQL_PASSWORD`` to every host if you are doing
# a multi-node DevStack installation.
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_USER=${MYSQL_USER:-root}
read_password MYSQL_PASSWORD "ENTER A PASSWORD TO USE FOR MYSQL."

# NOTE: Don't specify ``/db`` in this string so we can use it for multiple services
BASE_SQL_CONN=${BASE_SQL_CONN:-mysql://$MYSQL_USER:$MYSQL_PASSWORD@$MYSQL_HOST}

# Rabbit connection info
if is_service_enabled rabbit; then
    RABBIT_HOST=${RABBIT_HOST:-localhost}
    read_password RABBIT_PASSWORD "ENTER A PASSWORD TO USE FOR RABBIT."
fi


# Swift
# -----

# TODO: add logging to different location.

# Set ``SWIFT_DATA_DIR`` to the location of swift drives and objects.
# Default is the common DevStack data directory.
SWIFT_DATA_DIR=${SWIFT_DATA_DIR:-${DEST}/data/swift}

# Set ``SWIFT_CONFIG_DIR`` to the location of the configuration files.
# Default is ``/etc/swift``.
SWIFT_CONFIG_DIR=${SWIFT_CONFIG_DIR:-/etc/swift}

# DevStack will create a loop-back disk formatted as XFS to store the
# swift data. Set ``SWIFT_LOOPBACK_DISK_SIZE`` to the disk size in bytes.
# Default is 1 gigabyte.
SWIFT_LOOPBACK_DISK_SIZE=${SWIFT_LOOPBACK_DISK_SIZE:-1000000}

# The ring uses a configurable number of bits from a path’s MD5 hash as
# a partition index that designates a device. The number of bits kept
# from the hash is known as the partition power, and 2 to the partition
# power indicates the partition count. Partitioning the full MD5 hash
# ring allows other parts of the cluster to work in batches of items at
# once which ends up either more efficient or at least less complex than
# working with each item separately or the entire cluster all at once.
# By default we define 9 for the partition count (which mean 512).
SWIFT_PARTITION_POWER_SIZE=${SWIFT_PARTITION_POWER_SIZE:-9}

# Set ``SWIFT_REPLICAS`` to configure how many replicas are to be
# configured for your Swift cluster.  By default the three replicas would need a
# bit of IO and Memory on a VM you may want to lower that to 1 if you want to do
# only some quick testing.
SWIFT_REPLICAS=${SWIFT_REPLICAS:-3}

if is_service_enabled swift; then
    # If we are using swift3, we can default the s3 port to swift instead
    # of nova-objectstore
    if is_service_enabled swift3;then
        S3_SERVICE_PORT=${S3_SERVICE_PORT:-8080}
    fi
    # We only ask for Swift Hash if we have enabled swift service.
    # SWIFT_HASH is a random unique string for a swift cluster that
    # can never change.
    read_password SWIFT_HASH "ENTER A RANDOM SWIFT HASH."
fi


# Keystone
# --------

# The ``SERVICE_TOKEN`` is used to bootstrap the Keystone database.  It is
# just a string and is not a 'real' Keystone token.
read_password SERVICE_TOKEN "ENTER A SERVICE_TOKEN TO USE FOR THE SERVICE ADMIN TOKEN."
# Services authenticate to Identity with servicename/SERVICE_PASSWORD
read_password SERVICE_PASSWORD "ENTER A SERVICE_PASSWORD TO USE FOR THE SERVICE AUTHENTICATION."
# Horizon currently truncates usernames and passwords at 20 characters
read_password ADMIN_PASSWORD "ENTER A PASSWORD TO USE FOR HORIZON AND KEYSTONE (20 CHARS OR LESS)."

# Set the tenant for service accounts in Keystone
SERVICE_TENANT_NAME=${SERVICE_TENANT_NAME:-service}



# Log files
# ---------

# Draw a spinner so the user knows something is happening
function spinner()
{
    local delay=0.75
    local spinstr='|/-\'
    printf "..." >&3
    while [ true ]; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b" >&3
    done
}

# Echo text to the log file, summary log file and stdout
# echo_summary "something to say"
function echo_summary() {
    if [[ -t 3 && "$VERBOSE" != "True" ]]; then
        kill >/dev/null 2>&1 $LAST_SPINNER_PID
        if [ ! -z "$LAST_SPINNER_PID" ]; then
            printf "\b\b\bdone\n" >&3
        fi
        echo -n $@ >&6
        spinner &
        LAST_SPINNER_PID=$!
    else
        echo $@ >&6
    fi
}

# Echo text only to stdout, no log files
# echo_nolog "something not for the logs"
function echo_nolog() {
    echo $@ >&3
}

# Set up logging for ``stack.sh``
# Set ``LOGFILE`` to turn on logging
# Append '.xxxxxxxx' to the given name to maintain history
# where 'xxxxxxxx' is a representation of the date the file was created
if [[ -n "$LOGFILE" || -n "$SCREEN_LOGDIR" ]]; then
    LOGDAYS=${LOGDAYS:-7}
    TIMESTAMP_FORMAT=${TIMESTAMP_FORMAT:-"%F-%H%M%S"}
    CURRENT_LOG_TIME=$(date "+$TIMESTAMP_FORMAT")
fi

if [[ -n "$LOGFILE" ]]; then
    # First clean up old log files.  Use the user-specified ``LOGFILE``
    # as the template to search for, appending '.*' to match the date
    # we added on earlier runs.
    LOGDIR=$(dirname "$LOGFILE")
    LOGNAME=$(basename "$LOGFILE")
    mkdir -p $LOGDIR
    find $LOGDIR -maxdepth 1 -name $LOGNAME.\* -mtime +$LOGDAYS -exec rm {} \;
    LOGFILE=$LOGFILE.${CURRENT_LOG_TIME}
    SUMFILE=$LOGFILE.${CURRENT_LOG_TIME}.summary

    # Redirect output according to config
    # Copy stdout to fd 3
    exec 3>&1
    if [[ "$VERBOSE" == "True" ]]; then
        # Redirect stdout/stderr to tee to write the log file
        exec 1> >( tee "${LOGFILE}" ) 2>&1
        # Set up a second fd for output
        exec 6> >( tee "${SUMFILE}" )
    else
        # Set fd 1 and 2 to primary logfile
        exec 1> "${LOGFILE}" 2>&1
        # Set fd 6 to summary logfile and stdout
        exec 6> >( tee "${SUMFILE}" /dev/fd/3 )
    fi

    echo_summary "stack.sh log $LOGFILE"
    # Specified logfile name always links to the most recent log
    ln -sf $LOGFILE $LOGDIR/$LOGNAME
    ln -sf $SUMFILE $LOGDIR/$LOGNAME.summary
else
    # Set up output redirection without log files
    # Copy stdout to fd 3
    exec 3>&1
    if [[ "$VERBOSE" != "True" ]]; then
        # Throw away stdout and stderr
        exec 1>/dev/null 2>&1
    fi
    # Always send summary fd to original stdout
    exec 6>&3
fi

# Set up logging of screen windows
# Set ``SCREEN_LOGDIR`` to turn on logging of screen windows to the
# directory specified in ``SCREEN_LOGDIR``, we will log to the the file
# ``screen-$SERVICE_NAME-$TIMESTAMP.log`` in that dir and have a link
# ``screen-$SERVICE_NAME.log`` to the latest log file.
# Logs are kept for as long specified in ``LOGDAYS``.
if [[ -n "$SCREEN_LOGDIR" ]]; then

    # We make sure the directory is created.
    if [[ -d "$SCREEN_LOGDIR" ]]; then
        # We cleanup the old logs
        find $SCREEN_LOGDIR -maxdepth 1 -name screen-\*.log -mtime +$LOGDAYS -exec rm {} \;
    else
        mkdir -p $SCREEN_LOGDIR
    fi
fi


# Set Up Script Execution
# -----------------------

# Kill background processes on exit
trap clean EXIT
clean() {
    local r=$?
    kill >/dev/null 2>&1 $(jobs -p)
    exit $r
}


# Exit on any errors so that errors don't compound
trap failed ERR
failed() {
    local r=$?
    kill >/dev/null 2>&1 $(jobs -p)
    set +o xtrace
    [ -n "$LOGFILE" ] && echo "${0##*/} failed: full log in $LOGFILE"
    exit $r
}

# Print the commands being run so that we can see the command that triggers
# an error.  It is also useful for following along as the install occurs.
set -o xtrace


# Install Packages
# ================

# OpenStack uses a fair number of other projects.

# Install package requirements
echo_summary "Installing package prerequisites"
if [[ "$os_PACKAGE" = "deb" ]]; then
    install_package $(get_packages $FILES/apts)
else
    install_package $(get_packages $FILES/rpms)
fi

if [[ $SYSLOG != "False" ]]; then
    install_package rsyslog-relp
fi

if is_service_enabled mysql; then

    if [[ "$os_PACKAGE" = "deb" ]]; then
        # Seed configuration with mysql password so that apt-get install doesn't
        # prompt us for a password upon install.
        cat <<MYSQL_PRESEED | sudo debconf-set-selections
mysql-server-5.1 mysql-server/root_password password $MYSQL_PASSWORD
mysql-server-5.1 mysql-server/root_password_again password $MYSQL_PASSWORD
mysql-server-5.1 mysql-server/start_on_boot boolean true
MYSQL_PRESEED
    fi

    # while ``.my.cnf`` is not needed for OpenStack to function, it is useful
    # as it allows you to access the mysql databases via ``mysql nova`` instead
    # of having to specify the username/password each time.
    if [[ ! -e $HOME/.my.cnf ]]; then
        cat <<EOF >$HOME/.my.cnf
[client]
user=$MYSQL_USER
password=$MYSQL_PASSWORD
host=$MYSQL_HOST
EOF
        chmod 0600 $HOME/.my.cnf
    fi
    # Install mysql-server
    install_package mysql-server
fi

if is_service_enabled swift; then
    # Install memcached for swift.
    install_package memcached
fi

TRACK_DEPENDS=${TRACK_DEPENDS:-False}

# Install python packages into a virtualenv so that we can track them
if [[ $TRACK_DEPENDS = True ]] ; then
    echo_summary "Installing Python packages into a virtualenv $DEST/.venv"
    install_package python-virtualenv

    rm -rf $DEST/.venv
    virtualenv --system-site-packages $DEST/.venv
    source $DEST/.venv/bin/activate
    $DEST/.venv/bin/pip freeze > $DEST/requires-pre-pip
fi

# Install python requirements
echo_summary "Installing Python prerequisites"
pip_install $(get_packages $FILES/pips | sort -u)


# Check Out Source
# ----------------

echo_summary "Installing OpenStack project source"

install_keystoneclient

# glance, swift middleware and nova api needs keystone middleware
if is_service_enabled key g-api n-api swift; then
    # unified auth system (manages accounts/tokens)
    install_keystone
fi
if is_service_enabled swift; then
    # storage service
    git_clone $SWIFT_REPO $SWIFT_DIR $SWIFT_BRANCH
    # storage service client and and Library
    git_clone $SWIFTCLIENT_REPO $SWIFTCLIENT_DIR $SWIFTCLIENT_BRANCH
    if is_service_enabled swift3; then
        # swift3 middleware to provide S3 emulation to Swift
        git_clone $SWIFT3_REPO $SWIFT3_DIR $SWIFT3_BRANCH
    fi
fi


# Initialization
# ==============

echo_summary "Configuring OpenStack projects"

# Set up our checkouts so they are installed into python path
# allowing ``import nova`` or ``import glance.client``
configure_keystoneclient
if is_service_enabled key g-api n-api swift; then
    configure_keystone
fi
if is_service_enabled swift; then
    setup_develop $SWIFT_DIR
    setup_develop $SWIFTCLIENT_DIR
fi

if [[ $TRACK_DEPENDS = True ]] ; then
    $DEST/.venv/bin/pip freeze > $DEST/requires-post-pip
    if ! diff -Nru $DEST/requires-pre-pip $DEST/requires-post-pip > $DEST/requires.diff ; then
        cat $DEST/requires.diff
    fi
    echo "Ran stack.sh in depend tracking mode, bailing out now"
    exit 0
fi


# Syslog
# ------

if [[ $SYSLOG != "False" ]]; then
    if [[ "$SYSLOG_HOST" = "$HOST_IP" ]]; then
        # Configure the master host to receive
        cat <<EOF >/tmp/90-stack-m.conf
\$ModLoad imrelp
\$InputRELPServerRun $SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-m.conf /etc/rsyslog.d
    else
        # Set rsyslog to send to remote host
        cat <<EOF >/tmp/90-stack-s.conf
*.*		:omrelp:$SYSLOG_HOST:$SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-s.conf /etc/rsyslog.d
    fi
    echo_summary "Starting rsyslog"
    restart_service rsyslog
fi


# Finalize queue installation
# ----------------------------

if is_service_enabled rabbit; then
    # Start rabbitmq-server
    echo_summary "Starting RabbitMQ"
    if [[ "$os_PACKAGE" = "rpm" ]]; then
        # RPM doesn't start the service
        restart_service rabbitmq-server
    fi
    # change the rabbit password since the default is "guest"
    sudo rabbitmqctl change_password guest $RABBIT_PASSWORD
elif is_service_enabled qpid; then
    echo_summary "Starting qpid"
    restart_service qpidd
fi


# Mysql
# -----

if is_service_enabled mysql; then
    echo_summary "Configuring and starting MySQL"

    if [[ "$os_PACKAGE" = "deb" ]]; then
        MY_CONF=/etc/mysql/my.cnf
        MYSQL=mysql
    else
        MY_CONF=/etc/my.cnf
        MYSQL=mysqld
    fi

    # Start mysql-server
    if [[ "$os_PACKAGE" = "rpm" ]]; then
        # RPM doesn't start the service
        start_service $MYSQL
        # Set the root password - only works the first time
        sudo mysqladmin -u root password $MYSQL_PASSWORD || true
    fi
    # Update the DB to give user ‘$MYSQL_USER’@’%’ full control of the all databases:
    sudo mysql -uroot -p$MYSQL_PASSWORD -h127.0.0.1 -e "GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_USER'@'%' identified by '$MYSQL_PASSWORD';"

    # Now update ``my.cnf`` for some local needs and restart the mysql service

    # Change ‘bind-address’ from localhost (127.0.0.1) to any (0.0.0.0)
    sudo sed -i '/^bind-address/s/127.0.0.1/0.0.0.0/g' $MY_CONF

    # Set default db type to InnoDB
    if sudo grep -q "default-storage-engine" $MY_CONF; then
        # Change it
        sudo bash -c "source $TOP_DIR/functions; iniset $MY_CONF mysqld default-storage-engine InnoDB"
    else
        # Add it
        sudo sed -i -e "/^\[mysqld\]/ a \
default-storage-engine = InnoDB" $MY_CONF
    fi

    restart_service $MYSQL
fi

if [ -z "$SCREEN_HARDSTATUS" ]; then
    SCREEN_HARDSTATUS='%{= .} %-Lw%{= .}%> %n%f %t*%{= .}%+Lw%< %-=%{g}(%{d}%H/%l%{g})'
fi

# Create a new named screen to run processes in
screen -d -m -S $SCREEN_NAME -t shell -s /bin/bash
sleep 1
# Set a reasonable status bar
screen -r $SCREEN_NAME -X hardstatus alwayslastline "$SCREEN_HARDSTATUS"


# Keystone
# --------

if is_service_enabled key; then
    echo_summary "Starting Keystone"
    configure_keystone
    init_keystone
    start_keystone
    echo "Waiting for keystone to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= curl -s $KEYSTONE_AUTH_PROTOCOL://$SERVICE_HOST:$KEYSTONE_API_PORT/v2.0/ >/dev/null; do sleep 1; done"; then
      echo "keystone did not start"
      exit 1
    fi

    # ``keystone_data.sh`` creates services, admin and demo users, and roles.
    SERVICE_ENDPOINT=$KEYSTONE_AUTH_PROTOCOL://$KEYSTONE_AUTH_HOST:$KEYSTONE_AUTH_PORT/v2.0

    ADMIN_PASSWORD=$ADMIN_PASSWORD SERVICE_TENANT_NAME=$SERVICE_TENANT_NAME SERVICE_PASSWORD=$SERVICE_PASSWORD \
    SERVICE_TOKEN=$SERVICE_TOKEN SERVICE_ENDPOINT=$SERVICE_ENDPOINT SERVICE_HOST=$SERVICE_HOST \
    S3_SERVICE_PORT=$S3_SERVICE_PORT KEYSTONE_CATALOG_BACKEND=$KEYSTONE_CATALOG_BACKEND \
    DEVSTACK_DIR=$TOP_DIR ENABLED_SERVICES=$ENABLED_SERVICES HEAT_API_CFN_PORT=$HEAT_API_CFN_PORT \
        bash -x $FILES/keystone_data.sh

    # Set up auth creds now that keystone is bootstrapped
    export OS_AUTH_URL=$SERVICE_ENDPOINT
    export OS_TENANT_NAME=admin
    export OS_USERNAME=admin
    export OS_PASSWORD=$ADMIN_PASSWORD
fi

# Storage Service
# ---------------

if is_service_enabled swift; then
    echo_summary "Configuring Swift"

    # Make sure to kill all swift processes first
    swift-init all stop || true

    # First do a bit of setup by creating the directories and
    # changing the permissions so we can run it as our user.

    USER_GROUP=$(id -g)
    sudo mkdir -p ${SWIFT_DATA_DIR}/drives
    sudo chown -R $USER:${USER_GROUP} ${SWIFT_DATA_DIR}

    # Create a loopback disk and format it to XFS.
    if [[ -e ${SWIFT_DATA_DIR}/drives/images/swift.img ]]; then
        if egrep -q ${SWIFT_DATA_DIR}/drives/sdb1 /proc/mounts; then
            sudo umount ${SWIFT_DATA_DIR}/drives/sdb1
        fi
    else
        mkdir -p  ${SWIFT_DATA_DIR}/drives/images
        sudo touch  ${SWIFT_DATA_DIR}/drives/images/swift.img
        sudo chown $USER: ${SWIFT_DATA_DIR}/drives/images/swift.img

        dd if=/dev/zero of=${SWIFT_DATA_DIR}/drives/images/swift.img \
            bs=1024 count=0 seek=${SWIFT_LOOPBACK_DISK_SIZE}
    fi

    # Make a fresh XFS filesystem
    mkfs.xfs -f -i size=1024  ${SWIFT_DATA_DIR}/drives/images/swift.img

    # Mount the disk with mount options to make it as efficient as possible
    mkdir -p ${SWIFT_DATA_DIR}/drives/sdb1
    if ! egrep -q ${SWIFT_DATA_DIR}/drives/sdb1 /proc/mounts; then
        sudo mount -t xfs -o loop,noatime,nodiratime,nobarrier,logbufs=8  \
            ${SWIFT_DATA_DIR}/drives/images/swift.img ${SWIFT_DATA_DIR}/drives/sdb1
    fi

    # Create a link to the above mount
    for x in $(seq ${SWIFT_REPLICAS}); do
        sudo ln -sf ${SWIFT_DATA_DIR}/drives/sdb1/$x ${SWIFT_DATA_DIR}/$x; done

    # Create all of the directories needed to emulate a few different servers
    for x in $(seq ${SWIFT_REPLICAS}); do
            drive=${SWIFT_DATA_DIR}/drives/sdb1/${x}
            node=${SWIFT_DATA_DIR}/${x}/node
            node_device=${node}/sdb1
            [[ -d $node ]] && continue
            [[ -d $drive ]] && continue
            sudo install -o ${USER} -g $USER_GROUP -d $drive
            sudo install -o ${USER} -g $USER_GROUP -d $node_device
            sudo chown -R $USER: ${node}
    done

   sudo mkdir -p ${SWIFT_CONFIG_DIR}/{object,container,account}-server /var/run/swift
   sudo chown -R $USER: ${SWIFT_CONFIG_DIR} /var/run/swift

    if [[ "$SWIFT_CONFIG_DIR" != "/etc/swift" ]]; then
        # Some swift tools are hard-coded to use ``/etc/swift`` and are apparently not going to be fixed.
        # Create a symlink if the config dir is moved
        sudo ln -sf ${SWIFT_CONFIG_DIR} /etc/swift
    fi

    # Swift use rsync to synchronize between all the different
    # partitions (which make more sense when you have a multi-node
    # setup) we configure it with our version of rsync.
    sed -e "
        s/%GROUP%/${USER_GROUP}/;
        s/%USER%/$USER/;
        s,%SWIFT_DATA_DIR%,$SWIFT_DATA_DIR,;
    " $FILES/swift/rsyncd.conf | sudo tee /etc/rsyncd.conf
    if [[ "$os_PACKAGE" = "deb" ]]; then
        sudo sed -i '/^RSYNC_ENABLE=false/ { s/false/true/ }' /etc/default/rsync
    else
        sudo sed -i '/disable *= *yes/ { s/yes/no/ }' /etc/xinetd.d/rsync
    fi

    if is_service_enabled swift3;then
        swift_auth_server="s3token "
    fi

    # By default Swift will be installed with the tempauth middleware
    # which has some default username and password if you have
    # configured keystone it will checkout the directory.
    if is_service_enabled key; then
        swift_auth_server+="authtoken keystoneauth"
    else
        swift_auth_server=tempauth
    fi

    SWIFT_CONFIG_PROXY_SERVER=${SWIFT_CONFIG_DIR}/proxy-server.conf
    cp ${SWIFT_DIR}/etc/proxy-server.conf-sample ${SWIFT_CONFIG_PROXY_SERVER}

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT user
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT user ${USER}

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT swift_dir
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT swift_dir ${SWIFT_CONFIG_DIR}

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT workers
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT workers 1

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT log_level
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT log_level DEBUG

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT bind_port
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT bind_port ${SWIFT_DEFAULT_BIND_PORT:-8080}

    # Only enable Swift3 if we have it enabled in ENABLED_SERVICES
    is_service_enabled swift3 && swift3=swift3 || swift3=""

    iniset ${SWIFT_CONFIG_PROXY_SERVER} pipeline:main pipeline "catch_errors healthcheck cache ratelimit ${swift3} ${swift_auth_server} proxy-logging proxy-server"

    iniset ${SWIFT_CONFIG_PROXY_SERVER} app:proxy-server account_autocreate true

    # Configure Keystone
    sed -i '/^# \[filter:authtoken\]/,/^# \[filter:keystoneauth\]$/ s/^#[ \t]*//' ${SWIFT_CONFIG_PROXY_SERVER}
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken auth_host $KEYSTONE_AUTH_HOST
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken auth_port $KEYSTONE_AUTH_PORT
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken auth_protocol $KEYSTONE_AUTH_PROTOCOL
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken auth_uri $KEYSTONE_SERVICE_PROTOCOL://$KEYSTONE_SERVICE_HOST:$KEYSTONE_SERVICE_PORT/
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken admin_tenant_name $SERVICE_TENANT_NAME
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken admin_user swift
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken admin_password $SERVICE_PASSWORD

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} filter:keystoneauth use
    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} filter:keystoneauth operator_roles
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:keystoneauth operator_roles "Member, admin"

    if is_service_enabled swift3;then
        cat <<EOF>>${SWIFT_CONFIG_PROXY_SERVER}
# NOTE(chmou): s3token middleware is not updated yet to use only
# username and password.
[filter:s3token]
paste.filter_factory = keystone.middleware.s3_token:filter_factory
auth_port = ${KEYSTONE_AUTH_PORT}
auth_host = ${KEYSTONE_AUTH_HOST}
auth_protocol = ${KEYSTONE_AUTH_PROTOCOL}
auth_token = ${SERVICE_TOKEN}
admin_token = ${SERVICE_TOKEN}

[filter:swift3]
use = egg:swift3#swift3
EOF
    fi

    cp ${SWIFT_DIR}/etc/swift.conf-sample ${SWIFT_CONFIG_DIR}/swift.conf
    iniset ${SWIFT_CONFIG_DIR}/swift.conf swift-hash swift_hash_path_suffix ${SWIFT_HASH}

    # This function generates an object/account/proxy configuration
    # emulating 4 nodes on different ports
    function generate_swift_configuration() {
        local server_type=$1
        local bind_port=$2
        local log_facility=$3
        local node_number
        local swift_node_config

        for node_number in $(seq ${SWIFT_REPLICAS}); do
            node_path=${SWIFT_DATA_DIR}/${node_number}
            swift_node_config=${SWIFT_CONFIG_DIR}/${server_type}-server/${node_number}.conf

            cp ${SWIFT_DIR}/etc/${server_type}-server.conf-sample ${swift_node_config}

            iniuncomment ${swift_node_config} DEFAULT user
            iniset ${swift_node_config} DEFAULT user ${USER}

            iniuncomment ${swift_node_config} DEFAULT bind_port
            iniset ${swift_node_config} DEFAULT bind_port ${bind_port}

            iniuncomment ${swift_node_config} DEFAULT swift_dir
            iniset ${swift_node_config} DEFAULT swift_dir ${SWIFT_CONFIG_DIR}

            iniuncomment ${swift_node_config} DEFAULT devices
            iniset ${swift_node_config} DEFAULT devices ${node_path}

            iniuncomment ${swift_node_config} DEFAULT log_facility
            iniset ${swift_node_config} DEFAULT log_facility LOG_LOCAL${log_facility}

            iniuncomment ${swift_node_config} DEFAULT mount_check
            iniset ${swift_node_config} DEFAULT mount_check false

            iniuncomment ${swift_node_config} ${server_type}-replicator vm_test_mode
            iniset ${swift_node_config} ${server_type}-replicator vm_test_mode yes

            bind_port=$(( ${bind_port} + 10 ))
            log_facility=$(( ${log_facility} + 1 ))
        done
    }
    generate_swift_configuration object 6010 2
    generate_swift_configuration container 6011 2
    generate_swift_configuration account 6012 2

    # Specific configuration for swift for rsyslog. See
    # ``/etc/rsyslog.d/10-swift.conf`` for more info.
    swift_log_dir=${SWIFT_DATA_DIR}/logs
    rm -rf ${swift_log_dir}
    mkdir -p ${swift_log_dir}/hourly
    sudo chown -R $USER:adm ${swift_log_dir}
    sed "s,%SWIFT_LOGDIR%,${swift_log_dir}," $FILES/swift/rsyslog.conf | sudo \
        tee /etc/rsyslog.d/10-swift.conf
    restart_service rsyslog

    # This is where we create three different rings for swift with
    # different object servers binding on different ports.
    pushd ${SWIFT_CONFIG_DIR} >/dev/null && {

        rm -f *.builder *.ring.gz backups/*.builder backups/*.ring.gz

        port_number=6010
        swift-ring-builder object.builder create ${SWIFT_PARTITION_POWER_SIZE} ${SWIFT_REPLICAS} 1
        for x in $(seq ${SWIFT_REPLICAS}); do
            swift-ring-builder object.builder add z${x}-127.0.0.1:${port_number}/sdb1 1
            port_number=$[port_number + 10]
        done
        swift-ring-builder object.builder rebalance

        port_number=6011
        swift-ring-builder container.builder create ${SWIFT_PARTITION_POWER_SIZE} ${SWIFT_REPLICAS} 1
        for x in $(seq ${SWIFT_REPLICAS}); do
            swift-ring-builder container.builder add z${x}-127.0.0.1:${port_number}/sdb1 1
            port_number=$[port_number + 10]
        done
        swift-ring-builder container.builder rebalance

        port_number=6012
        swift-ring-builder account.builder create ${SWIFT_PARTITION_POWER_SIZE} ${SWIFT_REPLICAS} 1
        for x in $(seq ${SWIFT_REPLICAS}); do
            swift-ring-builder account.builder add z${x}-127.0.0.1:${port_number}/sdb1 1
            port_number=$[port_number + 10]
        done
        swift-ring-builder account.builder rebalance

    } && popd >/dev/null

   # Start rsync
    if [[ "$os_PACKAGE" = "deb" ]]; then
        sudo /etc/init.d/rsync restart || :
    else
        sudo systemctl start xinetd.service
    fi

   # First spawn all the swift services then kill the
   # proxy service so we can run it in foreground in screen.
   # ``swift-init ... {stop|restart}`` exits with '1' if no servers are running,
   # ignore it just in case
   swift-init all restart || true
   swift-init proxy stop || true

   unset s swift_hash swift_auth_server
fi


# Launch Services
# ===============

# Only run the services specified in ``ENABLED_SERVICES``
screen_it swift "cd $SWIFT_DIR && $SWIFT_DIR/bin/swift-proxy-server ${SWIFT_CONFIG_DIR}/proxy-server.conf -v"


# Run local script
# ================

# Run ``local.sh`` if it exists to perform user-managed tasks
if [[ -x $TOP_DIR/local.sh ]]; then
    echo "Running user script $TOP_DIR/local.sh"
    $TOP_DIR/local.sh
fi


# Fin
# ===

set +o xtrace

if [[ -n "$LOGFILE" ]]; then
    exec 1>&3
    # Force all output to stdout and logs now
    exec 1> >( tee -a "${LOGFILE}" ) 2>&1
else
    # Force all output to stdout now
    exec 1>&3
fi


# Using the cloud
# ---------------

echo ""

# If Keystone is present you can point ``nova`` cli to this server
if is_service_enabled key; then
    echo "Keystone is serving at $KEYSTONE_AUTH_PROTOCOL://$SERVICE_HOST:$KEYSTONE_API_PORT/v2.0/"
    echo "Examples on using novaclient command line is in exercise.sh"
    echo "The default users are: admin and demo"
    echo "The password: $ADMIN_PASSWORD"
fi

# Echo ``HOST_IP`` - useful for ``build_uec.sh``, which uses dhcp to give the instance an address
echo "This is your host ip: $HOST_IP"

# Warn that ``EXTRA_FLAGS`` needs to be converted to ``EXTRA_OPTS``
if [[ -n "$EXTRA_FLAGS" ]]; then
    echo_summary "WARNING: EXTRA_FLAGS is defined and may need to be converted to EXTRA_OPTS"
fi

# Indicate how long this took to run (bash maintained variable ``SECONDS``)
echo_summary "stack.sh completed in $SECONDS seconds."
