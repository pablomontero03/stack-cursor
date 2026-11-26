# Dashboard CI/CD — imagen ligera de producción
FROM node:20-alpine

WORKDIR /app

# Solo dependencias de producción (express); sin devDeps ni build step.
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund

ARG BUILD_DATE=unknown
COPY src ./src

ENV NODE_ENV=production \
    PORT=8080 \
    HOST=0.0.0.0

# Usuario no-root (node ya existe en la imagen alpine oficial).
USER node

EXPOSE 8080

# Healthcheck simple contra /healthz
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

CMD ["node", "src/server.js"]
