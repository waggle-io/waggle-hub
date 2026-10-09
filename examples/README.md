# Examples

Hand-written Hive resources for testing the hub before the Waggle renderers exist (Phase 1, step 9 of the plan). Each example is laid out like a cluster directory in [`waggle-clusters`](https://github.com/waggle-io/waggle-clusters), so it can be copied there as-is.

## `clusters/demo-aws`: OpenShift IPI on AWS

| File | Resource | Purpose |
| --- | --- | --- |
| `rendered/clusterdeployment.yaml` | `ClusterDeployment` | The cluster: name, base domain, region, OpenShift version, secret references |
| `rendered/install-config.yaml` | `Secret` (via `secretGenerator`) | Installer config: node types and counts, networking, AWS tags, SSH public key |
| `rendered/machinepool.yaml` | `MachinePool` | Lets Hive manage the worker MachineSets after install; must match `compute` in the install-config |
| `rendered/externalsecrets.yaml` | 3 × `ExternalSecret` | AWS credentials, Red Hat pull secret and SSH key from AWS Secrets Manager |

The resulting cluster has 3 control-plane and 3 worker `m6i.xlarge` nodes in `ap-south-1`, runs OpenShift `4.21.35` (the current default ClusterImageSet), and has its API at `https://api.demo-aws.aws.waggle.io:6443`.

### Prerequisites

1. **DNS:** a public Route53 hosted zone for `aws.waggle.io` in the target AWS account, delegated from `waggle.io`.
2. **Secrets Manager values:** Terraform creates these secrets empty, and the `aws-secrets-manager` ClusterSecretStore reads them. Set each one as described in the main README's [Secrets](../README.md#secrets) section:

   | Secret | Keys |
   | --- | --- |
   | `waggle/aws/target-account` | `aws_access_key_id`, `aws_secret_access_key` (IAM user with the [installer's permissions](https://docs.openshift.com/container-platform/latest/installing/installing_aws/installing-aws-account.html)) |
   | `waggle/redhat/pull-secret` | the whole pull secret JSON from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) |
   | `waggle/ssh/hive` | `ssh-privatekey`, `ssh-publickey` (PEM format: `ssh-keygen -t rsa -b 4096 -m PEM`) |

3. **SSH public key:** replace the `sshKey` placeholder in `install-config.yaml` with the public half of `waggle/ssh/hive`. Hive uses the private key to collect logs from a failed install but does not add the public key to the nodes itself.
4. **Quota:** the target account needs room for 6 `m6i.xlarge` instances (24 vCPUs of standard instances), 3 NAT gateways and 1 VPC in `ap-south-1`.

### Run it

Through GitOps, the way real clusters run:

```sh
cp -r examples/clusters/demo-aws <waggle-clusters>/clusters/
# open a PR to waggle-clusters, merge it; Argo CD creates Application cluster-demo-aws
```

Or directly on the hub, for a quick test:

```sh
kubectl create namespace demo-aws
# the ClusterSecretStore only serves namespaces with this label
kubectl label namespace demo-aws waggle.io/cluster-namespace=true
kubectl apply -k examples/clusters/demo-aws/rendered
```

Watch the install (30–45 minutes):

```sh
kubectl -n demo-aws get clusterdeployment demo-aws -w
kubectl -n demo-aws logs -f -l hive.openshift.io/cluster-deployment-name=demo-aws,hive.openshift.io/install=true -c hive
```

When `INSTALLED` is `true`, get the admin kubeconfig:

```sh
kubectl -n demo-aws extract secret/$(kubectl -n demo-aws get cd demo-aws -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}') --keys=kubeconfig --to=- > demo-aws.kubeconfig
```

### Tear it down

Through GitOps: delete `clusters/demo-aws/` in a PR and merge it. Directly: `kubectl -n demo-aws delete clusterdeployment demo-aws`.

Hive deprovisions every AWS resource tagged for the cluster. The credential `ExternalSecret`s carry `Delete=false` and `deletionPolicy: Retain`, so the credentials Hive needs to deprovision survive the cascade. Once `kubectl -n demo-aws get clusterdeprovision` is gone, delete the namespace. Then check the account is clean, with no load balancers, NAT gateways, volumes or hosted zones left that carry the `waggle.io/cluster-id=demo-aws` tag.
