{{/*
Base name for resources rendered by this chart.
Honors fullnameOverride, then nameOverride, then the chart name.
*/}}
{{- define "cluster-test.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels — the stable subset used in matchLabels/selectors.
*/}}
{{- define "cluster-test.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cluster-test.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Image reference. The tag defaults to "<appVersion>-<image.variant>", so the nginx
version is set in exactly one place (Chart.yaml appVersion); image.tag stays as an
explicit override for a one-off pin.
*/}}
{{- define "cluster-test.image" -}}
{{- $tag := .Values.image.tag | default (printf "%s-%s" .Chart.AppVersion .Values.image.variant) -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{/*
Common labels stamped on every object this chart owns.
*/}}
{{- define "cluster-test.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "cluster-test.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: cluster-test
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}
