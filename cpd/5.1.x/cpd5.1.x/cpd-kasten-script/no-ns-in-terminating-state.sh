#!/bin/bash

# check if any namespaces are in a terminating state
terminating_namespaces=$(kubectl get ns --no-headers | awk '$2 == "Terminating" {print $1}')
if [ -n "$terminating_namespaces" ]; then
    echo "The following namespaces are in a terminating state:"
    echo "$terminating_namespaces"
    echo "Please resolve these issues before proceeding."
    exit 1
else
    echo "No namespaces are in a terminating state."
fi