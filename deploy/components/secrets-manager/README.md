# Secrets Manager → EKS Runtime 환경변수

이 Component는 Service 저장소의 `.env.example` 중 민감값만 AWS Secrets Manager에서 읽어 각 Deployment의 환경변수로 주입한다.

```text
AWS Secrets Manager JSON
→ EKS Pod Identity
→ AWS Secrets Store CSI Provider
→ SecretProviderClass
→ Kubernetes Secret
→ Deployment envFrom
```

Port, Timeout, 내부 Service URL, Queue URL, Batch·Retention과 활성화 Flag는 Secret이 아니므로 Prod Alpha ConfigMap에서 관리한다. `AWS_ACCESS_KEY_ID`와 `AWS_SECRET_ACCESS_KEY`는 저장하지 않고 Pod Identity를 사용한다.

## Secret 입력

Terraform은 Secret Container와 IAM 권한만 만든다. 실제 값은 AWS Console에서 다음 순서로 입력한다.

```text
AWS Console
→ Secrets Manager
→ Secrets
→ 대상 doro-erp/prod/alpha/... Secret
→ Retrieve secret value
→ Edit
→ Key/value 또는 Plaintext JSON 입력
```

서비스별 JSON Key는 다음과 같다.

아래 빈 문자열은 Schema 예시일 뿐이다. 저장하기 전에 모든 값을 실제 Prod Credential로 채우며, 빈 값이 남은 JSON을 Secret Version으로 저장하지 않는다.

### `doro-erp/prod/alpha/store-access`

```json
{
  "STORE_ACCESS_DB_USERNAME": "",
  "STORE_ACCESS_DB_PASSWORD": "",
  "STORE_ACCESS_REDIS_USERNAME": "",
  "STORE_ACCESS_REDIS_PASSWORD": "",
  "STORE_ACCESS_IDENTITY_HMAC_RATE_LIMIT_SECRET": "",
  "STORE_ACCESS_IDENTITY_HMAC_IDEMPOTENCY_SECRET": "",
  "STORE_ACCESS_IDENTITY_HMAC_KIOSK_CREDENTIAL_SECRET": "",
  "STORE_ACCESS_PROVISIONING_USERNAME": "",
  "STORE_ACCESS_PROVISIONING_PASSWORD": ""
}
```

### `doro-erp/prod/alpha/commerce`

```json
{
  "COMMERCE_DB_USERNAME": "",
  "COMMERCE_DB_PASSWORD": "",
  "COMMERCE_ORDER_IDEMPOTENCY_HMAC_KEY": ""
}
```

### `doro-erp/prod/alpha/payment`

```json
{
  "PAYMENT_DB_USERNAME": "",
  "PAYMENT_DB_PASSWORD": "",
  "PAYMENT_TOSS_TEST_SECRET_KEY": "",
  "PAYMENT_PAYMENT_KEY_ENCRYPTION_KEY": "",
  "PAYMENT_IDEMPOTENCY_HMAC_KEY": ""
}
```

### `doro-erp/prod/alpha/queue`

```json
{
  "QUEUE_DB_USERNAME": "",
  "QUEUE_DB_PASSWORD": "",
  "QUEUE_ENTRY_IDEMPOTENCY_SECRET": ""
}
```

### `doro-erp/prod/alpha/audit`

```json
{
  "AUDIT_MONGODB_URI": ""
}
```

Edge에는 서비스 전용 민감값이 없으며 방향별 HMAC만 주입한다. Terraform이 만드는 `doro-erp/prod/alpha/edge` Container는 향후 Edge 전용 Secret을 위한 예약 공간이다.

## 방향별 HMAC Secret

하나의 공유 JSON에 모든 HMAC을 넣지 않는다. Secret 하나를 읽을 수 있으면 JSON 전체를 읽을 수 있으므로 다음처럼 방향별로 분리한다.

