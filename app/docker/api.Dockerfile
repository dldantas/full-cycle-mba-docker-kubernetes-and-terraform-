# syntax=docker/dockerfile:1
# API do Mural — build multi-stage.
# Contexto de build: app/api
#   docker build -f app/docker/api.Dockerfile -t mural-api app/api

# ---- build: toolchain Go completa, descartada no final ----
FROM golang:1.23-alpine AS build
WORKDIR /src

# Dependências primeiro: camada cacheada enquanto go.mod/go.sum não mudarem.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO_ENABLED=0 -> binário 100% estático (não depende de libc), roda em scratch/distroless.
# -trimpath / -s -w -> sem caminhos locais nem tabela de símbolos/debug.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/api .

# ---- runtime: só o binário ----
# distroless/static: sem shell nem gerenciador de pacotes, com CA certs, tzdata
# e usuário nonroot (uid 65532) — praticamente o tamanho do binário.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /api
ENV PORT=8080
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/api"]
