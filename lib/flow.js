// 런타임 없이 시험할 수 있는 순수 로직: 대기 반복, 문구, 음성 결과 해석.
import { GatewayError } from './api.js';

export const ANSWER_POLL_MS = 1000;
export const ANSWER_GIVE_UP_MS = 120000;
export const PAIR_POLL_MS = 3000;
// 안경 쪽 만료가 지나도 서버가 확정(404)할 때까지 이만큼 더 묻는다(승인 응답 유실 대비, 서버 재수령 기간 2분).
export const PAIR_GRACE_MS = 130000;
export const PAIR_CLOSED_RETRY_MS = 5000;
const PAIR_NETWORK_FAILURE_LIMIT = 3;
export const REQUEST_TIMEOUT_MS = 15000;
export const LISTEN_MAX_MS = 15000;
export const STOP_GRACE_MS = 3000;
export const RESULT_GRACE_MS = 1500;
export const TAP_DEBOUNCE_MS = 600;
export const LOAD_GUARD_MS = 800;
export const MAX_QUESTION_CHARS = 500;

// 상태마다 글자와 모양 두 가지로 알린다(단색 렌즈라 밝기만으로 구분하지 않는다).
const STATUS = {
  pairing: { glyph: '◇', label: '연결' },
  idle: { glyph: '○', label: '대기' },
  listening: { glyph: '●', label: '듣는 중' },
  thinking: { glyph: '…', label: '찾는 중' },
  done: { glyph: '✓', label: '완료' },
  error: { glyph: '▲', label: '오류' },
};

export function statusOf(state) {
  return STATUS[state] || STATUS.idle;
}

const ERROR_TEXT = {
  network: '서버에 연결하지 못했습니다.',
  unavailable: '서버가 잠시 응답하지 않습니다.',
  timeout: '답이 너무 늦어 멈췄습니다.',
  backend_failed: '메모를 찾는 중 오류가 났습니다.',
  no_evidence: '메모를 확인하지 못했습니다.',
  internal: '서버 안에서 오류가 났습니다.',
  busy: '다른 질문을 처리 중입니다. 잠시 뒤 다시.',
  rate_limited: '요청이 너무 잦습니다. 잠시 뒤 다시.',
  too_large: '질문이 너무 깁니다. 짧게 다시.',
  bad_request: '질문을 보내지 못했습니다.',
  not_found: '요청이 만료됐습니다. 다시 해 주세요.',
  bad_response: '서버 응답을 읽지 못했습니다.',
  unauthorized: '기기 인증이 풀렸습니다. 다시 연결합니다.',
  pairing_closed: '서버에서 안경 연결을 열어 주세요.',
  empty_speech: '말씀을 못 알아들었습니다.',
  speech_unavailable: '이 기기에서 음성 인식을 쓸 수 없습니다.',
  mic_denied: '마이크 권한이 없습니다.',
  speech_failed: '음성 인식에 실패했습니다.',
};

export function errorText(code) {
  return ERROR_TEXT[code] || '알 수 없는 오류가 났습니다.';
}

// 음성 인식 오류 이름을 우리 코드로 바꾼다. 문서에 오류 값 목록이 없어 흔한 이름만 고르고 나머지는 일반 실패로 본다.
export function speechErrorCode(name) {
  const n = String(name || '');
  if (n === 'not-allowed' || n === 'service-not-allowed' || /denied|permission/i.test(n)) return 'mic_denied';
  if (n === 'no-speech' || n === 'nomatch') return 'empty_speech';
  if (n === 'audio-capture' || n === 'InvalidStateError') return 'speech_unavailable';
  return 'speech_failed';
}

// 한 줄로 줄이고 넘치면 말줄임표.
export function oneLine(text, max = 24) {
  const s = String(text || '').replace(/\s+/g, ' ').trim();
  const chars = Array.from(s);
  return chars.length > max ? `${chars.slice(0, max - 1).join('')}…` : s;
}

export function answerLines(answer) {
  return String(answer || '')
    .split('\n')
    .map((t) => t.trim())
    .filter(Boolean)
    .map((text, i) => ({ id: `a${i}`, text }));
}

