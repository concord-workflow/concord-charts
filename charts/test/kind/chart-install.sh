#!/usr/bin/env bash

helm install --values values.yaml --namespace concord --create-namespace concord ../../
