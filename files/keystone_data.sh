#!/bin/bash
#
# Initial data for Keystone using python-keystoneclient
#
# Tenant               User      Roles
# ------------------------------------------------------------------
# admin                admin     admin
# service              swift     admin        # if enabled
# demo                 admin     admin
# demo                 demo      Member, anotherrole
# invisible_to_admin   demo      Member
# Tempest Only:
# alt_demo             alt_demo  Member
#
# Variables set before calling this script:
# SERVICE_TOKEN - aka admin_token in keystone.conf
# SERVICE_ENDPOINT - local Keystone admin endpoint
# SERVICE_TENANT_NAME - name of tenant containing service accounts
# SERVICE_HOST - host used for endpoint creation
# ENABLED_SERVICES - stack.sh's list of services to start
# DEVSTACK_DIR - Top-level DevStack directory
# KEYSTONE_CATALOG_BACKEND - used to determine service catalog creation

# Defaults
# --------

ADMIN_PASSWORD=${ADMIN_PASSWORD:-secrete}
SERVICE_PASSWORD=${SERVICE_PASSWORD:-$ADMIN_PASSWORD}
export SERVICE_TOKEN=$SERVICE_TOKEN
export SERVICE_ENDPOINT=$SERVICE_ENDPOINT
SERVICE_TENANT_NAME=${SERVICE_TENANT_NAME:-service}

function get_id () {
    echo `"$@" | awk '/ id / { print $4 }'`
}


# Tenants
# -------

ADMIN_TENANT=$(get_id keystone tenant-create --name=admin)
SERVICE_TENANT=$(get_id keystone tenant-create --name=$SERVICE_TENANT_NAME)
DEMO_TENANT=$(get_id keystone tenant-create --name=demo)
INVIS_TENANT=$(get_id keystone tenant-create --name=invisible_to_admin)


# Users
# -----

ADMIN_USER=$(get_id keystone user-create --name=admin \
                                         --pass="$ADMIN_PASSWORD" \
                                         --email=admin@example.com)
DEMO_USER=$(get_id keystone user-create --name=demo \
                                        --pass="$ADMIN_PASSWORD" \
                                        --email=demo@example.com)


# Roles
# -----

ADMIN_ROLE=$(get_id keystone role-create --name=admin)
KEYSTONEADMIN_ROLE=$(get_id keystone role-create --name=KeystoneAdmin)
KEYSTONESERVICE_ROLE=$(get_id keystone role-create --name=KeystoneServiceAdmin)
# ANOTHER_ROLE demonstrates that an arbitrary role may be created and used
# TODO(sleepsonthefloor): show how this can be used for rbac in the future!
ANOTHER_ROLE=$(get_id keystone role-create --name=anotherrole)


# Add Roles to Users in Tenants
keystone user-role-add --user_id $ADMIN_USER --role_id $ADMIN_ROLE --tenant_id $ADMIN_TENANT
keystone user-role-add --user_id $ADMIN_USER --role_id $ADMIN_ROLE --tenant_id $DEMO_TENANT
keystone user-role-add --user_id $DEMO_USER --role_id $ANOTHER_ROLE --tenant_id $DEMO_TENANT

# TODO(termie): these two might be dubious
keystone user-role-add --user_id $ADMIN_USER --role_id $KEYSTONEADMIN_ROLE --tenant_id $ADMIN_TENANT
keystone user-role-add --user_id $ADMIN_USER --role_id $KEYSTONESERVICE_ROLE --tenant_id $ADMIN_TENANT


# The Member role is used by Horizon and Swift so we need to keep it:
MEMBER_ROLE=$(get_id keystone role-create --name=Member)
keystone user-role-add --user_id $DEMO_USER --role_id $MEMBER_ROLE --tenant_id $DEMO_TENANT
keystone user-role-add --user_id $DEMO_USER --role_id $MEMBER_ROLE --tenant_id $INVIS_TENANT


# Services
# --------

# Keystone
if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
	KEYSTONE_SERVICE=$(get_id keystone service-create \
		--name=keystone \
		--type=identity \
		--description="Keystone Identity Service")
	keystone endpoint-create \
	    --region RegionOne \
		--service_id $KEYSTONE_SERVICE \
		--publicurl "http://$SERVICE_HOST:\$(public_port)s/v2.0" \
		--adminurl "http://$SERVICE_HOST:\$(admin_port)s/v2.0" \
		--internalurl "http://$SERVICE_HOST:\$(public_port)s/v2.0"
fi

# Swift
if [[ "$ENABLED_SERVICES" =~ "swift" ]]; then
    SWIFT_USER=$(get_id keystone user-create \
        --name=swift \
        --pass="$SERVICE_PASSWORD" \
        --tenant_id $SERVICE_TENANT \
        --email=swift@example.com)
    keystone user-role-add \
        --tenant_id $SERVICE_TENANT \
        --user_id $SWIFT_USER \
        --role_id $ADMIN_ROLE
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        SWIFT_SERVICE=$(get_id keystone service-create \
            --name=swift \
            --type="object-store" \
            --description="Swift Service")
        keystone endpoint-create \
            --region RegionOne \
            --service_id $SWIFT_SERVICE \
            --publicurl "http://$SERVICE_HOST:8080/v1/AUTH_\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:8080" \
            --internalurl "http://$SERVICE_HOST:8080/v1/AUTH_\$(tenant_id)s"
    fi
fi