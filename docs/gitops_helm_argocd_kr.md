# PR 리뷰 문서: Hackonomics-Infra — Helm 우산 차트, ArgoCD GitOps, Alertmanager

**날짜:** 2026-04-06
**브랜치:** `dev` → `main`
**저장소:** `syjoe02/Hackonomics-Infra`
**커밋:** `9841903` (feat), `b03d1b8` (fix)

---

## 1. 개요

이번 PR은 Hackonomics 스택을 K3s 클러스터에 배포하기 위한 **GitOps 기반 인프라**를 완성합니다. Docker Compose 기반 로컬 개발 환경을 유지하면서, Kubernetes 프로덕션 배포를 위한 Helm 차트 및 ArgoCD 자동화를 추가합니다.

### 핵심 목적

1. **Helm 우산 차트** — Central-Auth, Hackonomics-App, Kafka, PostgreSQL(×2), Redis(×2) 7개 서브차트를 하나의 릴리스로 관리합니다.

2. **ArgoCD 자동 동기화** — `syjoe02/Hackonomics-Infra` 저장소 변경을 감지하여 K3s 클러스터에 자동 반영합니다. CI/CD 파이프라인이 이미지 태그를 업데이트하면 ArgoCD가 자동으로 배포합니다.

3. **Prometheus 경보 규칙 및 Alertmanager** — Kafka 소비자 지연, 서비스 다운, gRPC 오류율, DLT 누적 등 프로덕션 경보를 구성합니다.

### 주요 변경 파일 수

| 구분 | 수량 |
|------|------|
| 신규 파일 | 70개 |
| 수정 파일 | 2개 |
| 총 삽입 | +2,101줄 |

---

## 2. 보안 검토 결과

**검토 도구:** `security-reviewer` 에이전트
**최종 결과: ✅ PASS (CRITICAL → 확인 후 미해당, HIGH → 조치 완료)**

### 발견 사항 및 조치

| 심각도 | 항목 | 파일 | 조치 |
|--------|------|------|------|
| CRITICAL (초기) | `env/.env.prod`에 실제 비밀번호 포함 — git 추적 위험 | `env/.env.prod` | **확인 결과 gitignore 보호 확인:** `git check-ignore -v env/.env.prod` → `.gitignore:1:env/` 패턴에 의해 정상 제외. 저장소에 추적되지 않음. 단, 임시 `git add .` 사고를 방지하기 위한 주의 필요 |
| CRITICAL (초기) | `env/.env`에 Kafka Cluster ID 및 테스트 비밀번호 포함 | `env/.env` | 동일한 gitignore 보호 확인. KAFKA_CLUSTER_ID는 공개 가능한 비밀이 아님 |
| HIGH | `values-k3s-dev.yaml`에 `serviceApiKey`, `djangoSecretKey` 하드코딩 → ArgoCD가 실제 Secret으로 materialize | `helm/values-k3s-dev.yaml` | **조치 완료:** 모든 자격증명 필드를 빈 문자열(`""`)로 교체하고 Sealed Secrets/Vault 주입 안내 주석 추가 |
| HIGH | `argocd/application.yaml` 주석이 시크릿 외부화를 잘못 설명 | `argocd/application.yaml` | **조치 완료:** 주석 수정 — ArgoCD Vault Plugin / Sealed Secrets / 쿠버네티스 Secret 주입 방법 명시 |
| MEDIUM | Prometheus(9090), Alertmanager(9093) 인증 없이 호스트에 노출 | `docker-compose.yml` | Docker Compose는 로컬 개발 환경 전용. 향후 `127.0.0.1` 바인딩 또는 리버스 프록시 인증 적용 권고 |
| MEDIUM | Kafka PLAINTEXT 리스너 | `docker-compose.yml` | 로컬 개발 환경 허용. 프로덕션 K3s 배포에서는 Helm 차트의 TLS 설정 사용 |
| MEDIUM | Alertmanager `null` 리버(수신자) — 모든 경보가 무음 처리 | `monitoring/alertmanager/alertmanager.yml` | 개발 환경 플레이스홀더. 프로덕션 배포 시 Slack/PagerDuty 수신자 설정 필요 (별도 티켓) |

### 보안 설계 긍정 사항

- `helm/hackonomics-infra/values.yaml`: 모든 민감 필드에 `CHANGE_ME_` 플레이스홀더 및 `# REQUIRED` 주석 ✓
- `argocd/application.yaml`: 클러스터 자격증명 미포함, `https://kubernetes.default.svc` (인-클러스터) 사용 ✓
- `monitoring/prometheus.yml.tmpl`: Basic Auth 자격증명이 `${VAR}` 환경변수 치환으로 처리 ✓
- `monitoring/alerts/rules.yml`: 경보 어노테이션에 민감 레이블 없음 ✓

---

## 3. 테스트 및 커버리지

**검증 방법:** `helm lint` + Python YAML 파서를 통한 비-템플릿 YAML 검증

| 검증 항목 | 결과 | 비고 |
|-----------|------|------|
| `helm lint helm/hackonomics-infra` | ✅ PASS | 0 failed (icon 권고 INFO만 존재) |
| 비-템플릿 YAML 파싱 | ✅ 26개 PASS | `argocd/`, `values*.yaml`, `monitoring/` 등 |
| Helm 템플릿 파일 (`{{ }}` 문법) | N/A | Go 템플릿 문법은 YAML 파서 제외, `helm lint`로 검증 |
| **전체 합계** | **PASS / 0 FAIL** | — |

