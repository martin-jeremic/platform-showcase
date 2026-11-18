{{/*
Base name for resources rendered by this umbrella chart.
Honors fullnameOverride, then nameOverride, then the chart name.
*/}}
{{- define "platform-traefik.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Common labels stamped on every object this chart owns.
*/}}
{{- define "platform-traefik.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "platform-traefik.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform-traefik
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Namespace the Gateway lives in (explicit override or release namespace).
*/}}
{{- define "platform-traefik.gatewayNamespace" -}}
{{- default .Release.Namespace .Values.gateway.namespace -}}
{{- end -}}
