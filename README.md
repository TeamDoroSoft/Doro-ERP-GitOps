# Doro-ERP-GitOps

Doro ERP의 Kubernetes 배포 Manifest와 운영 목표 상태를 소유한다. AWS 기반 자원과
Terraform은 `Doro-ERP-Infra`가 소유하며, 두 저장소는 Kubernetes ServiceAccount 이름과
Secrets Manager 경로 계약을 함께 유지한다.

배포 진입점과 선행 조건은 [`deploy/README.md`](deploy/README.md)를 따른다.

```bash
kubectl kustomize deploy/base
kubectl kustomize deploy/base/provider-admin
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

Provider Admin은 Public Gateway Route를 만들지 않고 EKS의 ClusterIP Service로만 실행한다.
Front Image 게시 Workflow가 Admin ECR Digest와 Base 포함을 GitOps PR에 함께 기록하므로 최초
이미지가 없는 상태에서 placeholder Deployment가 EKS에 생성되지 않는다. 승인된 PR이 병합된
뒤에는 SSM 관리 경로에서
`kubectl -n doro-alpha port-forward service/provider-admin 18080:8080`으로 접근한다. 현재
Provider Admin API는 Public Edge와 분리된 Private Admin Edge·OIDC Secret이 준비되지 않아
`/api/`가 의도적으로 503을 반환한다. 정적 Page 배포만으로 Admin 기능 완료로 판정하지 않는다.
