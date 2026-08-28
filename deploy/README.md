# Kubernetes 배포 Manifest

이 디렉터리는 Doro ERP의 여섯 Spring Boot Application을 EKS에 배포하기 위한 Kustomize Manifest를 소유한다.

## 구조

```text
deploy/
├─ base/
│  ├─ provider-admin/
│  ├─ provider-admin-edge-api/
│  ├─ edge-api/
│  ├─ store-access-api/
│  ├─ commerce-api/
│  ├─ payment-api/
│  ├─ queue-api/
│  └─ audit-api/
├─ components/
│  └─ secrets-manager/
├─ migrations/
│  └─ prod-alpha/
├─ platform/
│  └─ aws-load-balancer-controller/  # Controller 값과 Cluster 공통 GatewayClass
└─ overlays/
   └─ prod/alpha/
```

각 Base는 다음 Resource를 소유한다.

- `ServiceAccount`: Terraform의 EKS Pod Identity Association과 같은 이름을 사용한다.
- `Deployment`: 독립 Image, Health Probe, Resource 요청·제한과 기본 보안 Context를 정의한다.
- `Service`: Application Port를 노출하는 ClusterIP만 정의한다.
- `availability.yaml`: 서비스별 HPA와 PodDisruptionBudget을 정의한다.
- `HTTPRoute`: Edge Base만 브라우저에 공개할 `/api/v1` Prefix를 소유한다.
- `TargetGroupConfiguration`: Edge Target Group의 IP Target과 Readiness Health Check를 정의한다.
- `ConfigMap`: Port, Region과 안전한 기본 Feature Flag를 환경 변수로 제공한다.

Provider Admin Front Base는 Front 저장소의 Nginx Image를 Deployment와 ClusterIP Service로
실행한다. 별도 `provider-admin-edge-api` Base는 Public Edge와 동일한 `doro-erp-edge` Image를
`prod,admin` Profile로 실행한다. 전용 ALB가 Browser의 `/api/v1/provider/**`를 Admin Edge로
직접 전달하며 Admin Front Pod는 Application Proxy로 사용하지 않는다. Admin Nginx에 직접 들어온
`/api/`는 503으로 거절하고 Front Pod Egress도 열지 않는다. Admin Edge는 고정 Store Access
Service 주소와 Admin 전용 HMAC을 사용한다. Public Edge는 `prod` Profile과 기존 Public
Route·Secret만 유지한다.

Prod Alpha Overlay는 여섯 Public Runtime을 `doro-alpha`에, Provider Admin Front·Edge와 전용
Gateway를 `doro-provider-admin`에 배치한다. Root Image Transformer는 Public/Admin Edge 모두에
같은 `doro-erp-edge` Digest를 적용하고, Public Runtime에는
[`secrets-manager`](components/secrets-manager/README.md) Component를 결합한다.

기존 Release가 `provider-admin` Front를 `doro-alpha`에 만든 상태에서 이 Namespace 분리를
적용하면 Argo CD의 자동 Prune이 꺼져 있어 이전 Front Resource가 자동 삭제되지 않는다. 먼저
`doro-provider-admin`의 Front·Edge·Gateway가 Ready이고 Public 비도달 검증이 끝났는지 확인한 뒤,
이전 Namespace의 `deployment/service/configmap/hpa/pdb provider-admin`만 명시적으로 삭제한다.
Store Access나 Public Runtime은 이 정리 대상에 포함하지 않는다.

## 현재 적용 가능 범위

Manifest 구조, Runtime 설정, Secrets Manager 연결과 PostgreSQL Migration Job은 구현되어 있지만,
EKS에 적용할 Image Tag는 아직 완성되지 않았다. Prod Alpha NetworkPolicy는 포함되어 있지만
실제 CNI Enforcement와 Packet Test 전에는 격리 완료로 판정하지 않는다.

- Provider Admin Front Image는 ECR의 전체 Front Git SHA Tag와 일치하는 Digest만 Release Script로
  갱신한다. Admin Edge는 Service Release가 검증한 Public Edge와 동일한 Digest를 사용한다.
