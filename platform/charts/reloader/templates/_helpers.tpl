{{/*
Base name for resources rendered by this umbrella chart.
Honors fullnameOverride, then nameOverride, then the chart name.
*/}}
{{- define "platform-reloader.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Common labels stamped on every object this chart owns.
(The upstream Reloader subchart labels its own objects; these apply to any
extra objects this umbrella chart may template in the future.)
*/}}
{{- define "platform-reloader.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "platform-reloader.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform-reloader
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}
