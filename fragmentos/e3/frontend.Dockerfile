FROM node:22-alpine AS build

WORKDIR /app
ENV NG_CLI_ANALYTICS=false
COPY package*.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

# Imagen estatica: Caddy sirve la aplicacion compilada y hace de mismo origen
# para /v1/* en el gateway de la nube.
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/dist/vidalstore-frontend/browser /srv

EXPOSE 80
