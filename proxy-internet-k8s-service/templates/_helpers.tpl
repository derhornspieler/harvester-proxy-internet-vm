{{/*
Expand the name of the chart.
*/}}
{{- define "proxy-internet.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "proxy-internet.fullname" -}}
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
{{- define "proxy-internet.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "proxy-internet.labels" -}}
helm.sh/chart: {{ include "proxy-internet.chart" . }}
{{ include "proxy-internet.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "proxy-internet.selectorLabels" -}}
app.kubernetes.io/name: {{ include "proxy-internet.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Harbor secret name — use existing or auto-generated.
*/}}
{{- define "proxy-internet.harborSecretName" -}}
{{- if .Values.harbor.existingSecret }}
{{- .Values.harbor.existingSecret }}
{{- else }}
{{- include "proxy-internet.fullname" . }}-harbor
{{- end }}
{{- end }}

{{/*
Charts manifest — generates pipe-delimited manifest for helm-sync.
*/}}
{{- define "proxy-internet.chartsManifest" -}}
{{- range .Values.charts }}
http|{{ .source }}|{{ .version }}|{{ .harborProject }}|{{ .name }}|{{ .envVar }}
{{- end }}
{{- end }}

{{/*
MinIO secret name.
*/}}
{{- define "proxy-internet.minioSecretName" -}}
{{- if .Values.minio.existingSecret }}
{{- .Values.minio.existingSecret }}
{{- else }}
{{- include "proxy-internet.fullname" . }}-minio
{{- end }}
{{- end }}
