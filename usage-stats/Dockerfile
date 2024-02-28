FROM timberio/vector:latest-alpine

WORKDIR /etc/vector

ENV PORT 8080
ENV HOST 0.0.0.0

COPY vector_config.yaml /etc/vector/vector_config.yaml

EXPOSE 8080

CMD ["--config", "/etc/vector/vector_config.yaml"]