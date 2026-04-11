# Rearc Quest — Submission

**Repo:** 
https://github.com/srinathsankara/quest

**Live deployment:**
https://quest-alb-794288304.us-east-2.elb.amazonaws.com/

used charlesraegen038@gmail.com dummy account for AWS free account.
s
## What was built

Deployed the Rearc quest app on AWS using Docker, Terraform, and ECS Fargate with an Application Load Balancer and TLS.

| Index page
| Docker
| Secret word 
| Load balanced 
| TLS

## Architecture

```
Internet
    |
ALB (HTTPS 443) — HTTP 80 redirects to HTTPS
    |
ECS Fargate — port 3000
    |
charlesragen/quest:latest (Docker Hub)
+ SECRET_WORD injected as env var
```

- VPC with 2 public subnets across 2 availability zones
- ECS tasks only accept inbound traffic from the ALB security group
- Self-signed cert imported into ACM for TLS
- CloudWatch logs for container output

---

## Run locally

```bash
docker build -t quest .

# First run — get the secret word from /
docker run -p 3000:3000 quest

# Re-run with the secret word injected
docker run -p 3000:3000 -e SECRET_WORD="your_secret_word" quest
```

---

## Deploy to AWS

**Prerequisites:** Terraform, AWS CLI (`aws configure`), OpenSSL

**1. Generate TLS cert**

```bash
cd terraform
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout cert.key -out cert.crt \
  -subj "/CN=quest.internal/O=Quest" \
  -set_serial 1
```

**2. Deploy**

```bash
terraform init
terraform apply -var="secret_word=<your_secret_word>"
```

The ALB URL prints as output when complete.

**3. Tear down**

```bash
terraform destroy -var="secret_word=<your_secret_word>"
```

---

## Terraform layout

terraform/
main.tf       # provider config (aws + tls)
variables.tf  # region, secret_word, image
vpc.tf        # VPC, subnets, IGW, route tables
sg.tf         # ALB sg (80/443), ECS sg (3000 from ALB only)
acm.tf        # self-signed cert imported into ACM
alb.tf        # ALB, target group, HTTP→HTTPS redirect, HTTPS listener
ecs.tf        # cluster, task def, IAM role, service,CloudWatch logs
outputs.tf    # prints ALB URL
```

---

## Given more time, I would improve...
- On Resiliency by adding full multi cloud or add auto scaling policy.
- Remote Terraform state** — state is local right now; would move to S3.
- Would use a secrets manager to store the secret word.
- Would use github actions as part of CICD.
- Insted of self signed cert a proper domain with ACM DNS validation.
- GCP deployment** — started the GCP setup but billing/API enablement took time; would complete it for full multi-cloud coverage


