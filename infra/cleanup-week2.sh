#!/usr/bin/env bash
# 2주차 리소스 삭제 (과제 종료 후)
set -uo pipefail
ACC=$(aws sts get-caller-identity --query Account --output text)
BUCKET=kangwon-rag-docs-$ACC; ROLE=kangwon-rag-lambda-role; FN=kangwon-rag-chatbot
for a in $(aws apigatewayv2 get-apis --query "Items[?Name=='kangwon-rag-api'].ApiId" --output text); do aws apigatewayv2 delete-api --api-id $a; done
aws lambda delete-function --function-name $FN
aws logs delete-log-group --log-group-name /aws/lambda/$FN
aws iam delete-role-policy --role-name $ROLE --policy-name kb-query-only
aws iam detach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name $ROLE
# 버전 관리 버킷: 모든 버전 삭제 후 버킷 삭제
aws s3api delete-objects --bucket $BUCKET --delete "$(aws s3api list-object-versions --bucket $BUCKET \
  --query '{Objects: [Versions,DeleteMarkers][][].{Key:Key,VersionId:VersionId}}' --output json)" >/dev/null
aws s3api delete-bucket --bucket $BUCKET
