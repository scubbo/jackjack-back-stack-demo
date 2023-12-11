# How to run this yourself

* Fork this repository
* Create a `.env` file containing:

```
REPOSITORY=https://github.com/<path_to_forked_repository>
GITHUB_TOKEN=<Personal Access Token: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-personal-access-token-classic>
VAULT_TOKEN=root # default for 'dev' mode
```

(TBD what scopes the token needs - not outlined in the [original source repo](https://github.com/crossplane-contrib/back-stack). For now, I've granted none. If you want to create a repo with a GitHub workflow - as you would under the [Full End-to-End demo](#full-end-to-end-demo---create-a-legalzoom-ish-application-from-backstage-deploy-with-argocd-build-in-gha-using-credentials-created-in-vault-from-crossplane) - you will need to grant the `workflow` scope. If you want to push images to ghcr.io - as, again, is done in the End-to-end demo - you'll also need `write:packages`)

* `./install.sh`. Script _should_ be idempotent (i.e. you can re-run it after identifying and fixing an issue), but no promises :P use `./teardown.sh` to start from scratch.

# How this works

The `install.sh` script does the following:

* Use `kind` to create a cluster
* Use `helm` to install Crossplane to the cluster
* Using Crossplane (via a [Configuration](https://docs.crossplane.io/latest/concepts/packages/)), install BackStack CRDs
* Use `kubectl` to install some [Providers](https://docs.crossplane.io/latest/concepts/providers/) - the interfaces which let Crossplane manage non-k8s resources
* Install an instance of a Hub - a BackStack CRD which references a `REPOSITORY` (this one! Or, rather - your forked version of this one!) to know
  * This is why this repository contains directories named `argocd`, `backstage`, `crossplane`, and `kyverno` - these are the definitions for how those applications should be installed onto the cluster _via_ the Hub CRD.

Once everything's installed (which takes about 7-10 minutes), the following steps provide a pretty good Proof Of Concept of how the BACK stack works:

## Show that things exist

* Log in to ArgoCD with the provided URL and credentials
  * The `clusters` application comes pre-bundled with the demo BACK stack I was working from. The original demo showed how easy it was to create AKS/EKS clusters via Crossplane, but we're not interested in that functionality right now.
* Navigate to Backstage, wait until the Catalog shows objects populated (should be 4 of them, one for each element of the BACK stack)
  * (This can take about 10 minutes - better to do this in-advance if you're planning a demo)

## Creating a new application

### Creating a new application from external definition

(If you have been linked to this page from a StackOverflow question or a GitHub issue, you can skip this section)

* In Backstage, navigate to "[Create](https://backstage-7f000001.nip.io/create)", and choose "New Application Deployment"
* Fill out the metadata:
  * Application Source: `https://github.com/danielhelfand/examples`
   (the guestbook examples from both `https://github.com/kubernetes/examples` and `https://github.com/argoproj/argocd-example-apps/` are broken - see [here](https://github.com/argoproj/argocd-example-apps/issues/126) for the latter), and the former relies on an unavailable image `gcr.io/google-samples/gb-frontend:v4`
  * Path: `guestbook/all-in-one`
  * Click "Next"
* Fill out the next set of metadata:
  * "Owner" and "Repository" should be your forked version of this repository - e.g. for me it was `scubbo/jackjack-back-stack-demo`
    * Note that the labelling is misleading - the label under "Host" reads "_The host where the repository will be created_", but a repository is only being updated (actually, not even that - a PR created), not created
  * Click "Review", then "Create"
* Once Creation is complete, click through to the Pull Request, and Merge it
* The Argo Applications screen should now show an `applications` app. Click into it, and click "Sync" at the top of the page - everything should go Green
* Click into the sub-application (named whatever you entered as the name of your Application at the beginning of this section), and Sync - again, everything should (shortly) go green.
* You _could_ set up an Ingress to provide access to the application, but for a demo it's simpler just to port-forward: `kubectl -n default port-forward service/frontend 8080:80` - then in your browser, navigate to `localhost:8080`

### Creating an external resource with Crossplane

First, demonstrate creation of a Vault Policy directly:

```
$ kubectl -n vault exec -t vault-0 -- vault policy list
crossplane
default
root

$ kubectl apply -f - <<- EOF
apiVersion: vault.vault.upbound.io/v1alpha1
kind: Policy
metadata:
  name: vault-policy-created-by-crossplane
spec:
  forProvider:
    name: dev-team
    policy: |
      path "secret/my_app" {
        capabilities = ["update"]
      }
  providerConfigRef:
    name: vault-provider-config
EOF

$ kubectl -n vault exec -t vault-0 -- vault policy list
crossplane
default
dev-team
root
```

(Note that if you delete the Vault policy with the `vault` CLI, it will be recreated shortly afterwards as Kubernetes carries out reconciliation!)

### Creating Composite Resources with Crossplane

(Terminology note - a `Composition` is a template for the creation of `Composite Resources`, the latter of which are "_set[s] of provisioned managed resources_". A `CompositeResourceDefinition` is a definition of the schema used for requesting a `Composite Resource` - i.e. what parameters can be passed. The diagram [here](https://docs.crossplane.io/latest/concepts/composite-resources/#creating-composite-resources) is very helpful)

Create a [CompositeResourceDefinition](https://docs.crossplane.io/latest/concepts/composite-resource-definitions/) and a [Composition](https://docs.crossplane.io/latest/concepts/compositions/) (see [here](https://github.com/crossplane-contrib/function-go-templating) for discussion of the templating language):

```
$ kubectl apply -f -<<- EOF
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xapplicationvaultpolicies.crossplane-demo.legalzoom.com
spec:
  group: crossplane-demo.legalzoom.com
  names:
    kind: XApplicationVaultPolicy
    plural: xapplicationvaultpolicies
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                serviceName:
                  type: string
---
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: vault-policy-example
spec:
  compositeTypeRef:
    apiVersion: crossplane-demo.legalzoom.com/v1alpha1
    kind: XApplicationVaultPolicy
  mode: Pipeline
  pipeline:
    - step: create-policies
      functionRef:
        name: function-go-templating
      input:
        apiVersion: gotemplating.fn.crossplane.io/v1beta1
        kind: GoTemplate
        source: Inline
        inline:
          template: |
            apiVersion: vault.vault.upbound.io/v1alpha1
            kind: Policy
            metadata:
              annotations:
                gotemplating.fn.crossplane.io/composition-resource-name: dev-team-policy
            spec:
              forProvider:
                name: "dev-team-policy-for-{{ .observed.composite.resource.spec.serviceName }}"
                policy: "path \"secret/{{- .observed.composite.resource.spec.serviceName -}}\" { capabilities = [\"update\", \"read\"] }"
              providerConfigRef:
                name: vault-provider-config
            ---
            apiVersion: vault.vault.upbound.io/v1alpha1
            kind: Policy
            metadata:
              annotations:
                gotemplating.fn.crossplane.io/composition-resource-name: security-team-policy
            spec:
              forProvider:
                name: "security-team-policy-for-{{ .observed.composite.resource.spec.serviceName }}"
                policy: "path \"secret/{{- .observed.composite.resource.spec.serviceName -}}\" { capabilities = [\"update\",\"list\",\"delete\"] }"
              providerConfigRef:
                name: vault-provider-config
    - step: automatically-detect-ready-composed-resources
      functionRef:
        name: function-auto-ready
EOF
```

(Note that `spec.compositeTypeRef.apiVersion` and `spec.compositeTypeRef.kind` in the Composition must match the `spec.group`/`spec.versions[n].name` and `spec.names.kind` in the CompositeResourceDefinition. See documentation [here](https://docs.crossplane.io/latest/concepts/composite-resources/#creating-composite-resources): "_When a user calls the custom API, [...]Crossplane chooses the Composition to use based on the Composition’s compositeTypeRef_")

Now create a Composite Resource ("XR") from that Composition:

```
$ kubectl apply -f - <<- EOF
apiVersion: crossplane-demo.legalzoom.com/v1alpha1
kind: XApplicationVaultPolicy
metadata:
  name: application-vault-policy-for-service-1
spec:
  serviceName: my-service-1
EOF
```

And demonstrate that the approprate policies were created:

```
$ vault policy list
...
dev-team-policy-for-my-service-1
security-team-policy-for-my-service-1
...
```

Next, try updating the Composition to define the policies differently (e.g. consider changing the capabilities of one of the policies), and demonstrate that the policies change to match.

# Full End-to-end demo - create a LegalZoom(-ish) application from Backstage, deploy with ArgoCD, build in GHA using credentials created in Vault from Crossplane

## Create XRD and Composition to manage Vault bundles

```
$ kubectl apply -f - <<- EOF
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xapplicationvaultbundles.crossplane-demo.legalzoom.com
spec:
  group: crossplane-demo.legalzoom.com
  names:
    kind: XApplicationVaultBundle
    plural: xapplicationvaultbundles
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                owner:
                  type: string
                serviceName:
                  type: string
---
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: vault-bundles-example
spec:
  compositeTypeRef:
    apiVersion: crossplane-demo.legalzoom.com/v1alpha1
    kind: XApplicationVaultBundle
  resources:
    - name: Policy
      base:
        apiVersion: vault.vault.upbound.io/v1alpha1
        kind: Policy
        spec:
          providerConfigRef:
            name: vault-provider-config
      patches:
        - type: CombineFromComposite
          combine:
            variables:
              - fromFieldPath: spec.owner
              - fromFieldPath: spec.serviceName
            strategy: string
            string:
              fmt: "%s-%s-gha-policy"
          toFieldPath: "spec.forProvider.name"
        - type: CombineFromComposite
          combine:
            variables:
              - fromFieldPath: spec.owner
              - fromFieldPath: spec.serviceName
            strategy: string
            string:
              fmt: "path \"static-kv/data/github-pat/%s-%s\" { capabilities = [\"list\"] }"
          toFieldPath: "spec.forProvider.policy"
    - name: Role
      base:
        apiVersion: jwt.vault.upbound.io/v1alpha1
        kind: AuthBackendRole
        spec:
          forProvider:
            roleType: "jwt"
            userClaim: "workflow"
            tokenPolicies:
              - "{{ .observed.composite.resource.spec.owner }}-{{ .observed.composite.resource.spec.serviceName }}-gha"
            tokenMaxTtl: 3600
          providerConfigRef:
            name: vault-provider-config
      patches:
        - type: CombineFromComposite
          combine:
            variables:
              - fromFieldPath: spec.owner
              - fromFieldPath: spec.serviceName
            strategy: string
            string:
              fmt: "%s-%s"
          toFieldPath: "spec.forProvider.roleName"
        - type: CombineFromComposite
          combine:
            variables:
              - fromFieldPath: spec.owner
              - fromFieldPath: spec.serviceName
            strategy: string
            string:
              fmt: "%s/%s-app"
          toFieldPath: "spec.forProvider.boundClaims.repository"
        - type: CombineFromComposite
          combine:
            variables:
              - fromFieldPath: spec.owner
              - fromFieldPath: spec.serviceName
            strategy: string
            string:
              fmt: "%s-%s-gha-policy"
          toFieldPath: "spec.forProvider.tokenPolicies[0]"
EOF
```

(Note - the above _intentionally_ contains a typo, so that we can demonstrate the Composite-update-cascade functionality after creation. If you want to create it correctly from the start - note that the `capabilities` for `static-kv/data/github-pat/%s-%s` only provide `list`, not `read`)

## Manually configure Vault

### Secrets

Create a Vault secret containing the PAT (remember, we expect a `.env` containing `GITHUB_TOKEN`) - in a real productionalized setup, the secret would be provided by a [GitHub App installation](https://github.com/martinbaillie/vault-plugin-secrets-github)

```
# Not idempotent - repeating will give an error!
$ vault secrets enable -version=2 -path=static-kv kv
# (Replace `<owner>` and `<service-name>` with the value you are going to use - do not paste directly!)
$ vault kv put -mount=static-kv github-pat/<owner>-<service-name> token=$(grep 'GITHUB_TOKEN' .env | cut -d'=' -f2)
```

(Note - if you wanted to, you could do the above via Crossplane Vault Provider, too!)

### Accessibility

Set up a DNS name and forwarding so that there is a domain name, publicly-accessible from the Internet, which will point to your local Vault instance. This is so that GitHub Actions can access the Vault Entities that you create.

There is no one-size-fits-all solution to this, but here's what worked for me (run each of these commands in standalone terminal windows, or add ` &` at the end to run them in background mode):

* Port-forward the Vault Service so that it's available on a port on your local machine: `$ kubectl -n vault port-forward svc/vault 8200:8200`
* Use [`devtunnel`](https://harshmatharu.com/blog/share-local-services-quickly-with-dev-tunnels) to make a publicly-available tunnel to your machine's port 8200:

```
$ devtunnel host -p 8200 --protocol http --allow-anonymous
Hosting port: 80
Connect via browser: https://vdnfzt79-80.usw3.devtunnels.ms
Inspect network activity: https://vdnfzt79-80-inspect.usw3.devtunnels.ms

Ready to accept connections for tunnel: swift-dog-4ppm20h
```

(Your output will look different from mine!)

* Check that your setup works - go to the "Connect via browser" link and confirm that you see the Vault UI. Make a note of the address - you'll need it in the next step.

Note that this is, of course, not the most secure solution - tear this down once you're done, especially if you're running this on your home network! (And disconnect yourself from work VPN while doing this)

(I would have loved to get this working via Ingresses, but spent a couple hours tinkering with it to no avail. If you get it working, let me know!)

## Create the application
* Go to [Backstage Create](https://backstage-7f000001.nip.io/create)
* Select "New LegalZoom Application"
* Enter an arbitrary name for "Application Name", and enter the `devtunnel` URL (including scheme `https://`) in "Vault URL"

## Post-creation demo

* Go to the AppCode repo, demonstrate that the initial upload to `ghcr.io` has failed because the Policy has not been created yet
* Go to the PR, approve it, sync the `applications` ArgoCD App, retry the AppCode Action
* Now it will fail because we (intentionally!) created the Composition with the wrong capabilities, to show that an update to a Composition will cascade out to the associated Custom Resources. Use `kubectl edit Composition/vault-bundles-example`, find the appropriate line (44 at the time of writing), and update it - then demonstrate that a. the Vault policy has been updated, and b. the GitHub action (when rerun) succeeds.


# Thanks and acknowledgements

This demo was heavily inspired by, and builds on, [this repo](https://github.com/crossplane-contrib/back-stack) - though I've adapted it heavily to suit my own team's use-cases (in particular, cluster maintainance is not a big concern for us, but definition of Applications' "SDLC Infrastructure" - e.g. the Vault policies which allow GitHub Actions to execute - is). I also made some tweaks to the `install` script to make it idempotent (since I had to re-run a bunch of times to get around issues, and starting up the cluster from scratch each time was a pain!), such as using `kubectl apply` rather than `kubectl create` to create `clusterrolebinding`s and `ProviderConfig`s.
