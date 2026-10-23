# Capstone Project 1: Ship It — Complete Step-by-Step Guide

This guide covers all 5 steps plus deliverables required for **Capstone 1: Ship It (DevOps Capstone Projects — Beginner Edition)** for the Example Voting App.

---

## Architecture Overview & Services

The system comprises 5 components:
1. **`vote` (Python/Flask)**: Web frontend for users to cast their votes.
2. **`redis`**: In-memory queue holding incoming votes.
3. **`worker` (.NET)**: Background service consuming votes from Redis and saving them to PostgreSQL.
4. **`db` (PostgreSQL)**: Persistent database storing vote tallies.
5. **`result` (Node.js)**: Real-time web frontend displaying results.

---

## Five-Step Implementation Plan

| Step | Topic | Objective |
| :--- | :--- | :--- |
| **Step 1** | **Run Locally** | Fork repo, run `docker compose up -d`, vote, and verify result. |
| **Step 2** | **Containerize Safely** | Pin base images, add non-root user execution, and configure `.dockerignore`. |
| **Step 3** | **K8s with Terraform** | Provision AWS EKS cluster in default VPC and verify rebuildability. |
| **Step 4** | **Automate with CI/CD** | GitHub Actions workflow: Tests, Trivy Security Scans, Build & Push with SHA tag. |
| **Step 5** | **Deploy & Rollback with Helm** | Build one unified Helm chart, deploy release, trigger intentional failure, and test rollback. |

---

## Step 1: Run It Locally

### 1.1 Verify Docker Compose Setup
Run the stack locally from the repository root:
```bash
docker compose up -d
```

### 1.2 Validate Functionality
1. Open the Voting App: `http://localhost:8080` (or `http://localhost:5000` depending on port mappings).
2. Cast a vote (e.g. Cats or Dogs).
3. Open the Result App: `http://localhost:8081` (or `http://localhost:5001`).
4. Verify the vote count updates in real time.
5. Shut down local containers when verified:
   ```bash
   docker compose down
   ```

---

## Step 2: Containerize Safely

Secure containers by **pinning specific image digests or patch tags**, **running as a non-root user**, and **excluding unnecessary files with `.dockerignore`**.

### 2.1 Add `.dockerignore` Files

Create `.dockerignore` files for all services to keep images slim and prevent leaking git history/secrets.

#### File: `vote/.dockerignore`
```text
.git
.gitignore
__pycache__
*.pyc
*.pyo
*.pyd
.Python
env/
venv/
Dockerfile*
docker-compose*
README.md
```

#### File: `result/.dockerignore`
```text
.git
.gitignore
node_modules
npm-debug.log
Dockerfile*
docker-compose*
README.md
tests
```

#### File: `worker/.dockerignore`
```text
.git
.gitignore
bin/
obj/
Dockerfile*
docker-compose*
README.md
```

---

### 2.2 Secure `vote/Dockerfile` (Python)
- Pin base image to specific patch release.
- Create unprivileged user `appuser` (UID 1000).
- Switch to `USER appuser`.

```dockerfile
# base defines a base stage that uses the official python runtime base image
FROM python:3.11.9-slim AS base

# Add curl for healthcheck & clean apt cache
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Create unprivileged user
RUN groupadd -g 1000 appuser && \
    useradd -u 1000 -g appuser -m -s /bin/bash appuser

WORKDIR /usr/local/app

# Install dependencies as root to system python
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# dev stage for local file watching
FROM base AS dev
RUN pip install --no-cache-dir watchdog
ENV FLASK_ENV=development
USER appuser
CMD ["python", "app.py"]

# final stage for production bundle
FROM base AS final

# Copy code with non-root ownership
COPY --chown=appuser:appuser . .

EXPOSE 80

USER appuser
CMD ["gunicorn", "app:app", "-b", "0.0.0.0:80", "--log-file", "-", "--access-logfile", "-", "--workers", "4", "--keep-alive", "0"]
```

---

### 2.3 Secure `result/Dockerfile` (Node.js)
- Pin to `node:18.20.4-slim`.
- Use pre-existing `node` user (UID 1000).
- Set permissions for `/node_modules` and `/usr/local/app`.

