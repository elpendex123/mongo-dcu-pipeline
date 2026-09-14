{{/* Chart name. */}}
{{- define "app.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Resource name: the release name, which is the chart name in every command this project documents. */}}
{{- define "app.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "app.labels" -}}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/part-of: mongo-dcu-pipeline
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | trunc 63 | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | trunc 63 | quote }}
{{- end -}}

{{/*
The image reference, failing the render rather than the rollout when it is
wrong. "latest" is refused: a moving tag cannot be rolled back to.
*/}}
{{- define "app.image" -}}
{{- $repository := required "image.repository is required - render ansible/generated/values-<env>.yaml and pass it with -f" .Values.image.repository -}}
{{- $tag := required "image.tag is required - render ansible/generated/values-<env>.yaml and pass it with -f" .Values.image.tag -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must name a commit, not latest - a moving tag cannot be rolled back to" -}}
{{- end -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}

{{- define "app.serviceAccountName" -}}
{{- required "serviceAccount.name is required - the service account Ansible created" .Values.serviceAccount.name -}}
{{- end -}}
