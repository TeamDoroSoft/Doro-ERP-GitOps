# Cluster Autoscaler

Prod EKS `1.35`에는 Kubernetes Cluster Autoscaler `1.35.0`과 Helm Chart `9.58.0`을
사용한다. Terraform은 단일 AZ Managed Node Group의 경계 `min=2`, `max=4`, 전용 IAM
Role과 Pod Identity Association을 관리한다. Helm은
`kube-system/cluster-autoscaler` ServiceAccount와 Runtime을 관리한다.

Cluster Autoscaler는 `Insufficient cpu` 또는 `Insufficient memory`로 Pending인 Pod를
보고 같은 `ap-northeast-2a` Node Group을 최대 4대까지 확장한다. HPA는 Pod 수를
서비스별 2개에서 최대 4개까지 조정하고, Node 수는 Cluster Autoscaler가 조정한다.

## 적용 순서

먼저 Foundation Terraform을 적용해 Node Group 경계와 IAM을 준비한다.

```bash
cd terraform/environments/prod
terraform init -backend-config=backend.hcl
terraform plan -out=prod.tfplan
terraform apply prod.tfplan
aws eks update-kubeconfig --region ap-northeast-2 --name doro-erp-prod
```

Node Group이 `ap-northeast-2a`에서 최소 두 Node를 제공하는지 확인한다.

```bash
kubectl get nodes -L topology.kubernetes.io/zone,kubernetes.io/hostname
```

공식 Chart를 고정 Version으로 설치한다. Chart와 Image의 Minor Version은 EKS와 같은
`1.35` 계열을 유지한다.

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update autoscaler
helm upgrade --install cluster-autoscaler \
  autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version 9.58.0 \
  --values deploy/platform/cluster-autoscaler/values.yaml \
  --wait \
  --timeout 5m
```

## 검증

```bash
kubectl get deployment,pod -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler
kubectl logs -n kube-system deployment/cluster-autoscaler-aws-cluster-autoscaler --tail=100
kubectl get hpa,pod -n doro-alpha
kubectl get nodes -L topology.kubernetes.io/zone -w
```

부하 테스트에서 HPA가 Pod를 늘리고, 여유가 없을 때 Node가 `2 → 3 → 4`로 증가하는지
확인한다. 부하 제거 후 Pod가 최소 2개로 줄고 Node도 최소 2대로 복귀하는지 확인한다.
Scale-down 중 PDB와 `maxUnavailable: 1`이 유지되는지도 함께 확인한다.

Terraform은 Autoscaler가 조정하는 `desired_size` Drift를 무시하지만 `min_size`와
`max_size`는 계속 소유한다. Autoscaler를 제거하기 전에 Node Group의 실제 Desired 값을
확인하고 Terraform Plan에서 예상치 않은 축소가 없는지 검토한다.
