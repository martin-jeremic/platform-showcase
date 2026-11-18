{{- define "product-a-db.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "product-a-db.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: product-a
{{- end }}

{{- /* Digest-only. The Job MUST run the exact build the Deployment rolls; a tag would defeat
     the whole point of this chart. */ -}}
{{- define "product-a-db.digest" -}}
{{- $digest := required "image.digest is required (sha256:<64 hex>): the migration runs one exact build" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "image.digest must look like sha256:<64 hex>, got %q" $digest) -}}
{{- end -}}
{{- $digest -}}
{{- end }}