- Prod Alpha Overlay에는 RDS PostgreSQL URL, Redis Endpoint와 SQS Queue 값이 구성되어 있다. Store Access·Commerce·Payment·Queue의 Audit Outbox와 Audit SQS Listener는 Prod Alpha에서 명시적으로 활성화하며, MongoDB URI는 Audit Secret에서 주입한다. Audit DLQ Monitoring은 DLQ 조회 IAM을 별도로 승인하기 전까지 비활성 상태를 유지한다.
- 목표 경계는 CloudFront와 Internal ALB에서 각각 TLS를 종료하고, ALB 뒤 ClusterIP 구간은 HMAC과 Kubernetes Service DNS로 제한한 HTTP를 사용하는 구조다. 각 Runtime의 `*_ALLOW_CLUSTER_SERVICE_HTTP=true` opt-in 없이는 기동 시 Fail-Closed한다.
- CloudFront VPC Origin은 전용 `origin.doro.minseok.click` 이름과 Regional ACM 인증서를 사용해 Gateway API가 생성한 내부 ALB의 HTTPS 443 Listener에 연결한다. ALB에서 TLS를 종료한 뒤 Edge ClusterIP Target에는 HTTP로 전달한다.
- Argo CD Application은 [`../../argocd/applications/doro-erp-prod-alpha.yaml`](../../argocd/applications/doro-erp-prod-alpha.yaml)에 선언한다. GitOps PR 병합 뒤 Auto-Sync와 Self-Heal을 수행하고 자동 Prune은 하지 않는다.
- PostgreSQL Flyway Migration Credential과 Runtime Credential은 분리되어 있다. 실제 Credential 입력과 Migration Image Push가 필요하다.

Image Tag를 채우고 `deploy/migrations/README.md`의 네 Job이 모두 성공하기 전에
Application Overlay를 `kubectl apply`하거나 Argo CD Sync하지 않는다.
Controller IAM·Helm, Gateway API CRD와 GatewayClass는 Application Release보다 먼저 준비할 수 있다.

### Kiosk 다중 모드 Release 적용 Gate

이번 Release는 Runtime만 먼저 올리면 안 된다. 아래 조건을 순서대로 충족한다.

1. Infra 적용 전에 `edge_rate_limit_redis_user_id`에 사용할 ElastiCache ACL User를 별도로 만들고
   `doro:edge:public-checkout:client:*` Prefix와 `GET`, `SET`, `INCR`, `EVAL`, `EVALSHA`, `PING`만
   허용한다.
2. Infra Redis Stack을 적용한 뒤 출력된 Endpoint가 이 Overlay의
   `EDGE_PUBLIC_CHECKOUT_REDIS_HOST`와 같은지 확인한다. 다르면 GitOps 값을 실제 출력으로 바꾼다.
3. `doro-erp/prod/alpha/edge` Secret에
   `EDGE_PUBLIC_CHECKOUT_REDIS_USERNAME`, `EDGE_PUBLIC_CHECKOUT_REDIS_PASSWORD`,
   `EDGE_PUBLIC_CHECKOUT_CLIENT_RATE_LIMIT_HMAC_KEY` 세 Key를 입력한다. 값은 Git, Terraform 변수와
   Shell History에 기록하지 않는다.
4. Service Revision `bb635fa57c436bcb8d0949ca37534ec429408a57`에서 네 Migration Image를
   `bb635fa57c43-migration` Tag로 Build·Push하고 ECR에 모두 존재하는지 확인한다.
5. `doro-erp-prod-migrations` Application만 먼저 수동 Sync해 Store Access V15, Commerce V17,
   Queue V9를 적용한다. 네 Job이 모두 성공하기 전에는 Runtime Release PR을 병합하지 않는다.
6. Service `main` Publish Workflow가 만든 Runtime Image PR에서 Edge·Store Access·Commerce·Payment·
   Queue의 `source-revision`이 이번 변경을 포함한 `main` Revision인지 확인한 뒤 병합한다.
7. Runtime Rollout 뒤 Edge Redis 연결, Kiosk 등록·목록, Entry/Fulfillment Projection과 Payment
   Handoff 충돌 응답을 Smoke Test한다.

