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

# Install an "app-of-apps" - https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
waitfor default crd applications.argoproj.io
kubectl wait crd/applications.argoproj.io --for=condition=Established --timeout=1m
kubectl apply -f - <<- EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: applications
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${REPOSITORY}
    path: demo/applications
    targetRevision: HEAD
  destination:
    name: hostcluster
    namespace: default
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

# https://dev.to/asizikov/using-github-container-registry-with-kubernetes-38fb
DOCKER_CONFIG_AUTH=$(echo -n "${GITHUB_USERNAME}:${GITHUB_TOKEN}" | base64 | perl -pe 's/(.*)/{"auths":{"ghcr.io":{"auth":"$1"}}}/' | base64)
kubectl apply -f - <<- EOF
  apiVersion: v1
  kind: Secret
  type: kubernetes.io/dockerconfigjson
  metadata:
    name: dockerconfigjson-github-com
  data:
    .dockerconfigjson: ${DOCKER_CONFIG_AUTH}
EOF

# At this point in the original demo, AWS and Azure secrets were created

waitfor argocd secret argocd-initial-admin-secret
ARGO_INITIAL_PASSWORD=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

# configure vault
# (This part is _not_ idempotent. I'd love to make it so; but for now, if you run into issues while creating, delete the vault pod before retrying)
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

# Enable GitHub OIDC in Vault
# https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-hashicorp-vault
kubectl -n vault exec -i vault-0 -- vault auth enable jwt
kubectl -n vault exec -i vault-0 -- vault write auth/jwt/config \
        bound_issuer="https://token.actions.githubusercontent.com" \
        oidc_discovery_url="https://token.actions.githubusercontent.com"
# Creation of an application (by Backstage) will also create the Vault role which is accessible by actions for that repo.

# TODO - obviously this is less-than-secure! :P
# Cannot use `...vault create token -field token` because that results in some (awkwardly invisible!) control characters
# in the response
VAULT_ROOT_TOKEN=$(kubectl exec -n vault -it vault-0 -- vault token create | grep '^token\s' | awk '{print $2}' | sed 's/\r//')

# Install Vault Provider
# TODO - this is not technically idempotent if there is an issue while applying - the downloaded zip file, and
# partially-extracted directory, will not be cleaned up.
curl -sL -o provider-vault.zip "https://github.com/upbound/provider-vault/archive/refs/heads/main.zip"

unzip -j provider-vault.zip "provider-vault-main/package/crds/*" -d "vault-crds"
rm provider-vault.zip
kubectl apply -f vault-crds
rm -r vault-crds

# Taken from https://github.com/upbound/provider-vault/blob/main/examples/providerconfig/secret.yaml.tmpl
kubectl apply -f - <<-EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-creds-for-crossplane-provider
  namespace: vault
type: Opaque
stringData:
  credentials: |
    {
      "token_name": "vault-creds-test-token",
      "token": "${VAULT_ROOT_TOKEN}"
    }
EOF

kubectl apply -f - <<- EOF
apiVersion: vault.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: vault-provider-config
spec:
  address: http://vault.vault.svc.cluster.local:8200
  credentials:
    source: Secret
    secretRef:
      name: vault-creds-for-crossplane-provider
      namespace: vault
      key: credentials
EOF

cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-vault
spec:
  package: xpkg.upbound.io/upbound/provider-vault:v0.1.0
EOF

# Not strictly necessary, but these [Composition Functions](https://docs.crossplane.io/latest/concepts/composition-functions/#install-a-composition-function)
# allow parametrization of a Composition Resource based on input parameters
kubectl apply -f - <<- EOF
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-go-templating
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-go-templating:v0.3.0
EOF

kubectl apply -f - <<- EOF
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-auto-ready
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.2.1
EOF

# The ClusterRole that is created by the standard installation is missing some permissions, resulting in error messages
# logs from the Vault Provider
kubectl apply -f - <<- EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: extra-permissions-for-vault-provider-cluster-role
rules:
- apiGroups: ["identity.vault.upbound.io"]
  resources: ["groupmemberentityidsidses", "groupmembergroupidsidses", "mfaoktas"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["mfa.vault.upbound.io"]
  resources: ["oktas"]
  verbs: ["get", "watch", "list"]
EOF
VAULT_PROVIDER_SA=$(kubectl -n crossplane-system get sa | grep 'provider-vault' | awk '{print $1}')
while :
do
  if [[ -z "$VAULT_PROVIDER_SA" ]]; then
    echo "Waiting for crossplane-system Service Account to be created..."
    sleep 1
    VAULT_PROVIDER_SA=$(kubectl -n crossplane-system get sa | grep 'provider-vault' | awk '{print $1}')
  else
    break
  fi
done
kubectl apply -f - <<- EOF
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: extra-permissions-for-vault-provider
subjects:
- kind: ServiceAccount
  name: ${VAULT_PROVIDER_SA}
  namespace: crossplane-system
roleRef:
  kind: ClusterRole
  name: extra-permissions-for-vault-provider-cluster-role
  apiGroup: rbac.authorization.k8s.io
EOF

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
Vault: https://vault-7f000001.nip.io
  Token: ${VAULT_ROOT_TOKEN}
"

echo ""
echo "
(You probably also want to \`export VAULT_ADDR=https://vault-7f000001.nip.io; export VAULT_SKIP_VERIFY=true\`)
"
