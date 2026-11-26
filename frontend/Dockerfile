# OPS-01 / OPS-02: the SPA is built to static files and served by nginx, which also proxies /api to the Rails web
# service so the browser sees one origin (cookie stays SameSite=Lax; Secure; HttpOnly, no CORS).
FROM node:22-slim AS build
WORKDIR /app
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ .
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
# Build with the repository root as context: docker build -f frontend/Dockerfile .
COPY deploy/nginx.conf /etc/nginx/templates/default.conf.template
ENV API_UPSTREAM=http://web:3000
EXPOSE 80
