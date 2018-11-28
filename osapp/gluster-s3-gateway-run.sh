#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly DEFAULT_HEKETI_CLI_SERVER="http://heketi-storage.glusterfs.svc.cluster.local:8080"

KS_SERVICE_PORT="${KS_SERVICE_PORT:-35357}"
KS_AUTH_PORT="${KS_AUTH_PORT:-5000}"
REGION="${REGION:-US}"
OBJECT_SERVICE_URI='http://localhost:8080/v1/AUTH_$(tenant_id)s'
VOLUME_SIZE="${VOLUME_SIZE:-50}"
HEKETI_CLI_USER="${HEKETI_CLI_USER:-admin}"
HEKETI_CLI_SERVER="${HEKETI_CLI_SERVER:-$DEFAULT_HEKETI_CLI_SERVER}"
MYSQL_HOST=""

readonly USAGE="$(basename "${BASH_SOURCE[0]}") [-hn]

Options:
  -h   Show this message and exit.
  -n   Do not setup gluster volume with heketi."

function oskeystoneset() {
    openstack-config --set /etc/keystone/keystone.conf "$@"
}

function die() {
    echo "$@" >&2
    exit 1
}

function setup_env() {
    [[ -z "${MYSQL_ADMIN_PASS:-}" ]]        && MYSQL_ADMIN_PASS="$(openssl rand -hex 10)"
    [[ -z "${KEYSTONE_BOOTSTRAP_PASS:-}" ]] && KEYSTONE_BOOTSTRAP_PASS="$(openssl rand -hex 10)"
    [[ -z "${KEYSTONEDB_PASS:-}" ]]         && KEYSTONEDB_PASS="$(openssl rand -hex 10)"
    [[ -z "${SWIFT_USER_PASS:-}" ]]         && SWIFT_USER_PASS="$(openssl rand -hex 10)"

    SWIFT_USER_NAME="${SWIFT_USER_NAME:-swiftadmin}"

    # aka TENANT_NAME
    PROJECT_NAME="${PROJECT_NAME:-admin}"
}

function setup_mysql() {
    [[ -n "${MYSQL_HOST:-}" ]] && return 0
    if [[ -n "${GLUSTER_S3_GATEWAY_DB_PORT:-}" ]]; then
        MYSQL_HOST="${GLUSTER_S3_GATEWAY_DB_PORT##*://}"
        return 0
    fi

    rpm -q  mariadb-server >/dev/null 2>&1 || yum install -y mariadb-server
    systemctl start mariadb     # wait for mariadb to come up
    if ! systemctl is-active mariadb; then
        echo "mariadb failed to start" >&2
        exit 1
    fi
    mysqladmin --user=root password "${MYSQL_ADMIN_PASS}"
    mysql -p"${MYSQL_ADMIN_PASS}" -h "${MYSQL_HOST}" --execute="CREATE DATABASE keystone"
    mysql -p"${MYSQL_ADMIN_PASS}" -h "${MYSQL_HOST}" --execute="GRANT ALL PRIVILEGES \
        ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${KEYSTONEDB_PASS}'"
    mysql -p"${MYSQL_ADMIN_PASS}" -h "${MYSQL_HOST}" --execute="GRANT ALL PRIVILEGES \
        ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${KEYSTONEDB_PASS}'"
    MYSQL_HOST=localhost
}

function setup_keystone() {
    oskeystoneset database connection \
        "mysql+pymysql://keystone:${KEYSTONEDB_PASS}@${MYSQL_HOST}/keystone"
    oskeystoneset token provider fernet
    oskeystoneset signing token_format UUID
    # TODO remove
    oskeystoneset DEFAULT insecure_debug true
    oskeystoneset DEFAULT debug true

    su -s /bin/sh -c "keystone-manage db_sync" keystone

    keystone-manage fernet_setup     --keystone-user keystone --keystone-group keystone
    keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
    keystone-manage bootstrap \
        --bootstrap-password        "${KEYSTONE_BOOTSTRAP_PASS}" \
        --bootstrap-admin-url       http://localhost:${KS_SERVICE_PORT}/v3 \
        --bootstrap-internal-url    http://localhost:5000/v3 \
        --bootstrap-public-url      http://localhost:5000/v3 \
        --bootstrap-region-id       "${REGION}"
    ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/
    sed -i 's/^#\?\s*ServerName\>.*/ServerName localhost/' /etc/httpd/conf/httpd.conf

    systemctl enable httpd
    systemctl restart httpd
}

