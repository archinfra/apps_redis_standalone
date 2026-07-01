ARG REDIS_BASE_IMAGE=docker.io/library/redis:8
FROM ${REDIS_BASE_IMAGE}

LABEL org.opencontainers.image.title="archinfra redis standalone"
LABEL org.opencontainers.image.description="Redis standalone image for archinfra offline .run packages"

COPY docker/redis/redis.conf /etc/redis/redis.conf
COPY docker/redis/redis-standalone-entrypoint /usr/local/bin/redis-standalone-entrypoint
COPY docker/redis/redis-healthcheck /usr/local/bin/redis-healthcheck

RUN chmod +x /usr/local/bin/redis-standalone-entrypoint /usr/local/bin/redis-healthcheck \
    && mkdir -p /data /etc/redis \
    && chown -R redis:redis /data /etc/redis

USER redis
WORKDIR /data
EXPOSE 6379

ENTRYPOINT ["/usr/local/bin/redis-standalone-entrypoint"]
CMD ["redis-server", "/tmp/redis.conf"]
