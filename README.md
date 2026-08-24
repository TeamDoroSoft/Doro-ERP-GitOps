# Doro-ERP-GitOps

Doro ERP의 Kubernetes 배포 Manifest와 운영 목표 상태를 소유한다. AWS 기반 자원과
Terraform은 `Doro-ERP-Infra`가 소유하며, 두 저장소는 Kubernetes ServiceAccount 이름과
Secrets Manager 경로 계약을 함께 유지한다.

배포 진입점과 선행 조건은 [`deploy/README.md`](deploy/README.md)를 따른다.

```bash
kubectl kustomize deploy/base
kubectl kustomize deploy/overlays/prod/alpha
kubectl kustomize deploy/migrations/prod-alpha
bash -n deploy/scripts/record-prod-alpha-image.sh
```

현재 Argo CD Application/ApplicationSet은 아직 정의하지 않았다. 승인된 Image Digest를
Git에 기록하고 수동 Kustomize 적용을 검증한 뒤 자동 동기화를 도입한다.
