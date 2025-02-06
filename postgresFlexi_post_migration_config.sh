#!/bin/bash

### get current properties for function apps and update variables below
ENV="TNLBTEST"                           
NEW_POSTGRESQL_CONNECTIONURL="jdbc:postgresql://tnlbtestms-postgreSQL-flexi.postgres.database.azure.com:5432"
NEW_POSTGRESQL_USERNAME="Microservicedba@tnlbtestms-postgreSQL"
# current DB name. will be used later for identifying namespaces that are using it.
DB_URL="postgreSQL"

RESOURCE_GROUP="${ENV}-ms"
FUNCTION_APPS=($(az functionapp list --resource-group $RESOURCE_GROUP | jq -r '.[].name'))
SUBSCRIPTIONS=$(az account show | jq -r .id)
RESOURCE_GROUP_LOWER=$(echo "$RESOURCE_GROUP" | tr '[:upper:]' '[:lower:]')

###############################################################################################################################################################################
# get info on the deployed function apps for mysql single and create and array for the running ones
RUNNING_APP_LIST=()
echo "functionapp name | POSTGRESQL_CONNECTIONURL | POSTGRESQL_USERNAME | STATUS" 
for APP_NAME in "${FUNCTION_APPS[@]}"; do 
    APP_SETTINGS=$(az functionapp config appsettings list -g $RESOURCE_GROUP -n $APP_NAME)
    POSTGRESQL_CONNECTIONURL=$(echo "$APP_SETTINGS" | jq -r '.[] | select(.name == "POSTGRESQL_CONNECTIONURL") | .value')
    POSTGRESQL_USERNAME=$(echo "$APP_SETTINGS" | jq -r '.[] | select(.name == "POSTGRESQL_USERNAME") | .value')
    STATUS=$(az functionapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" --query 'state' -o tsv)
    if [ -z "$POSTGRESQL_CONNECTIONURL" ]; then
        POSTGRESQL_CONNECTIONURL="Not Found"
    fi
    if [ -z "$POSTGRESQL_USERNAME" ]; then
        POSTGRESQL_USERNAME="Not Found"
    fi
    echo "$APP_NAME | $POSTGRESQL_CONNECTIONURL | $POSTGRESQL_USERNAME | $STATUS"
    if [ "$POSTGRESQL_CONNECTIONURL" != "Not Found" ] && [ "$STATUS" == "Running" ]; then
        RUNNING_APP_LIST+=("$APP_NAME")
    fi
done
echo "${RUNNING_APP_LIST[@]}"

###############################################################################################################################################################################
# stop running function apps from the previously created array
# here we should also stop deployments that are connecting to the DB. this will become relevant for postgreSQL where we have multiple namespaces configured to use this DB.
# last while loop in this script can be used to identify such cases.
for APP_NAME in "${RUNNING_APP_LIST[@]}"; do
    echo "Stopping $APP_NAME"
	az functionapp stop --name "$APP_NAME" --resource-group "$RESOURCE_GROUP"
done

###############################################################################################################################################################################
### update the POSTGRESQL_CONNECTIONURL and POSTGRESQL_USERNAME for all the function apps with NEW_POSTGRESQL_CONNECTIONURL and NEW_POSTGRESQL_USERNAME
for APP_NAME in "${FUNCTION_APPS[@]}"; do 
    # Check if POSTGRESQL_CONNECTIONURL exists
    POSTGRESQL_CONNECTIONURL=$(az functionapp config appsettings list -g $RESOURCE_GROUP -n $APP_NAME | jq -r '.[] | select(.name == "POSTGRESQL_CONNECTIONURL") | .value')
    if [ -n "$POSTGRESQL_CONNECTIONURL" ]; then
        # Extract the specific path from the current POSTGRESQL_CONNECTIONURL
        URL_PATH=$(echo "$POSTGRESQL_CONNECTIONURL" | awk -F/ '{print "/"$NF}')
        
        # Update the POSTGRESQL_CONNECTIONURL with the new value
        az functionapp config appsettings set -g $RESOURCE_GROUP -n $APP_NAME --settings POSTGRESQL_CONNECTIONURL="${NEW_POSTGRESQL_CONNECTIONURL}${URL_PATH}" POSTGRESQL_USERNAME=$NEW_POSTGRESQL_USERNAME
        echo "Updated POSTGRESQL_CONNECTIONURL for $APP_NAME to ${NEW_POSTGRESQL_CONNECTIONURL}${URL_PATH} and POSTGRESQL_USERNAME to $NEW_POSTGRESQL_USERNAME"
    else
        echo "POSTGRESQL_CONNECTIONURL not found for $APP_NAME"
    fi
done

###############################################################################################################################################################################
# start function apps 
echo "Starting previously stopped function apps with POSTGRESQL_CONNECTIONURL:"
for APP_NAME in "${RUNNING_APP_LIST[@]}"; do
    echo "$APP_NAME"
	az functionapp start --name "$APP_NAME" --resource-group "$RESOURCE_GROUP"
done

###############################################################################################################################################################################
### get all namespaces that are using the DB connection string. Please pay attention to the url string as we might have different databases

releases=$(helm list -A --output json | jq -r '.[] | .name + " " + .namespace')

while read -r release namespace; do
  echo "Processing release: $release in namespace: $namespace"
  helm get values "$release" -n "$namespace" | grep -i $DB_URL
done <<< "$releases"

