{{/* MinIO S3 API Service (port 9000), from the subchart's fullnameOverride. */}}
{{- define "platform-minio.serviceName" -}}
{{- index .Values "minio" "fullnameOverride" | default (printf "%s-minio" .Release.Name) -}}
{{- end }}

{{/* MinIO console Service (port 9001): <fullname>-console. */}}
{{- define "platform-minio.consoleServiceName" -}}
{{- printf "%s-console" (include "platform-minio.serviceName" .) -}}
{{- end }}

{{/* Labels for the wrapper's own resources. Prefixed so they cannot collide with
     the subchart's own `minio.*` defines -- template names are global across a
     chart and its subcharts, and the later definition silently wins. */}}
{{- define "platform-minio.labels" -}}
app.kubernetes.io/name: minio
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}
