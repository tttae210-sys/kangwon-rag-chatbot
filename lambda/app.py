"""강원대 학사·장학 안내 RAG 챗봇 - 2주차 테스트 앱.

Lambda 함수 URL 하나로 채팅 화면(GET /)과 질문 API(POST /ask), 상태 확인(GET /health)을 제공한다.
3주차에 Bedrock Knowledge Bases(RetrieveAndGenerate)를 연결하기 전까지 /ask는 입력 검증과
응답 형식(answer + sources)만 확인하는 테스트 응답을 돌려준다.
"""
import json
import os
import time
from datetime import datetime, timezone

MAX_QUESTION_LEN = int(os.environ.get("MAX_QUESTION_LEN", "300"))
KB_ID = os.environ.get("KNOWLEDGE_BASE_ID", "")  # 3주차에 설정
DOCS_BUCKET = os.environ.get("DOCS_BUCKET", "")
APP_VERSION = "week2-test"

NO_EVIDENCE = "제공된 문서에서 근거를 찾지 못했습니다."

HTML = """<!DOCTYPE html>
<html lang="ko"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>강원대 학사·장학 안내 챗봇 (테스트)</title>
<style>
 body{margin:0;font-family:"Noto Sans KR","Malgun Gothic",system-ui,sans-serif;background:#f5f6f8;color:#1f2937}
 .wrap{max-width:720px;margin:0 auto;padding:28px 18px}
 h1{font-size:22px;margin:0 0 4px} .sub{color:#6b7280;font-size:14px;margin-bottom:18px}
 .badge{display:inline-block;background:#fef3c7;color:#92400e;border-radius:6px;padding:2px 8px;font-size:12px;margin-left:6px}
 #log{background:#fff;border:1px solid #e5e7eb;border-radius:12px;min-height:280px;padding:16px;margin-bottom:12px}
 .q{text-align:right;margin:10px 0}.q span{background:#1e40af;color:#fff;padding:8px 12px;border-radius:12px;display:inline-block;max-width:85%}
 .a{margin:10px 0}.a .body{background:#f3f4f6;padding:10px 12px;border-radius:12px;display:inline-block;max-width:90%;white-space:pre-wrap}
 .src{font-size:12px;color:#6b7280;margin-top:4px}
 form{display:flex;gap:8px} input{flex:1;padding:11px 12px;border:1px solid #d1d5db;border-radius:10px;font-size:15px;font-family:inherit}
 button{padding:0 18px;border:0;border-radius:10px;background:#1f2937;color:#fff;font-size:15px;cursor:pointer;font-family:inherit}
 .err{color:#b91c1c;font-size:13px;min-height:18px;margin-top:6px}
</style></head><body><div class="wrap">
<h1>강원대 학사·장학 안내 챗봇<span class="badge">2주차 테스트</span></h1>
<div class="sub">학사 공지·장학금·졸업요건을 물어보면 공식 문서를 근거로 답합니다. (지식 베이스 연결 전 테스트 버전)</div>
<div id="log"></div>
<form id="f"><input id="q" maxlength="__MAX__" placeholder="예: 복학 신청 기간이 언제야?" autocomplete="off"><button>질문</button></form>
<div class="err" id="err"></div>
</div>
<script>
const log=document.getElementById('log'),q=document.getElementById('q'),err=document.getElementById('err');
function add(cls,html){const d=document.createElement('div');d.className=cls;d.innerHTML=html;log.appendChild(d);log.scrollTop=log.scrollHeight;return d;}
function esc(s){return s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
document.getElementById('f').addEventListener('submit',async e=>{
  e.preventDefault();const text=q.value.trim();err.textContent='';
  if(!text){err.textContent='질문을 입력해 주세요.';return;}
  add('q','<span>'+esc(text)+'</span>');q.value='';
  const wait=add('a','<div class="body">답변을 찾는 중…</div>');
  try{
    const r=await fetch('ask',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({question:text})});
    const j=await r.json();
    if(!r.ok){wait.innerHTML='<div class="body">'+esc(j.error||'오류가 발생했습니다.')+'</div>';return;}
    let src=(j.sources||[]).map(s=>esc(s.title||'출처')).join(' · ');
    wait.innerHTML='<div class="body">'+esc(j.answer)+'</div>'+(src?'<div class="src">출처: '+src+'</div>':'<div class="src">'+esc(j.note||'')+'</div>');
  }catch(x){wait.innerHTML='<div class="body">서버에 연결하지 못했습니다.</div>';}
});
</script></body></html>""".replace("__MAX__", str(MAX_QUESTION_LEN))


def _resp(status, body, content_type="application/json; charset=utf-8"):
    if not isinstance(body, str):
        body = json.dumps(body, ensure_ascii=False)
    return {"statusCode": status, "headers": {"Content-Type": content_type}, "body": body}


def _log_metric(**fields):
    # 질문 원문은 남기지 않는다 (개인정보 보호). 길이·결과·처리 시간만 기록.
    print(json.dumps({"metric": "ask", **fields}, ensure_ascii=False))


def handle_ask(event):
    started = time.time()
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64
        raw = base64.b64decode(raw).decode("utf-8", "replace")
    try:
        question = (json.loads(raw).get("question") or "").strip()
    except (ValueError, AttributeError):
        return _resp(400, {"error": "요청 형식이 올바르지 않습니다."})

    if not question:
        _log_metric(result="empty", length=0)
        return _resp(400, {"error": "질문을 입력해 주세요."})
    if len(question) > MAX_QUESTION_LEN:
        _log_metric(result="too_long", length=len(question))
        return _resp(400, {"error": f"질문은 {MAX_QUESTION_LEN}자 이내로 입력해 주세요."})

    # 3주차: 여기서 bedrock-agent-runtime.retrieve_and_generate(knowledgeBaseId=KB_ID, ...) 호출
    answer = NO_EVIDENCE + " (지식 베이스 연결 전 테스트 응답입니다)"
    body = {
        "answer": answer,
        "sources": [],
        "note": "근거 문서가 없어 답변 불가 형식으로 응답했습니다. 학과 사무실 또는 학사 공지 게시판을 확인하세요.",
        "version": APP_VERSION,
    }
    _log_metric(result="no_source", length=len(question), ms=int((time.time() - started) * 1000))
    return _resp(200, body)


def handler(event, context):
    http = (event.get("requestContext") or {}).get("http") or {}
    method = http.get("method", "GET")
    path = event.get("rawPath", "/")

    if method == "GET" and path in ("/", "/index.html"):
        return _resp(200, HTML, "text/html; charset=utf-8")
    if method == "GET" and path == "/health":
        return _resp(200, {
            "status": "ok",
            "version": APP_VERSION,
            "region": os.environ.get("AWS_REGION"),
            "docs_bucket": DOCS_BUCKET,
            "knowledge_base": KB_ID or "not-connected",
            "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        })
    if method == "POST" and path == "/ask":
        return handle_ask(event)
    return _resp(404, {"error": "not found"})
