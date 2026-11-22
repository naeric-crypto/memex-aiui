<script type="application/json" def>
{
  "navigationBarTitleText": "내메모",
  "description": "사용자 개인 메모에서 일정·약속·골프·사람·장소·지난 기록을 찾아 짧게 보여 준다. 일정이나 사람에 대한 질문, '내메모' 로 시작하는 질문은 이 도구를 우선 사용한다. Searches the user's personal memos (schedule, people, places, past records) and shows a short answer. Read-only.",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "question": {
          "type": "string",
          "description": "사용자가 한 질문을 말한 그대로(한국어) 옮긴 문장. 예: '이번 주 일정 뭐 있어?', '홍길동이랑 마지막으로 언제 만났지?'. The user's question exactly as spoken, in the user's language."
        }
      }
    }
  }
}
</script>

<script setup>
import { DEVICE_NAME, GATEWAY_URL, TOKEN_KEY } from '../../config.js';
import { GatewayError, createGateway } from '../../lib/api.js';
import {
  LISTEN_MAX_MS,
  LOAD_GUARD_MS,
  REQUEST_TIMEOUT_MS,
  RESULT_GRACE_MS,
  STOP_GRACE_MS,
  TAP_DEBOUNCE_MS,
  answerLines,
  createPairWhenOpen,
  errorText,
  formatRemaining,
  makeRequestId,
  oneLine,
  questionFromQuery,
  readTranscript,
  speechErrorCode,
  statusOf,
  tooLong,
  waitForAnswer,
  waitForPair,
} from '../../lib/flow.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// 보내기 단계 실패: 서버가 받았는지 모르므로 같은 요청 식별자로 다시 보낸다(서버가 중복을 막는다).
const RESEND_CODES = ['network', 'busy', 'rate_limited', 'bad_response', 'unavailable', 'internal'];
// 서버가 작업을 끝내며 확정한 실패: 새 요청으로 다시 묻는다.
const TERMINAL_CODES = ['backend_failed', 'timeout', 'no_evidence'];

function detach(rec) {
  rec.onresult = null;
  rec.onnomatch = null;
  rec.onerror = null;
  rec.onend = null;
}

