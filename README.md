# How to run this yourself

* Fork this repository
* Create a `.env` file containing:

```
REPOSITORY=https://github.com/<path_to_forked_repository>
GITHUB_TOKEN=<Personal Access Token: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-personal-access-token-classic>
VAULT_TOKEN=root # default for 'dev' mode
```

(TBD what scopes the token needs - not outlined in the [original source repo](https://github.com/crossplane-contrib/back-stack). For now, I've granted none)

* `./install.sh`. Script _should_ be idempotent (i.e. you can re-run it after identifying and fixing an issue), but no promises :P use `./teardown.sh` to start from scratch.

# How this works

The `install.sh` script does the following:

* Use `kind` to create a cluster
* Use `helm` to install Crossplane to the cluster
* Using Crossplane (via a [Configuration](https://docs.crossplane.io/latest/concepts/packages/)), install BackStack CRDs
* Use `kubectl` to install some [Providers](https://docs.crossplane.io/latest/concepts/providers/) - the interfaces which let Crossplane manage non-k8s resources
* Install an instance of a Hub - a BackStack CRD which references a `REPOSITORY` (this one! Or, rather - your forked version of this one!) to know
  * This is why this repository contains directories named `argocd`, `backstage`, `crossplane`, and `kyverno` - these are the definitions for how those applications should be installed onto the cluster _via_ the Hub CRD.

Once everything's installed, the following steps provide a pretty good Proof Of Concept of how the BACK stack works:

## Showing that things exist

* Log in to ArgoCD with the provided URL and credentials
* Navigate to Backstage, wait until the Catalog shows objects populated (should be 4 of them, one for each element of the BACK stack)
  * (This can take about 10 minutes - better to do this in-advance if you're planning a demo)

## Creating a new application

* In Backstage, navigate to "Create", and choose the "New Application Deployment"
  * (Kind-of a misleading label - it's creating a new Application, not a Deployment of an Application, but w/e...)
* Fill in the metadata:
  * Application Name - arbitrary
  * Application Source - full URL of your forked repository (e.g. for me it was `https://github.com/scubbo/jackjack-back-stack-demo`)
  * Path - `backstage/examples/template/content`
  * Click "Next"
* Fill in the next set of metadata:
  * Owner - your GitHub username
  * Repository - arbitrary. I chose `jackjack-back-stack-demo-created-application`
  * Branch Name for Pull Requst - arbitrary. This will be the name of the Branch from which a PR is created to add this Application to the defined set of Applications.
  * Click "Review", then "Create"


  # Thanks and acknowledgements

  This demo was heavily inspired by, and builds on, [this repo](https://github.com/crossplane-contrib/back-stack) - though I've adapted it heavily to suit my own team's use-cases (in particular, cluster maintainance is not a big concern for us, but definition of Applications' "SDLC Infrastructure" - e.g. the Vault policies which allow GitHub Actions to execute - is). I also made some tweaks to the `install` script to make it idempotent (since I had to re-run a bunch of times to get around issues, and starting up the cluster from scratch each time was a pain!), such as using `kubectl apply` rather than `kubectl create` to create `clusterrolebinding`s and `ProviderConfig`s.