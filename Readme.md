# LakeSail POC Setup

This repo is set up so machine-specific values are not committed in source.
A new user only needs to do three things:

1. Set up Minikube, Docker, and Argo.
2. Set up AWS credentials and an S3 bucket.
3. Run the POC.

## 1. Local Cluster Setup

The local cluster setup script is [lakesail_local_cluster_setup.sh](/home/zeo/Desktop/lakesail/lakesail_local_cluster_setup.sh). It installs `minikube`, `kubectl`, and the Argo CLI when needed, creates the local Minikube cluster, and installs Argo Workflows.

What you need first:

- Docker installed and running
- permission to run `docker info`
- `sudo` access if the script needs to install `minikube`, `kubectl`, or `argo`

Run:

```bash
./lakesail_local_cluster_setup.sh setup
```

What this does:

- installs `minikube`, `kubectl`, and `argo` if they are missing
- creates the `lakesail-poc` Minikube cluster
- installs Argo Workflows into the `argo` namespace

Useful checks:

```bash
./lakesail_local_cluster_setup.sh status
docker info
minikube status --profile lakesail-poc
kubectl get pods -n argo
```

If setup succeeds, you can open the Argo UI with:

```bash
kubectl -n argo port-forward service/argo-server 2746:2746
```

Then open `https://localhost:2746`.

## 2. AWS Setup

You need:

- an AWS CLI profile that already works on your machine, usually `default`
- an existing S3 bucket that you control
- permission to access Glue and S3

Create the LakeSail credentials file:

```bash
SOURCE_AWS_PROFILE=default ./run_lakesail_distributed_poc.sh setup-credentials
```

This calls [setup_lakesail_credentials.sh](/home/zeo/Desktop/lakesail/setup_lakesail_credentials.sh) and writes a LakeSail-format credentials file to `${HOME}/lakesail-credentials` by default.

Create or edit [env.local.sh](/home/zeo/Desktop/lakesail/env.local.sh):

```bash
export S3_BUCKET="your-existing-bucket"
export AWS_CREDENTIALS_FILE="${HOME}/lakesail-credentials"
export AWS_PROFILE="lakesail"
export AWS_REGION="us-east-1"
```

`run_lakesail_distributed_poc.sh` automatically loads `env.local.sh` if it exists.

Optional Glue check:

```bash
./setup.sh
```

## 3. Run the POC

Run the distributed POC:

```bash
./run_lakesail_distributed_poc.sh run
```

Useful follow-up commands:

```bash
./run_lakesail_distributed_poc.sh status
./run_lakesail_distributed_poc.sh logs
./run_lakesail_distributed_poc.sh cleanup
```

## How The Runner Works

- The Docker image contains Python, `pysail`, and the dependencies from [requirements.txt](/home/zeo/Desktop/lakesail/requirements.txt).
- [lakesail_distributed_test.py](/home/zeo/Desktop/lakesail/lakesail_distributed_test.py) is not baked into the image for each run.
- The runner uploads that Python file into Kubernetes as a `ConfigMap` and mounts it into the Argo pod at `/opt/lakesail-poc/lakesail_distributed_test.py`.
- AWS credentials are uploaded as a Kubernetes `Secret` and mounted at `/var/run/lakesail/aws/credentials`.

## What Is Required

- `S3_BUCKET` must be set in your environment or in `env.local.sh`.
- `${HOME}/lakesail-credentials` must exist, or `AWS_CREDENTIALS_FILE` must point to another valid credentials file.
- Docker, Minikube, `kubectl`, and Argo must be available for the distributed run.

## Local Test

If you want to run the local Python script instead of the distributed Argo flow:

```bash
export S3_BUCKET="your-existing-bucket"
python3 src/basic_test.py
```