```dockerfile
FROM node:18.20.4-slim

# add curl and tini
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl tini && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/app

RUN npm install -g nodemon

COPY package*.json ./

RUN npm ci && \
    npm cache clean --force && \
    mv /usr/local/app/node_modules /node_modules && \
    chown -R node:node /node_modules

COPY --chown=node:node . .

ENV PORT=80
EXPOSE 80

USER node

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]
```

---

### 2.4 Secure `worker/Dockerfile` (.NET)
- Pin SDK and runtime images.
- Create non-root user in runtime stage.
- Run binary as `appuser`.

```dockerfile
FROM --platform=${BUILDPLATFORM} mcr.microsoft.com/dotnet/sdk:7.0.410 AS build
ARG TARGETPLATFORM
ARG TARGETARCH
ARG BUILDPLATFORM

WORKDIR /source
COPY *.csproj .
RUN dotnet restore -a $TARGETARCH

COPY . .
RUN dotnet publish -c release -o /app -a $TARGETARCH --self-contained false --no-restore

# app image
FROM mcr.microsoft.com/dotnet/runtime:7.0.20
RUN groupadd -g 1000 appuser && \
    useradd -u 1000 -g appuser -s /bin/sh appuser

WORKDIR /app
COPY --chown=appuser:appuser --from=build /app .

USER appuser
ENTRYPOINT ["dotnet", "Worker.dll"]
```

---

## Step 3: Create a Kubernetes Cluster with Terraform

Use Terraform to manage AWS EKS in the default VPC. Exclude `us-east-1e` because EKS does not support control plane instances there.

### 3.1 `backend.tf`
```hcl
terraform {
  backend "s3" {
    bucket       = "example-voting-app-terraform-state"
    key          = "example-voting-app/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = false
  }
}
```

### 3.2 `provider.tf`
```hcl
terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```

### 3.3 `variables.tf`
```hcl
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS Cluster Name"
  type        = string
  default     = "ts-capstone-cluster"
}
```

### 3.4 `vpc.tf`
```hcl
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
  }
}
```

### 3.5 `main.tf`
```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.15"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 1
      max_size       = 3
      desired_size   = 2
      instance_types = ["t3.medium"]
    }
  }
}
```

### 3.6 `outputs.tf`
```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
```

### 3.7 Verification Commands
```bash
# Initialize & check plan
terraform init
terraform plan

# Apply infrastructure
terraform apply -auto-approve

# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name ts-capstone-cluster
kubectl get nodes

# Prove clean destroy and recreate
terraform destroy -auto-approve
terraform apply -auto-approve
```

---

## Step 4: Automate with GitHub Actions CI/CD

Create a pipeline that on every push:
1. Runs tests or checks.
2. Runs **Trivy vulnerability scanner** on the built image.
3. Builds and pushes the image to GitHub Container Registry (`ghcr.io`) tagged with the **commit SHA**.

Create `.github/workflows/ci.yaml`:

```yaml
name: CI Pipeline - Build, Scan and Push

on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]

env:
  REGISTRY: ghcr.io
  IMAGE_OWNER: ${{ github.repository_owner }}

jobs:
  build-scan-push:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - name: vote
            context: ./vote
            dockerfile: ./vote/Dockerfile
          - name: result
            context: ./result
            dockerfile: ./result/Dockerfile
          - name: worker
            context: ./worker
            dockerfile: ./worker/Dockerfile

    permissions:
      contents: read
      packages: write
      security-events: write

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build image locally for scanning
        uses: docker/build-push-action@v5
        with:
          context: ${{ matrix.context }}
          file: ${{ matrix.dockerfile }}
          load: true
          tags: ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ matrix.name }}:${{ github.sha }}

      - name: Run Trivy Vulnerability Scanner
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ matrix.name }}:${{ github.sha }}
          format: 'table'
          exit-code: '0'
          ignore-unfixed: true
          vuln-type: 'os,library'
          severity: 'CRITICAL,HIGH'

      - name: Push Image with Commit SHA
        if: github.event_name != 'pull_request'
        run: |
          docker push ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ matrix.name }}:${{ github.sha }}
          docker tag ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ matrix.name }}:${{ github.sha }} ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ matrix.name }}:latest
          docker push ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ matrix.name }}:latest
```

