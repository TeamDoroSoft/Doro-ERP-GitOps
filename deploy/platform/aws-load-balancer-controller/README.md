# AWS Load Balancer Controller와 Gateway API

Prod EKS에는 AWS Load Balancer Controller `v3.5.0`을 Helm Chart `3.5.0`으로 설치한다.
Controller IAM Policy와 Pod Identity Association은 Terraform이 관리하고, Helm은
`kube-system/aws-load-balancer-controller` ServiceAccount와 Controller Runtime을 관리한다.
IAM Policy는 Controller `v3.5.0`의 공식
[`iam_policy.json`](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json)을
원문 그대로 고정한다.

Kubernetes Ingress는 사용하지 않는다. Cluster 공통 `GatewayClass`, Prod Alpha의
`LoadBalancerConfiguration`·`Gateway`, Edge 전용 `HTTPRoute`·`TargetGroupConfiguration`이
Internal ALB와 `/api/v1` Route를 관리한다. CloudFront VPC Origin은 이 ALB에 연결한다.

## 1. Foundation 준비

Terraform으로 Controller IAM Role과 Pod Identity Association, ALB Frontend Security
Group과 Regional ACM 인증서를 먼저 준비한다. 이 단계에서는 Gateway ALB가 아직 없으므로
Gateway ALB를 조회하는 최종 CloudFront Terraform Plan은 실행하지 않는다.

```bash
cd terraform/environments/prod
terraform init -backend-config=backend.hcl
aws eks update-kubeconfig --region ap-northeast-2 --name doro-erp-prod
```

## 2. Gateway API CRD 설치

표준 Gateway API CRD는 `v1.6.0`, AWS LBC Gateway CRD는 Controller와 같은 `v3.5.0`으로
고정한다. `main` Branch URL을 사용하지 않는다.

```bash
kubectl apply --server-side=true \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml

kubectl apply \
  -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/config/crd/gateway/gateway-crds.yaml

kubectl get crd \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  loadbalancerconfigurations.gateway.k8s.aws \
  targetgroupconfigurations.gateway.k8s.aws
```

## 3. Controller 설치 또는 갱신

Chart CRD와 Controller를 설치하고 `ALBGatewayAPI=true`를 명시적으로 활성화한다.

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm show crds eks/aws-load-balancer-controller --version 3.5.0 \
  | kubectl apply -f -

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version 3.5.0 \
  --values deploy/platform/aws-load-balancer-controller/values.yaml \
  --set-string vpcId="$(terraform -chdir=terraform/environments/prod/network output -raw vpc_id)" \
  --wait \
  --timeout 5m

kubectl rollout status deployment/aws-load-balancer-controller \
  --namespace kube-system \
  --timeout=5m
```

## 4. GatewayClass와 Prod Alpha Gateway 적용

Cluster 공통 `GatewayClass`를 먼저 적용한 뒤 Application Overlay를 적용한다. Overlay에는
Prod Alpha `Gateway`와 Edge Route가 포함된다. 기존 Ingress가 Cluster에 남아 있는 전환
환경에서는 `--prune`을 사용하지 않는다.

```bash
kubectl apply \
  -f deploy/platform/aws-load-balancer-controller/gateway-class.yaml

kubectl apply \
  -k deploy/overlays/prod/alpha
```

다음 상태를 확인한다.

```bash
kubectl get gatewayclass doro-alb

kubectl get \
  loadbalancerconfiguration,gateway,httproute,targetgroupconfiguration \
  --namespace doro-alpha

kubectl describe gateway doro-alpha-gateway \
  --namespace doro-alpha

kubectl describe httproute edge-api-route \
  --namespace doro-alpha
```

`GatewayClass`의 `Accepted`, `Gateway`의 `Accepted`·`Programmed`, `HTTPRoute`의
`Accepted`·`ResolvedRefs` Condition이 모두 `True`여야 한다. 새 ALB 이름은
`doro-erp-prod-alpha-gateway`이고 Scheme은 `internal`이어야 한다.

## 5. 기존 Ingress 정리

저장소에는 Ingress Manifest가 없다. 기존 Cluster에 남아 있는 Ingress는 새 Gateway ALB와
CloudFront 경로를 검증한 뒤에만 삭제한다.

```bash
kubectl delete ingress edge-api \
  --namespace doro-alpha

kubectl wait --for=delete ingress/edge-api \
  --namespace doro-alpha \
  --timeout=5m

kubectl delete ingressclass doro-alpha-alb --ignore-not-found

kubectl delete ingressclassparams doro-alpha-alb \
  --ignore-not-found
```

Ingress 삭제 전에 Controller를 제거하면 기존 ALB와 Target Group이 남을 수 있다. 기존
Ingress ALB가 AWS에서 삭제된 것을 확인한 뒤에만 IngressClass 계열을 정리한다.

## 고정 정책

- Internal ALB 이름: `doro-erp-prod-alpha-gateway`
- VPC ID: 고정값을 저장하지 않고 Network Terraform Output을 Helm에 전달
- HTTPS Listener: `origin.doro.minseok.click:443`
- Backend: Edge `HTTPRoute`의 `edge-api:8080` 하나
- Target Type: Pod IP
- Health Check: `HTTP:8080/actuator/health/readiness`, 성공 Code `200`
- Subnet: Private Application Subnet 2개
- Security Group: Terraform 관리 `doro-erp-prod-alpha-alb`
- AWS Tag: `Project=Doro-ERP`, `Environment=prod`, `Cell=alpha`, `Team=team2`
- Shield·WAF·WAFv2 자동 연결 비활성화; WAF는 CloudFront Terraform이 관리
