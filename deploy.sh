# This script might take about 20 minutes
# Please check the variables
RGLOCATION=eastus
RGNAME=rg-enterprise-networking-hubs
RGNAMESPOKES=rg-enterprise-networking-spokes
RGNAMECLUSTER=rg-cluster01
aksName=cluster01
runDate=$(date +%S%N)
spName=${aksName}-sp-${runDate}
serverAppName=${aksName}-server-${runDate}
clientAppName=${aksName}-kubectl-${runDate}
tenant_guid=**Your tenant id for Identities**
main_subscription=**Your Main subscription**


# We are going to use a new tenant to provide identity
az login  --allow-no-subscriptions -t $tenant_guid
#--Until change the subscription It will take about 1 minutes creating service principals

# Create the Azure AD application
k8sRbacAadProfileServerAppId=$(az ad app create --display-name "$serverAppName" --identifier-uris "https://${serverAppName}" --query appId -o tsv)

# Update the application group memebership claims
az ad app update --id $k8sRbacAadProfileServerAppId --set groupMembershipClaims=All

# Create a service principal for the Azure AD application
az ad sp create --id $k8sRbacAadProfileServerAppId

# Get the service principal secret
k8sRbacAadProfileServerAppSecret=$(az ad sp credential reset --name $k8sRbacAadProfileServerAppId  --credential-description "AKSClientSecret" --query password -o tsv)

az ad app permission add \
    --id $k8sRbacAadProfileServerAppId \
    --api 00000003-0000-0000-c000-000000000000 \
    --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope 06da0dbc-49e2-44d2-8312-53f166ab848a=Scope 7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role
az ad app permission grant --id $k8sRbacAadProfileServerAppId --api 00000003-0000-0000-c000-000000000000
az ad app permission admin-consent --id  $k8sRbacAadProfileServerAppId

k8sRbacAadProfileClientAppId=$(az ad app create \
    --display-name "${clientAppName}" \
    --native-app \
    --reply-urls "https://${clientAppName}" \
    --query appId -o tsv)

az ad sp create --id $k8sRbacAadProfileClientAppId

oAuthPermissionId=$(az ad app show --id $k8sRbacAadProfileServerAppId --query "oauth2Permissions[0].id" -o tsv)
az ad app permission add --id $k8sRbacAadProfileClientAppId --api $k8sRbacAadProfileServerAppId --api-permissions ${oAuthPermissionId}=Scope
az ad app permission grant --id $k8sRbacAadProfileClientAppId --api $k8sRbacAadProfileServerAppId

k8sRbacAadProfileTennetId=$(az account show --query tenantId -o tsv)

echo "k8sRbacAadProfileServerAppId=${k8sRbacAadProfileServerAppId}"
echo "k8sRbacAadProfileClientAppId=${k8sRbacAadProfileClientAppId}"
echo "k8sRbacAadProfileServerAppSecret=${k8sRbacAadProfileServerAppSecret}"
echo "k8sRbacAadProfileTennetId=${k8sRbacAadProfileTennetId}"

#back to main subscription
az login 
az account set -s $main_subscription

#Main Network.Build the hub. First arm template execution and catching outputs. This might take about 6 minutes
az group create --name "${RGNAME}" --location "${RGLOCATION}"

az deployment group create --resource-group "${RGNAME}" --template-file "./networking/hub-default.json"  --name "hub-0001" --parameters location=$RGLOCATION

HUB_VNET_ID=$(az deployment group show -g $RGNAME -n hub-0001 --query properties.outputs.hubVnetId.value -o tsv)

HUB_FW_NAME=$(az deployment group show -g $RGNAME -n hub-0001 --query properties.outputs.hubFwName.value -o tsv)

HUB_LA_NAME=$(az deployment group show -g $RGNAME -n hub-0001 --query properties.outputs.hubLaName.value -o tsv)
 
#Cluster Subnet.Build the spoke. Second arm template execution and catching outputs. This might take about 2 minutes
az group create --name "${RGNAMESPOKES}" --location "${RGLOCATION}"

az deployment group  create --resource-group "${RGNAMESPOKES}" --template-file "./networking/spoke-BU0001A0008.json" --name "spoke-0001" --parameters location=$RGLOCATION hubVnetResourceId=$HUB_VNET_ID hubFwName=$HUB_FW_NAME hubLaName=$HUB_LA_NAME

CLUSTER_VNET_RESOURCE_ID=$(az deployment group show -g $RGNAMESPOKES -n spoke-0001 --query properties.outputs.clusterVnetResourceId.value -o tsv)

USER_NODEPOOL_SUBNET_RESOURCE_ID=$(az deployment group show -g $RGNAMESPOKES -n spoke-0001 --query properties.outputs.userNodepoolSubnetResourceIds.value -o tsv)

SYSTEM_NODEPOOL_SUBNET_RESOURCE_ID=$(az deployment group show -g $RGNAMESPOKES -n spoke-0001 --query properties.outputs.systemNodepoolSubnetResourceIds.value -o tsv)

GATEWAY_SUBNET_RESOURCE_ID=$(az deployment group show -g $RGNAMESPOKES -n spoke-0001 --query properties.outputs.vnetGatewaySubnetResourceIds.value -o tsv)

GATEWAY_PUbLIC_IP_RESOURCE_ID=$(az deployment group show -g $RGNAMESPOKES -n spoke-0001 --query properties.outputs.appGatewayPipResourceIds.value -o tsv)

#Main Network Update. Third arm template execution and catching outputs. This might take about 3 minutes

az deployment group create --resource-group "${RGNAME}" --template-file  "./networking/hub-regionA.json" --name "hub-0002" --parameters location=$RGLOCATION nodepoolSubnetResourceIds="['$USER_NODEPOOL_SUBNET_RESOURCE_ID','$SYSTEM_NODEPOOL_SUBNET_RESOURCE_ID']"

#AKS Cluster Creation. Advance Networking. AAD identity integration. This might take about 8 minutes
az group create --name "${RGNAMECLUSTER}" --location "${RGLOCATION}"

# Cluster Parameters
echo "CLUSTER_VNET_RESOURCE_ID=${CLUSTER_VNET_RESOURCE_ID}"
echo "RGLOCATION=${RGLOCATION}"
echo "k8sRbacAadProfileServerAppId=${k8sRbacAadProfileServerAppId}"
echo "k8sRbacAadProfileClientAppId=${k8sRbacAadProfileClientAppId}"
echo "k8sRbacAadProfileServerAppSecret=${k8sRbacAadProfileServerAppSecret}"
echo "k8sRbacAadProfileTennetId=${k8sRbacAadProfileTennetId}"

az deployment group create --resource-group "${RGNAMECLUSTER}" --template-file "cluster-stamp.json" --name "cluster-0001" --parameters location=$RGLOCATION targetVnetResourceId=$CLUSTER_VNET_RESOURCE_ID k8sRbacAadProfileServerAppId=$k8sRbacAadProfileServerAppId k8sRbacAadProfileServerAppSecret=$k8sRbacAadProfileServerAppSecret k8sRbacAadProfileClientAppId=$k8sRbacAadProfileClientAppId k8sRbacAadProfileTennetId=$k8sRbacAadProfileTennetId allowedSubnetNames="snet-system-clusternodes,snet-user-clusternodes,snet-clusteringressservices,snet-applicationgateways"
