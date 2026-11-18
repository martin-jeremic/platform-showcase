{{- define "refdata.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "refdata.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "refdata.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "refdata.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: product-a
{{- end }}

{{- define "refdata.image" -}}
{{- $digest := required "image.digest is required (sha256:<64 hex>)" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "image.digest must look like sha256:<64 hex>, got %q" $digest) -}}
{{- end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end }}

{{- /* Kubernetes object names cannot contain "_" or capitals: commodityCodes -> commoditycodes. */ -}}
{{- define "refdata.dnsName" -}}
{{- . | replace "_" "-" | lower -}}
{{- end }}

{{- /*
Pod-level fields shared by every Job pod and the consumer: identity, pull secrets, security
context, placement. Param: the chart root context.
*/ -}}
{{- define "refdata.podSpecCommon" -}}
automountServiceAccountToken: false
serviceAccountName: {{ include "refdata.fullname" . }}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- /*
Container spec shared by every CronJob, every seed Job and the consumer Deployment.
Params: root (the chart context), args (list of CLI args), extraEnv (list), resources (map).
*/ -}}
{{- define "refdata.container" -}}
{{- $root := .root -}}
{{- $secret := $root.Values.azureKeyVault.syncedSecretName -}}
- name: loader
  image: {{ include "refdata.image" $root | quote }}
  imagePullPolicy: {{ $root.Values.image.pullPolicy }}
  {{- with .args }}
  args:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml $root.Values.securityContext | nindent 4 }}
  envFrom:
    - configMapRef:
        name: {{ include "refdata.fullname" $root }}-config
  env:
    - name: Database__PostgresConnection
      valueFrom:
        secretKeyRef:
          name: {{ $secret }}
          key: Database
    - name: Broker__Password
      valueFrom:
        secretKeyRef:
          name: {{ $secret }}
          key: BrokerPassword
    {{- with .extraEnv }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: staging
      mountPath: /app/staging
    {{- if $root.Values.azureKeyVault.enabled }}
    - name: secrets-store
      mountPath: /mnt/secrets-store
      readOnly: true
    {{- end }}
{{- end }}

{{- define "refdata.volumes" -}}
- name: tmp
  emptyDir: {}
{{- /* Staging is per run: content-addressed downloads only need to live as long as the load. */}}
- name: staging
  emptyDir:
    sizeLimit: 2Gi
{{- if .Values.azureKeyVault.enabled }}
- name: secrets-store
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: {{ .Values.azureKeyVault.secretProviderClassName | quote }}
{{- end }}
{{- end }}

{{- /*
Job spec shared by the CronJobs' jobTemplate and the seed Jobs. Params: root, args.
*/ -}}
{{- define "refdata.jobSpec" -}}
{{- $root := .root -}}
{{- $jd := $root.Values.jobDefaults -}}
{{- /* ttlSecondsAfterFinished is a JobSpec field. It lives HERE, inside jobTemplate.spec, never on
     the CronJobSpec one level up: the API server used to prune it there silently, but a
     server-side apply rejects the whole manifest ("field not declared in schema") and with it the
     entire release. Finished Jobs (and their pods' logs) are kept for a week, then collected. */}}
ttlSecondsAfterFinished: {{ $jd.ttlSecondsAfterFinished }}
backoffLimit: {{ $jd.backoffLimit }}
activeDeadlineSeconds: {{ $jd.activeDeadlineSeconds }}
template:
  metadata:
    labels:
      {{- include "refdata.selectorLabels" $root | nindent 6 }}
      example.com/role: loader
      {{- if $root.Values.workloadIdentity.enabled }}
      azure.workload.identity/use: "true"
      {{- end }}
  spec:
    restartPolicy: Never
    {{- include "refdata.podSpecCommon" $root | nindent 4 }}
    containers:
      {{- include "refdata.container" (dict "root" $root "args" .args "resources" $root.Values.resources) | nindent 6 }}
    volumes:
      {{- include "refdata.volumes" $root | nindent 6 }}
{{- end }}
