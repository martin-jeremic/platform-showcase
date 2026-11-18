{{- /*
Shared helper set, identical in all six product-b charts (each chart is rendered on its own, so
the neutral `pb.` define names never collide).
*/ -}}
{{- define "pb.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "pb.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "pb.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "pb.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: product-b
{{- end }}

{{- /* Digest-only image reference; the render fails without one. */ -}}
{{- define "pb.image" -}}
{{- $digest := required "image.digest is required (sha256:<64 hex>)" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "image.digest must look like sha256:<64 hex>, got %q" $digest) -}}
{{- end -}}
{{- printf "%s@%s" (required "image.repository is required" .Values.image.repository) $digest -}}
{{- end }}

{{- /* Pod Security "restricted" baseline shared by every container in product-b. */ -}}
{{- define "pb.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{- define "pb.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end }}
