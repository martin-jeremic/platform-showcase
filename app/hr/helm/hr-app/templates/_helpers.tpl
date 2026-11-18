{{- define "hr-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "hr-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hr-app.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "hr-app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "hr-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: hr
{{- end }}

{{- define "hr-app.configMapName" -}}
{{- default (printf "%s-config" (include "hr-app.fullname" .)) .Values.configMap.name }}
{{- end }}

{{- define "hr-app.image" -}}
{{- $repo := default (printf "%s/%s" .Values.image.defaultRegistry (include "hr-app.fullname" .)) .Values.image.repository -}}
{{- $digest := required "image.digest is required (sha256:<64 hex>)" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "image.digest must look like sha256:<64 hex>, got %q" $digest) -}}
{{- end -}}
{{- printf "%s@%s" $repo $digest -}}
{{- end }}
