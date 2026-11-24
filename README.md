# 강원대 학사·장학 안내 RAG 챗봇

강원대학교 학생이 학사 공지, 장학금 안내, 졸업요건을 자연어로 질문하면 공식 문서에서 찾은 근거와 출처를 함께 보여 주며 답하는 RAG 기반 챗봇입니다.

- 작성자: 박태경 (강원대학교 컴퓨터공학과)
- 진행 단계: **2주차 - AWS 환경 및 개발 환경 구성** (Knowledge Bases 연결 전 테스트 버전)

## 아키텍처

```
학생(브라우저) ──▶ API Gateway (HTTP API) ──▶ AWS Lambda (화면 + 질문 처리)
                        │  (3주차) RetrieveAndGenerate
                        ▼
              Amazon Bedrock Knowledge Bases ──▶ Bedrock 생성 모델 (Claude)
                        │ 유사도 검색
                        ▼
              Amazon S3 Vectors  ◀── Sync ── S3 문서 버킷 (PDF·HTML + 메타데이터)
```

| 구성 요소 | 서비스 | 2주차 상태 |
|---|---|---|
| 공개 진입점 | Amazon API Gateway (HTTP API) | 배포 완료, 스로틀링 초당 5건·버스트 10 |
| 웹 화면 + 백엔드 | AWS Lambda (Python 3.12) | 배포 완료 (`kangwon-rag-chatbot`) |
| 문서 저장소 | Amazon S3 | 생성 완료 (퍼블릭 차단, 버전 관리, SSE-S3) |
| 접근 제어 | AWS IAM | Lambda 역할: 로그 기록 + Knowledge Bases 조회만 허용 |
| 로그 | Amazon CloudWatch Logs | 보존 14일, 질문 원문 미기록 |
| 검색·답변 엔진 | Bedrock Knowledge Bases + S3 Vectors | 3주차 예정 |

## 설계 변경 사항 (2주차)

1주차 설계는 Lambda 함수 URL을 공개 주소로 쓰는 구성이었지만, 배포 후 함수 URL이 계정 차원에서 403(AccessDenied)을 반환해 같은 Lambda 앞에 API Gateway HTTP API를 두었습니다. Lambda 코드와 나머지 구성은 그대로이며, 동시 실행 예약(계정 한도 10이라 설정 불가) 대신 API 스로틀링으로 과다 호출을 막습니다.

## 폴더 구성

```
lambda/app.py               Lambda 함수 (GET / 채팅 화면, GET /health, POST /ask)
infra/setup-week2.sh        AWS 리소스 생성 스크립트 (CloudShell, ap-northeast-2)
infra/cleanup-week2.sh      리소스 삭제 스크립트
docs-sample/                테스트용 가상 문서 + Knowledge Bases 메타데이터 예시
```

## 배포

AWS CloudShell(서울 리전)에서 저장소를 받은 뒤 실행합니다.

```bash
git clone https://github.com/tttae210-sys/kangwon-rag-chatbot.git
cd kangwon-rag-chatbot
./infra/setup-week2.sh
```

## API

| 메서드 | 경로 | 설명 |
|---|---|---|
| GET | `/` | 채팅 화면 (HTML) |
| GET | `/health` | 상태 확인 (리전, 문서 버킷, Knowledge Base 연결 여부) |
| POST | `/ask` | `{"question": "..."}` → `{"answer", "sources", "note"}`. 빈 질문·300자 초과는 400 |

현재 `/ask`는 Knowledge Bases 연결 전이라 "제공된 문서에서 근거를 찾지 못했습니다" 형식의 테스트 응답을 돌려줍니다.

## 보안·개인정보

- 문서 버킷은 퍼블릭 액세스를 모두 차단하고, 사용자는 Lambda를 통해서만 접근합니다.
- 로그에는 질문 길이·결과·처리 시간만 남기고 질문 원문은 남기지 않습니다.
- 액세스 키 등 자격 증명은 저장소에 올리지 않습니다 (`.gitignore`에 `.env` 포함).
