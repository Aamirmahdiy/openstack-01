#!/bin/bash

SWIFT_PROXY="http://172.30.201.247:8080"

ACCOUNT="AUTH_test"

HOT_CONTAINER="hot-objects"
COLD_CONTAINER="cold"

AUTH_USER="test:tester"
AUTH_KEY="testing"

AGE_LIMIT=600


echo "=== HOT → COLD migration started ==="
date
echo


# =========================
# Get authentication token
# =========================

TOKEN=$(curl -si \
    -H "X-Auth-User: ${AUTH_USER}" \
    -H "X-Auth-Key: ${AUTH_KEY}" \
    "${SWIFT_PROXY}/auth/v1.0" \
    | awk '/X-Auth-Token:/ {print $2}' \
    | tr -d '\r')


if [ -z "$TOKEN" ]; then
    echo "ERROR: Could not get authentication token."
    exit 1
fi


echo "Authentication successful."
echo


# =========================
# Get objects from HOT
# =========================

OBJECTS=$(curl -s \
    -H "X-Auth-Token: $TOKEN" \
    "${SWIFT_PROXY}/v1/${ACCOUNT}/${HOT_CONTAINER}")


if [ -z "$OBJECTS" ]; then
    echo "No objects found in HOT."
    exit 0
fi


# =========================
# Process each object
# =========================

for OBJECT in $OBJECTS
do

    echo "Checking: $OBJECT"


    # =========================
    # Get object metadata
    # =========================

    LAST_MODIFIED=$(curl -sI \
        -H "X-Auth-Token: $TOKEN" \
        "${SWIFT_PROXY}/v1/${ACCOUNT}/${HOT_CONTAINER}/${OBJECT}" \
        | grep -i "^Last-Modified:")


    if [ -z "$LAST_MODIFIED" ]; then
        echo "Cannot get metadata. Skipping $OBJECT"
        echo
        continue
    fi


    LAST_TIMESTAMP=$(date -d "${LAST_MODIFIED#*: }" +%s)

    NOW=$(date +%s)

    AGE=$((NOW - LAST_TIMESTAMP))


    echo "Age: ${AGE} seconds"


    # =========================
    # Check object age
    # =========================

    if [ "$AGE" -lt "$AGE_LIMIT" ]; then
        echo "Not old enough. Keeping in HOT."
        echo
        continue
    fi


    echo "Object is old enough."
    echo "Copying $OBJECT from HOT to COLD..."


    # =========================
    # Server-Side COPY
    # =========================

    HTTP_CODE=$(curl -s \
        -o /dev/null \
        -w "%{http_code}" \
        -X COPY \
        -H "X-Auth-Token: $TOKEN" \
        -H "Destination: /${COLD_CONTAINER}/${OBJECT}" \
        -H "Content-Length: 0" \
        "${SWIFT_PROXY}/v1/${ACCOUNT}/${HOT_CONTAINER}/${OBJECT}")


    if [ "$HTTP_CODE" != "201" ]; then
        echo "COPY failed: HTTP $HTTP_CODE"
        echo "Keeping object in HOT."
        echo
        continue
    fi


    echo "COPY successful."
    echo "Object is now in COLD."


    # =========================
    # Delete from HOT
    # =========================

    HTTP_CODE=$(curl -s \
        -o /dev/null \
        -w "%{http_code}" \
        -X DELETE \
        -H "X-Auth-Token: $TOKEN" \
        "${SWIFT_PROXY}/v1/${ACCOUNT}/${HOT_CONTAINER}/${OBJECT}")


    if [ "$HTTP_CODE" == "204" ]; then
        echo "Deleted from HOT."
        echo "Migration completed for: $OBJECT"
    else
        echo "WARNING: Delete from HOT failed: HTTP $HTTP_CODE"
        echo "Object remains in both HOT and COLD."
    fi


    echo

done


echo "=== HOT → COLD migration completed ==="
date