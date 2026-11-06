# Release image for the website (www.quantumofthought.com): the static build
# behind Caddy. Build from the repo root, like the PWA's:
#   docker build -f site_web/Dockerfile -t qot-site .
# NODE_VERSION matches mise.toml (CI checks); bump them together.
ARG NODE_VERSION=24.22.2
ARG CADDY_VERSION=2.10.2

# 1. The site.
FROM node:${NODE_VERSION}-slim AS site
WORKDIR /repo/site_web
COPY site_web/package.json site_web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY site_web/ ./
RUN npm run build && npm test

# 2. Served by Caddy.
FROM caddy:${CADDY_VERSION}-alpine
COPY site_web/Caddyfile /etc/caddy/Caddyfile
COPY site_web/bin/site /usr/local/bin/site
COPY --from=site /repo/site_web/dist /srv
ENV PORT=8080
EXPOSE 8080
CMD ["site"]
