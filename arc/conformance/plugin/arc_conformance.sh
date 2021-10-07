#!/bin/bash

set -x
set -e

results_dir="${RESULTS_DIR:-/tmp/results}"

function waitForResources {
    available=false
    max_retries=60
    sleep_seconds=10
    RESOURCE=$1
    NAMESPACE=$2
    for i in $(seq 1 $max_retries)
    do
    if [[ ! $(kubectl wait --for=condition=available ${RESOURCE} --all --namespace ${NAMESPACE}) ]]; then
        sleep ${sleep_seconds}
    else
        available=true
        break
    fi
    done
    
    echo "$available"
}

# saveResults prepares the results for handoff to the Sonobuoy worker.
# See: https://github.com/vmware-tanzu/sonobuoy/blob/main/site/content/docs/main/plugins.md#how-plugins-work
saveResults() {
  cd ${results_dir}

    # Sonobuoy worker expects a tar file.
	tar czf results.tar.gz *

	# Signal the worker by writing out the name of the results file into a "done" file.
	printf ${results_dir}/results.tar.gz > ${results_dir}/done
}

# Ensure that we tell the Sonobuoy worker we are done regardless of results.
trap saveResults EXIT

# Login with service principal
az login --service-principal \
  -u ${CLIENT_ID} \
  -p ${CLIENT_SECRET} \
  --tenant ${TENANT_ID}

# Wait for resources in ARC ns
waitSuccessArc="$(waitForResources deployment azure-arc)"
if [ "${waitSuccessArc}" == false ]; then
    echo "deployment is not avilable in namespace - azure-arc"
    exit 1
fi

az extension add --name k8s-extension

az k8s-extension create \
   --name sscsiarc \
   --extension-type Microsoft.AzureKeyVaultSecretsProvider \
   --scope cluster --cluster-name ext-test \
   --resource-group nilekh \
   --cluster-type connectedClusters --release-train preview \
   --release-namespace kube-system \
   --configuration-settings 'secrets-store-csi-driver.enableSecretRotation=true' 'secrets-store-csi-driver.rotationPollInterval=30s' 'secrets-store-csi-driver.syncSecret.enabled=true' 'linux.volumes[0].name=cloudenvfile-vol' 'linux.volumes[0].hostPath.path=/etc/kubernetes/custom_environment.json' 'linux.volumes[0].hostPath.type=File' 'linux.volumeMounts[0].name=cloudenvfile-vol' 'linux.volumeMounts[0].mountPath=/etc/kubernetes/custom_environment.json'

# wait for secrets store csi driver and provider pods
kubectl wait pod -n kube-system --for=condition=Ready -l app=secrets-store-csi-driver
kubectl wait pod -n kube-system --for=condition=Ready -l app=csi-secrets-store-provider-azure

git clone -b arc-conformance https://github.com/nilekhc/secrets-store-csi-driver-provider-azure
cd secrets-store-csi-driver-provider-azure

make e2e-test

sleep 5m