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

Once everything's installed (which takes about 7-10 minutes), the following steps provide a pretty good Proof Of Concept of how the BACK stack works:

## Show that things exist

* Log in to ArgoCD with the provided URL and credentials
  * The `clusters` application comes pre-bundled with the demo BACK stack I was working from. The original demo showed how easy it was to create AKS/EKS clusters via Crossplane, but we're not interested in that functionality right now.
  * You probably want to go to "Settings -> Clusters" and change the name of `in-cluster` to `hostcluster` - see [this issue](https://github.com/back-stack/showcase/issues/1).
* Navigate to Backstage, wait until the Catalog shows objects populated (should be 4 of them, one for each element of the BACK stack)
  * (This can take about 10 minutes - better to do this in-advance if you're planning a demo)

## Creating a new application

### Creating a new application from external definition

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
* Manually create an [App-of-apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) so that the added application will show up. In Argo UI, click "New App". Fill out:
  * Application Name: Arbitrary (I chose `applications`)
  * Project Name: default
  * Repository URL: This should autofill, but - the full URL to your forked repository (e.g. `https://github.com/scubbo/jackjack-back-stack-demo`, for me)
  * Path: `demo/applications`
  * Cluster URL: `https://kubernetes.default.svc` (again, this should autofill)
  * Namespace: `default`
  * Click "Create"
  * (The reason that this has to be created manually, rather than by Argo seems to forbid creating an empty App-of-apps)
* The Argo Applications screen should now show an `applications` app. Click into it, and click "Sync" at the top of the page - everything should go Green
* Click into the sub-application (named whatever you entered as the name of your Application at the beginning of this section), and Sync - again, everything should (shortly) go green.
* You _could_ set up an Ingress to provide access to the application, but for a demo it's simpler just to port-forward: `kubectl -n default port-forward service/frontend 8080:80` - then in your browser, navigate to `localhost:8080`

(Next step TODO - demonstrate how to use Crossplane to manage outside-k8s resources, like Vaul Roles/Policies)

# Thanks and acknowledgements

This demo was heavily inspired by, and builds on, [this repo](https://github.com/crossplane-contrib/back-stack) - though I've adapted it heavily to suit my own team's use-cases (in particular, cluster maintainance is not a big concern for us, but definition of Applications' "SDLC Infrastructure" - e.g. the Vault policies which allow GitHub Actions to execute - is). I also made some tweaks to the `install` script to make it idempotent (since I had to re-run a bunch of times to get around issues, and starting up the cluster from scratch each time was a pain!), such as using `kubectl apply` rather than `kubectl create` to create `clusterrolebinding`s and `ProviderConfig`s.