export default {
  data: {
    state: 'idle',
    glyph: '○',
    label: '대기',
    code: '',
    remaining: '',
    heard: '',
    message: '',
    elapsed: '',
    lines: [],
    hint: '',
  },

  onLoad(query) {
    this.loadedAt = Date.now();
    this.lastTap = 0;
    this.run = 0;
    this.hidden = false;
    this.pairPosting = false;
    this.asking = false;
    this.speech = null;
    this.pair = null;
    this.job = null;
    this.pending = null;
    this.retry = null;
    this.memToken = '';
    this.revokedToken = '';
    this.api = createGateway({ baseUrl: GATEWAY_URL, fetchImpl: (url, init) => fetch(url, init), timeoutMs: REQUEST_TIMEOUT_MS });

    const question = questionFromQuery(query);
    if (question && tooLong(question)) {
      this.fail({ code: 'too_large' });
    } else if (!this.readToken()) {
      this.pending = question ? { question, source: 'assistant' } : null;
      this.startPairing();
    } else if (question) {
      this.ask(question, 'assistant', null);
    } else {
      this.setIdle('');
    }
  },

  onShow() {
    if (!this.hidden) return;
    this.hidden = false;
    this.resume();
  },

  onHide() {
    this.hidden = true;
    this.cancelSpeech();
  },

  onUnload() {
    this.hidden = true;
    this.cancelRuns();
    this.cancelSpeech();
  },

  // 가려진 동안 멈춘 일을 이어 간다. 요청이 오가는 중이면 그 요청이 끝나는 쪽에서 이어 간다.
  resume() {
    const state = this.data.state;
    if (state === 'pairing') {
      if (this.pair) this.pollPair();
      else if (this.readToken()) this.afterPaired();
      else if (!this.pairPosting) this.startPairing();
    } else if (state === 'thinking') {
      if (this.job) this.pollAnswer();
      else if (!this.asking) this.setIdle('');
    } else if (state === 'listening') {
      this.setIdle('');
    }
  },

  // 확인은 Enter(관자놀이 탭)로 받는다. 실제로 무언가 했을 때만 기본 동작을 막는다. 위아래·뒤로는 기본 동작 그대로.
  onKeyUp(event) {
    if (!event || event.code !== 'Enter') return;
    if (this.handlePrimary() && typeof event.preventDefault === 'function') event.preventDefault();
  },

  onTapScreen() {
    this.handlePrimary();
  },

  handlePrimary() {
    const t = Date.now();
    // 이 페이지를 연 그 탭의 꼬리, 그리고 한 번의 탭이 두 이벤트로 오는 경우를 거른다.
    if (t - this.loadedAt < LOAD_GUARD_MS || t - this.lastTap < TAP_DEBOUNCE_MS) return false;
    const state = this.data.state;
    if (state === 'thinking' || state === 'pairing') return false;
    this.lastTap = t;
    if (state === 'listening') {
      this.stopListening(this.speech);
      return true;
    }
    if (state === 'error') {
      if (!this.readToken()) {
        this.startPairing();
        return true;
      }
      if (this.retry) {
        const r = this.retry;
        this.retry = null;
        if (r.jobId) this.resumeJob(r);
        else this.ask(r.question, r.source, r.requestId);
        return true;
      }
    }
    this.startListening();
    return true;
  },

  // ---- 화면 상태 ----

  show(state, patch) {
    const s = statusOf(state);
    this.setData({ state, glyph: s.glyph, label: s.label, ...patch });
  },

  setIdle(message) {
    this.show('idle', {
      heard: '',
      lines: [],
      elapsed: '',
      message: message || '탭하고 질문하세요',
      hint: '예: 이번 주 일정 뭐 있어?',
    });
  },

  // retry: { question, source, requestId, jobId, token } — 탭했을 때 무엇을 다시 할지.
  fail(err, retry) {
    const code = err && err.code ? err.code : 'unknown';
    if (code === 'unauthorized') {
      this.clearToken();
      this.pending = retry ? { question: retry.question, source: retry.source } : null;
      this.startPairing();
      return;
    }
    this.retry = retry || null;
    this.show('error', {
      code: '',
      remaining: '',
      lines: [],
      elapsed: '',
      message: errorText(code),
      hint: !this.readToken() ? '탭하면 다시 연결합니다' : retry ? '탭하면 다시 물어봅니다' : '탭하고 다시 말하세요',
    });
  },

  newRun() {
    this.run += 1;
    return this.run;
  },

  cancelRuns() {
    this.run += 1;
  },

  // ---- 기기 토큰: 이번 실행에서 받은 것·지운 것이 저장소보다 앞선다 ----

  readToken() {
    if (this.memToken) return this.memToken;
    let stored = '';
    try {
      stored = localStorage.getItem(TOKEN_KEY) || '';
    } catch (e) {}
    return stored && stored !== this.revokedToken ? stored : '';
  },

  saveToken(token) {
    this.memToken = token;
    this.revokedToken = '';
    try {
      localStorage.setItem(TOKEN_KEY, token);
    } catch (e) {}
  },

  clearToken() {
    this.revokedToken = this.readToken();
    this.memToken = '';
    try {
      localStorage.removeItem(TOKEN_KEY);
    } catch (e) {}
  },

  // ---- 페어링 ----

  async startPairing() {
    const run = this.newRun();
    this.pair = null;
    this.show('pairing', { code: '', remaining: '', heard: '', lines: [], elapsed: '', message: '서버에 연결하는 중…', hint: '' });
    try {
      const p = await createPairWhenOpen({
        api: this.api,
        device: DEVICE_NAME,
        sleep,
        isCancelled: () => run !== this.run || this.hidden,
        onPosting: (on) => {
          if (run === this.run) this.pairPosting = on;
        },
        onClosed: () => {
          if (run === this.run) this.setData({ message: '서버에서 안경 연결을 열어 주세요', hint: '열리면 자동으로 코드가 뜹니다' });
        },
      });
      if (run !== this.run || p === null) return;
      this.pair = { pair_id: p.pair_id, secret: p.secret, code: p.code, expiresAt: Date.now() + p.expires_in * 1000 };
      this.show('pairing', {
        code: p.code,
        remaining: formatRemaining(p.expires_in * 1000),
        message: '서버에 이 코드 승인을 요청하세요',
        hint: '승인되면 자동으로 넘어갑니다',
      });
      if (!this.hidden) this.pollPair();
    } catch (e) {
      if (run === this.run) {
        this.pairPosting = false;
        this.fail(e, null);
      }
    }
  },

  async pollPair() {
    const run = this.newRun();
    const pair = this.pair;
    if (!pair) return;
    try {
      const token = await waitForPair({
        api: this.api,
        pairId: pair.pair_id,
        secret: pair.secret,
        expiresAt: pair.expiresAt,
        sleep,
        now: Date.now,
        isCancelled: () => run !== this.run || this.hidden,
        onTick: (left) => {
          if (run === this.run) this.setData({ remaining: formatRemaining(left) });
        },
      });
      if (token === null || run !== this.run) return;
      // 토큰은 받자마자 보관한다. 화면이 가려져 있으면 보류 질문은 다시 보일 때 보낸다.
      this.pair = null;
      this.saveToken(token);
      if (!this.hidden) this.afterPaired();
    } catch (e) {
      if (run !== this.run) return;
      this.pair = null;
      if (e && e.code === 'not_found') {
        this.retry = null;
        this.show('error', { code: '', remaining: '', message: '코드가 만료됐습니다.', hint: '탭하면 새 코드를 받습니다' });
      } else {
        this.fail(e, null);
      }
    }
  },

  afterPaired() {
    const pending = this.pending;
    this.pending = null;
    if (pending) this.ask(pending.question, pending.source, null);
    else this.setIdle('연결됐습니다. 탭하고 질문하세요');
  },

  // ---- 질문 ----

  async ask(question, source, requestId) {
    const run = this.newRun();
    if (tooLong(question)) {
      this.fail({ code: 'too_large' });
      return;
    }
    const token = this.readToken();
    if (!token) {
      this.pending = { question, source };
      this.startPairing();
      return;
    }
    const rid = requestId || makeRequestId();
    const startedAt = Date.now();
    this.retry = null;
    this.job = null;
    this.asking = true;
    this.show('thinking', { heard: oneLine(question, 26), lines: [], message: '메모를 찾는 중', elapsed: '', hint: '' });
    try {
      const job = await this.api.ask(token, question, { source, lang: 'ko-KR', requestId: rid });
      if (run !== this.run) return;
      this.asking = false;
      this.job = { id: job.id, token, question, source, requestId: rid, startedAt, resumed: false };
      if (!this.hidden) this.pollAnswer();
    } catch (e) {
      if (run !== this.run) return;
      this.asking = false;
      const code = e && e.code;
      // 401 이면 fail 이 이 질문을 들고 페어링으로 돌아간다.
      const resend = RESEND_CODES.indexOf(code) >= 0 || /^http_5/.test(code || '') || code === 'unauthorized';
      this.fail(e, resend ? { question, source, requestId: rid } : null);
    }
  },

  // 이미 서버에 접수된 작업을 다시 조회한다(조회가 끊겼거나 안경 쪽 120초가 지났을 때).
  resumeJob(r) {
    this.newRun();
    this.job = { id: r.jobId, token: r.token, question: r.question, source: r.source, requestId: r.requestId, startedAt: Date.now(), resumed: true };
    this.show('thinking', { heard: oneLine(r.question, 26), lines: [], message: '메모를 찾는 중', elapsed: '', hint: '' });
    this.pollAnswer();
  },

  async pollAnswer() {
    const run = this.newRun();
    const job = this.job;
    if (!job) return;
    try {
      const view = await waitForAnswer({
        api: this.api,
        token: job.token,
        id: job.id,
        startedAt: job.startedAt,
        sleep,
        now: Date.now,
        isCancelled: () => run !== this.run || this.hidden,
        onTick: (ms) => {
          if (run === this.run) this.setData({ elapsed: `${Math.floor(ms / 1000)}초` });
        },
      });
      if (view === null || run !== this.run) return;
      this.job = null;
      if (view.status === 'done') {
        this.show('done', {
          heard: oneLine(job.question, 26),
          message: '',
          elapsed: '',
          lines: answerLines(view.answer),
          hint: '탭: 새 질문 · 위아래: 넘기기',
        });
      } else {
        const code = view.error.code;
        this.fail(new GatewayError(code, view.error.message || ''), TERMINAL_CODES.indexOf(code) >= 0 ? { question: job.question, source: job.source, requestId: null } : null);
      }
    } catch (e) {
      if (run !== this.run) return;
      this.job = null;
      const code = e && e.code;
      if (code === 'unauthorized') {
        this.fail(e, { question: job.question, source: job.source, requestId: null });
        return;
      }
      if (code === 'not_found') {
        // 작업이 사라졌으면(서버 재시작·10분 경과) 새로 묻는다.
        if (job.resumed) this.ask(job.question, job.source, null);
        else this.fail(e, { question: job.question, source: job.source, requestId: null });
        return;
      }
      // 조회 실패·안경 쪽 마감: 서버 작업은 살아 있을 수 있으니 같은 작업을 다시 조회하게 둔다.
      this.fail(e, { question: job.question, source: job.source, requestId: job.requestId, jobId: job.id, token: job.token });
    }
  },

  // ---- 페이지 안 음성 인식 (탭으로 시작해야 한다) ----
  // 한 번 듣기 = 세션 하나. 확정 결과만 보내고, 오류·무매치면 보내지 않는다.
  // 가려지거나 새로 듣기를 시작하면 이전 세션을 무효로 하고 콜백을 떼어 낸다. 종료 이벤트가 안 와도 정해진 시간 뒤 끝낸다.

  startListening() {
    if (typeof SpeechRecognition === 'undefined') {
      this.fail({ code: 'speech_unavailable' });
      return;
    }
    this.cancelSpeech();
    const run = this.newRun();
    let rec;
    try {
      rec = new SpeechRecognition();
      rec.lang = 'ko-KR';
      rec.continuous = false;
      rec.interimResults = false;
      rec.maxAlternatives = 1;
    } catch (e) {
      this.fail({ code: 'speech_unavailable' });
      return;
    }
    const session = { rec, timers: [], grace: null, done: false, text: '', error: '' };
    const current = () => this.speech === session && !session.done;
    const finish = (ended) => {
      if (!current()) return;
      session.done = true;
      this.speech = null;
      this.clearSessionTimers(session);
      detach(rec);
      if (!ended) {
        try {
          rec.abort();
        } catch (e) {}
      }
      if (run !== this.run || this.hidden) return;
      if (session.error) this.fail({ code: session.error });
      else if (!session.text) this.fail({ code: 'empty_speech' });
      else this.ask(session.text, 'speech', null);
    };
    session.finish = finish;
    rec.onresult = (event) => {
      if (!current()) return;
      const t = readTranscript(event);
      if (!t) return;
      session.text = t;
      this.setData({ heard: oneLine(t, 26) });
      // 결과가 왔는데 종료 이벤트가 늦으면, 가장 최근 결과로부터 잠시 뒤 스스로 끝낸다.
      if (session.grace) clearTimeout(session.grace);
      session.grace = setTimeout(() => finish(false), RESULT_GRACE_MS);
    };
    rec.onnomatch = () => {
      if (current()) session.error = session.error || 'empty_speech';
    };
    rec.onerror = (event) => {
      if (!current()) return;
      session.error = speechErrorCode(event && event.error);
      finish(false);
    };
    rec.onend = () => finish(true);
    this.speech = session;
    this.retry = null;
    this.show('listening', { heard: '', lines: [], elapsed: '', message: '듣고 있어요…', hint: '말을 마치면 자동으로 찾습니다' });
    try {
      rec.start();
    } catch (e) {
      session.done = true;
      this.speech = null;
      detach(rec);
      this.fail({ code: e && e.name === 'InvalidStateError' ? 'speech_unavailable' : 'speech_failed' });
      return;
    }
    session.timers.push(setTimeout(() => this.stopListening(session), LISTEN_MAX_MS));
  },

  // 그만 들으라고 하고, 종료 이벤트가 안 오면 잠시 뒤 끝낸다.
  stopListening(session) {
    if (!session || session.done || this.speech !== session) return;
    try {
      session.rec.stop();
    } catch (e) {}
    session.timers.push(setTimeout(() => session.finish(false), STOP_GRACE_MS));
  },

  clearSessionTimers(session) {
    for (const t of session.timers) clearTimeout(t);
    session.timers = [];
    if (session.grace) clearTimeout(session.grace);
    session.grace = null;
  },

  // 지금 세션을 무효로 하고 정리한다(결과를 보내지 않는다).
  cancelSpeech() {
    const session = this.speech;
    if (!session) return;
    session.done = true;
    this.speech = null;
    this.clearSessionTimers(session);
    detach(session.rec);
    try {
      session.rec.abort();
    } catch (e) {}
  },
};
</script>

