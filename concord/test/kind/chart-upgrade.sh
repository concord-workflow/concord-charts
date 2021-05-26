#!/usr/bin/env bash

helm upgrade --values values.yaml --namespace concord --create-namespace concord ../../
