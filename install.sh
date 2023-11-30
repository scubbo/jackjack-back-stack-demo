#!/bin/bash

########################
# Phase 0 - Preliminaries
#
# Setting up useful functions, options, and constants; ensuring presence of required tools; etc.
########################

set -e

. scripts/common.sh

for tool in "kind" "jq" "helm"
do
  if ! command_exists "$tool"; then
    echo "This script relies on $tool. Install with 'brew install $tool' (assuming you're on Mac)"
    exit 1
  fi
done

CLUSTER_NAME="backstack-demo"

if [[ ! -f ".env" ]]; then
  echo "File \`.env\` not found"
  exit 1
fi
loadenv ./.env

for req_var in "REPOSITORY" "GITHUB_TOKEN"
do
  if [[ -z "${!req_var}" ]]; then
    echo "Missing required variable $req_var. Set it in \`.env\` file"
    exit 1
  fi
done

# TODO - version check of `helm` command:
# https://github.com/crossplane-contrib/back-stack/issues/37

########################
# Phase 1 - Cluster creation and basic installation
########################

if [[ $(kind get clusters | grep -c "$CLUSTER_NAME") -ne 0 ]]; then
  echo "Cluster already exists"
else
  echo "Cluster does not exist, creating"
  kind create cluster --name "$CLUSTER_NAME" --wait 5m --config=- <<- EOF
  kind: Cluster
  apiVersion: kind.x-k8s.io/v1alpha4
  nodes:
  - role: control-plane
    kubeadmConfigPatches:
    - |
      kind: InitConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          node-labels: "ingress-ready=true"
    extraPortMappings:
    - containerPort: 80
      hostPort: 80
      protocol: TCP
    - containerPort: 443
      hostPort: 443
      protocol: TCP
EOF

fi


# configure ingress
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s 

########################
# Phase 2 - Crossplane Installation
########################

# install crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm upgrade --install crossplane \
  --namespace crossplane-system \
  --create-namespace crossplane-stable/crossplane \
  --set args='{--enable-external-secret-stores}' \
  --wait

# install vault ess plugin
helm upgrade --install ess-plugin-vault \
  oci://xpkg.upbound.io/crossplane-contrib/ess-plugin-vault \
  --namespace crossplane-system \
  --set-json podAnnotations='{"vault.hashicorp.com/agent-inject": "true", "vault.hashicorp.com/agent-inject-token": "true", "vault.hashicorp.com/role": "crossplane", "vault.hashicorp.com/agent-run-as-user": "65532"}'

waitfor default crd configurations.pkg.crossplane.io

# install back stack configuration
kubectl apply -f - <<-EOF
    apiVersion: pkg.crossplane.io/v1
    kind: Configuration
    metadata:
      name: back-stack
    spec:
      package: ghcr.io/opendev-ie/back-stack-configuration:v1.0.3
EOF

########################
# Phase 2 - Provider installation
########################

# configure provider-helm for crossplane
waitfor default crd providerconfigs.helm.crossplane.io
kubectl wait crd/providerconfigs.helm.crossplane.io --for=condition=Established --timeout=1m
SA=$(kubectl -n crossplane-system get sa -o name | grep provider-helm | sed -e 's|serviceaccount\/||g')
# Switched this from `kubectl create` (in the original demo) to `kubectl apply`, so that this install script can be idempotent in case of errors
kubectl apply -f - <<-EOF
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: provider-helm-admin-binding
  subjects:
    - kind: ServiceAccount
      name: ${SA}
      namespace: crossplane-system
  roleRef:
    kind: ClusterRole
    name: cluster-admin
    apiGroup: rbac.authorization.k8s.io
EOF
kubectl apply -f - <<- EOF
    apiVersion: helm.crossplane.io/v1beta1
    kind: ProviderConfig
    metadata:
      name: local
    spec:
      credentials:
        source: InjectedIdentity
EOF

