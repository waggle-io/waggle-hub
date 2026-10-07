# waggle-hub

The hub cluster for [Waggle](https://github.com/waggle-io), an AI infra agent that turns a plain-language request for an OpenShift cluster into a validated, costed, approved plan and provisions it on AWS, Azure or GCP.

This repo holds everything that runs **on the hub**: Terraform for the EKS cluster, and the Argo CD app-of-apps that installs upstream Hive, External Secrets, cert-manager and (later) the Waggle components. Spoke clusters are not defined here; they live in [`waggle-clusters`](https://github.com/waggle-io/waggle-clusters).

![Waggle architecture](https://github.com/waggle-io/.github/blob/main/media/images/waggle-architecture.png?raw=true)

## Where the hub fits

The agent decides and explains; deterministic code validates, prices and renders; a human approves in Git; Hive executes. The hub is the "Hive executes" part, plus the services around it:

| Namespace | Component | Role |
| --- | --- | --- |
| `hive` | Upstream Hive (pinned image) | Runs `openshift-install`, tracks conditions, retries, deprovisions |
| `hive` | Cert renewer | Issues and rotates the `hiveadmission` serving cert from the EKS signer |
| `external-secrets` | External Secrets Operator | Syncs cloud credentials and the pull secret from Secrets Manager / Vault |
| `cert-manager` | cert-manager | General-purpose certificates for hub services |
| `argocd` | Argo CD | Syncs this repo (hub apps and its own install) and merged `waggle-clusters` directories |
| `waggle` | Waggle MCP server, status watcher, TTL reaper | *Planned* (Phases 4 and 7) |
| `<cluster>` | `ClusterDeployment`, `MachinePool`, secrets | One namespace per spoke cluster, applied from `waggle-clusters` |

**Trust boundary:** the agent never holds cloud credentials or apply rights. Credentials live on the hub as Secrets; the MCP server can read Hive state and write to Git, nothing more.

## Repository layout

```
waggle-hub/
├── deploy/
│   ├── eks/                    # Terraform: VPC, EKS, EBS CSI, AWS LB controller, ACM private CA
│   └── argocd/                 # Argo CD install: kustomize over upstream install.yaml
├── hack/                       # ClusterImageSet generator and checks
├── gitops/
│   ├── rootapp.yaml            # app of apps: apply once, Argo CD manages the rest
│   ├── kustomization.yaml      # lists the child Applications
│   ├── argocd/                 # Argo CD manages its own install
│   ├── certmanager/
│   ├── externalsecrets/
│   └── hive/
└── apps/                       # what each child Application deploys
    ├── certmanager/            # kustomize + Helm chart
    ├── externalsecrets/        # kustomize + Helm chart
    └── hive/                   # kustomize: upstream operator, CRDs, HiveConfig
        ├── admission-cert/     # cert renewer (Job + CronJob)
        └── clusterimagesets/   # offered OpenShift versions (generated)
```

## Bootstrap

### 1. Provision the EKS cluster

```sh
cd deploy/eks
terraform init
terraform apply
$(terraform output -raw configure_kubectl)
```

Review `variables.tf` first (region, cluster name, node sizing, domain). Size the node group for Hive plus install pods: install pods are short-lived but memory-hungry.

### 2. Install Argo CD

```sh
kubectl apply -k deploy/argocd --server-side
kubectl -n argocd rollout status deploy/argocd-server
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

`deploy/argocd` installs upstream Argo CD (pinned `v3.5.4`) with hub-specific settings:

- `kustomize.buildOptions: --enable-helm`, needed by the hub apps that render Helm charts through kustomize
- a health check for `Application` resources, so the root app's sync waves wait for each child app to become healthy
- `server.insecure: "true"` and an ALB Ingress (AWS Load Balancer Controller): TLS terminates at the ALB with the matching ACM certificate

Point a Route53 record for `gitops.waggle.io` at the ALB (`kubectl -n argocd get ingress argocd-server`). The CLI must use gRPC-Web through the ALB: `argocd login gitops.waggle.io --grpc-web`. Change the admin password and delete `argocd-initial-admin-secret` after first login.

After the root app syncs, Argo CD manages its own install via `gitops/argocd/argocd.yaml` (self-heal on, prune off).

### 3. Give Argo CD access to this repo

This repo is private, so Argo CD needs a GitHub token to read it. Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with:

- **Resource owner:** `waggle-io`
- **Repository access:** only `waggle-hub`
- **Permissions:** Contents → Read-only (Metadata → Read-only is added automatically)

Then register it as an Argo CD repository Secret. The token never goes in Git:

```sh
read -rs GITHUB_TOKEN   # paste the token; keeps it out of shell history

kubectl -n argocd create secret generic repo-waggle-hub \
  --from-literal=type=git \
  --from-literal=url=https://github.com/waggle-io/waggle-hub \
  --from-literal=username=git \
  --from-literal=password="$GITHUB_TOKEN"
kubectl -n argocd label secret repo-waggle-hub argocd.argoproj.io/secret-type=repository

unset GITHUB_TOKEN
```

Check that Argo CD can reach the repo: **Settings → Repositories** in the UI should show `waggle-hub` as *Successful*, or run `argocd repo list --grpc-web`.

Fine-grained tokens expire. Before expiry, create a new token and update the Secret in place:

```sh
read -rs GITHUB_TOKEN
kubectl -n argocd patch secret repo-waggle-hub \
  -p "{\"stringData\":{\"password\":\"$GITHUB_TOKEN\"}}"
unset GITHUB_TOKEN
```

> Once External Secrets has a `ClusterSecretStore`, this Secret can move to Secrets Manager and be synced by an `ExternalSecret`. That ExternalSecret can't live in this repo's sync path, because Argo CD needs the token before it can read the repo at all.

### 4. Apply the root app

```sh
kubectl apply -f gitops/rootapp.yaml
```

The root app syncs `gitops/`, which creates one child Application per hub app. Each child syncs automatically with prune and self-heal.

### 5. Verify Hive

```sh
kubectl -n hive get pods
kubectl -n hive get secret hiveadmission-serving-cert
```

Expect `hive-operator`, `hive-controllers`, `hive-clustersync`, `hive-machinepool` and `hiveadmission` pods. If `hiveadmission` is not ready, check the cert job: `kubectl -n hive logs job/hiveadmission-cert-issue`.

## Hub apps

| App | Source | Version | Notes |
| --- | --- | --- | --- |
| cert-manager | `charts.jetstack.io` | `v1.21.2` | CRDs installed by the chart and kept on uninstall |
| external-secrets | `charts.external-secrets.io` | `2.12.0` | No `ClusterSecretStore` yet; needs an IRSA role for AWS Secrets Manager |
| hive | `github.com/openshift/hive` | commit `01de8ed` | Operator, 21 CRDs and `HiveConfig`; image `quay.io/openshift-hive/hive:01de8edf26` |

Child Applications carry sync waves (Argo CD in wave -1, cert-manager and external-secrets in wave 0, Hive in wave 1). The `Application` health check in `deploy/argocd/argocd-cm.yaml` makes each wave wait for the previous one to be healthy.

## Running upstream Hive on EKS

Hive is built for OpenShift. Three things differ on vanilla Kubernetes, and the `apps/hive` kustomization handles each:

1. **No OLM, no versioned releases.** The operator manifests and CRDs come straight from the Hive repo at one pinned commit, and the image tag is that commit's short SHA. Upgrade by bumping both together in `apps/hive/kustomization.yaml`, then run the create-and-destroy cycle before merging.
2. **Apply order.** CRDs and the operator sync first; the `HiveConfig` waits for its CRD (sync wave 2 plus `SkipDryRunOnMissingResource`). Creating the `HiveConfig` is what makes the operator deploy the rest of Hive.
3. **Admission webhook certificate.** OpenShift's service-ca normally provides `hiveadmission-serving-cert`. On non-OpenShift, Hive injects the **cluster CA** into the webhook's CA bundle, so the cert must be signed by that CA. cert-manager certificates would be rejected. The cert renewer in `apps/hive/admission-cert/`:
   - generates a key and submits a CSR to the EKS signer `beta.eks.amazonaws.com/app-serving`, approves it and writes the Secret;
   - runs on every Argo CD sync (Job) and daily (CronJob), renewing when fewer than 15 days remain;
   - exists because EKS caps these certificates at **45 days**.

   Hive hashes the Secret onto the `hiveadmission` pod template, so a renewed cert rolls the webhook pods automatically.

> **Risk:** if the cert renewer fails silently, the Hive webhook rejects all writes once the cert expires. Alert on the age of `hiveadmission-serving-cert` and on failed `hiveadmission-cert-renew` jobs.

## OpenShift versions (ClusterImageSets)

The versions requesters can choose are Hive `ClusterImageSet`s in `apps/hive/clusterimagesets/`. Only `versions.yaml` is edited by hand; everything else in that directory is generated.

```yaml
channel: stable
arch: amd64
minors: ["4.22", "4.21", "4.20"]
keepPerMinor: 2          # latest z-stream + the previous one
default: "4.21"
warnDaysBeforeEOL: 60
```

`hack/gen-clusterimagesets.sh` reads it and, for each minor:

- takes the newest `keepPerMinor` releases in the `stable-<minor>` channel of the [OpenShift update graph](https://api.openshift.com/api/upgrades_info/v1/graph?channel=stable-4.21&arch=amd64), with `releaseImage` **pinned by digest**;
- checks the [Red Hat lifecycle API](https://access.redhat.com/product-life-cycles/api/v1/products?name=OpenShift%20Container%20Platform%204): it fails for a minor past maintenance support and warns within `warnDaysBeforeEOL` days;
- labels each set `waggle.io/minor`, `waggle.io/offered` and `waggle.io/default`, and annotates it with the errata link and support end date.

Versions that drop out of the window are **retired, not deleted**: they keep their file with `waggle.io/offered: "false"`, so existing `ClusterDeployment`s that reference them still resolve. Only `offered=true` sets should be shown to requesters. Delete a retired file by hand once no cluster in `waggle-clusters` references it.

The `clusterimagesets` workflow runs the generator daily and opens or updates a PR (branch `automation/clusterimagesets`) when new z-streams appear, with any end-of-life warnings in the description. Merging it is the approval; Argo CD then syncs the hive app. On PRs it runs `hack/verify-clusterimagesets.sh` (digest pinned, image exists, exactly one default, kustomization up to date) and fails if the committed files don't match what `versions.yaml` generates.

To change the offered versions, edit `versions.yaml`, then run:

```sh
hack/gen-clusterimagesets.sh
hack/verify-clusterimagesets.sh   # needs skopeo
```

and commit the result. Both scripts need `curl`, `jq` and `yq` (mikefarah v4).

> The workflow needs **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests** enabled on this repo.

## Roadmap for this repo

From the Waggle plan, the hub's pieces by phase:

**Phase 1: EKS hub with upstream Hive**

- [x] EKS cluster via Terraform
- [x] Hive CRDs and operator at a pinned commit, image set to the matching tag
- [x] Apply order via sync waves: CRDs, operator and RBAC, then `HiveConfig`
- [x] Cert renewer using the EKS `app-serving` signer
- [x] External Secrets Operator installed
- [ ] `ClusterSecretStore` and IRSA role for Secrets Manager; per-cluster credential and pull-secret sync
- [x] Argo CD install in `deploy/argocd`, self-managed after bootstrap
- [ ] Argo CD Application pointing at `waggle-clusters/clusters/`
- [x] `ClusterImageSet`s for the offered OpenShift versions, generated from the update graph
- [ ] Hand-written AWS `ClusterDeployment` provisioned and deprovisioned three times with no manual cleanup
- [ ] Forced cert rotation tested

**Later phases**

- [ ] Phase 3: price catalog CronJob
- [ ] Phase 4: Waggle MCP server in the `waggle` namespace, with read-only RBAC on Hive resources
- [ ] Phase 7: status watcher, TTL reaper, hibernation scheduler, actual-cost reconciler
- [ ] Phase 8: OpenTelemetry export and dashboards

## Related repositories

| Repo | Contents |
| --- | --- |
| [`waggle`](https://github.com/waggle-io/waggle) | Go module: `ClusterRequest` API, renderers, cost engine, optimizer, MCP server |
| [`waggle-clusters`](https://github.com/waggle-io/waggle-clusters) | GitOps repo, one directory per spoke cluster; merge is approval |
| [`waggle-agent`](https://github.com/waggle-io/waggle-agent) | OpenClaw workspace, `openshift-provision` skill, eval suite |