Payment Schema에는 이번 변경의 신규 Migration이 없지만 네 Migration Image는 같은 Service
Revision으로 맞춰 부분 Release를 피한다. Git Merge 결과의 Service SHA가 위 Revision과 달라지면
Migration Tag와 Runtime `source-revision`을 실제 `main` SHA 기준으로 다시 생성한다.

### Payment Handoff 활성화 순서

`PAYMENT_HANDOFF_ENABLED=true`만 먼저 반영하면 Payment는 방향별 HMAC과 token/client key 누락을
감지해 기동을 거절한다. 다음 의존성을 모두 준비한 뒤 동일 Runtime Release로 활성화한다.

1. Infra의 `hmac_directions` 정본에 이미 선언된 `commerce-to-payment`,
   `store-access-to-payment`, `payment-to-commerce`, `payment-to-store-access` Secret Container와
   caller/provider Pod Identity Reader 정책을 Terraform Plan에서 확인하고 먼저 적용한다.
2. 각 방향별 Secrets Manager Object에 README와 같은 JSON Key로 서로 다른 32-byte Base64 값을
   입력한다. `doro-erp/prod/alpha/payment`에는 `PAYMENT_HANDOFF_TOKEN_HMAC_KEY`와
   `PAYMENT_TOSS_TEST_CLIENT_KEY`도 입력한다. 실제 값은 Git·Terraform 변수에 저장하지 않는다.
3. SecretProviderClass가 Payment·Commerce·Store Access 양쪽 Kubernetes Secret에 같은 방향 Key를
   동기화했는지 Key 이름만 확인한다. 값이나 Digest는 출력하지 않는다.
4. Runtime Overlay를 Sync해 Payment handoff, Payment→Commerce eligibility,
   Payment→Store Access device validation, Commerce→Payment table handoff와
   Store Access→Payment active-handoff guard를 함께 활성화한다.
5. Payment, Commerce, Store Access Rollout이 모두 Ready인 뒤 직원·Order Kiosk handoff 생성,
   Payment Kiosk current 조회, Table checkout, 활성 handoff가 있는 기기 변경 차단을 Smoke Test한다.

이번 활성화에는 신규 Database Migration이 없다. Secret/IAM 준비 전 Runtime Sync는 CSI Mount 또는
Payment 기동을 fail-closed로 실패시키므로 금지하며, Rollback은 플래그만 내리는 대신 세 Runtime을
같은 직전 Git Revision으로 되돌려 caller/provider 방향을 일치시킨다.

## 기본 동작

Base의 비동기 Consumer와 Outbox는 실제 Queue URL이 준비되기 전까지 Fail-Closed 상태로 비활성화한다.

| Application | 기본 Port | 기본 비활성화 항목 |
|---|---:|---|
| Edge | 8080 | 해당 없음 |
| Store Access | 8081 | Audit Outbox |
| Commerce | 8082 | Payment Event Consumer, Queue·Audit Outbox, Payment Eligibility Provider |
| Payment | 8083 | Commerce Eligibility, Outbox |
| Queue | 8084 | Order Event Consumer, Audit Outbox, Internal Fulfillment |
| Audit | 8085 | SQS Listener, DLQ Monitoring |

실제 AWS Resource와 IAM 권한을 확인한 뒤 Overlay에서 필요한 기능만 활성화한다.

## Gateway API ALB와 공개 Route

AWS Load Balancer Controller는 AWS 공식 Helm Chart `3.5.0`으로 설치하며 Controller
`v3.5.0` IAM Policy와 Pod Identity는 Terraform이 관리한다. 설치와 검증 순서는
[`platform/aws-load-balancer-controller`](platform/aws-load-balancer-controller/README.md)를 따른다.

