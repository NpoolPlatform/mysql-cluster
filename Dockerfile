FROM mysql:8.0.44-debian

ARG all_proxy
ARG https_proxy
ARG http_proxy

RUN mkdir -p /usr/local/bin
RUN mv /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint-inner.sh

# RUN gpg --keyserver keyserver.ubuntu.com --recv-keys 467B942D3A79BD29
# RUN gpg --export --armor 467B942D3A79BD29 | apt-key add -
# RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-keys B7B3B788A8D3785C
RUN apt-get update -y
RUN apt-get install debian-archive-keyring -y
RUN apt-get update -y
RUN apt --fix-broken install -y
RUN apt-get update -y
RUN apt-get install curl net-tools lsb-release apt-utils jq -y

RUN all_proxy=$all_proxy https_proxy=$https_proxy http_proxy=$http_proxy curl -o /usr/local/bin/pmm2-client_2.37.0-6.buster_amd64.deb https://downloads.percona.com/downloads/pmm2/2.37.0/binary/debian/buster/x86_64/pmm2-client_2.37.0-6.buster_amd64.deb
RUN all_proxy=$all_proxy https_proxy=$https_proxy http_proxy=$http_proxy curl -o /usr/local/bin/percona-release_latest.$(lsb_release -sc)_all.deb https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb
RUN dpkg -i /usr/local/bin/pmm2-client_2.37.0-6.buster_amd64.deb
RUN dpkg -i /usr/local/bin/percona-release_latest.$(lsb_release -sc)_all.deb
RUN percona-release enable-only tools release
RUN all_proxy=$all_proxy apt-get update -y
RUN all_proxy=$all_proxy https_proxy=$https_proxy http_proxy=$http_proxy apt install percona-xtrabackup-24 -y
RUN all_proxy=$all_proxy https_proxy=$https_proxy http_proxy=$http_proxy apt install qpress -y

COPY .docker-tmp/consul /usr/bin/consul
COPY docker-entrypoint.sh /usr/local/bin
RUN chmod a+x /usr/local/bin/docker-entrypoint.sh
