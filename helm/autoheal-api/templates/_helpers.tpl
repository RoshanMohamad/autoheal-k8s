{{- define "autoheal-api.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "autoheal-api.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "autoheal-api.labels" -}}
app.kubernetes.io/name: {{ include "autoheal-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "autoheal-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "autoheal-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