Base의 Edge `HTTPRoute`는 재사용용 논리 Parent `doro-cell-gateway`를 참조하고 Prod Alpha
Overlay가 이를 `doro-alpha-gateway`로 교체한다. `LoadBalancerConfiguration`이
`doro-erp-prod-alpha-gateway` 내부 ALB, 두 Private Application Subnet, CloudFront 전용
Security Group과 공통 AWS Tag를 중앙에서 강제한다. Edge `TargetGroupConfiguration`은
Pod IP Target과 Readiness Health Check를 소유한다. Gateway HTTPS Listener의 hostname은
AWS Load Balancer Controller가 Regional ACM 인증서를 자동 탐색하기 위한 값이다.
CloudFront의 API Origin Request Policy는 요청의 Cookie·Query·나머지 Header를 보존하되
Viewer `Host`만 Origin 이름으로 교체한다. 따라서 전용 Origin 인증서 이름과 TLS 검증이
일치하고 Edge `HTTPRoute`의 `/api/v1` Rule이 요청을 수용한다. ALB Security Group은 CloudFront
Origin-Facing Prefix List의 TCP 443만 허용한다.

Provider Admin은 별도 `provider-admin-gateway`와 `LoadBalancerConfiguration`을 사용한다.
`admin.doro.minseok.click` Host에서 `/api/v1/provider/**`는 `provider-admin-edge-api:8080`,
그 밖의 경로는 `provider-admin:8080`으로 전달한다. ALB 이름과 Security Group은 각각
`doro-erp-prod-provider-admin`, `doro-erp-prod-provider-admin-alb`이며 Public Gateway의 Listener,
Route 또는 CloudFront Origin에는 연결하지 않는다.

| HTTPRoute 소유 서비스 | 공개 Prefix | 실제 Provider |
|---|---|---|
| Edge | `/api/v1` | Edge에 명시 등록된 Login·본인 비밀번호 변경·Catalog menu·Order·Payment·Audit만 각 Provider로 전달하고 나머지는 Fail-Closed |

업무 Module은 직접적인 Public HTTPRoute를 갖지 않는다. Payment 공개 계약은 Edge가
세션을 확인하고 서명해서 전달하며 Audit은 `/internal/v1/audits`만 제공한다. Module을
직접 ALB에 연결하면 Edge 인증 경계를 우회한다. 아직 승인되지 않은 Kiosk·Table·Queue·관리용 Catalog Route는 Edge에서도 열지 않는다.
Login·본인 비밀번호 Route는 Runtime과 테스트가 존재하지만 정본 OpenAPI·계약 ID 승인이 남아 있어 `DEPLOYMENT_VERIFIED`로 판정하지 않는다.
`/internal/**`와 `/actuator/**`도 HTTPRoute에 등록하지 않는다.

## 렌더링 검증

Cluster 접속 없이 다음 명령으로 Base와 Prod Alpha Overlay가 정상 조합되는지 확인한다.

```bash
kubectl kustomize deploy/base
kubectl kustomize deploy/base/provider-admin
kubectl kustomize deploy/base/provider-admin-edge-api
kubectl kustomize deploy/overlays/prod/alpha
```

Prod Alpha 결과에는 다음이 포함되어야 한다.

- Namespace 1개(`doro-provider-admin`; `doro-alpha`는 선행 환경이 소유)
- `doro-alpha`의 Public Runtime 6개와 `doro-provider-admin`의 Admin Front·Edge 2개
- Admin ServiceAccount `provider-admin-edge-api`, Front·Edge ClusterIP Service와 각 HPA·PDB
- Public HTTPRoute 1개와 Admin HTTPRoute 1개
- Public TargetGroupConfiguration 1개와 Admin Front·Edge TargetGroupConfiguration 2개
- Public/Admin LoadBalancerConfiguration과 Gateway 각각 2개
- Public SecretProviderClass 6개와 Admin Edge SecretProviderClass 1개
- 각 Deployment의 ConfigMap `envFrom`과 서비스별 Runtime Secret `envFrom`
- 각 Deployment의 Secrets Store CSI Volume
- PostgreSQL 사용 Deployment 4개의 `SPRING_FLYWAY_ENABLED=false`
- 각 Deployment와 HPA의 최소 Replica 2개
- 각 Deployment의 Zone·Hostname Topology Spread Constraint

Secret 원문은 렌더링 결과나 Git에 포함되지 않아야 한다.

Provider Admin Front와 Edge Base를 각각 렌더링하고, Prod Alpha 결과에서 모든 Admin Resource가
`doro-provider-admin`에만 존재하는지 확인한다. Front는 검증된 `doro-erp-frontend` Digest,
Admin Edge는 Public Edge와 동일한 `doro-erp-edge` Digest를 사용해야 한다. Admin Edge에만
`prod,admin` Profile, 전용 SecretProviderClass와 ServiceAccount가 있어야 하며 Public Edge에는
Admin HMAC이 없어야 한다.

