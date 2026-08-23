FROM python:3.11-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --upgrade pip && pip install --no-cache-dir --prefix=/install -r requirements.txt \
    && find /install -type d -name '__pycache__' -exec rm -rf {} + \
    && find /install -type f -name '*.pyc' -delete

#stage2
FROM python:3.11-slim
WORKDIR /app
RUN useradd --create-home --shell /bin/bash appuser && chown appuser:appuser /app
COPY --from=builder /install /usr/local
COPY --chown=appuser:appuser . .
USER appuser
EXPOSE 5000
CMD ["gunicorn", "--workers=1", "-b", "0.0.0.0:5000", "run:app"]
