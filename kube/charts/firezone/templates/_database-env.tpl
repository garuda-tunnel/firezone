{{/* Connection contract shared by the server and OIDC release tooling. */}}
{{- define "firezone.databaseEnv" -}}
{{- range $entry := list (dict "env" "HOST" "key" "host") (dict "env" "PORT" "key" "port") (dict "env" "NAME" "key" "dbname") (dict "env" "USER" "key" "username") (dict "env" "PASSWORD" "key" "password") }}
- name: DATABASE_{{ $entry.env }}
  valueFrom:
    secretKeyRef:
      name: {{ $.Values.databaseSecretName | quote }}
      key: {{ $entry.key | quote }}
{{- end }}
{{- end }}