## Replica·HPA·PDB와 Topology Spread

여섯 Runtime은 Deployment 초기 Replica와 HPA `minReplicas`를 모두 2로 고정한다. HPA는
CPU Request 대비 평균 사용률 70%를 기준으로 최대 4개까지 확장하고, Scale Down은 5분간
안정화한 뒤 60초마다 최대 1개 또는 50% 중 더 작은 폭으로 축소한다. Java Heap은 부하가
줄어도 즉시 반환되지 않을 수 있어 Memory Utilization은 자동 확장 신호로 사용하지 않는다.

서비스별 PodDisruptionBudget은 `maxUnavailable: 1`로 자발적 중단 중 최소 한 Replica를
유지한다. 이는 Node 장애 같은 비자발적 중단을 막지 않으므로 실제 장애 검증을 대체하지 않는다.

재사용 Base의 각 Deployment는 `topology.kubernetes.io/zone`과
`kubernetes.io/hostname`에 대해 `maxSkew: 1`, `minDomains: 2`, `DoNotSchedule`을 사용한다.
Prod Alpha Overlay는 비용과 현재 운영 제약을 반영한 단일 AZ Workload이므로 Zone 제약만
제거하고 Hostname `DoNotSchedule`은 유지한다. 따라서 서비스별 두 Replica는 같은
`ap-northeast-2a` 안에서도 서로 다른 Node에 배치되며, Node가 한 대뿐이면 두 번째 Replica는
의도적으로 Pending 상태를 유지한다.

HPA의 Resource Metric은 EKS Metrics Server Community Add-on에서 제공한다. HPA가 최대
Replica를 요청해 Node 여유 용량을 넘으면 Cluster Autoscaler가 단일 AZ Managed Node Group을
최소 2대에서 최대 4대까지 확장한다. 설치 값과 적용 순서는
[`platform/cluster-autoscaler`](platform/cluster-autoscaler/README.md)를 따른다. 배포 뒤
`kubectl top`, HPA Condition, Node별 Pod 배치, Node `2 → 4 → 2` 증감과 Drain 중 PDB 동작을
확인하기 전에는 자동 확장과 가용성이 검증된 것으로 판정하지 않는다. 단일 AZ 구성은 해당 AZ
장애를 견디지 못하며 운영 Multi-AZ 기준을 대체하지 않는다.

## Prod Alpha NetworkPolicy

Prod Alpha Overlay는 `app.kubernetes.io/component`가 `edge` 또는 `application`인 여섯
Runtime Pod에 Ingress와 Egress 기본 거부를 적용한다. 허용 행렬은 다음과 같다.

| 출발지 | 목적지 | TCP Port | 용도 |
|---|---|---:|---|
| Prod VPC `10.24.0.0/16` | Edge | 8080 | IP Target ALB 요청과 Health Check |
| Edge | Store Access / Commerce / Payment / Audit | 8081 / 8082 / 8083 / 8085 | 공개 Route의 승인된 내부 Provider 호출 |
| Store Access | Commerce | 8082 | Store Access가 소유한 Commerce 내부 호출 |
| Commerce | Store Access / Queue | 8081 / 8084 | Context 조회와 Fulfillment 호출 |
| Payment | Commerce | 8082 | 주문·금액·결제 가능 상태 확인 |
| 모든 Application | CoreDNS | TCP·UDP 53 | Service와 외부 Endpoint DNS 조회 |
| 모든 Application | EKS Pod Identity Agent `169.254.170.23/32` | 80 | Pod Identity Credential 조회 |
| Edge | Prod VPC | 6379 | 공개 Checkout 공통 rate-limit Redis TLS |
| Store Access | Prod VPC | 5432 / 6379 / 443 | PostgreSQL / Redis / SQS PrivateLink |
| Commerce, Queue | Prod VPC | 5432 / 443 | PostgreSQL / SQS PrivateLink |
| Payment | Prod VPC / 외부 | 5432 / 443 | PostgreSQL / SQS PrivateLink와 Toss Test HTTPS |
| Audit | Prod VPC / 외부 | 443 / 27017 | SQS PrivateLink / MongoDB Atlas SRV Target |

