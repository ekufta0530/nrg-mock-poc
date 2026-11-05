FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

RUN pip install --no-cache-dir redis==5.2.1 && useradd -u 10001 -m app

WORKDIR /app
COPY app/ /app/

USER 10001
EXPOSE 8080
ENTRYPOINT ["python", "/app/main.py"]