> `helm lint` 결과: `[INFO] Chart.yaml: icon is recommended` — 아이콘 설정은 선택 사항으로 기능에 영향 없음.

---

## 4. 주요 코드 변경점

### 4-1. Helm 우산 차트 (`helm/hackonomics-infra/`)

**구조:**

```
hackonomics-infra/          # 우산 차트
├── Chart.yaml              # apiVersion: v2, 7개 의존성 선언
├── values.yaml             # 기본값 (CHANGE_ME_ 플레이스홀더)
└── charts/
    ├── central-auth/       # Go BFF + pgBouncer 사이드카 + HPA
    ├── hackonomics-app/    # Django web/worker/beat + pgBouncer + 2개 HPA
    ├── kafka/              # KRaft 모드 Kafka StatefulSet + 토픽 셋업 Job
    ├── postgres-go/        # Central-Auth용 PostgreSQL StatefulSet
    ├── postgres-django/    # Django용 PostgreSQL StatefulSet
    ├── redis-go/           # Central-Auth용 Redis StatefulSet
    └── redis-django/       # Django용 Redis StatefulSet
```

**핵심 설계:**

| 서브차트 | 핵심 기능 |
|----------|----------|
| `central-auth` | gRPC(:50051) + HTTP(:8081) + 메트릭(:9091) 포트 노출; pgBouncer 트랜잭션 풀링; HPA(min 3, max 10) |
| `hackonomics-app` | web/worker/beat 별도 Deployment 분리; web/worker 독립 HPA; pgBouncer 세션 풀링 |
| `kafka` | KRaft(컨트롤러+브로커 통합) StatefulSet; Init Job으로 토픽 자동 생성 |

### 4-2. ArgoCD 애플리케이션 매니페스트 (`argocd/application.yaml`)

```yaml
syncPolicy:
  automated:
    prune: true      # Git에서 삭제된 리소스를 클러스터에서도 제거
    selfHeal: true   # 클러스터 수동 변경을 Git 상태로 자동 복원
  syncOptions:
    - CreateNamespace=true   # hackonomics 네임스페이스 자동 생성
    - ServerSideApply=true   # 대용량 리소스의 어노테이션 크기 제한 우회
```

**GitOps 워크플로우 완성:**
```
Central-Auth/Django 코드 변경
  → GitHub Actions CI (테스트 + 빌드 + GHCR 푸시)
    → Infra 저장소 values.yaml 이미지 태그 업데이트
      → ArgoCD가 변경 감지 → K3s 클러스터 자동 배포
```

### 4-3. Prometheus 경보 규칙 (`monitoring/alerts/rules.yml`)

| 경보명 | 조건 | 심각도 |
|--------|------|--------|
| `KafkaBrokerDown` | `kafka_brokers < 1` (1분 지속) | critical |
| `KafkaConsumerGroupLagHigh` | `lag > 1000` (5분 지속) | warning |
| `KafkaConsumerGroupLagCritical` | `lag > 10000` (2분 지속) | critical |
| `KafkaEventsDropped` | `rate(central_auth_kafka_events_dropped_total[5m]) > 0` (2분) | warning |
| `ServiceDown` | `up == 0` (2분 지속) | critical |
| `DjangoHighErrorRate` | HTTP 5xx율 > 5% (5분) | warning |
| `GrpcHighErrorRate` | gRPC non-OK율 > 5% (5분) | warning |

### 4-4. Docker Compose 변경 — Alertmanager 추가

- `prom/alertmanager:v0.28.1` 서비스 추가 (포트 9093, healthcheck 포함)
- Prometheus에 `/etc/prometheus/alerts` 볼륨 마운트 추가
- `prometheus.yml.tmpl`에 `alerting` 블록 및 `rule_files` 글로브 추가
- `prometheus-config-init`에 `.env.shared` 로드 추가 (공유 시크릿 접근)

---

## 5. 배포 전 필수 조치 사항

> 이 항목들은 `main` 머지 전 반드시 완료해야 합니다.

- [ ] **Sealed Secrets 또는 ArgoCD Vault Plugin 설정** — `values-k3s-dev.yaml`의 빈 자격증명 필드에 실제 값 주입 메커니즘 구성
- [ ] **Alertmanager 수신자 설정** — `monitoring/alertmanager/alertmanager.yml`의 `null` 수신자를 Slack 또는 PagerDuty로 교체
- [ ] **ArgoCD repo 접근 권한** — `syjoe02/Hackonomics-Infra` 저장소에 대한 ArgoCD SSH/HTTPS 자격증명 등록

---

## 6. 참조 링크

- 변경 파일 목록: `git show --stat dev`
- 연관 PR: [Central-Auth gRPC 서버](../../../Central-auth/docs/review/PR_20260406_grpc_server_resilience.md)
- 연관 PR: [Hackonomics-2026 gRPC 어댑터](../../../Hackonomics-2026/docs/review/PR_20260406_grpc_adapter_django.md)