function setup_openstack() {
    osproxyset filter:authtoken auth_url            "http://localhost:${KS_SERVICE_PORT}"
    osproxyset filter:authtoken username            "admin"
    osproxyset filter:authtoken password            "${KEYSTONE_BOOTSTRAP_PASS}"
    osproxyset filter:authtoken project_domain_id   "default"
    osproxyset filter:authtoken user_domain_id      "default"
    osproxyset filter:authtoken project_name        "${PROJECT_NAME}"
    osproxyset filter:s3token   auth_uri            "http://localhost:${KS_SERVICE_PORT}"
    osproxyset filter:s3token   project_domain_id   'default';
    osproxyset filter:s3token   user_domain_id      'default';
    osproxyset filter:s3token   project_name        "${PROJECT_NAME}";
    osproxyset filter:s3token   username            'admin';
    osproxyset filter:s3token   password            "${KEYSTONE_BOOTSTRAP_PASS}";

    # unset some conflicting variables
    for var in admin_tenant_name admin_user admin_password uth_host auth_port auth_protocol; do
        openstack-config --del /etc/swift/proxy-server.conf "$var"
    done

    chown -R swift:swift /etc/swift
    chmod -R 0700 /etc/swift

    (
        echo export OS_USERNAME=admin
        echo export OS_PASSWORD="${KEYSTONE_BOOTSTRAP_PASS}"
        echo export OS_PROJECT_NAME="${PROJECT_NAME}"
        echo export OS_USER_DOMAIN_NAME=Default
        echo export OS_PROJECT_DOMAIN_NAME=Default
        echo export OS_AUTH_URL="http://localhost:${KS_AUTH_PORT}/v3"
        echo export OS_IDENTITY_API_VERSION=3
    ) > ~/.openstack_admin_auth.env.sh

    . ~/.openstack_admin_auth.env.sh

    local interface role

    openstack service create --name=swift --description "Swift Service" object-store
    for interface in admin public internal; do
        openstack endpoint create --region "${REGION}" swift "$interface" "${OBJECT_SERVICE_URI}"
    done
    for role in KeystoneServiceAdmin KeystoneAdmin member; do
        openstack role create "$role"
        openstack role add --user "${OS_USERNAME}" --project "${OS_PROJECT_NAME}" "$role"
    done

    #openstack project create --description "Swift S3 Project" "${PROJECT_NAME}"
    openstack user create --password "${SWIFT_USER_PASS}" "${SWIFT_USER_NAME}"
    openstack role add --project "${OS_PROJECT_NAME}" --user "${SWIFT_USER_NAME}" admin
    openstack ec2 credentials create --project "${OS_PROJECT_NAME}" --user "${SWIFT_USER_NAME}"

    export AWS_ACCESS_KEY_ID="$(openstack ec2 credentials list \
        --user "${SWIFT_USER_NAME}" -f json | jq -r '.[0].Access')"
    export AWS_SECRET_ACCESS_KEY="$(openstack ec2 credentials list \
        --user "${SWIFT_USER_NAME}" -f json | jq -r '.[0].Secret')"
    (
        echo export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
        echo export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
    ) >> ~/.bashrc
}

function setup_gluster_volume() {
    ADMIN_ID="$(openstack project show -f json admin | jq -r '.id')"
    [[ -z "${ADMIN_ID}" ]] && die "Could not determine id of the admin project!"

    if [[ -z "${HEKETI_CLI_SERVER:-}" || -z "${HEKETI_CLI_KEY:-}" ]]; then
        echo "One of HEKETI_CLI_SERVER, HEKETI_CLI_KEY is not set!"
        echo "Please setup gluster volume manually with the following commands:"
        echo ""
        echo "    heketi-cli -s $DEFAULT_HEKETI_CLI_SERVER --user admin \\"
        echo "        --secret \$HEKETI_CLI_KEY \\"
        echo "        volume create --size=$VOLUME_SIZE --name $ADMIN_ID $ADMIN_ID"
    else
        export HEKETI_CLI_SERVER HEKETI_CLI_USER HEKETI_CLI_KEY
        heketi-cli volume create --size="$VOLUME_SIZE" --name "$ADMIN_ID" "$ADMIN_ID"
        echo "Gluster volume '$ADMIN_ID' created for the S3 bucket."
    fi
}

function setup_swift() {
    local project_id="${1:-$ADMIN_ID}"
    pushd /etc/swift
        /usr/bin/gluster-swift-gen-builders "$project_id"
    popd

    # restart keystone
    systemctl restart httpd
    systemctl enable memcached
    systemctl start memcached

    local service
    for service in proxy container account object object-expirer; do
        systemctl enable "openstack-swift-$service"
        systemctl start  "openstack-swift-$service"
    done

    # TODO mount volume in here
    mkdir "/mnt/gluster-object/${ADMIN_ID}"
    chown swift:swift "/mnt/gluster-object/${ADMIN_ID}"
}

function setup_s3cmd() {
    cat >~/.s3cfg <<EOF
[default]
access_key = ${AWS_ACCESS_KEY_ID}
secret_key = ${AWS_SECRET_ACCESS_KEY}
bucket_location = ${REGION}
encrypt = False
host_base = localhost:8080
host_bucket = localhost:8080
signature_v2 = False
signurl_use_https = False
simpledb_host = localhost:8080
use_https = False
EOF
}

function setup_awscli() {
    cat >~/.aws/credentials <<EOF
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
    cat >~/.aws/config <<EOF
[profile default]
region = ${REGION}
s3 =
    endpoint_url = http://localhost:8080
[plugins]
endpoint = awscli_plugin_endpoint
EOF
}

volume_setup=1

while getopts "hn" opt; do
    case "${opt}" in
    h) echo "${USAGE}"; exit 0; ;;
    n) volume_setup=0; ;;
    *)
        echo "See help!" >&2
        exit 1
        ;;
    esac
done

setup_env
setup_mysql
setup_keystone
setup_openstack
[[ "${volume_setup}" == 1 ]] && setup_gluster_volume
setup_swift "$ADMIN_ID"
setup_s3cmd
