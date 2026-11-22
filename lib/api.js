// 게이트웨이 HTTP 클라이언트. 계약은 docs/contract.md.
// fetch 는 주입받는다(안경에서는 AIUI 의 fetch, 시험에서는 가짜).

export class GatewayError extends Error {
  constructor(code, message, { status = 0, retryAfter = 0 } = {}) {
    super(message);
    this.name = 'GatewayError';
    this.code = code;
    this.status = status;
    this.retryAfter = retryAfter;
  }
}

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const nonEmpty = (v) => typeof v === 'string' && v.length > 0;
const finite = (v) => typeof v === 'number' && Number.isFinite(v);
const badResponse = () => new GatewayError('bad_response', '서버 응답 형식이 다릅니다.');

// 본문을 못 읽어도 HTTP 상태로 뜻을 정한다(프록시가 HTML 오류를 줄 때).
function codeForStatus(status) {
  if (status === 401) return 'unauthorized';
  if (status === 403) return 'forbidden';
  if (status === 404) return 'not_found';
  if (status === 413) return 'too_large';
  if (status === 429) return 'rate_limited';
  if (status === 503) return 'busy';
  if (status === 502 || status === 504) return 'unavailable';
  return `http_${status}`;
}

export function createGateway({ baseUrl, fetchImpl, timeoutMs = 15000 }) {
  if (typeof fetchImpl !== 'function') throw new TypeError('fetchImpl 이 필요합니다');
  const base = String(baseUrl).replace(/\/+$/, '');

  // route 는 고정된 경로다. 조회 식별자는 요청 URL 에만 붙인다.
  async function request(method, route, { token, body, headers = {}, timeout = timeoutMs, expect = [200] } = {}, suffix = '') {
    const h = { ...headers };
    if (token) h.Authorization = `Bearer ${token}`;
    if (body !== undefined) h['content-type'] = 'application/json';
    let res;
    try {
      res = await fetchImpl(base + route + suffix, {
        method,
        headers: h,
        body: body === undefined ? undefined : JSON.stringify(body),
        timeout: Math.max(1000, Math.round(timeout)),
      });
    } catch (e) {
      console.log(`[memex] HTTP ${method} ${route} network`);
      throw new GatewayError('network', '서버에 연결하지 못했습니다.');
    }
    let data = null;
    try {
      data = await res.json();
    } catch (e) {
      data = null;
    }
    if (!res.ok) {
      console.log(`[memex] HTTP ${method} ${route} ${res.status}`);
      const err = isObject(data) && isObject(data.error) ? data.error : {};
      const retry = res.headers && typeof res.headers.get === 'function' ? Number(res.headers.get('retry-after')) : 0;
      throw new GatewayError(
        nonEmpty(err.code) ? err.code : codeForStatus(res.status),
        nonEmpty(err.message) ? err.message : `서버 오류 ${res.status}`,
        { status: res.status, retryAfter: Number.isFinite(retry) && retry > 0 ? retry : 0 },
      );
    }
    if (expect.indexOf(res.status) < 0 || !isObject(data)) throw badResponse();
    return data;
  }

  return {
    async health(opts = {}) {
      const d = await request('GET', '/healthz', opts);
      if (d.ok !== true || d.service !== 'memex-gw') throw badResponse();
      return d;
    },

    // → { pair_id, code, secret, expires_in }. 창이 닫혀 있으면 GatewayError(pairing_closed).
    async createPair(device, opts = {}) {
      const d = await request('POST', '/v1/pair', { ...opts, body: device ? { device } : {}, expect: [201] });
      const expires = d.expires_in;
      if (!nonEmpty(d.pair_id) || typeof d.code !== 'string' || !/^\d{6}$/.test(d.code) || !nonEmpty(d.secret)) throw badResponse();
      if (!finite(expires) || expires <= 0 || expires > 3600) throw badResponse();
      return { pair_id: d.pair_id, code: d.code, secret: d.secret, expires_in: expires };
    },

    // → { status: 'pending' } | { status: 'approved', token }. 만료·없음은 GatewayError(not_found).
    async checkPair(pairId, secret, opts = {}) {
      const d = await request('GET', '/v1/pair', { ...opts, headers: { 'X-Pair-Secret': secret } }, `/${encodeURIComponent(pairId)}`);
      if (d.status === 'pending') return { status: 'pending' };
      if (d.status === 'approved' && nonEmpty(d.token)) return { status: 'approved', token: d.token };
      throw badResponse();
    },

    // → { id, status: 'thinking' }. requestId 가 같으면 서버는 같은 작업을 돌려준다.
    async ask(token, question, { source = 'speech', lang = 'ko-KR', requestId, ...opts } = {}) {
      const body = { question, source, lang };
      if (requestId) body.request_id = requestId;
      const d = await request('POST', '/v1/ask', { ...opts, token, body, expect: [202, 200] });
      if (!nonEmpty(d.id) || (d.status !== 'thinking' && d.status !== 'done' && d.status !== 'error')) throw badResponse();
      return { id: d.id, status: d.status };
    },

    // → { id, status: 'thinking'|'done'|'error', answer?, error?, elapsed_ms }
    async getAnswer(token, id, opts = {}) {
      const d = await request('GET', '/v1/ask', { ...opts, token }, `/${encodeURIComponent(id)}`);
      if (d.id !== id || !finite(d.elapsed_ms)) throw badResponse();
      if (d.status === 'thinking') return d;
      if (d.status === 'done' && typeof d.answer === 'string') return d;
      if (d.status === 'error' && isObject(d.error) && nonEmpty(d.error.code)) return d;
      throw badResponse();
    },
  };
}
