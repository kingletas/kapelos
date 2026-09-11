# TLS certificate

`kapelos cert` writes `cert.pem` and `key.pem` here, and `etc/traefik/dynamic/tls.yml` to tell Traefik to serve them. All three are ignored by git.

Until they exist, Traefik serves a self-signed certificate of its own, so HTTPS works and the browser warns.
