# ---- Stage 1: Build React app ----
FROM node:20-alpine AS builder

WORKDIR /build
COPY package*.json ./
RUN npm install

COPY public/ ./public/
COPY src/ ./src/

RUN npm run build

# ---- Stage 2: Serve with Nginx ----
FROM nginx:1.27-alpine

# Upgrade openssl/libcrypto to >=3.3.7-r0 to fix CVE-2026-31789 (CRITICAL)
RUN apk upgrade --no-cache libcrypto3 libssl3

RUN rm /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/conf.d/default.conf

COPY --from=builder /build/build /usr/share/nginx/html

RUN chown -R nginx:nginx /usr/share/nginx/html && \
    chown -R nginx:nginx /var/cache/nginx && \
    chown -R nginx:nginx /var/log/nginx && \
    touch /var/run/nginx.pid && chown nginx:nginx /var/run/nginx.pid

USER nginx

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:80/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
