FROM traefik:v3.5
# Add curl for healthcheck
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache curl
