{{/*
Expand the name of the chart.
*/}}
{{- define "azurite.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "azurite.fullname" -}}
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
Chart label.
*/}}
{{- define "azurite.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "azurite.labels" -}}
helm.sh/chart: {{ include "azurite.chart" . }}
{{ include "azurite.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "azurite.selectorLabels" -}}
app.kubernetes.io/name: {{ include "azurite.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Build the azurite command from values.
*/}}
{{- define "azurite.command" -}}
{{- $args := list "azurite" }}
{{- if .Values.azurite.loose }}
{{- $args = append $args "--loose" }}
{{- end }}
{{- if .Values.azurite.skipApiVersionCheck }}
{{- $args = append $args "--skipApiVersionCheck" }}
{{- end }}
{{- if .Values.azurite.disableProductStyleUrl }}
{{- $args = append $args "--disableProductStyleUrl" }}
{{- end }}
{{- if .Values.azurite.debug }}
{{- $args = append $args "--debug" }}
{{- $args = append $args .Values.azurite.debug }}
{{- end }}
{{- $args = append $args (printf "--blobHost %s"  .Values.azurite.blobHost) }}
{{- $args = append $args (printf "--queueHost %s" .Values.azurite.queueHost) }}
{{- $args = append $args (printf "--tableHost %s" .Values.azurite.tableHost) }}
{{- $args = append $args (printf "--location %s"  .Values.azurite.location) }}
{{- if .Values.azurite.extraArgs }}
{{- $args = append $args .Values.azurite.extraArgs }}
{{- end }}
{{- join " " $args }}
{{- end }}

{{/*
Name of the PVC.
*/}}
{{- define "azurite.pvcName" -}}
{{- if .Values.persistence.existingClaim }}
{{- .Values.persistence.existingClaim }}
{{- else }}
{{- include "azurite.fullname" . }}
{{- end }}
{{- end }}
