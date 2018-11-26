FROM registry.access.redhat.com/rhel7:latest

RUN yum-config-manager \
  --enable rhel-7-server-openstack-13-devtools-rpms \
  --enable rhel-7-server-openstack-13-optools-rpms \
  --enable rhel-7-server-openstack-13-rpms \
  --enable rhel-7-server-openstack-13-tools-rpms \
  --enable rhel-7-server-extras-rpms \
  --enable rh-gluster-3-client-for-rhel-7-server-rpms

RUN yum install -y httpd python2-openstackclient iproute \
        python2-swiftclient mod_wsgi mariadb mariadb-server \
        openstack-keystone openstack-utils openstack-swift-proxy \
        openstack-swift-account openstack-swift-container \
        openstack-swift-object openstack-swift-plugin-swift3 \
        python-keystoneclient heketi-client jq memcached #; yum clean all

# s3curl dependencies
RUN yum install -y libxml2 perl-Digest-HMAC unzip
RUN \
  tmp="$(mktemp -d)"; cd "${tmp}"; \
  curl -L -O http://s3.amazonaws.com/doc/s3-example-code/s3-curl.zip; \
  unzip s3-curl.zip; \
  sed -i -e '/^\(my \)\?@endpoints\s*=\s*/,/;/s/^/#/' -e "/^#\(my \)\?@endpoints/i \
my @endpoints = ( 'http://localhost:8080', );" "s3-curl/s3curl.pl"; \
  install -m 0755 "s3-curl/s3curl.pl" /usr/local/bin/s3curl.pl; \
  cd -; rm -rf "${tmp}";

# install s3cmd
RUN yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm; \
  yum install -y s3cmd

# install awscli
RUN yum-config-manager --enable 'rhel-server-rhscl-7-rpms'; \
  yum install -y python27; \
  scl enable python27 'pip install awscli awscli-plugin-endpoint'

# swiftonfile dependencies
RUN yum install -y --enablerepo=rh-gluster-3-for-rhel-7-server-rpms\
         python-gluster python-scandir
# swiftonfile expects openstack-swift rpms of version 2.10 which is much older
# then available in openstack-13 repositories
RUN yumdownloader -t -y --enablerepo=rh-gluster-3-for-rhel-7-server-rpms \
                swiftonfile && \
        rpm -Uvh --replacefiles --nodeps swiftonfile-*.noarch.rpm && \
        rm -fv swiftonfile-*.noarch.rpm

# TODO: remove
RUN yum install -y vim less tcpdump
ENV EDITOR=vim

RUN systemctl enable mariadb httpd

COPY gluster-s3-gateway-run.sh /run.sh
RUN chmod +x /run.sh

ENV KS_SERVICE_PORT=35357
ENV KS_AUTH_PORT=5000

# configure osproxy
RUN echo -e '#!/bin/bash\nopenstack-config --set "$@"' \
    > /usr/local/bin/osset; chmod +x /usr/local/bin/osset;
RUN echo -e '#!/bin/bash\nopenstack-config --set /etc/swift/proxy-server.conf "$@"' \
    > /usr/local/bin/osproxyset; chmod +x /usr/local/bin/osproxyset;
RUN \
  osproxyset pipeline:main            pipeline      "catch_errors gatekeeper healthcheck proxy-logging cache bulk tempurl ratelimit authtoken swift3 s3token keystone copy container-quotas account-quotas slo dlo versioned_writes proxy-logging proxy-server"; \
  osproxyset DEFAULT          log_level                     DEBUG;                \
  osproxyset DEFAULT          workers                       2;                    \
  osproxyset filter:keystone  operator_roles                'admin, swiftoperator'; \
  osproxyset filter:authtoken signing_dir                   /etc/swift;           \
  osproxyset filter:authtoken delay_auth_decision           True;                 \
  osproxyset filter:authtoken include_service_catalog       False;                \
  osproxyset filter:authtoken auth_plugin                   password;             \
  osproxyset filter:authtoken cache                         swift.cache;          \
  osproxyset app:proxy-server allow_account_management      False;                \
  osproxyset app:proxy-server auto_create_account_prefix    gs;                   \
  osproxyset app:proxy-server expiring_objects_account_name expiring;             \
  osproxyset filter:swift3    use                           'egg:swift3#swift3';  \
  osproxyset filter:s3token   use                           'egg:swift3#s3token'; \
  osproxyset filter:s3token   reseller_prefix               'AUTH_';              \
  osproxyset filter:s3token   delay_auth_decision           'False';              \
  osproxyset filter:s3token   auth_version                  '3';                  \
  osproxyset filter:s3token   http_timeout                  '10.0';               \
  osproxyset filter:s3token   log_level                     'DEBUG';              \
  osproxyset filter:s3token   insecure                      'True';               \
  osset /etc/swift/account-server.conf   DEFAULT            bind_port                  6012;                        \
  osset /etc/swift/account-server.conf   DEFAULT            devices                    /mnt/gluster-object;         \
  osset /etc/swift/account-server.conf   DEFAULT            mount_check                false;                       \
  osset /etc/swift/account-server.conf   DEFAULT            disable_fallocate          true;                        \
  osset /etc/swift/account-server.conf   DEFAULT            workers                    1;                           \
  osset /etc/swift/account-server.conf   app:account-server use                        'egg:gluster_swift#account'; \
  osset /etc/swift/account-server.conf   app:account-server auto_create_account_prefix gs;                          \
  osset /etc/swift/object-server.conf    DEFAULT            bind_port                  6010;                        \
  osset /etc/swift/object-server.conf    DEFAULT            devices                    /mnt/gluster-object;         \
  osset /etc/swift/object-server.conf    DEFAULT            mount_check                false;                       \
  osset /etc/swift/object-server.conf    DEFAULT            disable_fallocate          true;                        \
  osset /etc/swift/object-server.conf    DEFAULT            workers                    1;                           \
  osset /etc/swift/object-server.conf    app:object-server  use                        'egg:gluster_swift#object';  \
  osset /etc/swift/object-server.conf    app:object-server  auto_create_object_prefix  gs;                          \
  osset /etc/swift/container-server.conf DEFAULT            bind_port                  6011;                        \
  osset /etc/swift/container-server.conf DEFAULT            devices                    /mnt/gluster-object;         \
  osset /etc/swift/container-server.conf DEFAULT            mount_check                false;                       \
  osset /etc/swift/container-server.conf DEFAULT            disable_fallocate          true;                        \
  osset /etc/swift/container-server.conf DEFAULT            workers                    1;                           \
  osset /etc/swift/container-server.conf app:object-server  use                        'egg:gluster_swift#object';  \
  osset /etc/swift/container-server.conf app:object-server  auto_create_object_prefix  gs;

RUN mkdir /mnt/gluster-object && chown swift:swift /mnt/gluster-object
 
  #osproxyset filter:keystone               is:admin                True;                  \
  #osproxyset filter:keystone use 'egg:swift#keystoneauth'; \
  #osproxyset filter:authtoken paste.filter_factory 'keystoneclient.middleware.auth_token:filter_factory'; \
  #osproxyset filter:authtoken auth_uri "http://localhost:${KS_SERVICE_PORT}/v3"; \
  #osproxyset DEFAULT log_name proxy_server; \
  
CMD ["/sbin/init"]
