FROM node:18.20.8-slim

# add curl for healthcheck; upgrade first to pick up patched OS packages
# hadolint ignore=DL3005,DL3008
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends curl tini && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/app

COPY package*.json ./

RUN npm ci && \
    npm cache clean --force && \
    mv /usr/local/app/node_modules /node_modules

# Copy with ownership set at write time — avoids a separate chown layer
COPY --chown=node:node . .

USER node

# Set default environment variables for both the application and PostgreSQL connection
ENV PORT=80 \
    PG_HOST=db \
    PG_PORT=5432 \
    PG_USER=postgres \
    PG_PASSWORD=postgres \
    PG_DATABASE=postgres

EXPOSE 80

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]
