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

Infra 저장소의 Dockerfile을 사용하되 Build Context는 Service 저장소 루트로 지정한다.
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
    --file ../Doro-ERP-Infra/deploy/migrations/Dockerfile \
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
5. Migration Overlay만 먼저 적용한다.

```bash
cd ~/Doro-ERP-Infra
kubectl kustomize deploy/migrations/prod-alpha
kubectl apply -k deploy/migrations/prod-alpha

kubectl wait \
  --for=condition=complete \
  --timeout=10m \
  job/store-access-db-migration \
  job/commerce-db-migration \
  job/payment-db-migration \
  job/queue-db-migration \
  -n doro-alpha
```

네 Job이 모두 `Complete`일 때만 Application Overlay를 적용한다.

```bash
kubectl get jobs,pods -n doro-alpha -l app.kubernetes.io/component=database-migration
kubectl logs -n doro-alpha job/store-access-db-migration
kubectl logs -n doro-alpha job/commerce-db-migration
kubectl logs -n doro-alpha job/payment-db-migration
kubectl logs -n doro-alpha job/queue-db-migration
```

로그에는 `Successfully applied` 또는 `Schema ... is up to date`가 나와야 한다. Credential
원문은 출력하거나 지원 요청에 복사하지 않는다.

## 재실행과 실패 처리

Job Template은 생성 후 수정할 수 없으므로 새 Image Tag로 재실행할 때 기존 Job만 삭제하고
다시 적용한다. DB Schema는 삭제하지 않는다.

```bash
kubectl delete job \
  store-access-db-migration \
  commerce-db-migration \
  payment-db-migration \
  queue-db-migration \
  -n doro-alpha

kubectl apply -k deploy/migrations/prod-alpha
```

실패하면 Application을 배포하지 말고 해당 Job의 Pod Event와 Flyway Log를 먼저 확인한다.

```bash
kubectl describe job JOB_NAME -n doro-alpha
kubectl get pods -n doro-alpha -l job-name=JOB_NAME
kubectl logs -n doro-alpha job/JOB_NAME
```