<page>
  <view class="page" bindtap="onTapScreen">
    <view class="top">
      <text class="brand">내메모</text>
      <text class="status">{{glyph}} {{label}}</text>
    </view>

    <view class="pair" ink:if="{{state === 'pairing'}}">
      <text class="code" ink:if="{{code}}">{{code}}</text>
      <text class="body">{{message}}</text>
      <text class="meta" ink:if="{{remaining}}">남은 시간 {{remaining}}</text>
    </view>
    <view class="main {{state === 'error' ? 'main-error' : ''}}" ink:else>
      <text class="heard" ink:if="{{heard}}">{{heard}}</text>
      <text class="body" ink:if="{{message}}">{{message}}</text>
      <text class="meta" ink:if="{{elapsed}}">{{elapsed}}</text>
      <view class="answer" ink:if="{{lines.length}}">
        <text class="line {{index === 0 ? 'line-lead' : ''}}" ink:for="{{lines}}" ink:key="id">{{item.text}}</text>
      </view>
    </view>

    <text class="hint" ink:if="{{hint}}">{{hint}}</text>
  </view>
</page>

<style>
.page {
  --mx-green: #40ff5e;
  --mx-ink: rgba(64, 255, 94, 0.72);
  --mx-line: rgba(64, 255, 94, 0.24);
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 12px 16px;
  box-sizing: border-box;
  background-color: #000000;
  color: var(--mx-ink);
}

.top {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
  padding-bottom: 8px;
  border-bottom: 1px solid var(--mx-line);
}

.brand {
  font-size: 14px;
  font-weight: 500;
  color: var(--mx-ink);
}

.status {
  font-size: 12px;
  color: var(--mx-ink);
}

.pair {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  padding-top: 16px;
}

.code {
  font-family: monospace;
  font-size: 22px;
  font-weight: 500;
  color: var(--mx-green);
  padding: 8px 16px;
  border: 1px solid var(--mx-ink);
  border-radius: 6px;
}

.main {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.main-error {
  padding-left: 8px;
  border-left: 1px dashed var(--mx-ink);
}

.heard {
  font-size: 12px;
  color: var(--mx-ink);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.body {
  font-size: 14px;
  font-weight: 500;
  line-height: 1.45;
  color: var(--mx-green);
}

.meta {
  font-family: monospace;
  font-size: 12px;
  color: var(--mx-ink);
}

.answer {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.line {
  font-size: 14px;
  line-height: 1.45;
  color: var(--mx-ink);
}

.line-lead {
  color: var(--mx-green);
}

.hint {
  font-size: 12px;
  color: var(--mx-ink);
  padding-top: 8px;
  border-top: 1px solid var(--mx-line);
}
</style>
