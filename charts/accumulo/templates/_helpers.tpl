{{/*
Expand the name of the chart.
*/}}
{{- define "accumulo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "accumulo.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "accumulo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "accumulo.labels" -}}
helm.sh/chart: {{ include "accumulo.chart" . }}
{{ include "accumulo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "accumulo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "accumulo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component labels
*/}}
{{- define "accumulo.componentLabels" -}}
{{ include "accumulo.labels" . }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "accumulo.serviceAccountName" -}}
{{- if .Values.auth.serviceAccount.create }}
{{- default (include "accumulo.fullname" .) .Values.auth.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.auth.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Accumulo image
*/}}
{{- define "accumulo.image" -}}
{{- $registry := .Values.global.imageRegistry | default .Values.accumulo.image.registry }}
{{- printf "%s/%s:%s" $registry .Values.accumulo.image.repository .Values.accumulo.image.tag }}
{{- end }}

{{/*
Alluxio image
*/}}
{{- define "alluxio.image" -}}
{{- $registry := .Values.global.imageRegistry | default .Values.alluxio.image.registry }}
{{- printf "%s/%s:%s" $registry .Values.alluxio.image.repository .Values.alluxio.image.tag }}
{{- end }}

{{/*
ZooKeeper connection string
*/}}
{{- define "accumulo.zookeeperHosts" -}}
{{- if .Values.zookeeper.enabled }}
{{- $fullname := include "accumulo.fullname" . }}
{{- printf "%s-zookeeper:2181" $fullname }}
{{- else }}
{{- .Values.zookeeper.external.hosts }}
{{- end }}
{{- end }}

{{/*
Storage configuration based on provider
*/}}
{{- define "accumulo.storageConfig" -}}
{{- $provider := .Values.storage.provider }}
{{- if eq $provider "s3" }}
alluxio.master.mount.table.root.ufs=s3://{{ .Values.storage.s3.bucket }}/
{{- else if eq $provider "gcs" }}
alluxio.master.mount.table.root.ufs=gs://{{ .Values.storage.gcs.bucket }}/
{{- else if eq $provider "azure" }}
alluxio.master.mount.table.root.ufs=abfs://{{ .Values.storage.azure.container }}@{{ .Values.storage.azure.account }}.dfs.core.windows.net/
{{- else if eq $provider "minio" }}
alluxio.master.mount.table.root.ufs=s3://{{ .Values.storage.minio.bucket }}/
{{- end }}
{{- end }}

{{/*
Pod anti-affinity configuration
*/}}
{{- define "accumulo.podAntiAffinity" -}}
{{- if .podAntiAffinity.enabled }}
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchLabels:
        {{- include "accumulo.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: {{ .component }}
    topologyKey: {{ .podAntiAffinity.topologyKey }}
{{- end }}
{{- end }}

{{/*
Resource configuration
*/}}
{{- define "accumulo.resources" -}}
{{- if .resources }}
resources:
  {{- toYaml .resources | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Common environment variables for Accumulo containers
*/}}
{{- define "accumulo.commonEnv" -}}
- name: ACCUMULO_INSTANCE_NAME
  value: {{ .Values.accumulo.instance.name | quote }}
- name: ACCUMULO_INSTANCE_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "accumulo.fullname" . }}-secret
      key: instance-secret
- name: ZOOKEEPER_HOSTS
  value: {{ include "accumulo.zookeeperHosts" . | quote }}
- name: ACCUMULO_LOG_DIR
  value: "/opt/accumulo/logs"
{{- end }}