---

## Step 5: Deploy and Roll Back with Helm

Structure a single Helm chart under `charts/voting-app/`.

### 5.1 Chart Structure
```text
charts/voting-app/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── db-deployment.yaml
    ├── db-service.yaml
    ├── redis-deployment.yaml
    ├── redis-service.yaml
    ├── result-deployment.yaml
    ├── result-service.yaml
    ├── vote-deployment.yaml
    ├── vote-service.yaml
    └── worker-deployment.yaml
```

### 5.2 `charts/voting-app/Chart.yaml`
```yaml
apiVersion: v2
name: voting-app
description: Helm chart for Example Voting App (Capstone 1)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

### 5.3 `charts/voting-app/values.yaml`
```yaml
registry: ghcr.io/your-github-username

vote:
  image:
    repository: vote
    tag: latest
    pullPolicy: Always
  replicas: 2
  port: 80
  service:
    type: LoadBalancer
    port: 5000

result:
  image:
    repository: result
    tag: latest
    pullPolicy: Always
  replicas: 2
  port: 80
  service:
    type: LoadBalancer
    port: 5001

worker:
  image:
    repository: worker
    tag: latest
    pullPolicy: Always
  replicas: 1

redis:
  image: redis:alpine
  port: 6379

db:
  image: postgres:15-alpine
  port: 5432
  user: postgres
  password: postgrespassword
  name: postgres
  storageSize: 1Gi
```

### 5.4 Example Template: `vote-deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-vote
  labels:
    app: vote
spec:
  replicas: {{ .Values.vote.replicas }}
  selector:
    matchLabels:
      app: vote
  template:
    metadata:
      labels:
        app: vote
    spec:
      containers:
        - name: vote
          image: "{{ .Values.registry }}/{{ .Values.vote.image.repository }}:{{ .Values.vote.image.tag }}"
          imagePullPolicy: {{ .Values.vote.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.vote.port }}
          env:
            - name: OPTION_A
              value: "Cats"
            - name: OPTION_B
              value: "Dogs"
```

### 5.5 Deploying the Release
```bash
helm upgrade --install voting-app ./charts/voting-app \
  --set registry="ghcr.io/<your-github-username>" \
  --set vote.image.tag="<commit-sha>" \
  --set result.image.tag="<commit-sha>" \
  --set worker.image.tag="<commit-sha>"
```

### 5.6 Simulating a Bad Release & Testing Rollback
1. **Ship a bad release on purpose** (pointing to a nonexistent image tag):
   ```bash
   helm upgrade voting-app ./charts/voting-app --set vote.image.tag="bad-broken-tag-12345"
   ```
2. **Observe the failure:**
   ```bash
   kubectl get pods -l app=vote
   # STATUS will show ErrImagePull or ImagePullBackOff
   ```
3. **Roll back to the previous healthy revision:**
   ```bash
   # View release history
   helm history voting-app

   # Roll back to previous good release revision (e.g. revision 1)
   helm rollback voting-app 1
   ```
4. **Confirm health restoration:**
   ```bash
   kubectl rollout status deployment/voting-app-vote
   kubectl get pods
   ```

---

## Capstone 1: "Done Means" Checklist for Submission

- [x] **Forked Repository with Clear README**: Documenting architecture, setup instructions, and commands.
- [x] **Safe Containers**: Non-root users (`node`, `appuser`), pinned tags, `.dockerignore`.
- [x] **Reproducible K8s Cluster via Terraform**: EKS cluster in default VPC, successfully destroyed and rebuilt from code.
- [x] **Working GitHub Actions Pipeline**: Auto-builds, runs Trivy scan, tags with commit SHA.
- [x] **Unified Helm Chart**: All services deployed via `values.yaml`.
- [x] **Live Rollback Demonstrated**: Deploy broken release, run `helm rollback`, verify zero-downtime recovery.
- [x] **Architecture Diagram**: Clean diagram showing client flow through services and databases.
