#!/usr/bin/env bash
# 2주차 AWS 환경 구성 스크립트 (AWS CloudShell, ap-northeast-2에서 실행)
# 만드는 것: S3 문서 버킷, Lambda 실행 역할, Lambda 테스트 앱 + 함수 URL, 로그 보존 기간
set -euo pipefail
REGION=ap-northeast-2
ACC=$(aws sts get-caller-identity --query Account --output text)
BUCKET=kangwon-rag-docs-$ACC
ROLE=kangwon-rag-lambda-role
FN=kangwon-rag-chatbot
HERE=$(cd "$(dirname "$0")/.." && pwd)

echo "== 1. S3 문서 버킷: $BUCKET"
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET" --region $REGION \
    --create-bucket-configuration LocationConstraint=$REGION >/dev/null
fi
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3 cp "$HERE/docs-sample/" "s3://$BUCKET/docs/" --recursive

echo "== 2. Lambda 실행 역할: $ROLE (로그 기록 + Knowledge Bases 호출만 허용)"
if ! aws iam get-role --role-name $ROLE >/dev/null 2>&1; then
  aws iam create-role --role-name $ROLE --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name $ROLE \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  sleep 10
fi
aws iam put-role-policy --role-name $ROLE --policy-name kb-query-only --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"bedrock:Retrieve\",\"bedrock:RetrieveAndGenerate\"],
     \"Resource\":\"arn:aws:bedrock:$REGION:$ACC:knowledge-base/*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"bedrock:InvokeModel\"],
     \"Resource\":[\"arn:aws:bedrock:*::foundation-model/*\",\"arn:aws:bedrock:*:$ACC:inference-profile/*\"]}
  ]}"
ROLE_ARN=$(aws iam get-role --role-name $ROLE --query Role.Arn --output text)

echo "== 3. Lambda 함수: $FN"
( cd "$HERE/lambda" && rm -f /tmp/fn.zip && zip -q /tmp/fn.zip app.py )
ENV="Variables={DOCS_BUCKET=$BUCKET,MAX_QUESTION_LEN=300}"
if aws lambda get-function --function-name $FN >/dev/null 2>&1; then
  aws lambda update-function-code --function-name $FN --zip-file fileb:///tmp/fn.zip >/dev/null
else
  for i in 1 2 3 4 5; do
    aws lambda create-function --function-name $FN --runtime python3.12 --handler app.handler \
      --role "$ROLE_ARN" --zip-file fileb:///tmp/fn.zip --timeout 30 --memory-size 256 \
      --environment "$ENV" >/dev/null && break
    echo "  역할 전파 대기 후 재시도($i)"; sleep 8
  done
fi
aws lambda wait function-active-v2 --function-name $FN

echo "== 4. 로그 보존 기간 14일"
aws logs create-log-group --log-group-name /aws/lambda/$FN 2>/dev/null || true
aws logs put-retention-policy --log-group-name /aws/lambda/$FN --retention-in-days 14

echo "== 5. 동시 실행 제한 (과다 호출 방지)"
aws lambda put-function-concurrency --function-name $FN --reserved-concurrent-executions 5 >/dev/null \
  || echo "  (계정 동시 실행 한도가 낮아 예약 동시성을 설정하지 못함 - 계정 한도 내에서만 실행됨)"

echo "== 6. 함수 URL (공개, 인증 없음)"
if ! aws lambda get-function-url-config --function-name $FN >/dev/null 2>&1; then
  aws lambda create-function-url-config --function-name $FN --auth-type NONE >/dev/null
  aws lambda add-permission --function-name $FN --statement-id public-url \
    --action lambda:InvokeFunctionUrl --principal '*' --function-url-auth-type NONE >/dev/null
  aws lambda add-permission --function-name $FN --statement-id public-url-invoke \
    --action lambda:InvokeFunction --principal '*' --invoked-via-function-url >/dev/null 2>&1 \
    || echo "  (InvokeFunction 권한 추가 생략)"
fi
URL=$(aws lambda get-function-url-config --function-name $FN --query FunctionUrl --output text)

echo "== 7. API Gateway HTTP API (함수 URL이 계정 제한으로 403을 반환해 공개 진입점으로 추가)"
FARN=$(aws lambda get-function --function-name $FN --query Configuration.FunctionArn --output text)
API=$(aws apigatewayv2 get-apis --query "Items[?Name=='kangwon-rag-api'].ApiId" --output text)
if [ -z "$API" ]; then
  API=$(aws apigatewayv2 create-api --name kangwon-rag-api --protocol-type HTTP --target "$FARN" --query ApiId --output text)
  aws lambda add-permission --function-name $FN --statement-id apigw-invoke --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$REGION:$ACC:$API/*" >/dev/null
fi
# 동시 실행 예약 대신 API 스로틀링으로 과다 호출 방지 (초당 5건, 버스트 10)
aws apigatewayv2 update-stage --api-id $API --stage-name '$default' \
  --default-route-settings ThrottlingBurstLimit=10,ThrottlingRateLimit=5 >/dev/null
ENDPOINT=$(aws apigatewayv2 get-api --api-id $API --query ApiEndpoint --output text)/
echo
echo "완료! 서비스 주소: $ENDPOINT"
echo "상태 확인: ${ENDPOINT}health"
echo "(참고) 함수 URL: $URL"
