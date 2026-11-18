{{/*
Expand the name of the chart.
*/}}
{{- define "rabbitmq.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rabbitmq.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rabbitmq.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rabbitmq.labels" -}}
helm.sh/chart: {{ include "rabbitmq.chart" . }}
{{ include "rabbitmq.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rabbitmq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rabbitmq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Name of the Secret holding credentials.
If azureKeyVault.enabled, the secret is synced by the CSI driver. Otherwise it MUST
be a pre-created Secret (auth.existingSecret, keys rabbitmq-username /
rabbitmq-password). There is no third path: the chart this was forked from rendered
a Secret from `auth.password` in values, and its overlays carried plaintext
passwords for four environments, production included. The template is gone, not
merely unused.
*/}}
{{- define "rabbitmq.secretName" -}}
{{- if .Values.azureKeyVault.enabled }}
{{- .Values.azureKeyVault.syncedSecretName }}
{{- else }}
{{- required "auth.existingSecret is required when azureKeyVault.enabled is false: this chart never renders a password Secret from values" .Values.auth.existingSecret }}
{{- end }}
{{- end }}

{{/*
Input validation, included by the StatefulSet. `guest` is RabbitMQ's built-in
default user: it may only connect from localhost, so a platform that "works" with
it in a dev shell fails from every pod -- and a password for it in any vault means
someone tried. The event SPI in Keycloak also silently falls back to guest when
its username is unset, which is why both sides name the user explicitly.
*/}}
{{- define "rabbitmq.validate" -}}
{{- $u := required "auth.username is required" .Values.auth.username -}}
{{- if eq (lower $u) "guest" -}}
{{- fail "auth.username must not be guest: the built-in guest user is localhost-only and is the first credential anyone tries" -}}
{{- end -}}
{{- if and .Values.azureKeyVault.enabled (not (has .Values.azureKeyVault.authMode (list "workloadIdentity" "vmManagedIdentity" "servicePrincipal"))) -}}
{{- fail "azureKeyVault.authMode must be one of: workloadIdentity, vmManagedIdentity, servicePrincipal" -}}
{{- end -}}
{{- end -}}

{{/*
Name of the PVC.
*/}}
{{- define "rabbitmq.pvcName" -}}
{{- if .Values.persistence.existingClaim }}
{{- .Values.persistence.existingClaim }}
{{- else }}
{{- include "rabbitmq.fullname" . }}
{{- end }}
{{- end }}

{{/*
ServiceAccount name. Honors an explicit override, else the release fullname.
*/}}
{{- define "rabbitmq.serviceAccountName" -}}
{{- if .Values.serviceAccount.name -}}
{{- .Values.serviceAccount.name -}}
{{- else -}}
{{- include "rabbitmq.fullname" . -}}
{{- end -}}
{{- end -}}
