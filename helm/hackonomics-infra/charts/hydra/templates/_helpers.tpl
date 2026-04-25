{{- define "hydra.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "hydra.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "hydra" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "hydra.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "hydra.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "hydra.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hydra.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
