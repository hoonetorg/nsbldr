# nsbldr image: Ansible + content for desktop/network automation and for configuring
# automation platforms (AAP / AWX / Ascender). Built on an execution environment image and
# keeps its entrypoint, user and ansible-runner, so the same image also works as EE in a platform.
ARG BASE_IMAGE=ghcr.io/ctrliq/ascender-ee:25.6.2
FROM ${BASE_IMAGE}

# kubectl: keep within +-1 minor version of the clusters you talk to
ARG KUBECTL_VERSION=1.37.2
ARG KUBECTL_SHA256=c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4
ARG OC_VERSION=4.22.18
ARG OC_SHA256=3255cddb8b32800ec3aa2a414204e7e284b7cbfeda0e8e4348a31ba0ee286c4e

USER root

COPY requirements/ /tmp/req/

RUN dnf -y install rsync openssh-clients \
 && dnf clean all \
 && python3 -m pip install --no-cache-dir -r /tmp/req/requirements.txt \
 && ansible-galaxy collection install -p /usr/share/ansible/collections -r /tmp/req/collections.yml \
 && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && echo "${KUBECTL_SHA256}  /usr/local/bin/kubectl" | sha256sum -c - \
 && curl -fsSLo /tmp/oc.tgz "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux-amd64-rhel9-${OC_VERSION}.tar.gz" \
 && echo "${OC_SHA256}  /tmp/oc.tgz" | sha256sum -c - \
 && tar -xzf /tmp/oc.tgz -C /usr/local/bin oc \
 && chmod 755 /usr/local/bin/kubectl /usr/local/bin/oc \
 && rm -rf /tmp/req /tmp/oc.tgz

# AAP's own CLI (automation-controller-cli, needs an AAP subscription/repo) - optional:
# put the RPM into requirements/ and enable
# RUN dnf -y install /tmp/req/automation-controller-cli-*.rpm && dnf clean all

RUN mkdir -p /nsbldr
COPY src/ansible.cfg /nsbldr/ansible.cfg
COPY src/nsbldr src/nsbldr-init src/ctlenv /usr/local/bin/
RUN chmod 755 /usr/local/bin/nsbldr /usr/local/bin/nsbldr-init /usr/local/bin/ctlenv

# back to the EE's user; ENTRYPOINT, CMD and WORKDIR of the EE are kept.
# cnsbldr runs the container with --user=root and --entrypoint (default ansible-playbook).
USER 1000
