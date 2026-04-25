{{- define "central-auth.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "central-auth.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "central-auth" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "central-auth.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "central-auth.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "central-auth.selectorLabels" -}}
app.kubernetes.io/name: {{ include "central-auth.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
