TODO:

* Install script to:
  * Use `k3d` to create a cluster
  * Install Backstage, Argo, and Crossplane on it
  * Install app-of-apps on it
  ...

* Does Backstage support authorization for carrying out actions? (e.g. only owners can update an application's config)
* Can the default Branch Name For Pull Request be set based on the Application Name? Otherwise there'll be clashes.
* Investigate https://github.com/upbound/provider-vault

## Issues to raise on base repo

* `helm repo add` // `update` needed for crossplane?