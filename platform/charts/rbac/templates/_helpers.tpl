{{/*
Common labels stamped on every object this chart owns.
*/}}
{{- define "rbac.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform
example.com/access-tier: entra
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Input validation. Included at the top of every template so a bad values file fails
at render time rather than after half the objects have already landed on the cluster.

The GUID check is the important one. Kubernetes accepts ANY string as a Group
subject and never verifies it resolves, so a typo'd or empty object ID produces a
RoleBinding that silently grants nothing — the failure surfaces days later as a
developer saying "Forbidden". Refusing to render is the cheaper failure.

Emits no output.
*/}}
{{- define "rbac.validate" -}}
{{- $guid := "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" -}}
{{- $nilGuid := "00000000-0000-0000-0000-000000000000" -}}
{{- $roles := list "view" "edit" "admin" -}}
{{- $fillHint := "fill it from the Entra groups: az ad group show --group <name> --query id -o tsv" -}}
{{- $seenNs := dict -}}
{{- range .Values.namespaces -}}
  {{- if not .name -}}
    {{- fail "every namespaces[] entry needs a name" -}}
  {{- end -}}
  {{- if hasKey $seenNs .name -}}
    {{- fail (printf "namespaces[] lists %q more than once — two RoleBindings would fight over the same namespace" .name) -}}
  {{- end -}}
  {{- $_ := set $seenNs .name true -}}
  {{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .name) -}}
    {{- fail (printf "namespaces[%s].name is not a valid DNS-1123 label (lowercase alphanumerics and '-', starting and ending alphanumeric)" .name) -}}
  {{- end -}}
  {{- $role := .role | default "edit" -}}
  {{- if not (has $role $roles) -}}
    {{- fail (printf "namespaces[%s].role must be one of view|edit|admin (got %q)" .name $role) -}}
  {{- end -}}
  {{- $id := .entraGroupId | default "" -}}
  {{- if not (regexMatch $guid $id) -}}
    {{- fail (printf "namespaces[%s].entraGroupId must be an Entra group object ID (GUID); got %q — %s" .name $id $fillHint) -}}
  {{- end -}}
  {{- if eq $id $nilGuid -}}
    {{- fail (printf "namespaces[%s].entraGroupId is the all-zeros placeholder GUID — %s" .name $fillHint) -}}
  {{- end -}}
{{- end -}}
{{- $seenCrb := dict -}}
{{- range .Values.clusterBindings -}}
  {{- if not .name -}}
    {{- fail "every clusterBindings[] entry needs a name (it becomes the ClusterRoleBinding name)" -}}
  {{- end -}}
  {{- if hasKey $seenCrb .name -}}
    {{- fail (printf "clusterBindings[] lists %q more than once" .name) -}}
  {{- end -}}
  {{- $_ := set $seenCrb .name true -}}
  {{- $cr := .clusterRole | default "" -}}
  {{- if not (has $cr $roles) -}}
    {{- fail (printf "clusterBindings[%s].clusterRole must be one of view|edit|admin (got %q). cluster-admin is not grantable here — AKS owns that tier via admin_group_object_ids" .name $cr) -}}
  {{- end -}}
  {{- $id := .entraGroupId | default "" -}}
  {{- if not (regexMatch $guid $id) -}}
    {{- fail (printf "clusterBindings[%s].entraGroupId must be an Entra group object ID (GUID); got %q — %s" .name $id $fillHint) -}}
  {{- end -}}
  {{- if eq $id $nilGuid -}}
    {{- fail (printf "clusterBindings[%s].entraGroupId is the all-zeros placeholder GUID — %s" .name $fillHint) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
