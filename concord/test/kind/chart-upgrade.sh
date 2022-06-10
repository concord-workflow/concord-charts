#!/usr/bin/env bash

helm upgrade --install --values values.yaml --namespace concord --create-namespace concord ../../
