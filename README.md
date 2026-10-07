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
| `argocd` | Argo CD | Syncs this repo (hub apps) and merged `waggle-clusters` directories |
| `waggle` | Waggle MCP server, status watcher, TTL reaper | *Planned* (Phases 4 and 7) |
| `<cluster>` | `ClusterDeployment`, `MachinePool`, secrets | One namespace per spoke cluster, applied from `waggle-clusters` |

**Trust boundary:** the agent never holds cloud credentials or apply rights. Credentials live on the hub as Secrets; the MCP server can read Hive state and write to Git, nothing more.

## Repository layout

```
waggle-hub/
├── deploy/
│   ├── eks/                    # Terraform: VPC, EKS, EBS CSI, AWS LB controller, ACM private CA
│   └── argocd/                 # Argo CD install (to be added)
└── apps/
    ├── rootapp.yaml            # app of apps: apply once, Argo CD manages the rest
    ├── applications/           # one Argo CD Application per hub app
    │   ├── certmanager.yaml
    │   ├── externalsecrets.yaml
    │   └── hive.yaml
    ├── certmanager/            # kustomize + Helm chart
    ├── externalsecrets/        # kustomize + Helm chart
    └── hive/                   # kustomize: upstream operator, CRDs, HiveConfig
        └── admission-cert/     # cert renewer (Job + CronJob)
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

Install Argo CD into the `argocd` namespace. The hub apps use kustomize's `helmCharts`, so Argo CD must have Helm enabled for kustomize builds in `argocd-cm`:

```yaml
data:
  kustomize.buildOptions: --enable-helm
```

With the Argo CD Helm chart, set this under `configs.cm`.

### 3. Apply the root app

```sh
kubectl apply -f apps/rootapp.yaml
```

The root app syncs `apps/applications`, which creates one child Application per hub app. Each child syncs automatically with prune and self-heal.

### 4. Verify Hive

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

Child Applications carry sync waves (cert-manager and external-secrets in wave 0, Hive in wave 1). Argo CD only waits on a child app's health between waves if an `argoproj.io/Application` health check is configured in `argocd-cm`.

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

## Roadmap for this repo

From the Waggle plan, the hub's pieces by phase:

**Phase 1: EKS hub with upstream Hive**

- [x] EKS cluster via Terraform
- [x] Hive CRDs and operator at a pinned commit, image set to the matching tag
- [x] Apply order via sync waves: CRDs, operator and RBAC, then `HiveConfig`
- [x] Cert renewer using the EKS `app-serving` signer
- [x] External Secrets Operator installed
- [ ] `ClusterSecretStore` and IRSA role for Secrets Manager; per-cluster credential and pull-secret sync
- [ ] Argo CD install in `deploy/argocd`, plus an Application pointing at `waggle-clusters/clusters/`
- [ ] `ClusterImageSet`s for the offered OpenShift versions
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
