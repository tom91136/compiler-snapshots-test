FROM almalinux:8
RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
RUN dnf config-manager --set-enabled powertools
RUN dnf install -y gcc-toolset-14 file bzip2 texinfo flex git jq ninja-build python3-devel cmake3 wget bison automake openssl-devel ccache squashfs-tools