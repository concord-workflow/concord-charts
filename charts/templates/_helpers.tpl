{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "concord.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "concord.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "concord.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Generate Docker registry secret name
*/}}
{{- define "registry-secret.name" -}}
{{- printf "registry-secret-%s" (include "concord.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "imagePullSecret" }}
{{- printf "{\"auths\": {\"%s\": {\"auth\": \"%s\"}}}" .Values.registry (printf "%s:%s" .Values.registryCredentials.username .Values.registryCredentials.password | b64enc) | b64enc }}
{{- end }}

{{/*
Select image pull secret
*/}}
{{- define "imagePullSecretName" }}
    {{- if ( .Values.registryCredentials.enabled ) }}
        {{- print "imagePullSecrets:" }}
        {{- printf "\n  - name: %s" (include "registry-secret.name" . ) }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "concord.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "concord.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}
