# syntax=docker/dockerfile:1
# Front do Mural — estático servido por nginx, com proxy de /api parametrizável.
# Contexto de build: app/web
#   docker build -f app/docker/web.Dockerfile -t mural-web app/web
#
# nginx-unprivileged é a variante oficial do nginx que roda como usuário não-root
# (uid 101) e escuta em 8080 — mesma porta que o template já usa.
FROM nginxinc/nginx-unprivileged:1.27-alpine

# O entrypoint do nginx roda envsubst em /etc/nginx/templates/*.template no boot
# e grava o resultado em /etc/nginx/conf.d/. Assim ${API_UPSTREAM} vem do ambiente
# e a MESMA imagem serve em qualquer lugar (compose, kind, produção) sem rebuild.
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY index.html app.js styles.css /usr/share/nginx/html/

# Default pensado para o compose; no cluster o chart sobrescreve via ConfigMap.
ENV API_UPSTREAM=api:8080
EXPOSE 8080
