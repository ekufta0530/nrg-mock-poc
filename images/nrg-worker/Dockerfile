FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    # How the kubelet/runtime maps CPU shares to cgroup v2 cpu.weight on the target AMI.
    # "quadratic" (runc >= 1.3 / crun, e.g. the EKS 1.35 AL2023 AMI: 2000m -> 174) or
    # "legacy" (older runc: 2000m -> 79). scripts/verify-cpu-weight.sh tells you which.
    CGROUP_WEIGHT_MODEL=quadratic

RUN pip install --no-cache-dir redis==5.2.1 && useradd -u 10001 -m app

WORKDIR /app
COPY app/ /app/

USER 10001
EXPOSE 8080
ENTRYPOINT ["python", "/app/main.py"]