| Secret 이름 뒤 경로 | JSON Key | 읽는 서비스 |
|---|---|---|
| `hmac/edge-to-store-access` | `DORO_HMAC_EDGE_TO_STORE_ACCESS_SECRET` | Edge, Store Access |
| `hmac/edge-to-audit` | `DORO_HMAC_EDGE_TO_AUDIT_SECRET` | Edge, Audit |
| `hmac/edge-to-payment` | `DORO_HMAC_EDGE_TO_PAYMENT_SECRET` | Edge, Payment |
| `hmac/edge-to-commerce` | `DORO_HMAC_EDGE_TO_COMMERCE_SECRET` | Edge, Commerce |
| `hmac/edge-to-queue` | `DORO_HMAC_EDGE_TO_QUEUE_SECRET` | Edge, Queue |
| `hmac/commerce-to-store-access` | `DORO_HMAC_COMMERCE_TO_STORE_ACCESS_SECRET` | Commerce, Store Access |
| `hmac/store-access-to-commerce` | `DORO_HMAC_STORE_ACCESS_TO_COMMERCE_SECRET` | Store Access, Commerce |
| `hmac/payment-to-commerce` | `DORO_HMAC_PAYMENT_TO_COMMERCE_SECRET` | Payment, Commerce |
| `hmac/commerce-to-queue` | `DORO_HMAC_COMMERCE_TO_QUEUE_SECRET` | Commerce, Queue |
| `hmac/actor-context` | `COMMERCE_ACTOR_CONTEXT_SECRET` | Edge, Store Access, Commerce |

각 Secret 값은 해당 JSON Key 하나만 가진 Object로 입력한다. 32-byte Base64가 필요한 HMAC은 로컬 보안 Terminal에서 다음처럼 생성하고 화면 공유·Shell History·Git에 남기지 않는다.

```bash
openssl rand -base64 32
```

같은 출력값을 여러 방향에 재사용하지 않는다.

## Kustomize 연결

Prod Alpha Overlay의 `kustomization.yaml`에 Component를 추가한다.

```yaml
components:
  - ../../../components/secrets-manager
```

Component는 다음 이름을 전제로 한다.

| Deployment·Container·ServiceAccount | 동기화되는 Kubernetes Secret |
|---|---|
| `edge-api` | `doro-erp-edge-runtime` |
| `store-access-api` | `doro-erp-store-access-runtime` |
| `commerce-api` | `doro-erp-commerce-runtime` |
| `payment-api` | `doro-erp-payment-runtime` |
| `queue-api` | `doro-erp-queue-runtime` |
| `audit-api` | `doro-erp-audit-runtime` |

Terraform의 Pod Identity Association도 위 ServiceAccount 이름과 `doro-alpha` Namespace를 사용한다. 이름을 바꾸면 Terraform과 Patch를 함께 변경한다.

## 검증

Secret 원문을 출력하지 않고 Resource와 Key 이름만 확인한다.

```bash
kubectl get pods -n aws-secrets-manager
kubectl get csidriver secrets-store.csi.k8s.io
kubectl get secretproviderclass -n doro-alpha
kubectl get secret -n doro-alpha \
  doro-erp-edge-runtime \
  doro-erp-store-access-runtime \
  doro-erp-commerce-runtime \
  doro-erp-payment-runtime \
  doro-erp-queue-runtime \
  doro-erp-audit-runtime
```

Pod가 Secret Volume을 Mount해야 Kubernetes Secret 동기화가 시작된다. Pod가 `CreateContainerConfigError` 또는 `FailedMount`이면 다음을 확인한다.

```bash
kubectl describe pod -n doro-alpha POD_NAME
kubectl logs -n aws-secrets-manager \
  -l app.kubernetes.io/name=secrets-store-csi-driver-provider-aws
```

로그나 지원 요청에 Secret 원문을 복사하지 않는다.

## Rotation

CSI Rotation Poll Interval은 2분이다. Mounted File과 동기화된 Kubernetes Secret은 갱신되지만 실행 중인 JVM의 환경변수는 바뀌지 않는다. Secret Version을 갱신한 뒤 동기화를 확인하고 대상 Deployment를 Rollout한다.

```bash
kubectl rollout restart deployment/SERVICE-api -n doro-alpha
kubectl rollout status deployment/SERVICE-api -n doro-alpha
```
