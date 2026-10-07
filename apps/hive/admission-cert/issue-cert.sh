#!/bin/sh
# Issues (or renews) the hiveadmission serving cert from the EKS cluster CA.
# Idempotent: exits early while the current cert has more than RENEW_BEFORE left.
set -eu

NS="${HIVE_NS:-hive}"
SVC=hiveadmission
SECRET=hiveadmission-serving-cert
CSR_NAME="${SVC}.${NS}"
SIGNER=beta.eks.amazonaws.com/app-serving
RENEW_BEFORE="${RENEW_BEFORE:-1296000}" # 15 days, in seconds

command -v openssl >/dev/null 2>&1 || apk add --no-cache openssl >/dev/null

WORK=$(mktemp -d)
cd "$WORK"

if kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.tls\.crt}' >crt.b64 2>/dev/null && [ -s crt.b64 ]; then
  base64 -d crt.b64 >current.crt
  if openssl x509 -in current.crt -noout -checkend "$RENEW_BEFORE" >/dev/null; then
    echo "$SECRET is valid until $(openssl x509 -in current.crt -noout -enddate | cut -d= -f2); nothing to do"
    exit 0
  fi
  echo "$SECRET expires within ${RENEW_BEFORE}s; renewing"
else
  echo "$SECRET not found; issuing"
fi

openssl genrsa -out tls.key 2048 2>/dev/null
openssl req -new -key tls.key -out tls.csr \
  -subj "/CN=${SVC}.${NS}.svc" \
  -addext "subjectAltName=DNS:${SVC},DNS:${SVC}.${NS},DNS:${SVC}.${NS}.svc,DNS:${SVC}.${NS}.svc.cluster.local"

kubectl delete csr "$CSR_NAME" --ignore-not-found
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  request: $(base64 <tls.csr | tr -d '\n')
  signerName: ${SIGNER}
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF
kubectl certificate approve "$CSR_NAME"

CRT=""
for _ in $(seq 1 30); do
  CRT=$(kubectl get csr "$CSR_NAME" -o jsonpath='{.status.certificate}')
  [ -n "$CRT" ] && break
  sleep 2
done
if [ -z "$CRT" ]; then
  echo "timed out waiting for $CSR_NAME to be signed" >&2
  kubectl get csr "$CSR_NAME" -o yaml >&2
  exit 1
fi
echo "$CRT" | base64 -d >tls.crt

kubectl -n "$NS" create secret tls "$SECRET" --cert=tls.crt --key=tls.key \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl delete csr "$CSR_NAME"

echo "$SECRET issued, valid until $(openssl x509 -in tls.crt -noout -enddate | cut -d= -f2)"
