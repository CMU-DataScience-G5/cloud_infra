FROM python:3.12-slim

WORKDIR /app
# CPU-only torch (~200 MB instead of ~2.5 GB with CUDA): MONAI pre/post-processing only.
RUN pip install --no-cache-dir torch==2.14.1 --index-url https://download.pytorch.org/whl/cpu
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py pipeline.py ./

RUN useradd --uid 10001 app
USER 10001

EXPOSE 8080
# Single process per pod (Prometheus metrics are per-process); scale with replicas/HPA.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080", "--timeout-keep-alive", "650"]
