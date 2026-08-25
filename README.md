# Doro-ERP-GitOps

Doro ERP의 Kubernetes 배포 Manifest와 운영 목표 상태를 소유한다. AWS 기반 자원과
Terraform은 `Doro-ERP-Infra`가 소유하며, 두 저장소는 Kubernetes ServiceAccount 이름과
Secrets Manager 경로 계약을 함께 유지한다.

배포 진입점과 선행 조건은 [`deploy/README.md`](deploy/README.md)를 따른다.

```bash
kubectl kustomize deploy/base
kubectl kustomize deploy/base/provider-admin
kubectl kustomize deploy/base/provider-admin-edge-api
kubectl kustomize deploy/overlays/prod/alpha
kubectl kustomize deploy/migrations/prod-alpha
bash -n deploy/scripts/record-prod-alpha-image.sh
bash -n deploy/scripts/record-prod-alpha-admin-image.sh
kubectl apply --dry-run=client -f argocd/applications/doro-erp-prod-alpha.yaml
```

[`doro-erp-prod-alpha`](argocd/applications/doro-erp-prod-alpha.yaml) Argo CD Application은
GitOps `main`의 Prod Alpha Overlay를 추적하고 Auto-Sync와 Self-Heal을 사용한다. 자동 Prune은
비활성화해 Git에서 Resource가 제거되더라도 별도 검토 없이 Cluster Resource를 삭제하지 않는다.
Service Image 게시 Workflow는 승인된 ECR Digest를 기록하는 GitOps PR을 만들며, 사람이 해당
PR을 검토해 병합한 뒤에만 Argo CD가 EKS Rollout을 시작한다.

Application 설정을 Cluster에 반영하거나 복구할 때는 다음 명령을 사용한다.

```bash
kubectl apply -f argocd/applications/doro-erp-prod-alpha.yaml
kubectl get application doro-erp-prod-alpha -n argocd
```

Provider Admin은 Public Gateway·CloudFront와 분리된 `doro-provider-admin` Namespace에서
Front와 `provider-admin-edge-api`를 실행한다. `admin.doro.minseok.click` 전용 Internal ALB는
Management EC2 Security Group에서 오는 HTTPS만 수용하며, 운영자는 Infra가 소유한 고정 목적지
SSM Port Forwarding Document를 통해 접근한다. Admin Edge만 `prod,admin` Profile과 전용
OIDC·Session·Store Access HMAC Secret을 받고 Public Edge는 기존 `prod` Profile과 Secret 경계를
유지한다. 실제 Secret 입력·Terraform Apply·SSM/TLS/Browser Smoke 전에는 배포 검증 완료로
판정하지 않는다.
