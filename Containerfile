FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        python3 \
        ansible \
        ansible-core \
        python3-paramiko \
        openssh-client \
        sshpass \
        sudo \
        git \
        rsync \
        procps \
        iproute2 \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /nsbldr
WORKDIR /nsbldr

COPY src/nsbldr /usr/local/bin/nsbldr
COPY src/ansible.cfg /nsbldr/ansible.cfg
RUN chmod +x /usr/local/bin/nsbldr

#ENTRYPOINT ["/usr/local/bin/nsbldr"]
ENTRYPOINT ["ansible-playbook"]