Kubernetes NetworkPolicy는 FQDN이나 AWS Security Group을 목적지 Selector로 사용할 수
없다. 따라서 ALB IP Target의 Source와 RDS·ElastiCache·Interface Endpoint는 현재 Prod
VPC CIDR로 제한하며, 세부 Resource 격리는 각 Resource Security Group과 Pod Identity
IAM이 담당한다. ALB 허용 규칙은 같은 VPC의 다른 Source도 Edge 8080에 도달할 수 있으므로
ALB Security Group의 Backend 규칙을 함께 유지해야 한다.

Toss와 Atlas의 IP는 Provider가 변경할 수 있어 Payment의 외부 TCP 443과 Audit의 외부
TCP 27017을 VPC·Kubernetes Service CIDR 밖의 전체 IPv4로 허용했다. 이는 Port 단위의
단계적 제한이며 FQDN-aware Egress Gateway 또는 CNI 정책을 도입하기 전까지 임의의 같은
Port 목적지도 허용하는 잔여 위험이 있다. Atlas M0를 PrivateLink로 전환할 수 없다는 Prod
설계도 이 제한의 배경이다. IPv6 Pod/Endpoint를 활성화할 때는 별도 IPv6 정책을 추가하기 전
배포하지 않는다.

Foundation Terraform은 Cluster Kubernetes Version과 호환되는 최신 Amazon VPC CNI
Managed Add-on을 선택하고 `enableNetworkPolicy=true`로 Enforcement를 활성화한다. Plan에서
선택된 CNI가 NetworkPolicy 지원 Version인지 확인하고, 적용 뒤에는
허용 행렬의 연결 성공과 Edge→Queue, 업무 Module→Edge, Namespace 간 호출, 비승인 Port의
실패를 실제 Pod에서 검증한다. Amazon VPC CNI는 선택된 Pod가 실행되는 Node에서 오는
Kubelet Probe를 허용하므로 별도 Ingress Source를 추가하지 않는다. 이 Overlay의 Selector는
Runtime Pod만 대상으로 하며 별도 `deploy/migrations` Job에는 적용되지 않는다. Migration
NetworkPolicy는 Job 실행 시점과 DB Endpoint가 확정된 뒤 그 Kustomization에서 별도로 적용한다.

현재 CNI는 기본 `standard` 시작 모드를 유지하므로 새 Pod에 Policy Endpoint가 준비되기 전
짧은 기본 허용 구간이 있다. Cluster 핵심 Add-on까지 필요한 Egress 정책을 갖춘 뒤에만
`NETWORK_POLICY_ENFORCING_MODE=strict` 전환을 별도 Rollout으로 검토한다.

Provider Admin Namespace는 모든 Pod의 Ingress·Egress를 기본 거부한다. Admin Internal ALB에서
Front·Edge 8080을 허용하고, Admin Edge에만 `doro-alpha` Store Access 8081, DNS, Pod Identity
Agent와 외부 OIDC HTTPS 443 Egress를 허용한다. Front Pod Egress는 계속 거절한다. Store Access
Ingress도 `doro-provider-admin`의
`provider-admin-edge-api`만 추가 허용한다. NetworkPolicy는 ALB Security Group, 실제 CNI 적용과
Packet Test를 대체하지 않는다.

## Release 값 반영

Service Image 게시 Workflow는 검증된 ECR Digest를 GitOps Release PR에 기록한다. Script는
전체 Git SHA Tag가 실제 ECR에서 입력 Digest를 가리키는지 확인한 뒤 대상 서비스 항목 하나만
변경하며 Cluster에는 직접 적용하지 않는다. GitOps PR은 자동 병합하지 않으며 승인된 PR이
`main`에 병합되면 Argo CD가 Prod Alpha Overlay를 자동 동기화한다.

Front Provider Admin Workflow도 동일하게 `record-prod-alpha-admin-image.sh`를 실행해
`doro-erp-frontend` Digest를 기록한다. Admin Front와 Private Edge Runtime은 Overlay에 유지되며,
Script는 검증된 Front Digest 항목만 갱신한다.

