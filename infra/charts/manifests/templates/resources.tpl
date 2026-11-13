{{- /*
Render every object from .Values.resources as its own YAML document. Values are
data, not templates, so strings like "{{ .password }}" (External Secrets
templating) reach the cluster unchanged. The .tpl extension keeps YAML linters
and IaC scanners from parsing this Go template as a Kubernetes manifest.
*/ -}}
{{- range .Values.resources }}
---
{{ toYaml . }}
{{- end }}
