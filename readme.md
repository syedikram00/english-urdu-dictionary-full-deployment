# English–Urdu Dictionary — Full Cloud Deployment

A small dictionary web app — look up an English word and get its definition, an example sentence, and its Urdu translation — used as the vehicle for a much bigger goal: provisioning real AWS infrastructure with Terraform, deploying onto it with Helm, and wiring up a GitHub Actions pipeline that takes a `git push` all the way to a live, internet-facing update on a real Kubernetes cluster.

## What It Does

Type an English word into the dashboard. The app:
1. Calls the [Free Dictionary API](https://dictionaryapi.dev/) for the definition and an example sentence
2. Translates the definition into Urdu
3. Returns all three, displayed in a simple, clean UI (Urdu rendered right-to-left)

## Why This Project Exists

Every other project built alongside this one ran on a local `kind` cluster — a real learning tool, but ultimately a simulation on a laptop. This project's actual purpose was to answer: *what does it take to run something for real, on the actual internet, provisioned as code, deployed automatically?* The dictionary app itself is intentionally simple — the infrastructure and pipeline are the real subject.

## Architecture

```
git push
    │
    ▼
GitHub Actions
    ├─ Run tests (mocked external API calls)
    ├─ Build Docker image → push to Docker Hub
    ├─ Authenticate to AWS
    ├─ Update kubeconfig for the live EKS cluster
    └─ helm upgrade --install → deploys onto EKS
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │   AWS (provisioned by Terraform) │
                    │                                 │
                    │   VPC → 2 public subnets (2 AZs) │
                    │   Internet Gateway + Route Table │
                    │   EKS Cluster + IAM roles         │
                    │   Node Group (2 EC2 instances)    │
                    │                                 │
                    │   Kubernetes Service (LoadBalancer)│
                    │        │                        │
                    │        ▼                        │
                    │   Real AWS Load Balancer         │
                    │   with a public DNS hostname      │
                    └───────────────────────────────┘
                                    │
                                    ▼
                         Anyone, anywhere, on the internet
```

## Tech Stack

| Layer | Tool |
|---|---|
| Application | Python, FastAPI |
| Frontend | Jinja2 templates, HTML/CSS, vanilla JS |
| External APIs | Free Dictionary API, Google Translate (via `deep-translator`) |
| Testing | Pytest (external API calls mocked) |
| Containerization | Docker |
| CI/CD | GitHub Actions |
| Container Registry | Docker Hub |
| Infrastructure as Code | Terraform |
| Cloud Provider | AWS (VPC, EC2, EKS, IAM, ELB) |
| Orchestration | Kubernetes (EKS) |
| Packaging | Helm |
| Remote State | S3 (state storage) + DynamoDB (state locking) |

## Project Structure

```
simple-dictionary-full-deployment/
├── app/
│   └── main.py                     # FastAPI app: dashboard + /lookup endpoint
├── templates/
│   └── index.html                  # Search UI
├── static/
│   └── style.css
├── tests/
│   └── test_main.py                 # Pytest suite, external APIs mocked
├── dictionary-chart/                 # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── deployment.yaml
│       └── service.yaml             # type: LoadBalancer
├── terraform/
│   └── main.tf                      # VPC, subnets, IAM, EKS cluster, node group
├── Dockerfile
├── requirements.txt
├── .gitignore
├── .github/
│   └── workflows/
│       └── ci.yml                   # Test → build → push → deploy to real EKS
└── README.md
```

## Running Locally

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

Visit `http://localhost:8000/`.

## Running Tests

```bash
python -m pytest tests/test_main.py
```

Both external calls (the dictionary lookup and the Urdu translation) are mocked, so tests run instantly and don't depend on either third-party service being available — important since neither exists inside the CI environment either.

## Infrastructure (Terraform)

### What gets provisioned

- **1 VPC** (`10.0.0.0/16`)
- **2 public subnets**, one per Availability Zone (`us-east-1a`, `us-east-1b`) — required for EKS control plane high availability
- **Subnet tags** required for EKS and load balancer discovery:
  - `kubernetes.io/cluster/<cluster-name> = shared`
  - `kubernetes.io/role/elb = 1`
- **1 Internet Gateway + 1 Route Table**, associated with both subnets
- **IAM role for the EKS control plane**, with `AmazonEKSClusterPolicy` attached
- **IAM role for worker nodes**, with three managed policies attached (`AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`)
- **1 EKS cluster**
- **1 EKS managed node group** (2 × `t3.small` EC2 instances)

### Remote state

State is stored in S3 with DynamoDB-backed locking, so concurrent `apply` operations fail safely rather than corrupting state:

```hcl
terraform {
  backend "s3" {
    bucket         = "my-s3-terraformstate-bucket"
    key            = "dictionary-deployment/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
  }
}
```

### Provisioning

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Cluster creation takes roughly 8-10 minutes; the node group takes a further 2-3 minutes. This is normal — AWS is doing substantial real work, not a stuck process.

### Pointing kubectl at the cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name dictionary-eks-cluster
kubectl get nodes
```

## Deploying (Helm)

```bash
helm install dictionary-app ./dictionary-chart
kubectl get svc
```

The Service is type `LoadBalancer` — on real EKS (unlike a local `kind` cluster), this directly provisions a genuine AWS Elastic Load Balancer with a public DNS hostname. No Ingress controller is needed for this project; EKS's native LoadBalancer support handles external routing directly.

DNS for a freshly created load balancer can take a few minutes to propagate before it resolves — if `curl` or a browser can't reach it immediately after `apply`, that's expected; it does not indicate a misconfiguration.

## CI/CD Pipeline

On every push, GitHub Actions:
1. Runs the pytest suite
2. Builds the Docker image and pushes it to Docker Hub (tagged `latest` and by commit SHA)
3. Authenticates to AWS using IAM user credentials stored as repository secrets
4. Updates its kubeconfig to point at the live EKS cluster
5. Runs `helm upgrade --install`, deploying the change automatically

This is the piece that was structurally impossible with a local `kind` cluster used elsewhere: GitHub's hosted runners have no network path to a laptop, but they can reach a real, publicly addressable AWS resource — making genuine, automatic, push-to-deploy CI/CD possible for the first time.

## The EKS Access Entry Gotcha (a real, non-obvious lesson)

The first automated deploy failed with:
```
Error: kubernetes cluster unreachable: the server has asked for the client to provide credentials
```

This is a subtle but important EKS behavior: **AWS-level IAM permissions and Kubernetes-level cluster access are two separate systems.** By default, only the IAM identity that originally created an EKS cluster has any access to its Kubernetes API — a different IAM user (such as the one GitHub Actions authenticates as) has zero access inside the cluster, even with full `AdministratorAccess` at the AWS level, until it is explicitly granted access.

The fix, using EKS Access Entries (the modern replacement for manually editing the `aws-auth` ConfigMap):

```bash
aws eks create-access-entry \
  --cluster-name dictionary-eks-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:user/<CI_IAM_USERNAME> \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name dictionary-eks-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:user/<CI_IAM_USERNAME> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

Note: Access Entries require the cluster's authentication mode to be `API` or `API_AND_CONFIG_MAP`. A cluster created without specifying this explicitly may already default to a mode that supports it — worth confirming with `aws eks describe-cluster --query "cluster.accessConfig"` before assuming an update is needed.

## Cost Awareness

Unlike every other project in this portfolio, this one provisions **real, billed AWS infrastructure**: an EKS control plane (~$0.10/hour), two EC2 worker nodes, and an Elastic Load Balancer, all accruing cost continuously while running. A billing alarm was set up before any of this work began, and the full stack is torn down with `terraform destroy` (after `helm uninstall`, so the load balancer is cleaned up correctly) at the end of each working session rather than left running.

### Teardown order

```bash
helm uninstall dictionary-app   # removes the LoadBalancer Service first
cd terraform
terraform destroy
```

Uninstalling the Helm release before running `terraform destroy` matters: the load balancer was created by Kubernetes (in response to the `LoadBalancer` Service type), not by Terraform directly, so Terraform has no record of it and won't clean it up on its own.

## What This Project Demonstrates

- Writing real AWS networking infrastructure (VPC, multi-AZ subnets, routing) by hand, including the specific tagging conventions EKS requires, rather than relying on a black-box module before understanding what it abstracts
- IAM roles and managed policy attachments for both an EKS control plane and its worker nodes
- Remote Terraform state with locking, verified under genuine concurrent access
- Deploying to a real, multi-node cloud Kubernetes cluster via Helm, using a native `LoadBalancer` Service rather than an Ingress controller
- Diagnosing and resolving a real, non-obvious EKS access-control issue by distinguishing AWS IAM permissions from Kubernetes-level cluster access
- Building a genuinely complete CI/CD pipeline capable of deploying to real infrastructure — something a local development cluster cannot support, since a hosted CI runner has no network path to a personal machine
- Treating cloud cost as a first-class operational concern: billing alarms, and deliberate, ordered teardown after each session

## Future Improvements

- HTTPS via an ACM certificate and an Application Load Balancer (currently plain HTTP)
- Move Terraform state locking to the newer S3-native locking mechanism (`use_lockfile`), replacing the now-deprecated `dynamodb_table` parameter
- A dedicated, minimally-scoped IAM user for CI (rather than reusing a broadly-permissioned one)
- Terraform modules for the VPC and EKS cluster, to make this reusable across future projects
- Autoscaling the node group based on real load
