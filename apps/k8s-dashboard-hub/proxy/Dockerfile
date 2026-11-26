FROM node:22
WORKDIR /app
RUN echo '{"name":"k8s-dashboard-proxy","version":"1.0.0","main":"server.js","dependencies":{"express":"^4.18.2"}}' > package.json \
    && npm install --omit=dev --quiet
COPY server.js ./
EXPOSE 8090
USER node
CMD ["node", "server.js"]
