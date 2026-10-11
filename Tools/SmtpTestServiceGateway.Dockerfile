# The digest is resolved and recorded during the native gateway acceptance.
FROM python:3.14-alpine@sha256:f6a589d43c42b9e7f7dc67a12d37132491f362859a5d750607710cc56da3bc72

RUN addgroup -S smtp-gateway && adduser -S -G smtp-gateway smtp-gateway
WORKDIR /app
COPY --chown=smtp-gateway:smtp-gateway Tools/SmtpTestServiceGateway.py /app/SmtpTestServiceGateway.py
USER smtp-gateway
EXPOSE 1025
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 CMD python -c "import socket; s=socket.create_connection(('127.0.0.1',1025),2); s.close()"
ENTRYPOINT ["python", "/app/SmtpTestServiceGateway.py"]