```bash
./deploy/scripts/record-prod-alpha-image.sh \
  payment \
  0123456789abcdef0123456789abcdef01234567 \
  sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
git diff -- deploy/overlays/prod/alpha/kustomization.yaml
kubectl kustomize deploy/overlays/prod/alpha >/dev/null
```

Overlay의 `images` 항목은 다음 형태를 사용한다.

```yaml
images:
  - name: doro-erp-payment
    newName: 727646470302.dkr.ecr.ap-northeast-2.amazonaws.com/doro-erp-payment
    digest: sha256:ECR_DIGEST # source-revision: FULL_GIT_SHA
```

Provider Admin은 AWS 계정 `727646470302`, Region `ap-northeast-2`의 ECR Repository
`doro-erp-frontend`를 사용한다. `sha256:unconfigured`는 실제 Digest로 간주하지 않으며 Release
Script가 실제 ECR Tag와 Digest 일치를 검증한 경우에만 교체한다.

변경을 Commit한 뒤 Migration이 필요한 서비스는 전용 Job을 먼저 완료하고 PR의 렌더링 결과를
검토한다. 병합 뒤 Argo CD가 전체 Overlay를 Sync해도 Pod Template이 바뀐 Deployment만
Rollout한다. `kubectl rollout status`와 서비스 Smoke Test를 통과해야 Release가 완료된다.
Rollback도 동일 Script에 이전 전체 Git SHA와 Digest를 전달해 Git에 기록한 뒤 다시 Apply한다.
EKS Console이나 `kubectl set image`로만 변경해 Git과 Cluster 상태를 어긋나게 하지 않는다.

## 중앙 Application Log

Prod Alpha ConfigMap은 Spring Boot Console Log를 ECS JSON으로 전환하고 `service.name`,
`service.environment=prod-alpha`, `cell=alpha`와 MDC의 `requestId`를 구조화한다. Stack Trace는
Log 수집 비용과 단일 Event 크기를 제한하기 위해 16 KiB로 자른다. CloudWatch Observability
Add-on은 Container Log에 Kubernetes Metadata를 결합해
`/aws/containerinsights/doro-erp-prod/application`으로 전송한다. `/actuator/**`는 계속 Public
HTTPRoute에 노출하지 않는다.

Cookie, Authorization, HMAC, 비밀번호, 전체 요청·응답 Body와 결제정보를 Log에 추가하지 않는다.
Application Signals 자동 계측은 이번 단계에서 비활성화하며 수동 Release와 중앙 Log를 검증한
뒤 서비스별로 도입한다.

공개 Checkout rate limit은 `edge.public.checkout.client.rate_limit` Counter와
`outcome=allowed|limited|unavailable`만 노출한다. Client IP, HMAC Digest, Token과 Public ID를
Metric Tag나 로그에 추가하지 않는다. Prometheus Operator와 Application Signals는 사용하지 않으며,
`limited`·`unavailable`일 때만 Edge가 고정된 비민감 Event 이름을 기록한다. Infra의 Container Insights
Log Metric Filter가 이를 `DoroERP/Edge` 저카디널리티 Metric으로 변환해 Redis 장애와 제한 급증을
각각 SNS 경보에 연결한다. 실제 Log 수집·Filter·Alarm 상태는 Apply 후 별도 운영 검증 대상이다.

공개 Checkout 경로는 기존 Edge HTTPRoute의 `/api/v1` Prefix에 포함되므로 별도 Route가 필요 없고,
Edge의 외부 Redis Counter에는 업무 Migration Job이 없다.

일반 설정은 ConfigMap Patch로, Credential과 HMAC Key는 AWS Secrets Manager로 전달한다. 실제 Secret 값과 값이 채워진 환경 파일은 커밋하지 않는다.

PostgreSQL Schema 변경은 Runtime Deployment가 수행하지 않는다. 서비스 SQL로 만든 Migration
Image와 별도 Credential을 사용하는 네 Kubernetes Job의 구성·실행 방법은
[`migrations/README.md`](migrations/README.md)를 따른다.
