{{/* Nome base do chart. */}}
{{- define "mural.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Nome completo: <release> ou <release>-<chart>. */}}
{{- define "mural.fullname" -}}
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

{{/* Labels comuns. */}}
{{- define "mural.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "mural.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mural
{{- end }}

{{/* Selector de um componente. Uso: include "mural.selectorLabels" (dict "ctx" . "component" "api") */}}
{{- define "mural.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mural.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* Nomes dos componentes. */}}
{{- define "mural.api.fullname" -}}{{ include "mural.fullname" . }}-api{{- end }}
{{- define "mural.web.fullname" -}}{{ include "mural.fullname" . }}-web{{- end }}
{{- define "mural.postgres.fullname" -}}{{ include "mural.fullname" . }}-postgres{{- end }}

{{/* Secret com a credencial do banco (próprio ou pré-existente). */}}
{{- define "mural.secretName" -}}
{{- if .Values.database.existingSecret }}
{{- .Values.database.existingSecret }}
{{- else }}
{{- include "mural.fullname" . }}-db
{{- end }}
{{- end }}

{{/* Referência de imagem repo:tag. */}}
{{- define "mural.image" -}}
{{- printf "%s:%s" .repository (toString .tag) }}
{{- end }}
