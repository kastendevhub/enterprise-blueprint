ARG KASTEN_VERSION=8.0.2
FROM gcr.io/kasten-images/kanister-tools:${KASTEN_VERSION}

ARG HELM_VERSION=3.7.1
ARG KUBECTL_VERSION=1.32.0

USER root

RUN microdnf install -y \
    tar \
    jq \
    findutils \
    nc \
    && microdnf clean all \
    && curl -LO "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && curl -LO "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
    && tar -zxvf "helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
    && mv linux-amd64/helm /usr/local/bin/helm \
    && rm -rf linux-amd64 helm-v${HELM_VERSION}-linux-amd64.tar.gz \
    && curl -LO "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz" \
    && tar -xzf openshift-client-linux.tar.gz \
    && mv oc /usr/local/bin/oc \    
    && rm -f openshift-client-linux.tar.gz README.md \
    && curl -LO https://github.com/IBM/cpd-cli/releases/download/v14.1.3/cpd-cli-linux-EE-14.1.3.tgz \
    && tar -xzf cpd-cli-linux-EE-14.1.3.tgz \
    && rm cpd-cli-linux-EE-14.1.3.tgz 

ENV PATH=/cpd-cli-linux-EE-14.1.3-1968:/cpd-cli-linux-EE-14.1.3-1968/plugins/lib/linux:$PATH
        
COPY --chmod=755 cpd-kasten-script /cpd-kasten-script

USER 1001

ENTRYPOINT ["/bin/sh"]