# configure provider-kubernetes for crossplane
waitfor default crd providerconfigs.kubernetes.crossplane.io
kubectl wait crd/providerconfigs.kubernetes.crossplane.io --for=condition=Established --timeout=1m
SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed -e 's|serviceaccount\/||g')
while :
do
  # Weirdly, `kubectl wait crd/...` does _not_ actually seem to properly wait for the creation of the service account -
  # the first time this script is run, `SA` is often empty. This loop waits for the value to be populated.
  if [[ -z "$SA" ]]; then
    echo "Waiting for crossplane-system Service Account to be created..."
    sleep 1
    SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed -e 's|serviceaccount\/||g')
  else
    break
  fi
done
kubectl apply -f - <<- EOF
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: provider-kubernetes-admin-binding
  subjects:
    - kind: ServiceAccount
      name: ${SA}
      namespace: crossplane-system
  roleRef:
    kind: ClusterRole
    name: cluster-admin
    apiGroup: rbac.authorization.k8s.io
EOF
kubectl apply  -f - <<- EOF
    apiVersion: kubernetes.crossplane.io/v1alpha1
    kind: ProviderConfig
    metadata:
      name: local
    spec:
      credentials:
        source: InjectedIdentity
EOF

# At this point in the original demo, `provide-aws` and `provider-azure` were installed

########################
# Phase 3 - Hub installation
#
# (In a multi-cluster setup, this would be the main cluster which administrates "spoke" clusters - see diagram at
# https://github.com/crossplane-contrib/back-stack/tree/main. In this simple single-cluster setup, these are the
# components which deploy, reconcile, and monitor Crossplane-managed resources)
########################

waitfor default crd hubs.backstack.cncf.io
kubectl wait crd/hubs.backstack.cncf.io --for=condition=Established --timeout=1m
kubectl apply -f - <<-EOF
    apiVersion: backstack.cncf.io/v1alpha1
    kind: Hub
    metadata:
      name: hub
    spec: 
      parameters:
        clusterId: local
        repository: ${REPOSITORY}
        backstage:
          host: backstage-7f000001.nip.io
        argocd:
          host: argocd-7f000001.nip.io
        vault:
          host: vault-7f000001.nip.io
EOF


########################
# Phase 4 - Secret installation
########################
waitfor default ns argocd
kubectl apply -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: clusters
      namespace: argocd
      labels:
        argocd.argoproj.io/secret-type: repository
    stringData:
      type: git
      url: ${REPOSITORY}
      password: ${GITHUB_TOKEN}
      username: back-stack
EOF

waitfor default ns backstage
kubectl apply -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: backstage
      namespace: backstage
    stringData:
      GITHUB_TOKEN: ${GITHUB_TOKEN}
      VAULT_TOKEN: ${VAULT_TOKEN}
EOF

# At this point in the original demo, AWS and Azure secrets were created

waitfor argocd secret argocd-initial-admin-secret
ARGO_INITIAL_PASSWORD=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

# configure vault
kubectl wait -n vault pod/vault-0 --for=condition=Ready --timeout=1m
kubectl -n vault exec -i vault-0 -- vault auth enable kubernetes
kubectl -n vault exec -i vault-0 -- sh -c 'vault write auth/kubernetes/config \
        token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
kubectl -n vault exec -i vault-0 -- vault policy write crossplane - <<EOF
path "secret/data/*" {
    capabilities = ["create", "read", "update", "delete"]
}
path "secret/metadata/*" {
    capabilities = ["create", "read", "update", "delete"]
}
EOF
kubectl -n vault exec -i vault-0 -- vault write auth/kubernetes/role/crossplane \
    bound_service_account_names="*" \
    bound_service_account_namespaces=crossplane-system \
    policies=crossplane \
    ttl=24h

# restart ess pod
kubectl get -n crossplane-system pods -o name | grep ess-plugin-vault | xargs kubectl delete -n crossplane-system 

# ready to go!
echo ""
echo "
Your BACK Stack is ready!

Backstage: https://backstage-7f000001.nip.io
ArgoCD: https://argocd-7f000001.nip.io
  username: admin
  password ${ARGO_INITIAL_PASSWORD}
"
