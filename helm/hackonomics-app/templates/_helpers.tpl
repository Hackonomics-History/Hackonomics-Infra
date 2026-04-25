{{- define "hackonomics-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "hackonomics-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "hackonomics-app" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "hackonomics-app.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "hackonomics-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Component-scoped selector labels — prevents Service from routing to worker/beat pods */}}
{{- define "hackonomics-app.selectorLabels.web" -}}
app.kubernetes.io/name: {{ include "hackonomics-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: web
{{- end }}

{{- define "hackonomics-app.selectorLabels.worker" -}}
app.kubernetes.io/name: {{ include "hackonomics-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: worker
{{- end }}

{{- define "hackonomics-app.selectorLabels.beat" -}}
app.kubernetes.io/name: {{ include "hackonomics-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: beat
{{- end }}
