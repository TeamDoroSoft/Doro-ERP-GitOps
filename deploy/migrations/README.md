# PostgreSQL Flyway Migration

Store Access, Commerce, Payment, Queue의 Flyway Migration을 Runtime Deployment와 분리한다.
Runtime Pod에는 `SPRING_FLYWAY_ENABLED=false`가 주입되고, 각 Migration Job만 해당 DB의
`*_migration` Role을 사용한다.

## 보안 경계

- Terraform은 `doro-erp/prod/alpha/migration/{service}` Secret 4개를 만든다.
- Migration별 전용 IAM Role, EKS Pod Identity와 ServiceAccount를 사용한다.
- Runtime Pod Identity는 Migration Secret을 읽을 수 없다.
- URL은 Manifest에 저장하지만 Username과 Password는 Secrets Manager/CSI로만 주입한다.
- Flyway Password는 명령행 인수가 아니라 `FLYWAY_PASSWORD` 환경변수로 전달한다.

각 Migration Secret의 JSON Schema는 동일하다.

```json
{
  "DB_MIGRATION_USERNAME": "store_access_migration",
  "DB_MIGRATION_PASSWORD": "POSTGRES_BOOTSTRAP에서_설정한_값"
}
```

서비스별 Username은 다음과 같다.

| Secret 이름 | `DB_MIGRATION_USERNAME` |
|---|---|
| `doro-erp/prod/alpha/migration/store-access` | `store_access_migration` |
| `doro-erp/prod/alpha/migration/commerce` | `commerce_migration` |
| `doro-erp/prod/alpha/migration/payment` | `payment_migration` |
| `doro-erp/prod/alpha/migration/queue` | `queue_migration` |

## Migration Image Build

GitOps 저장소의 Dockerfile을 사용하되 Build Context는 Service 저장소 루트로 지정한다.
Flyway Image Version은 Service가 사용하는 `12.4.0`과 맞춘다. 각 Image는 해당 서비스의
`db/migration` 디렉터리만 포함한다.

```bash
cd ~/Doro-ERP-Service

export AWS_REGION=ap-northeast-2
export AWS_ACCOUNT_ID=727646470302
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export MIGRATION_TAG="$(git rev-parse --short=12 HEAD)-migration"

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

for service in store-access commerce payment queue; do
  docker build \
    --file ../Doro-ERP-GitOps/deploy/migrations/Dockerfile \
    --build-arg "MIGRATION_SOURCE=apps/${service}-api/src/main/resources/db/migration" \
    --tag "${ECR_REGISTRY}/doro-erp-${service}:${MIGRATION_TAG}" \
    .
  docker push "${ECR_REGISTRY}/doro-erp-${service}:${MIGRATION_TAG}"
done
```

ECR Repository는 Immutable Tag를 사용하므로 같은 Tag를 덮어쓰지 않는다. Service Git SHA가
바뀌면 새 `MIGRATION_TAG`를 만든다.

## 적용 순서

1. Foundation Terraform을 먼저 Apply해 네 Migration Secret, IAM Role과 Pod Identity를 만든다.
2. AWS Console에서 네 Migration Secret JSON을 입력한다.
3. 위 Image를 Build·Push한다.
4. `deploy/migrations/prod-alpha/kustomization.yaml`의 네 `newTag`를 실제 `MIGRATION_TAG`로 바꾼다.
5. [`doro-erp-prod-migrations`](../../argocd/applications/doro-erp-prod-migrations.yaml)
   Application Manifest를 적용한 뒤 Migration Application을 수동 Sync한다. ServiceAccount와
   SecretProviderClass가 먼저
   적용되고, 네 Migration Job은 Sync Hook으로 실행된다.

```bash
cd ~/Doro-ERP-GitOps
kubectl kustomize deploy/migrations/prod-alpha
kubectl apply -f argocd/applications/doro-erp-prod-migrations.yaml

# Argo CD UI에서 doro-erp-prod-migrations Application을 Sync한다.
```

현재 Kiosk 다중 모드 Release의 Migration Tag는 Service Revision
`bb635fa57c436bcb8d0949ca37534ec429408a57`에서 만든 `bb635fa57c43-migration`이다. 네 ECR
Repository에 이 Tag가 모두 존재하기 전에는 Migration Application을 Sync하지 않는다. Service가
다른 Revision으로 병합되거나 다시 Build되면 이 고정값을 그대로 사용하지 말고 해당 Revision의
새 Immutable Tag로 네 항목을 함께 교체한다.

Sync 중에는 다음 명령으로 Hook Job을 확인할 수 있다.

```bash
kubectl get jobs,pods -n doro-alpha -l app.kubernetes.io/component=database-migration
```

Argo CD에서 Migration Application의 마지막 Operation이 `Succeeded`일 때만 Runtime
Application을 Sync한다. 성공한 Hook Job은 `HookSucceeded` 정책에 따라 바로 삭제되므로,
Sync 완료 후 Job이 조회되지 않는 것이 정상이다.

```bash
kubectl get application doro-erp-prod-migrations \
  -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OPERATION:.status.operationState.phase'
```

실행 중 로그에는 `Successfully applied` 또는 `Schema ... is up to date`가 나와야 한다.
Credential 원문은 출력하거나 지원 요청에 복사하지 않는다.

## 재실행과 실패 처리

Migration Job은 Argo CD Sync Hook으로 실행한다. `BeforeHookCreation`은 다음 Sync 전에 남아
있는 이전 Hook Job을 정리하고, `HookSucceeded`는 성공한 Job을 정리한다. 따라서 완료된 Job이
삭제된 뒤 Application이 다시 `OutOfSync`가 되거나, 변경 불가능한 기존 Job Template 때문에
Sync가 실패하지 않는다. DB Schema는 삭제하지 않는다.

```bash
# Argo CD UI에서 doro-erp-prod-migrations Application을 다시 Sync한다.
```

실패하면 Application을 배포하지 말고 해당 Job의 Pod Event와 Flyway Log를 먼저 확인한다.

```bash
kubectl describe job JOB_NAME -n doro-alpha
kubectl get pods -n doro-alpha -l job-name=JOB_NAME
kubectl logs -n doro-alpha job/JOB_NAME
```