export function formatRemaining(ms) {
  const sec = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`;
}

// SpeechRecognition result 이벤트에서 확정된 글자만 꺼낸다(isFinal 이 false 로 표시된 잠정 결과는 뺀다).
export function readTranscript(event) {
  const results = event && event.results;
  if (!results || typeof results.length !== 'number') return '';
  let text = '';
  for (let i = 0; i < results.length; i += 1) {
    const r = results[i];
    const alt = r && r[0];
    if (r && r.isFinal === false) continue;
    if (alt && typeof alt.transcript === 'string') text += alt.transcript;
  }
  return text.trim();
}

// 시스템 비서가 넘긴 질문(onLoad query). 문자열이 아니거나 비면 ''. 길이는 자르지 않는다(뜻이 바뀌므로).
export function questionFromQuery(query) {
  return query && typeof query.question === 'string' ? query.question.trim() : '';
}

export function tooLong(question) {
  return Array.from(String(question)).length > MAX_QUESTION_CHARS;
}

// 같은 질문을 다시 보낼 때 서버가 중복 작업을 만들지 않게 하는 요청 식별자.
export function makeRequestId() {
  const bytes = new Uint8Array(12);
  if (typeof crypto !== 'undefined' && crypto && typeof crypto.getRandomValues === 'function') crypto.getRandomValues(bytes);
  else for (let i = 0; i < bytes.length; i += 1) bytes[i] = Math.floor(Math.random() * 256);
  return `q${Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')}`;
}

const RETRYABLE = new Set(['network', 'rate_limited', 'busy', 'bad_response', 'unavailable']);
const waitAfter = (e, base) => Math.max(base, e && e.retryAfter ? e.retryAfter * 1000 : 0);

// 답이 나올 때까지 묻는다. 시작 시각(startedAt)부터 giveUpMs 가 절대 마감이다.
// 묻기 전·쉬기 전에 취소를 보고(null), 받은 최종 결과는 취소돼도 돌려준다(이미 서버가 끝낸 일이라).
export async function waitForAnswer({ api, token, id, sleep, now, isCancelled, onTick, startedAt, intervalMs = ANSWER_POLL_MS, giveUpMs = ANSWER_GIVE_UP_MS, requestTimeoutMs = REQUEST_TIMEOUT_MS }) {
  const started = typeof startedAt === 'number' ? startedAt : now();
  const deadline = started + giveUpMs;
  const timeout = () => new GatewayError('timeout', errorText('timeout'));
  for (;;) {
    if (isCancelled()) return null;
    let left = deadline - now();
    if (left <= 0) throw timeout();
    let view = null;
    let pause = intervalMs;
    try {
      view = await api.getAnswer(token, id, { timeout: Math.min(requestTimeoutMs, left) });
    } catch (e) {
      if (!(e instanceof GatewayError) || !RETRYABLE.has(e.code)) throw e;
      pause = waitAfter(e, intervalMs);
    }
    if (view && view.status !== 'thinking') {
      if (now() > deadline) throw timeout();
      return view;
    }
    left = deadline - now();
    if (onTick) onTick(now() - started);
    if (left <= 0) throw timeout();
    if (isCancelled()) return null;
    await sleep(Math.min(pause, left));
  }
}

// 승인될 때까지 묻는다. 취소되면 null, 승인되면 토큰. 서버가 404 로 확정하면 GatewayError(not_found).
// 유효기간은 서버가 판정한다: 안경 쪽 만료가 지나도 grace 동안은 같은 secret 으로 계속 묻는다.
export async function waitForPair({ api, pairId, secret, expiresAt, sleep, now, isCancelled, onTick, intervalMs = PAIR_POLL_MS, requestTimeoutMs = REQUEST_TIMEOUT_MS, graceMs = PAIR_GRACE_MS }) {
  for (;;) {
    if (isCancelled()) return null;
    let r = null;
    let pause = intervalMs;
    try {
      r = await api.checkPair(pairId, secret, { timeout: requestTimeoutMs });
    } catch (e) {
      if (!(e instanceof GatewayError) || !RETRYABLE.has(e.code)) throw e;
      pause = waitAfter(e, intervalMs);
    }
    if (r && r.status === 'approved') return r.token;
    const left = expiresAt - now();
    if (onTick) onTick(Math.max(0, left));
    if (left <= -graceMs) throw new GatewayError('not_found', errorText('not_found'));
    if (isCancelled()) return null;
    await sleep(pause);
  }
}

// 창이 닫혔거나 HTTP 응답을 받지 못하면 다시 신청한다. 연속 네트워크 실패에만 횟수 제한을 둔다.
// 신청이 받아들여지면 취소됐어도 그 결과를 돌려준다.
// onPosting(true/false): 실제 신청 요청이 오가는 동안만 true (창 열림을 기다리며 쉬는 동안은 false).
export async function createPairWhenOpen({ api, device, sleep, isCancelled, onClosed, onNetworkWait, onPosting, intervalMs = PAIR_CLOSED_RETRY_MS, requestTimeoutMs = REQUEST_TIMEOUT_MS }) {
  let networkFailures = 0;
  for (;;) {
    if (isCancelled()) return null;
    let pause = intervalMs;
    if (onPosting) onPosting(true);
    try {
      const p = await api.createPair(device, { timeout: requestTimeoutMs });
      if (onPosting) onPosting(false);
      return p;
    } catch (e) {
      if (onPosting) onPosting(false);
      if (isCancelled()) return null;
      if (!(e instanceof GatewayError)) throw e;
      if (e.code === 'network') {
        networkFailures += 1;
        if (networkFailures >= PAIR_NETWORK_FAILURE_LIMIT) throw e;
        if (onNetworkWait) onNetworkWait();
      } else {
        networkFailures = 0;
        if (e.code === 'pairing_closed') {
          if (onClosed) onClosed();
        } else if (e.code !== 'rate_limited') {
          throw e;
        }
      }
      pause = waitAfter(e, intervalMs);
    }
    if (isCancelled()) return null;
    await sleep(pause);
  }
}
