# Incertotech
This is the "orchastration" repo that runs all of the demo apps (including the homepage) for incertotech.com in containers

## Let's Encrypt Certbot
When setting up a new server with ssl, do the following:
 - update the EC2 hostname and username in github actions' secrets
 - run the Certbot Init github workflow

When renewing the ssl certificate on a server, do the following:
- run the Certbot Renew github workflow

The `TLS expiry check` workflow runs daily and fails (GitHub emails the owner) if any
public hostname serves a certificate expiring within 21 days. The k8s design
([k8s/README.md](k8s/README.md)) removes certbot entirely: TLS terminates at an AWS
ALB with an auto-renewing ACM certificate.

## Running in docker (local dev)
- set local env variables to local-k8
```bash
bash run-docker.dev.sh
```
Open [http://localhost:8080](http://localhost:8080) to view it in the browser.

## Running in docker (higher env)
```bash
bash run-docker.sh
```

## Running in kubernetes (local, experimental)
A side-by-side kustomize setup lives in [k8s/](k8s/README.md). It does not change the docker-compose deployment.
```bash
make local-k8s-start
```
