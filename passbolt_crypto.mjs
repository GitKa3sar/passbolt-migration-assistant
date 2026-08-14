#!/usr/bin/env node

/**
 * Local OpenPGP and Passbolt GPGAuth bridge.
 *
 * Input and output are one JSON document over stdin/stdout. Private-key
 * passphrases and resource passwords are accepted only through stdin and are
 * never included in the output, logs, command line, environment, or files.
 */

import { createHash, randomUUID } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { pathToFileURL } from 'node:url';
import * as openpgp from 'openpgp';

const INPUT_LIMIT = 64 * 1024 * 1024;
const KEY_FILE_LIMIT = 2 * 1024 * 1024;
const RESPONSE_LIMIT = 64 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 25_000;
const MAX_REDIRECTS = 5;
const MAX_ACL_OBJECTS = 2_000;
const MAX_ACL_PERMISSION_ROWS = 20_000;
const MAX_ACL_CATALOG_BYTES = 3 * 1024 * 1024;
const MAX_ACL_PLAN_OPERATIONS = 2_000;
const USER_AGENT = 'Passbolt-Migration-Assistant/0.22.0';
const RESOURCE_METADATA_OBJECT_TYPE = 'PASSBOLT_RESOURCE_METADATA';
const FOLDER_METADATA_OBJECT_TYPE = 'PASSBOLT_FOLDER_METADATA';
const SECRET_DATA_OBJECT_TYPE = 'PASSBOLT_SECRET_DATA';
const METADATA_PRIVATE_KEY_OBJECT_TYPE = 'PASSBOLT_METADATA_PRIVATE_KEY';
const TOKEN_PATTERN = /^gpgauthv1\.3\.0\|36\|[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\|gpgauthv1\.3\.0$/i;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
const UUID_V4_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

class SafeError extends Error {
  constructor(code, message, details = undefined) {
    super(message);
    this.name = 'SafeError';
    this.code = code;
    this.details = details;
  }
}

function assert(condition, code, message, details = undefined) {
  if (!condition) {
    throw new SafeError(code, message, details);
  }
}

function normalizeFingerprint(value, label = 'fingerprint') {
  const normalized = String(value ?? '').replace(/[^0-9a-f]/gi, '').toUpperCase();
  assert(normalized.length === 40, 'INVALID_FINGERPRINT', `${label} non valida.`);
  return normalized;
}

function normalizeBaseUrl(value) {
  let parsed;
  try {
    parsed = new URL(String(value ?? '').trim());
  } catch {
    throw new SafeError('INVALID_BASE_URL', "L'URL Passbolt non e valido.");
  }
  assert(parsed.protocol === 'https:', 'HTTPS_REQUIRED', "L'URL Passbolt deve usare HTTPS.");
  assert(Boolean(parsed.hostname), 'INVALID_BASE_URL', "L'URL Passbolt non contiene un host.");
  assert(parsed.pathname === '/' && !parsed.search && !parsed.hash, 'INVALID_BASE_URL', "Indicare soltanto l'URL base di Passbolt.");
  return parsed.origin;
}

function decodeHeaderValue(value) {
  const raw = String(value ?? '');
  // Passbolt encodes GPGAuth headers with application/x-www-form-urlencoded
  // semantics. Go's url.QueryUnescape (used by the official client) converts
  // literal '+' characters to spaces before percent-decoding; JavaScript's
  // decodeURIComponent does not. A correctly encoded base64 '+' remains %2B
  // and is therefore preserved by this order of operations.
  const formEncoded = raw.replace(/\+/g, ' ');
  try {
    return decodeURIComponent(formEncoded).replace(/\\ /g, ' ');
  } catch {
    return formEncoded.replace(/\\ /g, ' ');
  }
}

function apiBody(document) {
  if (document && typeof document === 'object' && Object.hasOwn(document, 'body')) {
    return document.body;
  }
  return document;
}

function apiMessage(document, fallback) {
  const header = document && typeof document === 'object' ? document.header : null;
  if (header && typeof header === 'object' && typeof header.message === 'string') {
    return header.message.replace(/[\r\n]+/g, ' ').slice(0, 300);
  }
  return fallback;
}

async function readInput() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    assert(size <= INPUT_LIMIT, 'INPUT_TOO_LARGE', 'Richiesta locale troppo grande.');
    chunks.push(chunk);
  }
  assert(size > 0, 'EMPTY_INPUT', 'Nessuna richiesta ricevuta.');
  let value;
  try {
    value = JSON.parse(stripUtf8Bom(Buffer.concat(chunks).toString('utf8')));
  } catch {
    throw new SafeError('INVALID_INPUT', 'La richiesta locale non contiene JSON valido.');
  }
  assert(value && typeof value === 'object' && !Array.isArray(value), 'INVALID_INPUT', 'La richiesta locale deve essere un oggetto JSON.');
  return value;
}

async function loadPrivateKey(filePath, passphrase) {
  assert(typeof filePath === 'string' && filePath.trim(), 'KEY_PATH_REQUIRED', 'Selezionare il file della chiave privata OpenPGP.');
  assert(isAbsolute(filePath), 'KEY_PATH_NOT_ABSOLUTE', 'Il percorso della chiave privata deve essere assoluto.');
  const absolutePath = resolve(filePath);
  let info;
  try {
    info = await stat(absolutePath);
  } catch {
    throw new SafeError('KEY_NOT_FOUND', 'Il file della chiave privata non e accessibile.');
  }
  assert(info.isFile(), 'KEY_NOT_FILE', 'Il percorso selezionato non e un file.');
  assert(info.size > 0 && info.size <= KEY_FILE_LIMIT, 'KEY_FILE_SIZE', 'Il file della chiave privata ha una dimensione non consentita.');

  let armored;
  try {
    armored = await readFile(absolutePath, 'utf8');
  } catch {
    throw new SafeError('KEY_READ_FAILED', 'Impossibile leggere il file della chiave privata.');
  }
  assert(
    armored.includes('-----BEGIN PGP PRIVATE KEY BLOCK-----') && armored.includes('-----END PGP PRIVATE KEY BLOCK-----'),
    'NOT_PRIVATE_KEY',
    'Il file non contiene una chiave privata OpenPGP completa.',
  );

  let privateKey;
  try {
    privateKey = await openpgp.readPrivateKey({ armoredKey: armored });
  } catch {
    throw new SafeError('INVALID_PRIVATE_KEY', 'La chiave privata OpenPGP non e valida.');
  }
  const wasEncrypted = !privateKey.isDecrypted();
  if (wasEncrypted) {
    assert(typeof passphrase === 'string' && passphrase.length > 0, 'PASSPHRASE_REQUIRED', 'Inserire la passphrase della chiave privata.');
    try {
      privateKey = await openpgp.decryptKey({ privateKey, passphrase });
    } catch {
      throw new SafeError('BAD_PASSPHRASE', 'Passphrase non corretta oppure chiave privata non utilizzabile.');
    }
  }
  assert(privateKey.isDecrypted(), 'KEY_LOCKED', 'La chiave privata non e stata sbloccata.');
  const publicKey = privateKey.toPublic();
  return {
    privateKey,
    publicKey,
    fingerprint: normalizeFingerprint(publicKey.getFingerprint(), 'Fingerprint della chiave utente'),
    keyId: publicKey.getKeyID().toHex().toUpperCase(),
    userIds: publicKey.getUserIDs().map((value) => String(value).slice(0, 300)),
    encrypted: wasEncrypted,
  };
}

function parseSetCookie(headers) {
  if (typeof headers.getSetCookie === 'function') {
    return headers.getSetCookie();
  }
  const combined = headers.get('set-cookie');
  if (!combined) return [];
  return combined.split(/,(?=\s*[^;,=\s]+=[^;,]*)/g);
}

class PassboltSession {
  constructor(baseUrl) {
    this.baseUrl = baseUrl;
    this.cookies = new Map();
  }

  updateCookies(headers) {
    for (const cookieLine of parseSetCookie(headers)) {
      const firstPart = cookieLine.split(';', 1)[0];
      const separator = firstPart.indexOf('=');
      if (separator <= 0) continue;
      const name = firstPart.slice(0, separator).trim();
      const value = firstPart.slice(separator + 1).trim();
      if (!value) this.cookies.delete(name);
      else this.cookies.set(name, value);
    }
  }

  getCookie(name) {
    return this.cookies.get(name);
  }

  get csrfToken() {
    const value = this.cookies.get('csrfToken');
    if (!value) return null;
    try {
      return decodeURIComponent(value);
    } catch {
      return value;
    }
  }

  async request(path, options = {}) {
    const originalPath = String(path);
    const baseOrigin = new URL(this.baseUrl).origin;
    let requestUrl;
    try {
      requestUrl = new URL(originalPath, this.baseUrl);
    } catch {
      throw new SafeError('API_INVALID_PATH', `Il percorso API ${originalPath} non e valido.`);
    }
    assert(
      requestUrl.origin === baseOrigin && !requestUrl.username && !requestUrl.password,
      'API_CROSS_ORIGIN_REQUEST',
      `La richiesta a ${originalPath} non appartiene all'istanza Passbolt configurata.`,
    );

    let method = String(options.method ?? 'GET').toUpperCase();
    let requestBody = options.body === undefined ? undefined : JSON.stringify(options.body);
    const baseHeaders = {
      Accept: 'application/json',
      'User-Agent': USER_AGENT,
      ...(options.headers ?? {}),
    };
    const redirects = [];
    const signal = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
    let response;
    while (true) {
      const headers = new Headers(baseHeaders);
      headers.delete('Cookie');
      if (this.cookies.size) {
        headers.set('Cookie', [...this.cookies.entries()].map(([name, value]) => `${name}=${value}`).join('; '));
      }
      headers.delete('Content-Type');
      if (requestBody !== undefined) {
        headers.set('Content-Type', 'application/json');
      }
      headers.delete('X-CSRF-Token');
      if (!['GET', 'HEAD'].includes(method) && this.csrfToken) {
        headers.set('X-CSRF-Token', this.csrfToken);
      }

      try {
        response = await fetch(requestUrl, {
          method,
          headers,
          body: requestBody,
          redirect: 'manual',
          signal,
        });
      } catch (error) {
        const timeout = error && (error.name === 'TimeoutError' || error.name === 'AbortError');
        throw new SafeError(timeout ? 'API_TIMEOUT' : 'API_CONNECTION_FAILED', timeout ? `Timeout durante la richiesta a ${originalPath}.` : `Connessione a ${originalPath} non riuscita.`);
      }
      this.updateCookies(response.headers);

      if (!REDIRECT_STATUSES.has(response.status)) break;
      const location = response.headers.get('location');
      assert(location, 'API_REDIRECT_MISSING_LOCATION', `Il redirect ricevuto da ${originalPath} non indica una destinazione.`);
      assert(redirects.length < MAX_REDIRECTS, 'API_TOO_MANY_REDIRECTS', `Troppi redirect durante la richiesta a ${originalPath}.`);

      let nextUrl;
      try {
        nextUrl = new URL(location, requestUrl);
      } catch {
        throw new SafeError('API_REDIRECT_INVALID', `Il redirect ricevuto da ${originalPath} non e valido.`);
      }
      assert(
        nextUrl.origin === baseOrigin && !nextUrl.username && !nextUrl.password,
        'API_REDIRECT_CROSS_ORIGIN',
        `Un redirect di ${originalPath} verso un'origine diversa e stato rifiutato.`,
      );
      nextUrl.hash = '';
      redirects.push({ status: response.status, path: nextUrl.pathname });

      // Match the normal HTTP redirect semantics used by the official client:
      // 301/302/303 turn a non-GET request into GET; 307/308 preserve it.
      if ([301, 302, 303].includes(response.status) && !['GET', 'HEAD'].includes(method)) {
        method = 'GET';
        requestBody = undefined;
      }
      try {
        await response.body?.cancel();
      } catch {
        // The destination can still be followed if the empty redirect body
        // cannot be cancelled by the current Node.js implementation.
      }
      requestUrl = nextUrl;
    }

    const contentLength = Number(response.headers.get('content-length'));
    assert(!Number.isFinite(contentLength) || contentLength <= RESPONSE_LIMIT, 'API_RESPONSE_TOO_LARGE', `La risposta di ${originalPath} e troppo grande.`);
    let raw;
    try {
      raw = await response.arrayBuffer();
    } catch {
      throw new SafeError('API_RESPONSE_READ_FAILED', `La risposta di ${originalPath} non e stata letta completamente.`);
    }
    assert(raw.byteLength <= RESPONSE_LIMIT, 'API_RESPONSE_TOO_LARGE', `La risposta di ${originalPath} e troppo grande.`);
    const text = Buffer.from(raw).toString('utf8');
    let document = null;
    if (text.trim()) {
      try {
        document = JSON.parse(text);
      } catch {
        const redirectNote = redirects.length ? ` dopo ${redirects.length} redirect interno` : '';
        throw new SafeError(
          'API_INVALID_JSON',
          `${originalPath} non ha restituito JSON valido${redirectNote}.`,
          { endpoint: originalPath, http_status: response.status, redirect_count: redirects.length, final_path: requestUrl.pathname },
        );
      }
    }
    const result = { status: response.status, headers: response.headers, document, redirects };
    if (!options.allowError && !response.ok) {
      throw new SafeError(
        'API_HTTP_ERROR',
        apiMessage(document, `${originalPath} ha restituito HTTP ${response.status}.`),
        { endpoint: originalPath, http_status: response.status, redirect_count: redirects.length },
      );
    }
    return result;
  }
}

async function getServerKey(session, expectedFingerprint) {
  const response = await session.request('/auth/verify.json');
  const body = apiBody(response.document);
  assert(body && typeof body === 'object', 'SERVER_KEY_MISSING', 'La verifica Passbolt non contiene la chiave del server.');
  assert(typeof body.fingerprint === 'string' && typeof body.keydata === 'string', 'SERVER_KEY_MISSING', 'La verifica Passbolt non contiene fingerprint e chiave pubblica.');
  const advertised = normalizeFingerprint(body.fingerprint, 'Fingerprint del server');
  assert(advertised === expectedFingerprint, 'SERVER_FINGERPRINT_MISMATCH', 'La fingerprint del server Passbolt e cambiata. Login interrotto.');
  let publicKey;
  try {
    publicKey = await openpgp.readKey({ armoredKey: body.keydata });
  } catch {
    throw new SafeError('SERVER_KEY_INVALID', 'La chiave pubblica del server Passbolt non e valida.');
  }
  const actual = normalizeFingerprint(publicKey.getFingerprint(), 'Fingerprint OpenPGP del server');
  assert(actual === expectedFingerprint, 'SERVER_KEY_FINGERPRINT_MISMATCH', 'La chiave pubblica ricevuta non corrisponde alla fingerprint attesa.');
  return publicKey;
}

async function verifyServerOwnership(session, serverPublicKey, userFingerprint) {
  const token = `gpgauthv1.3.0|36|${randomUUID()}|gpgauthv1.3.0`;
  const encrypted = await openpgp.encrypt({
    message: await openpgp.createMessage({ text: token }),
    encryptionKeys: serverPublicKey,
    format: 'armored',
  });
  let response = await session.request('/auth/verify.json?api-version=v2', {
    method: 'POST',
    body: { data: { gpg_auth: { keyid: userFingerprint, server_verify_token: encrypted } } },
    allowError: true,
  });
  let returned = decodeHeaderValue(response.headers.get('x-gpgauth-verify-response'));
  if (!returned) {
    response = await session.request('/auth/verify.json?api-version=v2', {
      method: 'POST',
      body: { gpg_auth: { keyid: userFingerprint, server_verify_token: encrypted } },
      allowError: true,
    });
    returned = decodeHeaderValue(response.headers.get('x-gpgauth-verify-response'));
  }
  assert(response.status >= 200 && response.status < 500 && returned, 'SERVER_OWNERSHIP_UNVERIFIED', 'Passbolt non ha restituito la prova GPGAuth del server.');
  assert(returned === token, 'SERVER_OWNERSHIP_MISMATCH', 'La prova GPGAuth del server non corrisponde. Login interrotto.');
}

async function decryptServerChallenge(armoredChallenge, privateKey, serverPublicKey) {
  let message;
  try {
    message = await openpgp.readMessage({ armoredMessage: armoredChallenge });
  } catch {
    throw new SafeError('AUTH_CHALLENGE_INVALID', 'La sfida GPGAuth ricevuta non e un messaggio OpenPGP valido.');
  }
  let decrypted;
  try {
    decrypted = await openpgp.decrypt({
      message,
      decryptionKeys: privateKey,
      verificationKeys: serverPublicKey,
      format: 'utf8',
    });
  } catch {
    throw new SafeError('AUTH_CHALLENGE_DECRYPT_FAILED', 'Impossibile decifrare o verificare la sfida GPGAuth.');
  }
  assert(Array.isArray(decrypted.signatures) && decrypted.signatures.length > 0, 'AUTH_CHALLENGE_UNSIGNED', 'La sfida GPGAuth non contiene una firma del server.');
  try {
    await Promise.all(decrypted.signatures.map((signature) => signature.verified));
  } catch {
    throw new SafeError('AUTH_CHALLENGE_BAD_SIGNATURE', 'La firma della sfida GPGAuth non e valida.');
  }
  const token = String(decrypted.data ?? '').trim();
  assert(TOKEN_PATTERN.test(token), 'AUTH_TOKEN_INVALID', 'Il token GPGAuth decifrato non ha il formato previsto.');
  return token;
}

function mfaProvidersFromResponse(response) {
  const body = apiBody(response.document);
  const providerData = body && typeof body === 'object' ? (body.mfa_providers ?? body.providers) : null;
  const providers = Array.isArray(providerData)
    ? providerData.map(String)
    : providerData && typeof providerData === 'object'
      ? Object.keys(providerData).filter((name) => Boolean(providerData[name]))
      : [];
  return [...new Set(providers.map((provider) => provider.toLowerCase()).filter((provider) => /^[a-z0-9_-]{1,32}$/.test(provider)))].slice(0, 10);
}

function isMfaChallengeResponse(response) {
  const responseHeader = response.document && typeof response.document === 'object' ? response.document.header : null;
  const responseHeaderUrl = responseHeader && typeof responseHeader === 'object' && typeof responseHeader.url === 'string'
    ? responseHeader.url.toLowerCase()
    : '';
  const redirectedToMfa = response.redirects.some((redirect) => redirect.path.toLowerCase().includes('/mfa/'));
  const forbidden = response.status === 403 || (responseHeader && Number(responseHeader.code) === 403);
  return Boolean(forbidden && (response.status === 403 || redirectedToMfa || responseHeaderUrl.includes('/mfa/')));
}

function stripUtf8Bom(value) {
  return value.charCodeAt(0) === 0xfeff ? value.slice(1) : value;
}

function mfaClockSkewSeconds(response) {
  const header = response.document && typeof response.document === 'object' ? response.document.header : null;
  const serverTime = header && typeof header === 'object'
    ? Number(header.servertime ?? header.server_time)
    : Number.NaN;
  if (!Number.isFinite(serverTime) || serverTime <= 0) return null;
  return Math.round(serverTime - (Date.now() / 1000));
}

function validateTotpCode(value) {
  const code = String(value ?? '').trim();
  assert(code.length > 0, 'MFA_TOTP_REQUIRED', 'Inserire il codice MFA TOTP di 6 cifre e ripetere l’operazione.');
  assert(/^\d{6}$/.test(code), 'MFA_TOTP_FORMAT', 'Il codice MFA TOTP deve contenere esattamente 6 cifre.');
  return code;
}

async function completeTotpMfa(session, challengeResponse, value) {
  const providers = mfaProvidersFromResponse(challengeResponse);
  if (!providers.includes('totp')) {
    const providerLabel = providers.length ? providers.join(', ') : 'non comunicato';
    throw new SafeError(
      'MFA_PROVIDER_UNSUPPORTED',
      `L’account richiede un provider MFA non ancora supportato da questa procedura (${providerLabel}).`,
      { mfa_providers: providers },
    );
  }

  const totp = validateTotpCode(value);
  const clockSkewSeconds = mfaClockSkewSeconds(challengeResponse);
  const response = await session.request('/mfa/verify/totp.json?api-version=v2', {
    method: 'POST',
    // The current Passbolt API contract accepts only the provider field.
    // Older servers also accept this minimal payload, while an extra
    // `remember` field can be rejected by strict request validation.
    body: { totp },
    allowError: true,
  });
  const responseHeader = response.document && typeof response.document === 'object' ? response.document.header : null;
  const apiFailed = responseHeader && typeof responseHeader === 'object' && responseHeader.status === 'error';
  if (response.status === 429) {
    throw new SafeError('MFA_RATE_LIMITED', 'Troppi tentativi MFA. Attendere e riprovare con un nuovo codice TOTP.', {
      http_status: response.status,
      ...(clockSkewSeconds === null ? {} : { clock_skew_seconds: clockSkewSeconds }),
    });
  }
  if (response.status < 200 || response.status >= 300 || apiFailed) {
    const clockHint = clockSkewSeconds !== null && Math.abs(clockSkewSeconds) >= 20
      ? ` L'orologio del PC differisce da quello del server di circa ${Math.abs(clockSkewSeconds)} secondi.`
      : '';
    throw new SafeError(
      'MFA_TOTP_REJECTED',
      `Il codice MFA TOTP non e stato accettato. Generare un nuovo codice e riprovare.${clockHint}`,
      {
        http_status: response.status,
        ...(clockSkewSeconds === null ? {} : { clock_skew_seconds: clockSkewSeconds }),
      },
    );
  }
  assert(session.getCookie('passbolt_mfa'), 'MFA_COOKIE_MISSING', 'Passbolt ha accettato il codice MFA ma non ha restituito il cookie di autorizzazione atteso.');
  return 'totp';
}

async function authenticate(session, keyMaterial, expectedFingerprint, mfaTotp = '') {
  let authPhase = 'server_key';
  try {
    const serverPublicKey = await getServerKey(session, expectedFingerprint);
    authPhase = 'server_ownership';
    await verifyServerOwnership(session, serverPublicKey, keyMaterial.fingerprint);

    // Passbolt's current GPGAuth contract wraps both login stages in
    // data.gpg_auth. Keep an unwrapped retry only for legacy instances.
    authPhase = 'user_challenge';
    let wrappedPayload = true;
    let stageOne = await session.request('/auth/login.json?api-version=v2', {
      method: 'POST',
      body: { data: { gpg_auth: { keyid: keyMaterial.fingerprint } } },
      allowError: true,
    });
    let challengeHeader = stageOne.headers.get('x-gpgauth-user-auth-token');
    if (!challengeHeader) {
      wrappedPayload = false;
      stageOne = await session.request('/auth/login.json?api-version=v2', {
        method: 'POST',
        body: { gpg_auth: { keyid: keyMaterial.fingerprint } },
        allowError: true,
      });
      challengeHeader = stageOne.headers.get('x-gpgauth-user-auth-token');
    }
    assert(challengeHeader, 'AUTH_CHALLENGE_MISSING', apiMessage(stageOne.document, 'Passbolt non ha restituito la sfida GPGAuth per questo utente.'));
    authPhase = 'challenge_decryption';
    const challenge = decodeHeaderValue(challengeHeader);
    const token = await decryptServerChallenge(challenge, keyMaterial.privateKey, serverPublicKey);

    authPhase = 'challenge_response';
    const stageTwoData = {
      gpg_auth: {
        keyid: keyMaterial.fingerprint,
        user_token_result: token,
      },
    };
    const stageTwo = await session.request('/auth/login.json?api-version=v2', {
      method: 'POST',
      body: wrappedPayload ? { data: stageTwoData } : stageTwoData,
      allowError: true,
    });
    if (stageTwo.status < 200 || stageTwo.status >= 300) {
      throw new SafeError('AUTH_FAILED', apiMessage(stageTwo.document, `Login GPGAuth non riuscito (HTTP ${stageTwo.status}).`), { http_status: stageTwo.status });
    }
    const authenticatedHeader = stageTwo.headers.get('x-gpgauth-authenticated');
    assert(!authenticatedHeader || authenticatedHeader.toLowerCase() === 'true', 'AUTH_NOT_CONFIRMED', 'Passbolt non ha confermato il completamento del login GPGAuth.');
    authPhase = 'session_cookie';
    const hasSession = ['passbolt_session', 'CAKEPHP', 'PHPSESSID'].some((name) => Boolean(session.getCookie(name)));
    assert(hasSession, 'AUTH_SESSION_MISSING', 'Il login non ha restituito un cookie di sessione Passbolt.');

    authPhase = 'identity_check';
    let mfaProvider = null;
    let meResponse = await session.request('/users/me.json?api-version=v2', { allowError: true });
    if (isMfaChallengeResponse(meResponse)) {
      authPhase = 'mfa_totp';
      mfaProvider = await completeTotpMfa(session, meResponse, mfaTotp);
      authPhase = 'identity_after_mfa';
      meResponse = await session.request('/users/me.json?api-version=v2', { allowError: true });
      if (isMfaChallengeResponse(meResponse)) {
        throw new SafeError('MFA_TOTP_REJECTED', 'La verifica MFA non ha autorizzato la sessione. Generare un nuovo codice TOTP e riprovare.');
      }
    }
    if (meResponse.status < 200 || meResponse.status >= 300) {
      const redirectNote = meResponse.redirects.length ? ` dopo ${meResponse.redirects.length} redirect interno` : '';
      throw new SafeError('AUTH_IDENTITY_FAILED', apiMessage(meResponse.document, `Lettura dell'identita utente non riuscita (HTTP ${meResponse.status}${redirectNote}).`), { http_status: meResponse.status });
    }
    authPhase = 'identity_binding';
    const user = apiBody(meResponse.document);
    assert(user && typeof user === 'object' && typeof user.id === 'string', 'AUTH_IDENTITY_INVALID', "Passbolt non ha restituito un'identita utente valida.");
    const accountFingerprint = user.gpgkey && typeof user.gpgkey === 'object' && typeof user.gpgkey.fingerprint === 'string'
      ? normalizeFingerprint(user.gpgkey.fingerprint, "Fingerprint dell'account Passbolt")
      : null;
    assert(!accountFingerprint || accountFingerprint === keyMaterial.fingerprint, 'AUTH_KEY_IDENTITY_MISMATCH', "La chiave privata non corrisponde alla chiave dell'identita Passbolt autenticata.");
    return { user, serverPublicKey, mfaProvider };
  } catch (error) {
    if (error instanceof SafeError) {
      const safeDetails = error.details && typeof error.details === 'object' && !Array.isArray(error.details)
        ? error.details
        : {};
      error.details = { ...safeDetails, auth_phase: authPhase };
    }
    throw error;
  }
}

async function logout(session) {
  try {
    await session.request('/auth/logout.json?api-version=v2', { method: 'POST', allowError: true });
  } catch {
    // Logout is best-effort; the server session still expires independently.
  }
}

function safeUser(user) {
  const profile = user.profile && typeof user.profile === 'object' ? user.profile : {};
  return {
    id: String(user.id ?? ''),
    username: String(user.username ?? '').slice(0, 300),
    first_name: String(profile.first_name ?? '').slice(0, 120),
    last_name: String(profile.last_name ?? '').slice(0, 120),
    active: Boolean(user.active),
  };
}

function simplifyResourceTypes(document) {
  const body = apiBody(document);
  const entries = Array.isArray(body) ? body : [];
  return entries
    .filter((entry) => entry && typeof entry === 'object')
    .map((entry) => ({
      id: typeof entry.id === 'string' ? entry.id : '',
      slug: typeof entry.slug === 'string' ? entry.slug : '',
      name: typeof entry.name === 'string' ? entry.name.slice(0, 200) : '',
      definition: parseResourceDefinition(entry.definition),
    }))
    .filter((entry) => entry.id && entry.slug);
}

function parseJsonObject(value) {
  let parsed = value;
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed);
    } catch {
      return null;
    }
  }
  return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
}

function parseResourceDefinition(value) {
  const definition = parseJsonObject(value);
  if (!definition) return null;
  return {
    ...definition,
    resource: parseJsonObject(definition.resource) ?? definition.resource,
    secret: parseJsonObject(definition.secret) ?? definition.secret,
  };
}

function resourceSchemaHasField(resourceType, section, field) {
  const schema = resourceType?.definition && typeof resourceType.definition === 'object'
    ? resourceType.definition[section]
    : null;
  return Boolean(
    schema
    && typeof schema === 'object'
    && schema.properties
    && typeof schema.properties === 'object'
    && Object.hasOwn(schema.properties, field),
  );
}

function resourceSecretIsString(resourceType) {
  const schema = resourceType?.definition && typeof resourceType.definition === 'object'
    ? resourceType.definition.secret
    : null;
  if (schema && typeof schema === 'object' && typeof schema.type === 'string') {
    return schema.type === 'string';
  }
  return resourceType?.slug === 'password-string' || resourceType?.slug === 'v5-password-string';
}

function resourceDescriptionIsMetadata(resourceType) {
  const inMetadata = resourceSchemaHasField(resourceType, 'resource', 'description');
  const inSecret = resourceSchemaHasField(resourceType, 'secret', 'description');
  if (inMetadata || inSecret) return inMetadata && !inSecret;
  return resourceSecretIsString(resourceType);
}

function selectResourceType(types, format) {
  const slugs = format === 'v5'
    ? ['v5-default', 'v5-password-string']
    : ['password-and-description', 'password-string'];
  return slugs.map((slug) => types.find((entry) => entry.slug === slug)).find(Boolean) ?? null;
}

function normalizeResourceFormat(value) {
  const format = String(value ?? 'auto').trim().toLowerCase();
  assert(['auto', 'v4', 'v5'].includes(format), 'INVALID_RESOURCE_FORMAT', 'Il formato risorsa deve essere Automatico, v4 oppure v5.');
  return format;
}

function normalizeDestinationMode(value) {
  const mode = String(value ?? 'client_folders').trim().toLowerCase();
  assert(['client_folders', 'client_mapping', 'direct_folder', 'root'].includes(mode), 'INVALID_DESTINATION_MODE', 'La destinazione deve essere Cartelle per cliente, Mappatura per cliente, Cartella Passbolt selezionata oppure Radice Passbolt.');
  return mode;
}

function normalizeDestinationFolderId(value) {
  if (value === null || value === undefined || String(value).trim() === '') return null;
  const folderId = String(value).trim();
  assert(folderId.length <= 200 && !/[\u0000-\u001f\u007f]/.test(folderId), 'INVALID_DESTINATION_FOLDER', 'La cartella Passbolt selezionata non contiene un identificatore valido.');
  return folderId;
}

function normalizeReconciliationBatchId(value) {
  if (value === null || value === undefined || String(value).trim() === '') return null;
  const batchId = String(value).trim().toLowerCase();
  assert(UUID_V4_PATTERN.test(batchId), 'INVALID_RECONCILIATION_BATCH', 'L’identificativo del registro di riconciliazione non e valido.');
  return batchId;
}

function requiredClientLabels(candidates) {
  const labels = new Map();
  for (const candidate of candidates) {
    const key = normalizeComparable(candidate.client);
    if (!labels.has(key)) labels.set(key, candidate.client);
  }
  return [...labels.values()].sort((left, right) => left.localeCompare(right, 'it-IT', { sensitivity: 'base' }));
}

function normalizeClientDestinationMapping(value, candidates) {
  const requiredClients = requiredClientLabels(candidates);
  const requiredByKey = new Map(requiredClients.map((client) => [normalizeComparable(client), client]));
  if (value === null || value === undefined) {
    return { entries: [], byClient: new Map(), requiredClients };
  }
  assert(Array.isArray(value), 'INVALID_CLIENT_DESTINATION_MAPPING', 'La mappatura delle destinazioni per cliente non e valida.');
  assert(value.length <= requiredClients.length, 'INVALID_CLIENT_DESTINATION_MAPPING', 'La mappatura contiene piu clienti del lotto selezionato.');
  const entriesByKey = new Map();
  for (const item of value) {
    assert(item && typeof item === 'object', 'INVALID_CLIENT_DESTINATION_MAPPING', 'Una destinazione cliente non e valida.');
    assert(Object.hasOwn(item, 'folder_id'), 'INVALID_CLIENT_DESTINATION_MAPPING', 'Una destinazione cliente non indica esplicitamente la cartella o la radice.');
    const suppliedClient = String(item.client ?? '').trim();
    const key = normalizeComparable(suppliedClient);
    assert(suppliedClient && suppliedClient.length <= 256 && !/[\u0000-\u001f\u007f]/.test(suppliedClient), 'INVALID_CLIENT_DESTINATION_MAPPING', 'Una destinazione non indica un cliente valido.');
    assert(requiredByKey.has(key), 'INVALID_CLIENT_DESTINATION_MAPPING', `Il cliente ${suppliedClient} non appartiene al lotto selezionato.`);
    assert(!entriesByKey.has(key), 'INVALID_CLIENT_DESTINATION_MAPPING', `Il cliente ${requiredByKey.get(key)} compare piu volte nella mappatura.`);
    entriesByKey.set(key, {
      client: requiredByKey.get(key),
      folder_id: normalizeDestinationFolderId(item.folder_id),
    });
  }
  const entries = requiredClients
    .map((client) => entriesByKey.get(normalizeComparable(client)))
    .filter(Boolean);
  return {
    entries,
    byClient: new Map(entries.map((entry) => [normalizeComparable(entry.client), entry])),
    requiredClients,
  };
}

function settingsValue(settings, path, fallback = undefined) {
  let current = settings;
  for (const segment of path) {
    if (!current || typeof current !== 'object' || !Object.hasOwn(current, segment)) return fallback;
    current = current[segment];
  }
  return current;
}

function normalizeComparable(value) {
  return String(value ?? '').trim().toLocaleLowerCase('it-IT');
}

function safeCandidates(value) {
  assert(Array.isArray(value), 'CANDIDATES_REQUIRED', 'Il piano non contiene candidati validi.');
  assert(value.length > 0, 'CANDIDATES_REQUIRED', 'Selezionare almeno un candidato pronto.');
  const seen = new Set();
  return value.map((item) => {
    assert(item && typeof item === 'object', 'INVALID_CANDIDATE', 'Un candidato del piano non e valido.');
    const candidateId = String(item.candidate_id ?? '').trim();
    const title = String(item.title ?? '').trim();
    const username = String(item.username ?? '').trim();
    const uri = String(item.uri ?? '').trim();
    const client = String(item.client ?? '').trim();
    const sourceSha256 = String(item.source_sha256 ?? '').trim().toLowerCase();
    const sourceAtRoot = item.source_at_root;
    assert(candidateId && candidateId.length <= 200, 'INVALID_CANDIDATE', 'Un candidato non contiene un identificatore valido.');
    assert(!seen.has(candidateId), 'DUPLICATE_CANDIDATE_ID', 'Il piano contiene due volte lo stesso candidato.');
    assert(title && title.length <= 255, 'INVALID_TITLE', 'Ogni candidato deve avere un titolo di massimo 255 caratteri.');
    assert(username.length <= 255 && uri.length <= 2048, 'INVALID_CANDIDATE', 'Username o URL superano i limiti consentiti.');
    assert(client && client.length <= 256, 'INVALID_CLIENT', 'Ogni candidato deve indicare un cliente valido.');
    assert(typeof sourceAtRoot === 'boolean', 'INVALID_CLIENT', 'Ogni candidato deve indicare se il documento si trova nella radice sorgente.');
    assert(!sourceSha256 || /^[0-9a-f]{64}$/.test(sourceSha256), 'INVALID_CANDIDATE', 'L’hash sorgente di un candidato non e valido.');
    assert(!/[\u0000-\u001f\u007f]/.test(title + username + uri + client), 'INVALID_CANDIDATE', 'Titolo, username, URL o cliente contengono caratteri di controllo non consentiti.');
    seen.add(candidateId);
    return {
      candidate_id: candidateId,
      client,
      source_at_root: sourceAtRoot,
      title,
      username,
      uri,
      ...(sourceSha256 ? { source_sha256: sourceSha256 } : {}),
    };
  });
}

function rawExistingResources(document) {
  const body = apiBody(document);
  return (Array.isArray(body) ? body : []).filter((entry) => entry && typeof entry === 'object');
}

function isEncryptedMetadataResource(resource) {
  return typeof resource?.metadata === 'string' && resource.metadata.includes('-----BEGIN PGP MESSAGE-----');
}

function isEncryptedMetadataFolder(folder) {
  return typeof folder?.metadata === 'string' && folder.metadata.includes('-----BEGIN PGP MESSAGE-----');
}

async function decryptMessageText(armoredMessage, decryptionKeys, verificationKeys = undefined, signatureRequired = false, errorCode = 'OPENPGP_DECRYPT_FAILED', errorMessage = 'Decifratura OpenPGP non riuscita.') {
  let result;
  try {
    result = await openpgp.decrypt({
      message: await openpgp.readMessage({ armoredMessage }),
      decryptionKeys,
      ...(verificationKeys ? { verificationKeys } : {}),
      format: 'utf8',
    });
    if (signatureRequired) {
      assert(result.signatures.length > 0, 'OPENPGP_SIGNATURE_MISSING', 'Il messaggio OpenPGP non contiene la firma richiesta.');
      await Promise.all(result.signatures.map((signature) => signature.verified));
    }
  } catch (error) {
    if (error instanceof SafeError) throw error;
    throw new SafeError(errorCode, errorMessage);
  }
  return String(result.data);
}

function metadataKeyEntries(document) {
  const body = apiBody(document);
  return (Array.isArray(body) ? body : []).filter((entry) => entry && typeof entry === 'object' && typeof entry.id === 'string');
}

async function loadSharedMetadataKey(entry, user, keyMaterial, baseUrl) {
  assert(entry && typeof entry === 'object', 'METADATA_KEY_NOT_FOUND', 'La chiave metadati condivisa richiesta non e disponibile.');
  const advertisedFingerprint = normalizeFingerprint(entry.fingerprint, 'Fingerprint della chiave metadati');
  let advertisedPublicKey;
  try {
    advertisedPublicKey = await openpgp.readKey({ armoredKey: String(entry.armored_key ?? '') });
  } catch {
    throw new SafeError('METADATA_PUBLIC_KEY_INVALID', 'La chiave pubblica dei metadati non e valida.');
  }
  assert(
    normalizeFingerprint(advertisedPublicKey.getFingerprint(), 'Fingerprint OpenPGP della chiave metadati') === advertisedFingerprint,
    'METADATA_PUBLIC_KEY_MISMATCH',
    'La chiave pubblica dei metadati non corrisponde alla fingerprint dichiarata.',
  );

  const envelopes = Array.isArray(entry.metadata_private_keys) ? entry.metadata_private_keys : [];
  const ownedEnvelopes = envelopes.filter((item) => item && typeof item === 'object' && String(item.user_id ?? '') === String(user.id));
  assert(ownedEnvelopes.length === 1, 'METADATA_PRIVATE_KEY_UNAVAILABLE', 'Passbolt non ha restituito una copia univoca della chiave metadati per questo utente.');
  const envelope = ownedEnvelopes[0];
  assert(!envelope.metadata_key_id || String(envelope.metadata_key_id) === String(entry.id), 'METADATA_PRIVATE_KEY_MISMATCH', 'La copia privata non appartiene alla chiave metadati richiesta.');
  const clearEnvelope = await decryptMessageText(
    String(envelope.data ?? ''),
    keyMaterial.privateKey,
    keyMaterial.publicKey,
    true,
    'METADATA_PRIVATE_KEY_DECRYPT_FAILED',
    'La copia privata della chiave metadati non puo essere decifrata o la sua firma non e valida.',
  );
  let privateKeyData;
  try {
    privateKeyData = JSON.parse(clearEnvelope);
  } catch {
    throw new SafeError('METADATA_PRIVATE_KEY_DATA_INVALID', 'La copia privata della chiave metadati non contiene JSON valido.');
  }
  assert(privateKeyData && typeof privateKeyData === 'object', 'METADATA_PRIVATE_KEY_DATA_INVALID', 'La copia privata della chiave metadati non e valida.');
  assert(privateKeyData.object_type === METADATA_PRIVATE_KEY_OBJECT_TYPE, 'METADATA_PRIVATE_KEY_OBJECT_TYPE', 'Il tipo della chiave metadati privata non e valido.');
  let metadataDomain;
  try {
    const parsedDomain = new URL(String(privateKeyData.domain ?? ''));
    assert(parsedDomain.pathname === '/' && !parsedDomain.search && !parsedDomain.hash && !parsedDomain.username && !parsedDomain.password, 'METADATA_PRIVATE_KEY_DOMAIN', 'Il dominio nella chiave metadati non e valido.');
    metadataDomain = parsedDomain.origin;
  } catch (error) {
    if (error instanceof SafeError) throw error;
    throw new SafeError('METADATA_PRIVATE_KEY_DOMAIN', 'Il dominio nella chiave metadati non e valido.');
  }
  assert(metadataDomain === baseUrl, 'METADATA_PRIVATE_KEY_DOMAIN', 'La chiave metadati appartiene a un dominio Passbolt diverso.');
  assert(normalizeFingerprint(privateKeyData.fingerprint, 'Fingerprint nella chiave metadati') === advertisedFingerprint, 'METADATA_PRIVATE_KEY_FINGERPRINT', 'La fingerprint nella chiave metadati privata non coincide con quella pubblica.');

  let privateKey;
  try {
    privateKey = await openpgp.readPrivateKey({ armoredKey: String(privateKeyData.armored_key ?? '') });
    if (!privateKey.isDecrypted()) {
      privateKey = await openpgp.decryptKey({ privateKey, passphrase: String(privateKeyData.passphrase ?? '') });
    }
  } catch {
    throw new SafeError('METADATA_PRIVATE_KEY_INVALID', 'La chiave metadati privata ricevuta da Passbolt non e utilizzabile.');
  }
  assert(privateKey.isDecrypted(), 'METADATA_PRIVATE_KEY_LOCKED', 'La chiave metadati privata e ancora protetta.');
  assert(
    normalizeFingerprint(privateKey.toPublic().getFingerprint(), 'Fingerprint della chiave metadati privata') === advertisedFingerprint,
    'METADATA_PRIVATE_KEY_FINGERPRINT',
    'La chiave metadati privata non coincide con la chiave pubblica dichiarata.',
  );
  return {
    id: String(entry.id),
    type: 'shared_key',
    fingerprint: advertisedFingerprint,
    publicKey: advertisedPublicKey,
    privateKey,
  };
}

function newestMetadataKey(entries) {
  const active = entries.filter((entry) => !entry.deleted && !entry.expired);
  return active.sort((left, right) => {
    const leftTime = Date.parse(String(left.created ?? left.modified ?? '')) || 0;
    const rightTime = Date.parse(String(right.created ?? right.modified ?? '')) || 0;
    return leftTime - rightTime;
  }).at(-1) ?? null;
}

async function decryptExistingResources(entries, user, keyMaterial, baseUrl, sharedKeyEntries, sharedKeyCache) {
  const resources = [];
  const getSharedKey = async (keyId) => {
    if (sharedKeyCache.has(keyId)) return sharedKeyCache.get(keyId);
    const entry = sharedKeyEntries.get(keyId);
    assert(entry, 'METADATA_KEY_NOT_FOUND', `La chiave metadati ${keyId} richiesta da una risorsa non e disponibile.`);
    const loaded = await loadSharedMetadataKey(entry, user, keyMaterial, baseUrl);
    sharedKeyCache.set(keyId, loaded);
    return loaded;
  };

  for (const entry of entries) {
    const id = typeof entry.id === 'string' ? entry.id : '';
    assert(id, 'RESOURCE_METADATA_INVALID', 'Una risorsa esistente non contiene un identificatore valido.');
    if (!isEncryptedMetadataResource(entry)) {
      assert(typeof entry.name === 'string' && entry.name.length > 0, 'RESOURCE_METADATA_UNAVAILABLE', 'I metadati di una risorsa esistente non sono disponibili per il confronto duplicati.');
      resources.push({
        id,
        name: entry.name,
        username: typeof entry.username === 'string' ? entry.username : '',
        uri: typeof entry.uri === 'string' ? entry.uri : '',
        folder_parent_id: typeof entry.folder_parent_id === 'string' ? entry.folder_parent_id : null,
        permission: entry.permission && typeof entry.permission === 'object' ? entry.permission : null,
        permissions: normalizeFolderPermissions(entry.permissions),
        raw_permission_count: Array.isArray(entry.permissions) ? entry.permissions.filter((permission) => permission && typeof permission === 'object').length : 0,
      });
      continue;
    }

    assert(keyMaterial, 'METADATA_DECRYPTION_KEY_REQUIRED', 'La chiave utente e necessaria per confrontare i metadati v5 esistenti.');
    const metadataKeyType = String(entry.metadata_key_type ?? '');
    const metadataKeyId = String(entry.metadata_key_id ?? '');
    assert(['user_key', 'shared_key'].includes(metadataKeyType) && metadataKeyId, 'RESOURCE_METADATA_KEY_INVALID', 'Una risorsa v5 non indica una chiave metadati valida.');
    let decryptionKey;
    if (metadataKeyType === 'user_key') {
      const userGpgKeyId = String(user.gpgkey?.id ?? '');
      assert(userGpgKeyId && metadataKeyId === userGpgKeyId, 'RESOURCE_PERSONAL_METADATA_KEY_UNAVAILABLE', 'Una risorsa usa una chiave metadati personale diversa da quella dell’utente autenticato.');
      decryptionKey = keyMaterial.privateKey;
    } else {
      decryptionKey = (await getSharedKey(metadataKeyId)).privateKey;
    }
    const clearMetadata = await decryptMessageText(
      entry.metadata,
      decryptionKey,
      undefined,
      false,
      'RESOURCE_METADATA_DECRYPT_FAILED',
      `I metadati cifrati della risorsa ${id} non possono essere decifrati.`,
    );
    let metadata;
    try {
      metadata = JSON.parse(clearMetadata);
    } catch {
      throw new SafeError('RESOURCE_METADATA_INVALID', `I metadati cifrati della risorsa ${id} non contengono JSON valido.`);
    }
    assert(metadata && typeof metadata === 'object' && metadata.object_type === RESOURCE_METADATA_OBJECT_TYPE, 'RESOURCE_METADATA_INVALID', `Il tipo dei metadati della risorsa ${id} non e valido.`);
    assert(typeof metadata.resource_type_id === 'string' && metadata.resource_type_id === String(entry.resource_type_id ?? ''), 'RESOURCE_METADATA_TYPE_MISMATCH', `I metadati della risorsa ${id} non corrispondono al tipo dichiarato.`);
    assert(typeof metadata.name === 'string' && metadata.name.length > 0, 'RESOURCE_METADATA_INVALID', `I metadati della risorsa ${id} non contengono un nome valido.`);
    const uris = Array.isArray(metadata.uris) ? metadata.uris : [];
    resources.push({
      id,
      name: metadata.name,
      username: typeof metadata.username === 'string' ? metadata.username : '',
      uri: typeof uris[0] === 'string' ? uris[0] : '',
      folder_parent_id: typeof entry.folder_parent_id === 'string' ? entry.folder_parent_id : null,
      permission: entry.permission && typeof entry.permission === 'object' ? entry.permission : null,
      permissions: normalizeFolderPermissions(entry.permissions),
      raw_permission_count: Array.isArray(entry.permissions) ? entry.permissions.filter((permission) => permission && typeof permission === 'object').length : 0,
    });
  }
  return resources;
}

function rawExistingFolders(document) {
  const body = apiBody(document);
  return (Array.isArray(body) ? body : []).filter((entry) => entry && typeof entry === 'object');
}

function normalizePermissionType(value) {
  const type = Number(value);
  return [1, 7, 15].includes(type) ? type : null;
}

function normalizeFolderPermissions(value) {
  if (!Array.isArray(value)) return [];
  const permissions = [];
  const seen = new Set();
  for (const item of value) {
    if (!item || typeof item !== 'object') continue;
    const aro = String(item.aro ?? '');
    const aroForeignKey = String(item.aro_foreign_key ?? '');
    const type = normalizePermissionType(item.type);
    if (!['User', 'Group'].includes(aro) || !aroForeignKey || type === null) continue;
    const key = `${aro}:${aroForeignKey}`;
    if (seen.has(key)) continue;
    seen.add(key);
    permissions.push({ aro, aro_foreign_key: aroForeignKey, type });
  }
  return permissions.sort((left, right) => (
    left.aro.localeCompare(right.aro)
    || left.aro_foreign_key.localeCompare(right.aro_foreign_key)
    || left.type - right.type
  ));
}

function findPersonalFolderOwnerPermission(value, currentUserId, folderId) {
  if (!Array.isArray(value)) return null;
  for (const item of value) {
    if (!item || typeof item !== 'object') continue;
    const id = String(item.id ?? '');
    const aco = String(item.aco ?? 'Folder');
    const acoForeignKey = String(item.aco_foreign_key ?? folderId);
    const aro = String(item.aro ?? '');
    const aroForeignKey = String(item.aro_foreign_key ?? '');
    const type = normalizePermissionType(item.type);
    if (id && aco === 'Folder' && acoForeignKey === folderId && aro === 'User' && aroForeignKey === currentUserId && type === 15) {
      return {
        id,
        aco: 'Folder',
        aco_foreign_key: folderId,
        aro: 'User',
        aro_foreign_key: currentUserId,
        type,
      };
    }
  }
  return null;
}

async function buildShareDirectory(document, user, keyMaterial) {
  const body = apiBody(document);
  assert(Array.isArray(body), 'SHARE_DIRECTORY_INVALID', 'Passbolt non ha restituito un elenco valido di utenti e gruppi condivisibili.');
  const users = new Map();
  const groups = new Map();

  for (const entry of body) {
    if (!entry || typeof entry !== 'object') continue;
    const id = String(entry.id ?? '');
    if (!id) continue;
    const isUser = typeof entry.username === 'string' || Boolean(entry.gpgkey) || typeof entry.role_id === 'string';
    if (!isUser) {
      groups.set(id, {
        id,
        name: String(entry.name ?? '').slice(0, 300),
        user_count: Number.isInteger(Number(entry.user_count)) ? Number(entry.user_count) : null,
        deleted: Boolean(entry.deleted),
      });
      continue;
    }

    const active = entry.active === true && !entry.deleted && !entry.disabled;
    const memberships = (Array.isArray(entry.groups_users) ? entry.groups_users : [])
      .filter((membership) => membership && typeof membership === 'object' && String(membership.user_id ?? '') === id)
      .map((membership) => String(membership.group_id ?? ''))
      .filter(Boolean);
    const gpgkey = entry.gpgkey && typeof entry.gpgkey === 'object' ? entry.gpgkey : null;
    let publicKey = null;
    let fingerprint = null;
    let keyError = null;
    if (!active) {
      keyError = `L'utente ${String(entry.username ?? id)} non e attivo.`;
    } else if (String(user.id ?? '') === id && keyMaterial?.publicKey) {
      publicKey = keyMaterial.publicKey;
      fingerprint = keyMaterial.fingerprint;
      if (gpgkey?.fingerprint) {
        try {
          assert(
            normalizeFingerprint(gpgkey.fingerprint, `Fingerprint di ${String(entry.username ?? id)}`) === fingerprint,
            'SHARE_PUBLIC_KEY_MISMATCH',
            `La chiave pubblica di ${String(entry.username ?? id)} non coincide con la chiave autenticata.`,
          );
        } catch (error) {
          keyError = error instanceof SafeError ? error.message : `La chiave pubblica di ${String(entry.username ?? id)} non e verificabile.`;
          publicKey = null;
          fingerprint = null;
        }
      }
    } else if (!gpgkey || gpgkey.deleted || !String(gpgkey.armored_key ?? '').includes('-----BEGIN PGP PUBLIC KEY BLOCK-----')) {
      keyError = `Passbolt non ha restituito una chiave pubblica attiva per ${String(entry.username ?? id)}.`;
    } else if (gpgkey.expires && Date.parse(String(gpgkey.expires)) <= Date.now()) {
      keyError = `La chiave pubblica di ${String(entry.username ?? id)} risulta scaduta.`;
    } else {
      try {
        publicKey = await openpgp.readKey({ armoredKey: String(gpgkey.armored_key) });
        fingerprint = normalizeFingerprint(publicKey.getFingerprint(), `Fingerprint OpenPGP di ${String(entry.username ?? id)}`);
        assert(
          fingerprint === normalizeFingerprint(gpgkey.fingerprint, `Fingerprint dichiarata di ${String(entry.username ?? id)}`),
          'SHARE_PUBLIC_KEY_MISMATCH',
          `La chiave pubblica di ${String(entry.username ?? id)} non corrisponde alla fingerprint dichiarata.`,
        );
      } catch (error) {
        keyError = error instanceof SafeError ? error.message : `La chiave pubblica di ${String(entry.username ?? id)} non e valida.`;
        publicKey = null;
        fingerprint = null;
      }
    }
    users.set(id, {
      id,
      username: String(entry.username ?? '').slice(0, 300),
      first_name: String(entry.profile?.first_name ?? '').slice(0, 150),
      last_name: String(entry.profile?.last_name ?? '').slice(0, 150),
      active,
      memberships: [...new Set(memberships)].sort(),
      publicKey,
      fingerprint,
      key_error: keyError,
    });
  }

  const currentUserId = String(user.id ?? '');
  if (currentUserId && !users.has(currentUserId) && keyMaterial?.publicKey) {
    users.set(currentUserId, {
      id: currentUserId,
      username: String(user.username ?? '').slice(0, 300),
      first_name: String(user.profile?.first_name ?? '').slice(0, 150),
      last_name: String(user.profile?.last_name ?? '').slice(0, 150),
      active: true,
      memberships: [],
      publicKey: keyMaterial.publicKey,
      fingerprint: keyMaterial.fingerprint,
      key_error: null,
    });
  }
  return { users, groups };
}

function buildFolderSharePlan(permissions, shareDirectory, currentUserId) {
  if (!permissions.length) {
    return { ready: false, failure: 'Passbolt non ha restituito la maschera completa dei permessi della cartella condivisa.', recipients: [] };
  }
  if (!permissions.some((permission) => permission.aro === 'Group' || permission.aro_foreign_key !== currentUserId)) {
    return { ready: false, failure: 'La maschera dichiarata condivisa non contiene alcun altro utente o gruppo.', recipients: [] };
  }
  if (!shareDirectory) {
    return { ready: false, failure: 'L’elenco degli utenti e dei gruppi Passbolt non e leggibile.', recipients: [] };
  }

  const recipientSources = new Map();
  const addRecipient = (userId, source) => {
    if (!recipientSources.has(userId)) recipientSources.set(userId, []);
    recipientSources.get(userId).push(source);
  };
  for (const permission of permissions) {
    if (permission.aro === 'User') {
      addRecipient(permission.aro_foreign_key, { aro: 'User', aro_foreign_key: permission.aro_foreign_key, type: permission.type });
      continue;
    }
    const group = shareDirectory.groups.get(permission.aro_foreign_key);
    if (!group || group.deleted) {
      return { ready: false, failure: `Il gruppo ${permission.aro_foreign_key} presente nei permessi non e piu disponibile.`, recipients: [] };
    }
    const groupUsers = [...shareDirectory.users.values()].filter((entry) => entry.memberships.includes(group.id) && entry.active);
    if (group.user_count !== null && groupUsers.length !== group.user_count) {
      return { ready: false, failure: `La composizione del gruppo ${group.name || group.id} non e stata restituita integralmente da Passbolt.`, recipients: [] };
    }
    for (const groupUser of groupUsers) {
      addRecipient(groupUser.id, { aro: 'Group', aro_foreign_key: group.id, type: permission.type });
    }
  }

  const recipients = [];
  for (const [userId, sources] of recipientSources) {
    const directoryUser = shareDirectory.users.get(userId);
    if (!directoryUser || !directoryUser.active) {
      return { ready: false, failure: `Un destinatario dei permessi (${userId}) non e un utente Passbolt attivo.`, recipients: [] };
    }
    if (!directoryUser.publicKey || directoryUser.key_error || !directoryUser.fingerprint) {
      return { ready: false, failure: directoryUser.key_error || `La chiave pubblica del destinatario ${directoryUser.username || userId} non e disponibile.`, recipients: [] };
    }
    recipients.push({
      user_id: userId,
      username: directoryUser.username,
      fingerprint: directoryUser.fingerprint,
      permission_type: Math.max(...sources.map((source) => source.type)),
      sources: sources.sort((left, right) => left.aro.localeCompare(right.aro) || left.aro_foreign_key.localeCompare(right.aro_foreign_key)),
    });
  }
  recipients.sort((left, right) => left.username.localeCompare(right.username, 'it-IT', { sensitivity: 'base' }) || left.user_id.localeCompare(right.user_id));
  return { ready: recipients.length > 0, failure: recipients.length ? null : 'La cartella condivisa non contiene destinatari attivi verificabili.', recipients };
}

function buildPermissionConfiguration(permissionModeValue, permissionTemplateValue, shareDirectory, currentUserId) {
  const mode = normalizePermissionMode(permissionModeValue);
  if (mode === 'inherited') {
    assert(permissionTemplateValue === undefined || permissionTemplateValue === null || (Array.isArray(permissionTemplateValue) && permissionTemplateValue.length === 0), 'INVALID_PERMISSION_TEMPLATE', 'La modalita Ereditata non accetta una maschera di permessi personalizzata.');
    return {
      mode,
      template: [],
      permissions: null,
      recipients: null,
      configuration_hash: digestPlan({ mode, permissions: [] }),
    };
  }

  assert(shareDirectory, 'PERMISSION_DIRECTORY_UNAVAILABLE', 'L’elenco autenticato degli utenti e dei gruppi Passbolt non e disponibile. Riaprire l’editor dei permessi e riprovare.');
  const template = normalizeCustomPermissionEntries(permissionTemplateValue, currentUserId);
  assert(template.length > 0, 'EMPTY_PERMISSION_TEMPLATE', 'Selezionare almeno un utente o gruppo per usare i permessi personalizzati.');
  for (const permission of template) {
    if (permission.aro === 'User') {
      const directoryUser = shareDirectory.users.get(permission.aro_foreign_key);
      assert(directoryUser?.active, 'PERMISSION_USER_UNAVAILABLE', `L’utente ${permission.aro_foreign_key} non e disponibile o non e attivo.`);
    } else {
      const group = shareDirectory.groups.get(permission.aro_foreign_key);
      assert(group && !group.deleted, 'PERMISSION_GROUP_UNAVAILABLE', `Il gruppo ${permission.aro_foreign_key} non e disponibile.`);
    }
  }
  const permissions = normalizeFolderPermissions([
    ...template,
    { aro: 'User', aro_foreign_key: currentUserId, type: 15 },
  ]);
  const sharePlan = buildFolderSharePlan(permissions, shareDirectory, currentUserId);
  assert(sharePlan.ready, 'PERMISSION_TEMPLATE_UNAVAILABLE', sharePlan.failure || 'I permessi personalizzati non sono applicabili in sicurezza.');
  assert(sharePlan.recipients.some((recipient) => recipient.user_id !== currentUserId), 'PERMISSION_TEMPLATE_HAS_NO_RECIPIENTS', 'I permessi personalizzati devono includere almeno un altro utente attivo oltre al proprietario autenticato.');
  return {
    mode,
    template,
    permissions,
    recipients: sharePlan.recipients,
    configuration_hash: digestPlan({ mode, permissions: template }),
  };
}

function permissionCatalog(shareDirectory, currentUserId) {
  const entries = [];
  for (const user of shareDirectory.users.values()) {
    if (user.id === currentUserId) continue;
    const displayName = `${user.first_name} ${user.last_name}`.trim() || user.username || user.id;
    entries.push({
      aro: 'User',
      aro_foreign_key: user.id,
      subject_type: 'Utente',
      display_name: displayName,
      detail: user.username || user.id,
      available: Boolean(user.active && user.publicKey && user.fingerprint && !user.key_error),
      unavailable_reason: user.key_error,
      recipient_count: user.active ? 1 : 0,
    });
  }
  for (const group of shareDirectory.groups.values()) {
    const permissions = normalizeFolderPermissions([
      { aro: 'User', aro_foreign_key: currentUserId, type: 15 },
      { aro: 'Group', aro_foreign_key: group.id, type: 1 },
    ]);
    const plan = buildFolderSharePlan(permissions, shareDirectory, currentUserId);
    const externalRecipientCount = plan.recipients.filter((recipient) => recipient.user_id !== currentUserId).length;
    entries.push({
      aro: 'Group',
      aro_foreign_key: group.id,
      subject_type: 'Gruppo',
      display_name: group.name || group.id,
      detail: `${externalRecipientCount} destinatari verificati`,
      available: Boolean(!group.deleted && plan.ready && externalRecipientCount > 0),
      unavailable_reason: group.deleted ? 'Gruppo eliminato.' : (plan.failure || (externalRecipientCount > 0 ? null : 'Il gruppo non contiene altri utenti attivi.')),
      recipient_count: externalRecipientCount,
    });
  }
  return entries.sort((left, right) => (
    left.subject_type.localeCompare(right.subject_type, 'it-IT', { sensitivity: 'base' })
    || left.display_name.localeCompare(right.display_name, 'it-IT', { sensitivity: 'base' })
    || left.aro_foreign_key.localeCompare(right.aro_foreign_key)
  ));
}

async function decryptExistingFolders(entries, user, keyMaterial, baseUrl, sharedKeyEntries, sharedKeyCache, shareDirectory = null) {
  const folders = [];
  const getSharedKey = async (keyId) => {
    if (sharedKeyCache.has(keyId)) return sharedKeyCache.get(keyId);
    const entry = sharedKeyEntries.get(keyId);
    assert(entry, 'METADATA_KEY_NOT_FOUND', `La chiave metadati ${keyId} richiesta da una cartella non e disponibile.`);
    const loaded = await loadSharedMetadataKey(entry, user, keyMaterial, baseUrl);
    sharedKeyCache.set(keyId, loaded);
    return loaded;
  };

  for (const entry of entries) {
    const id = typeof entry.id === 'string' ? entry.id : '';
    assert(id, 'FOLDER_METADATA_INVALID', 'Una cartella esistente non contiene un identificatore valido.');
    const folderParentId = typeof entry.folder_parent_id === 'string' ? entry.folder_parent_id : null;
    const permissionType = normalizePermissionType(entry.permission?.type);
    const personal = typeof entry.personal === 'boolean' ? entry.personal : null;
    const permissions = normalizeFolderPermissions(entry.permissions);
    const rawPermissionCount = Array.isArray(entry.permissions)
      ? entry.permissions.filter((permission) => permission && typeof permission === 'object').length
      : 0;
    const personalOwnerPermission = findPersonalFolderOwnerPermission(entry.permissions, String(user.id ?? ''), id);
    const inferredShared = personal === false || permissions.length > 1 || permissions.some((permission) => (
      permission.aro === 'Group' || permission.aro_foreign_key !== String(user.id ?? '')
    ));
    const sharePlan = inferredShared
      ? buildFolderSharePlan(permissions, shareDirectory, String(user.id ?? ''))
      : { ready: true, failure: null, recipients: [] };
    const canCreateByPermission = inferredShared
      ? permissionType === 7 || permissionType === 15
      : permissionType === null || permissionType === 7 || permissionType === 15;
    const folderSummary = {
      id,
      folder_parent_id: folderParentId,
      permission_type: permissionType,
      personal,
      shared: inferredShared,
      can_create: canCreateByPermission && sharePlan.ready,
      share_ready: sharePlan.ready,
      share_failure: sharePlan.failure,
      share_permissions: permissions,
      share_recipients: sharePlan.recipients,
      raw_permission_count: rawPermissionCount,
      personal_owner_permission: personalOwnerPermission,
    };
    if (!isEncryptedMetadataFolder(entry)) {
      assert(typeof entry.name === 'string' && entry.name.length > 0, 'FOLDER_METADATA_UNAVAILABLE', 'I metadati di una cartella esistente non sono disponibili.');
      folders.push({ ...folderSummary, name: entry.name });
      continue;
    }

    assert(keyMaterial, 'METADATA_DECRYPTION_KEY_REQUIRED', 'La chiave utente e necessaria per leggere i metadati v5 delle cartelle.');
    const metadataKeyType = String(entry.metadata_key_type ?? '');
    const metadataKeyId = String(entry.metadata_key_id ?? '');
    assert(['user_key', 'shared_key'].includes(metadataKeyType) && metadataKeyId, 'FOLDER_METADATA_KEY_INVALID', 'Una cartella v5 non indica una chiave metadati valida.');
    let decryptionKey;
    if (metadataKeyType === 'user_key') {
      const userGpgKeyId = String(user.gpgkey?.id ?? '');
      assert(userGpgKeyId && metadataKeyId === userGpgKeyId, 'FOLDER_PERSONAL_METADATA_KEY_UNAVAILABLE', 'Una cartella usa una chiave metadati personale diversa da quella dell’utente autenticato.');
      decryptionKey = keyMaterial.privateKey;
    } else {
      decryptionKey = (await getSharedKey(metadataKeyId)).privateKey;
    }
    const clearMetadata = await decryptMessageText(
      entry.metadata,
      decryptionKey,
      undefined,
      false,
      'FOLDER_METADATA_DECRYPT_FAILED',
      `I metadati cifrati della cartella ${id} non possono essere decifrati.`,
    );
    let metadata;
    try {
      metadata = JSON.parse(clearMetadata);
    } catch {
      throw new SafeError('FOLDER_METADATA_INVALID', `I metadati cifrati della cartella ${id} non contengono JSON valido.`);
    }
    assert(metadata && typeof metadata === 'object' && metadata.object_type === FOLDER_METADATA_OBJECT_TYPE, 'FOLDER_METADATA_INVALID', `Il tipo dei metadati della cartella ${id} non e valido.`);
    assert(typeof metadata.name === 'string' && metadata.name.length > 0, 'FOLDER_METADATA_INVALID', `I metadati della cartella ${id} non contengono un nome valido.`);
    folders.push({ ...folderSummary, name: metadata.name });
  }
  return folders;
}

function buildFolderCatalog(existingFolders) {
  const byId = new Map(existingFolders.map((folder) => [folder.id, folder]));
  const pathCache = new Map();
  const resolving = new Set();
  const resolvePath = (folder) => {
    if (pathCache.has(folder.id)) return pathCache.get(folder.id);
    assert(!resolving.has(folder.id), 'FOLDER_TREE_INVALID', 'La struttura delle cartelle Passbolt contiene un ciclo non valido.');
    resolving.add(folder.id);
    try {
      const parent = folder.folder_parent_id ? byId.get(folder.folder_parent_id) : null;
      const path = parent
        ? `${resolvePath(parent)} / ${folder.name}`
        : folder.name;
      pathCache.set(folder.id, path);
      return path;
    } finally {
      resolving.delete(folder.id);
    }
  };
  return existingFolders
    .map((folder) => ({ ...folder, path: resolvePath(folder) }))
    .sort((left, right) => left.path.localeCompare(right.path, 'it-IT', { sensitivity: 'base' }));
}

function folderSharingFields(folder) {
  if (!folder?.shared) {
    return {
      shared: false,
      share_permissions: [],
      share_recipients: [],
      share_recipient_count: 0,
      share_permission_count: 0,
    };
  }
  return {
    shared: true,
    share_permissions: folder.share_permissions,
    share_recipients: folder.share_recipients,
    share_recipient_count: folder.share_recipients.length,
    share_permission_count: folder.share_permissions.length,
  };
}

function planDestinations(candidates, existingFolders, existingResources, destinationMode, folderFormat, destinationFolderId = null, clientDestinationMapping = null) {
  if (destinationMode === 'root') {
    return {
      folders: [],
      destinations: new Map(candidates.map((candidate) => [candidate.candidate_id, {
        destination_key: 'root',
        folder_action: 'root',
        folder_id: null,
        folder_name: null,
        folder_path: 'Radice Passbolt',
      }])),
      failure: null,
    };
  }

  const foldersById = new Map();
  const foldersByParentAndName = new Map();
  const folderParentIds = new Set();
  for (const folder of existingFolders) {
    if (!foldersById.has(folder.id)) foldersById.set(folder.id, folder);
    const childKey = JSON.stringify([
      folder.folder_parent_id ?? null,
      normalizeComparable(folder.name),
    ]);
    const siblings = foldersByParentAndName.get(childKey) ?? [];
    siblings.push(folder);
    foldersByParentAndName.set(childKey, siblings);
    if (folder.folder_parent_id !== null && folder.folder_parent_id !== undefined) {
      folderParentIds.add(folder.folder_parent_id);
    }
  }
  const resourceFolderIds = new Set(
    existingResources
      .map((resource) => resource.folder_parent_id)
      .filter((folderId) => folderId !== null && folderId !== undefined),
  );

  if (destinationMode === 'client_mapping') {
    const mappingByClient = clientDestinationMapping?.byClient ?? new Map();
    const folderPlans = new Map();
    const destinations = new Map();
    let failure = null;
    for (const candidate of candidates) {
      const clientKey = normalizeComparable(candidate.client);
      const mapping = mappingByClient.get(clientKey);
      if (!mapping) {
        if (!failure) failure = `Configurare una destinazione Passbolt per il cliente ${candidate.client}.`;
        destinations.set(candidate.candidate_id, {
          destination_key: `client-map:missing:${clientKey}`,
          folder_action: 'missing',
          folder_id: null,
          folder_name: null,
          folder_path: null,
        });
        continue;
      }
      if (mapping.folder_id === null) {
        destinations.set(candidate.candidate_id, {
          destination_key: 'root',
          folder_action: 'root',
          folder_id: null,
          folder_name: null,
          folder_path: 'Radice Passbolt',
        });
        continue;
      }
      const folder = foldersById.get(mapping.folder_id) ?? null;
      if (!folder) {
        if (!failure) failure = `La cartella configurata per il cliente ${candidate.client} non e piu disponibile.`;
        destinations.set(candidate.candidate_id, {
          destination_key: `client-map:missing:${clientKey}`,
          folder_action: 'missing',
          folder_id: null,
          folder_name: null,
          folder_path: null,
        });
        continue;
      }
      if (!folder.can_create && !failure) {
        failure = folder.shared && folder.share_failure
          ? `La cartella condivisa ${folder.path} non e utilizzabile: ${folder.share_failure}`
          : `Non disponi del permesso necessario per creare risorse nella cartella ${folder.path}, configurata per ${candidate.client}.`;
      }
      const destinationKey = `folder:${folder.id}`;
      if (!folderPlans.has(destinationKey)) {
        folderPlans.set(destinationKey, {
          destination_key: destinationKey,
          name: folder.name,
          path: folder.path,
          action: 'reuse',
          folder_id: folder.id,
          folder_parent_id: folder.folder_parent_id,
          format: null,
          ...folderSharingFields(folder),
        });
      }
      destinations.set(candidate.candidate_id, {
        destination_key: destinationKey,
        folder_action: 'reuse',
        folder_id: folder.id,
        folder_name: folder.name,
        folder_path: folder.path,
        ...folderSharingFields(folder),
      });
    }
    return { folders: [...folderPlans.values()], destinations, failure };
  }

  const selectedFolder = destinationFolderId
    ? foldersById.get(destinationFolderId) ?? null
    : null;
  if (destinationMode === 'direct_folder') {
    let failure = null;
    if (!destinationFolderId) {
      failure = 'Selezionare la cartella Passbolt nella quale importare direttamente le risorse.';
    } else if (!selectedFolder) {
      failure = 'La cartella Passbolt selezionata non e piu disponibile.';
    } else if (!selectedFolder.can_create) {
      failure = selectedFolder.shared && selectedFolder.share_failure
        ? `La cartella condivisa selezionata non e utilizzabile: ${selectedFolder.share_failure}`
        : 'Non disponi del permesso necessario per creare risorse nella cartella Passbolt selezionata.';
    }
    const destinationKey = selectedFolder ? `folder:${selectedFolder.id}` : 'folder:missing';
    return {
      folders: selectedFolder ? [{
        destination_key: destinationKey,
        name: selectedFolder.name,
        path: selectedFolder.path,
        action: 'reuse',
        folder_id: selectedFolder.id,
        folder_parent_id: selectedFolder.folder_parent_id,
        format: null,
        ...folderSharingFields(selectedFolder),
      }] : [],
      destinations: new Map(candidates.map((candidate) => [candidate.candidate_id, {
        destination_key: destinationKey,
        folder_action: selectedFolder ? 'reuse' : 'missing',
        folder_id: selectedFolder?.id ?? null,
        folder_name: selectedFolder?.name ?? null,
        folder_path: selectedFolder?.path ?? null,
        ...folderSharingFields(selectedFolder),
      }])),
      failure,
    };
  }

  const folderPlans = new Map();
  let failure = null;
  if (destinationFolderId && !selectedFolder) {
    failure = 'La cartella Passbolt scelta come contenitore non e piu disponibile.';
  } else if (selectedFolder && !selectedFolder.can_create) {
    failure = selectedFolder.shared && selectedFolder.share_failure
      ? `Il contenitore condiviso selezionato non e utilizzabile: ${selectedFolder.share_failure}`
      : 'Non disponi del permesso necessario per creare contenuti nel contenitore Passbolt selezionato.';
  }
  const parentId = selectedFolder?.id ?? null;
  const parentPath = selectedFolder?.path ?? null;
  for (const candidate of candidates) {
    if (candidate.source_at_root) continue;
    const normalizedClient = normalizeComparable(candidate.client);
    const destinationKey = `client:${parentId ?? 'root'}:${normalizedClient}`;
    if (folderPlans.has(destinationKey)) continue;
    const matches = foldersByParentAndName.get(
      JSON.stringify([parentId, normalizedClient]),
    ) ?? [];
    if (matches.length > 1) {
      const matchingIds = matches.map((folder) => folder.id).join(', ');
      failure = `Esistono ${matches.length} cartelle chiamate ${candidate.client} nello stesso contenitore Passbolt (ID: ${matchingIds}). La destinazione non e univoca: eliminare in Passbolt le copie personali vuote in eccesso, lasciarne una sola e ripetere il dry-run.`;
    }
    const match = matches.length === 1 ? matches[0] : null;
    let reconcilePersonalFolder = false;
    if (match && selectedFolder?.shared && !match.shared) {
      const containsResources = resourceFolderIds.has(match.id);
      const containsFolders = folderParentIds.has(match.id);
      const hasSoleVerifiedOwner = match.personal === true
        && match.permission_type === 15
        && match.raw_permission_count === 1
        && match.share_permissions.length === 1
        && Boolean(match.personal_owner_permission?.id);
      if (!containsResources && !containsFolders && hasSoleVerifiedOwner) {
        reconcilePersonalFolder = true;
      } else {
        failure = `La cartella ${match.path} esiste nel contenitore condiviso ma risulta personale e non puo essere riconciliata automaticamente. Per sicurezza deve essere vuota e avere come unico proprietario l'utente autenticato; verificare la cartella ${match.id} in Passbolt e ripetere il dry-run.`;
      }
    } else if (match && !match.can_create) {
      failure = match.shared && match.share_failure
        ? `La cartella condivisa ${match.path} non e utilizzabile: ${match.share_failure}`
        : `Non disponi del permesso necessario per creare risorse nella cartella ${match.path}.`;
    }
    const folderPath = match?.path ?? (parentPath ? `${parentPath} / ${candidate.client}` : candidate.client);
    const inheritedSharedFolder = (!match || reconcilePersonalFolder) && selectedFolder?.shared ? selectedFolder : null;
    folderPlans.set(destinationKey, {
      destination_key: destinationKey,
      name: candidate.client,
      path: folderPath,
      action: reconcilePersonalFolder ? 'repair_share' : (match ? 'reuse' : 'create'),
      folder_id: match?.id ?? null,
      folder_parent_id: parentId,
      format: match ? null : folderFormat,
      ...((match && !reconcilePersonalFolder) ? folderSharingFields(match) : folderSharingFields(inheritedSharedFolder)),
      existing_permission: reconcilePersonalFolder ? match.personal_owner_permission : null,
      share_inherited_from_folder_id: inheritedSharedFolder?.id ?? null,
      share_inherited_from_path: inheritedSharedFolder?.path ?? null,
    });
  }
  const destinations = new Map();
  for (const candidate of candidates) {
    if (candidate.source_at_root) {
      destinations.set(candidate.candidate_id, {
        destination_key: 'root',
        folder_action: 'root',
        folder_id: null,
        folder_name: null,
        folder_path: 'Radice Passbolt',
      });
      continue;
    }
    const destinationKey = `client:${parentId ?? 'root'}:${normalizeComparable(candidate.client)}`;
    const folder = folderPlans.get(destinationKey);
    destinations.set(candidate.candidate_id, {
      destination_key: destinationKey,
      folder_action: folder.action,
      folder_id: folder.folder_id,
      folder_name: folder.name,
      folder_path: folder.path,
      shared: folder.shared,
      share_permissions: folder.share_permissions,
      share_recipients: folder.share_recipients,
      share_recipient_count: folder.share_recipient_count,
      share_permission_count: folder.share_permission_count,
      share_inherited_from_folder_id: folder.share_inherited_from_folder_id ?? null,
      share_inherited_from_path: folder.share_inherited_from_path ?? null,
    });
  }
  return { folders: [...folderPlans.values()], destinations, failure };
}

function credentialIdentityKey(title, username, uri) {
  return JSON.stringify([
    normalizeComparable(title),
    normalizeComparable(username),
    normalizeComparable(uri),
  ]);
}

function credentialLocationKey(title, username, uri, folderParentId) {
  return JSON.stringify([
    credentialIdentityKey(title, username, uri),
    folderParentId ?? null,
  ]);
}

function buildCandidatePlan(candidates, existingResources, duplicateDetectionAvailable, destinations = null) {
  const planned = [];
  const existingByIdentity = new Map();
  if (duplicateDetectionAvailable) {
    for (const resource of existingResources) {
      const identityKey = credentialIdentityKey(resource.name, resource.username, resource.uri);
      const matches = existingByIdentity.get(identityKey) ?? [];
      matches.push(resource);
      existingByIdentity.set(identityKey, matches);
    }
  }
  const createdByIdentityAndDestination = new Map();
  for (const candidate of candidates) {
    const destination = destinations?.get(candidate.candidate_id) ?? {
      destination_key: 'root',
      folder_action: 'root',
      folder_id: null,
      folder_name: null,
      folder_path: 'Radice Passbolt',
    };
    const identityKey = credentialIdentityKey(candidate.title, candidate.username, candidate.uri);
    const exactMatches = existingByIdentity.get(identityKey) ?? [];
    const inDestination = exactMatches.find((resource) => (
      destination.folder_action === 'root'
        ? resource.folder_parent_id === null || resource.folder_parent_id === undefined
        : (destination.folder_action === 'reuse' || destination.folder_action === 'repair_share')
          && resource.folder_parent_id === destination.folder_id
    ));
    const elsewhere = !inDestination ? exactMatches[0] : null;
    const batchKey = JSON.stringify([identityKey, destination.destination_key]);
    const batchMatch = createdByIdentityAndDestination.get(batchKey) ?? null;
    const action = inDestination || batchMatch ? 'duplicate' : elsewhere ? 'blocked' : 'create';
    const plannedCandidate = {
      ...candidate,
      ...destination,
      action,
      duplicate_kind: inDestination ? 'server_destination' : batchMatch ? 'batch' : elsewhere ? 'server_elsewhere' : null,
      duplicate_resource_id: inDestination?.id ?? elsewhere?.id ?? null,
      duplicate_candidate_id: !inDestination && batchMatch ? batchMatch.candidate_id : null,
    };
    planned.push(plannedCandidate);
    if (action === 'create') createdByIdentityAndDestination.set(batchKey, plannedCandidate);
  }
  return planned;
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function digestPlan(plan) {
  return createHash('sha256').update(canonicalJson(plan), 'utf8').digest('hex');
}

function permissionTypeLabel(type) {
  switch (Number(type)) {
    case 1:
      return 'Lettura';
    case 7:
      return 'Aggiornamento';
    case 15:
      return 'Proprietario';
    default:
      return 'Non disponibile';
  }
}

function aclPermissionRows(permissions, shareDirectory, currentUserId) {
  return permissions.map((permission) => {
    if (permission.aro === 'User') {
      const user = shareDirectory.users.get(permission.aro_foreign_key);
      const displayName = user
        ? (`${user.first_name} ${user.last_name}`.trim() || user.username || user.id)
        : permission.aro_foreign_key;
      const verified = Boolean(user?.active && user.publicKey && user.fingerprint && !user.key_error);
      return {
        subject_kind: 'User',
        subject_type: 'Utente diretto',
        subject_id: permission.aro_foreign_key,
        display_name: displayName,
        detail: user?.username || permission.aro_foreign_key,
        permission_type: permission.type,
        permission_label: permissionTypeLabel(permission.type),
        current_user: permission.aro_foreign_key === currentUserId,
        verified,
        verification_status: verified ? 'Chiave verificata' : (user?.key_error || (user ? 'Utente non attivo o chiave non verificabile.' : 'Utente non presente nella directory autenticata.')),
        recipient_count: user?.active ? 1 : 0,
      };
    }

    const group = shareDirectory.groups.get(permission.aro_foreign_key);
    const plan = group && !group.deleted
      ? buildFolderSharePlan(normalizeFolderPermissions([
        { aro: 'User', aro_foreign_key: currentUserId, type: 15 },
        permission,
      ]), shareDirectory, currentUserId)
      : { ready: false, failure: 'Gruppo non presente nella directory autenticata.', recipients: [] };
    const externalRecipientCount = plan.recipients.filter((recipient) => recipient.user_id !== currentUserId).length;
    const verified = Boolean(group && !group.deleted && plan.ready);
    return {
      subject_kind: 'Group',
      subject_type: 'Gruppo',
      subject_id: permission.aro_foreign_key,
      display_name: group?.name || permission.aro_foreign_key,
      detail: `${externalRecipientCount} destinatari effettivi verificati`,
      permission_type: permission.type,
      permission_label: permissionTypeLabel(permission.type),
      current_user: false,
      verified,
      verification_status: verified ? 'Composizione e chiavi verificate' : (group?.deleted ? 'Gruppo eliminato.' : plan.failure),
      recipient_count: externalRecipientCount,
    };
  });
}

function buildAclObjectCatalog(existingFolders, existingResources, shareDirectory, currentUserId) {
  const folderCatalog = buildFolderCatalog(existingFolders);
  const foldersById = new Map(folderCatalog.map((folder) => [folder.id, folder]));
  const objects = [];
  let totalPermissionRows = 0;

  const addObject = ({ objectType, id, name, path, parentPath, permission, permissions, rawPermissionCount }) => {
    totalPermissionRows += permissions.length;
    assert(totalPermissionRows <= MAX_ACL_PERMISSION_ROWS, 'ACL_CATALOG_TOO_LARGE', `Il catalogo contiene piu di ${MAX_ACL_PERMISSION_ROWS} righe di permesso e non puo essere mostrato in un'unica operazione.`);
    const rows = aclPermissionRows(permissions, shareDirectory, currentUserId);
    const structurallyComplete = rawPermissionCount > 0 && rawPermissionCount === permissions.length;
    const verifiedSubjects = rows.every((row) => row.verified);
    const warnings = [];
    if (rawPermissionCount === 0) {
      warnings.push('Passbolt non ha restituito la maschera completa dei permessi per questo oggetto.');
    } else if (rawPermissionCount !== permissions.length) {
      warnings.push('Una o piu voci della maschera non hanno una struttura User/Group valida.');
    }
    const unavailableCount = rows.filter((row) => !row.verified).length;
    if (unavailableCount > 0) {
      warnings.push(`${unavailableCount} soggetti non risultano completamente verificabili nella directory autenticata.`);
    }
    const shared = permissions.some((entry) => entry.aro === 'Group' || entry.aro_foreign_key !== currentUserId);
    const inspectionStatus = structurallyComplete && verifiedSubjects
      ? 'verified'
      : (structurallyComplete ? 'warning' : 'incomplete');
    objects.push({
      object_type: objectType,
      object_type_label: objectType === 'folder' ? 'Cartella' : 'Risorsa',
      object_id: id,
      name: String(name).slice(0, 300),
      path: String(path).slice(0, 4_096),
      parent_path: parentPath ? String(parentPath).slice(0, 4_096) : null,
      shared,
      sharing_label: shared ? 'Condiviso' : 'Personale',
      current_access_type: normalizePermissionType(permission?.type),
      current_access_label: permissionTypeLabel(permission?.type),
      permission_count: permissions.length,
      raw_permission_count: rawPermissionCount,
      acl_complete: structurallyComplete,
      subjects_verified: verifiedSubjects,
      inspection_status: inspectionStatus,
      warnings,
      permissions: rows,
    });
  };

  for (const folder of folderCatalog) {
    const parent = folder.folder_parent_id ? foldersById.get(folder.folder_parent_id) : null;
    addObject({
      objectType: 'folder',
      id: folder.id,
      name: folder.name,
      path: folder.path,
      parentPath: parent?.path ?? null,
      permission: folder.permission_type === null ? null : { type: folder.permission_type },
      permissions: folder.share_permissions,
      rawPermissionCount: folder.raw_permission_count,
    });
  }

  for (const resource of existingResources) {
    const parent = resource.folder_parent_id ? foldersById.get(resource.folder_parent_id) : null;
    const parentPath = parent?.path ?? (resource.folder_parent_id ? 'Cartella non disponibile' : 'Radice Passbolt');
    addObject({
      objectType: 'resource',
      id: resource.id,
      name: resource.name,
      path: `${parentPath} / ${resource.name}`,
      parentPath,
      permission: resource.permission,
      permissions: resource.permissions,
      rawPermissionCount: resource.raw_permission_count,
    });
  }

  return objects.sort((left, right) => (
    left.path.localeCompare(right.path, 'it-IT', { sensitivity: 'base' })
    || left.object_type.localeCompare(right.object_type)
    || left.object_id.localeCompare(right.object_id)
  ));
}

async function analyzeAclCatalog(session, user, keyMaterial) {
  const [resourcesResponse, foldersResponse, shareDirectoryResponse] = await Promise.all([
    session.request('/resources.json?api-version=v2&contain[permission]=1&contain[permissions]=1&contain[permissions.user.profile]=1&contain[permissions.group]=1', { allowError: true }),
    session.request('/folders.json?api-version=v2&contain[permission]=1&contain[permissions]=1&contain[permissions.user.profile]=1&contain[permissions.group]=1', { allowError: true }),
    session.request('/share/search-aros.json?api-version=v2&contain[gpgkey]=1&contain[groups_users]=1', { allowError: true }),
  ]);
  assert(resourcesResponse.status >= 200 && resourcesResponse.status < 300, 'ACL_RESOURCES_READ_FAILED', apiMessage(resourcesResponse.document, 'Impossibile leggere le risorse Passbolt per il visualizzatore dei permessi.'));
  assert(foldersResponse.status >= 200 && foldersResponse.status < 300, 'ACL_FOLDERS_READ_FAILED', apiMessage(foldersResponse.document, 'Impossibile leggere le cartelle Passbolt per il visualizzatore dei permessi.'));
  assert(shareDirectoryResponse.status >= 200 && shareDirectoryResponse.status < 300, 'ACL_DIRECTORY_READ_FAILED', apiMessage(shareDirectoryResponse.document, 'Impossibile leggere la directory autenticata dei soggetti Passbolt.'));

  const resourceEntries = rawExistingResources(resourcesResponse.document);
  const folderEntries = rawExistingFolders(foldersResponse.document);
  assert(resourceEntries.length + folderEntries.length <= MAX_ACL_OBJECTS, 'ACL_CATALOG_TOO_LARGE', `Il visualizzatore supporta al massimo ${MAX_ACL_OBJECTS} cartelle e risorse per sessione.`);
  const needsMetadataKeys = resourceEntries.some(isEncryptedMetadataResource) || folderEntries.some(isEncryptedMetadataFolder);
  let metadataKeyList = [];
  if (needsMetadataKeys) {
    const keysResponse = await session.request('/metadata/keys.json?api-version=v2&contain[metadata_private_keys]=1', { allowError: true });
    assert(keysResponse.status >= 200 && keysResponse.status < 300, 'ACL_METADATA_KEYS_READ_FAILED', apiMessage(keysResponse.document, 'Le chiavi metadati necessarie per leggere gli oggetti v5 non sono disponibili.'));
    metadataKeyList = metadataKeyEntries(keysResponse.document);
  }
  const sharedKeyEntries = new Map(metadataKeyList.map((entry) => [String(entry.id), entry]));
  const sharedKeyCache = new Map();
  const shareDirectory = await buildShareDirectory(shareDirectoryResponse.document, user, keyMaterial);
  const existingFolders = await decryptExistingFolders(folderEntries, user, keyMaterial, session.baseUrl, sharedKeyEntries, sharedKeyCache, shareDirectory);
  const existingResources = await decryptExistingResources(resourceEntries, user, keyMaterial, session.baseUrl, sharedKeyEntries, sharedKeyCache);
  const objects = buildAclObjectCatalog(existingFolders, existingResources, shareDirectory, String(user.id ?? ''));
  const permissionRecordsByObject = new Map();
  for (const [objectType, entries] of [['folder', folderEntries], ['resource', resourceEntries]]) {
    const expectedAco = objectType === 'folder' ? 'Folder' : 'Resource';
    for (const entry of entries) {
      const objectId = String(entry?.id ?? '').trim();
      if (!objectId || !Array.isArray(entry?.permissions)) continue;
      const records = entry.permissions.map((permission) => ({
        id: String(permission?.id ?? '').trim(),
        aco: String(permission?.aco ?? expectedAco),
        aco_foreign_key: String(permission?.aco_foreign_key ?? objectId),
        aro: String(permission?.aro ?? ''),
        aro_foreign_key: String(permission?.aro_foreign_key ?? '').trim(),
        type: normalizePermissionType(permission?.type),
      }));
      permissionRecordsByObject.set(`${objectType}:${objectId}`, records);
    }
  }
  assert(Buffer.byteLength(JSON.stringify(objects), 'utf8') <= MAX_ACL_CATALOG_BYTES, 'ACL_CATALOG_TOO_LARGE', 'Il catalogo ACL supera il limite sicuro della risposta locale; affinare il supporto a cataloghi di grandi dimensioni prima di procedere.');
  return {
    catalog: {
      objects,
      folder_count: objects.filter((entry) => entry.object_type === 'folder').length,
      resource_count: objects.filter((entry) => entry.object_type === 'resource').length,
      shared_count: objects.filter((entry) => entry.shared).length,
      verified_count: objects.filter((entry) => entry.inspection_status === 'verified').length,
      warning_count: objects.filter((entry) => entry.inspection_status !== 'verified').length,
    },
    runtime: { shareDirectory, permissionRecordsByObject },
  };
}

async function readAclCatalog(session, user, keyMaterial) {
  const analysis = await analyzeAclCatalog(session, user, keyMaterial);
  return analysis.catalog;
}

function normalizeAclObjectType(value) {
  const objectType = String(value ?? '').trim().toLowerCase();
  assert(['folder', 'resource'].includes(objectType), 'ACL_PLAN_OBJECT_TYPE_INVALID', 'Il tipo dell’oggetto selezionato non e valido.');
  return objectType;
}

function normalizeAclObjectId(value) {
  const objectId = String(value ?? '').trim();
  assert(objectId && objectId.length <= 200 && !/[\u0000-\u001f\u007f]/.test(objectId), 'ACL_PLAN_OBJECT_ID_INVALID', 'L’identificativo dell’oggetto selezionato non e valido.');
  return objectId;
}

function aclMaskFromRows(rows) {
  return normalizeFolderPermissions((Array.isArray(rows) ? rows : []).map((row) => ({
    aro: row?.subject_kind,
    aro_foreign_key: row?.subject_id,
    type: row?.permission_type,
  })));
}

function aclOperationLabel(action) {
  switch (action) {
    case 'add': return 'Aggiunta';
    case 'upgrade': return 'Aumento livello';
    case 'downgrade': return 'Riduzione livello';
    case 'revoke': return 'Revoca';
    default: return 'Nessuna modifica';
  }
}

function aclDirectoryStateDigest(permissions, shareDirectory) {
  const normalized = normalizeFolderPermissions(permissions);
  const proof = normalized.map((permission) => {
    if (permission.aro === 'User') {
      const user = shareDirectory.users.get(permission.aro_foreign_key);
      return {
        aro: 'User',
        aro_foreign_key: permission.aro_foreign_key,
        active: Boolean(user?.active),
        fingerprint: String(user?.fingerprint ?? ''),
        key_error: String(user?.key_error ?? ''),
      };
    }
    const group = shareDirectory.groups.get(permission.aro_foreign_key);
    const members = [...shareDirectory.users.values()]
      .filter((user) => user.memberships.includes(permission.aro_foreign_key))
      .map((user) => ({
        user_id: user.id,
        active: Boolean(user.active),
        fingerprint: String(user.fingerprint ?? ''),
        key_error: String(user.key_error ?? ''),
      }))
      .sort((left, right) => left.user_id.localeCompare(right.user_id));
    return {
      aro: 'Group',
      aro_foreign_key: permission.aro_foreign_key,
      deleted: Boolean(group?.deleted),
      user_count: group?.user_count ?? null,
      members,
    };
  });
  return digestPlan(proof);
}

function aclEffectiveUserAccess(permissions, shareDirectory) {
  const access = new Map();
  const grant = (userId, type) => {
    const current = access.get(userId) ?? 0;
    if (type > current) access.set(userId, type);
  };
  for (const permission of normalizeFolderPermissions(permissions)) {
    if (permission.aro === 'User') {
      const user = shareDirectory.users.get(permission.aro_foreign_key);
      assert(user?.active, 'ACL_PLAN_EFFECTIVE_USER_UNAVAILABLE', `L’utente ${permission.aro_foreign_key} non e disponibile per il calcolo dell’impatto effettivo.`);
      grant(permission.aro_foreign_key, permission.type);
      continue;
    }
    const group = shareDirectory.groups.get(permission.aro_foreign_key);
    assert(group && !group.deleted, 'ACL_PLAN_EFFECTIVE_GROUP_UNAVAILABLE', `Il gruppo ${permission.aro_foreign_key} non e disponibile per il calcolo dell’impatto effettivo.`);
    const members = [...shareDirectory.users.values()]
      .filter((user) => user.active && user.memberships.includes(permission.aro_foreign_key));
    assert(
      group.user_count === null || members.length === group.user_count,
      'ACL_PLAN_EFFECTIVE_GROUP_INCOMPLETE',
      `La composizione del gruppo ${group.name || group.id} non e completa.`,
    );
    for (const member of members) grant(member.id, permission.type);
  }
  return access;
}

function aclEffectiveUserImpact(currentPermissions, desiredPermissions, shareDirectory, currentUserId) {
  const before = aclEffectiveUserAccess(currentPermissions, shareDirectory);
  const after = aclEffectiveUserAccess(desiredPermissions, shareDirectory);
  assert(after.get(currentUserId) === 15, 'ACL_PLAN_CURRENT_OWNER_AT_RISK', 'Il proprietario autenticato perderebbe il livello Owner; il piano e stato bloccato.');
  const changes = [];
  for (const userId of [...new Set([...before.keys(), ...after.keys()])].sort()) {
    if (userId === currentUserId) continue;
    const beforeType = before.get(userId) ?? null;
    const afterType = after.get(userId) ?? null;
    if (beforeType === afterType) continue;
    assert(changes.length < MAX_ACL_PLAN_OPERATIONS, 'ACL_PLAN_EFFECTIVE_IMPACT_TOO_LARGE', `L’impatto effettivo coinvolge piu di ${MAX_ACL_PLAN_OPERATIONS} utenti e non puo essere confermato in un unico piano.`);
    const action = beforeType === null
      ? 'gain'
      : (afterType === null ? 'loss' : (afterType > beforeType ? 'upgrade' : 'downgrade'));
    const user = shareDirectory.users.get(userId);
    changes.push({
      user_id: userId,
      username: String(user?.username ?? '').slice(0, 300),
      display_name: (`${user?.first_name ?? ''} ${user?.last_name ?? ''}`.trim() || user?.username || userId).slice(0, 300),
      action,
      action_label: action === 'gain' ? 'Ottiene accesso' : (action === 'loss' ? 'Perde accesso' : (action === 'upgrade' ? 'Accesso aumentato' : 'Accesso ridotto')),
      before_permission_type: beforeType,
      before_permission_label: beforeType === null ? 'Nessuno' : permissionTypeLabel(beforeType),
      after_permission_type: afterType,
      after_permission_label: afterType === null ? 'Nessuno' : permissionTypeLabel(afterType),
    });
  }
  const counts = {
    before: before.size,
    after: after.size,
    gain: changes.filter((entry) => entry.action === 'gain').length,
    loss: changes.filter((entry) => entry.action === 'loss').length,
    upgrade: changes.filter((entry) => entry.action === 'upgrade').length,
    downgrade: changes.filter((entry) => entry.action === 'downgrade').length,
  };
  return { before, after, changes, counts };
}

function buildAclChangePlan(target, desiredPermissionValue, shareDirectory, currentUserId) {
  assert(target && typeof target === 'object', 'ACL_PLAN_OBJECT_NOT_FOUND', 'L’oggetto selezionato non e piu presente su Passbolt.');
  assert(target.acl_complete, 'ACL_PLAN_OBJECT_INCOMPLETE', 'La maschera ACL dell’oggetto selezionato non e completa; il dry-run e bloccato.');
  assert(target.subjects_verified, 'ACL_PLAN_SUBJECTS_UNVERIFIED', 'Uno o piu soggetti della ACL corrente non sono verificabili; il dry-run e bloccato.');
  assert(target.current_access_type === 15, 'ACL_PLAN_OWNER_REQUIRED', 'Solo un proprietario dell’oggetto puo preparare un piano di modifica ACL.');

  const currentPermissions = aclMaskFromRows(target.permissions);
  assert(
    currentPermissions.some((permission) => permission.aro === 'User' && permission.aro_foreign_key === currentUserId && permission.type === 15),
    'ACL_PLAN_CURRENT_OWNER_MISSING',
    'La ACL corrente non conferma il proprietario autenticato; il dry-run e bloccato.',
  );
  const desiredTemplate = normalizeCustomPermissionEntries(desiredPermissionValue, currentUserId);
  for (const permission of desiredTemplate) {
    if (permission.aro === 'User') {
      const directoryUser = shareDirectory.users.get(permission.aro_foreign_key);
      assert(directoryUser?.active, 'ACL_PLAN_USER_UNAVAILABLE', `L’utente ${permission.aro_foreign_key} non e disponibile o non e attivo.`);
    } else {
      const group = shareDirectory.groups.get(permission.aro_foreign_key);
      assert(group && !group.deleted, 'ACL_PLAN_GROUP_UNAVAILABLE', `Il gruppo ${permission.aro_foreign_key} non e disponibile.`);
    }
  }
  const desiredPermissions = normalizeFolderPermissions([
    ...desiredTemplate,
    { aro: 'User', aro_foreign_key: currentUserId, type: 15 },
  ]);
  const desiredRows = aclPermissionRows(desiredPermissions, shareDirectory, currentUserId);
  assert(desiredRows.every((row) => row.verified), 'ACL_PLAN_DESIRED_UNVERIFIED', 'La ACL desiderata contiene utenti, gruppi o chiavi non completamente verificabili.');
  const currentOwnerCount = currentPermissions.filter((permission) => permission.type === 15).length;
  const desiredOwnerCount = desiredPermissions.filter((permission) => permission.type === 15).length;
  assert(currentOwnerCount > 0, 'ACL_PLAN_LAST_OWNER_UNVERIFIED', 'La ACL corrente non contiene alcun proprietario verificato.');
  assert(desiredOwnerCount > 0, 'ACL_PLAN_LAST_OWNER_BLOCKED', 'Il piano eliminerebbe l’ultimo proprietario dell’oggetto.');
  assert(
    desiredPermissions.some((permission) => permission.aro === 'User' && permission.aro_foreign_key === currentUserId && permission.type === 15),
    'ACL_PLAN_CURRENT_OWNER_AT_RISK',
    'Il piano ridurrebbe o revocherebbe l’accesso del proprietario autenticato.',
  );
  const effectiveImpact = aclEffectiveUserImpact(currentPermissions, desiredPermissions, shareDirectory, currentUserId);

  const currentBySubject = new Map(currentPermissions.map((permission) => [`${permission.aro}:${permission.aro_foreign_key}`, permission]));
  const desiredBySubject = new Map(desiredPermissions.map((permission) => [`${permission.aro}:${permission.aro_foreign_key}`, permission]));
  const currentRowsBySubject = new Map(target.permissions.map((row) => [`${row.subject_kind}:${row.subject_id}`, row]));
  const desiredRowsBySubject = new Map(desiredRows.map((row) => [`${row.subject_kind}:${row.subject_id}`, row]));
  const keys = [...new Set([...currentBySubject.keys(), ...desiredBySubject.keys()])].sort();
  const operations = [];
  let unchangedCount = 0;
  for (const key of keys) {
    const before = currentBySubject.get(key) ?? null;
    const after = desiredBySubject.get(key) ?? null;
    if (before && after && before.type === after.type) {
      unchangedCount += 1;
      continue;
    }
    let action;
    if (!before) action = 'add';
    else if (!after) action = 'revoke';
    else action = after.type > before.type ? 'upgrade' : 'downgrade';
    const subject = desiredRowsBySubject.get(key) ?? currentRowsBySubject.get(key);
    const direction = ['downgrade', 'revoke'].includes(action) ? 'restrictive' : 'expansive';
    const sensitive = direction === 'restrictive' || after?.type === 15;
    assert(operations.length < MAX_ACL_PLAN_OPERATIONS, 'ACL_PLAN_TOO_LARGE', `Il confronto contiene piu di ${MAX_ACL_PLAN_OPERATIONS} modifiche e non puo essere mostrato in un unico piano.`);
    operations.push({
      sequence: operations.length + 1,
      action,
      action_label: aclOperationLabel(action),
      direction,
      direction_label: direction === 'restrictive' ? 'Riduce accesso' : 'Estende accesso',
      sensitive,
      risk_label: sensitive ? 'Sensibile' : 'Standard',
      subject_kind: subject.subject_kind,
      subject_type: subject.subject_type,
      subject_id: subject.subject_id,
      display_name: subject.display_name,
      detail: subject.detail,
      before_permission_type: before?.type ?? null,
      before_permission_label: before ? permissionTypeLabel(before.type) : 'Nessuno',
      after_permission_type: after?.type ?? null,
      after_permission_label: after ? permissionTypeLabel(after.type) : 'Nessuno',
    });
  }

  const counts = {
    add: operations.filter((operation) => operation.action === 'add').length,
    upgrade: operations.filter((operation) => operation.action === 'upgrade').length,
    downgrade: operations.filter((operation) => operation.action === 'downgrade').length,
    revoke: operations.filter((operation) => operation.action === 'revoke').length,
    unchanged: unchangedCount,
  };
  const objectStateDigest = digestPlan({
    object_type: target.object_type,
    object_id: target.object_id,
    permissions: currentPermissions,
  });
  const desiredAclDigest = digestPlan({
    object_type: target.object_type,
    object_id: target.object_id,
    permissions: desiredPermissions,
  });
  const directoryStateDigest = aclDirectoryStateDigest(
    normalizeFolderPermissions([...currentPermissions, ...desiredPermissions]),
    shareDirectory,
  );
  const planDigest = digestPlan({
    object_state_digest: objectStateDigest,
    desired_acl_digest: desiredAclDigest,
    directory_state_digest: directoryStateDigest,
    operations: operations.map((operation) => ({
      action: operation.action,
      subject_kind: operation.subject_kind,
      subject_id: operation.subject_id,
      before_permission_type: operation.before_permission_type,
      after_permission_type: operation.after_permission_type,
    })),
    effective_user_changes: effectiveImpact.changes.map((entry) => ({
      user_id: entry.user_id,
      action: entry.action,
      before_permission_type: entry.before_permission_type,
      after_permission_type: entry.after_permission_type,
    })),
    owner_count_after: desiredOwnerCount,
  });
  return {
    plan_id: randomUUID(),
    object: {
      object_type: target.object_type,
      object_type_label: target.object_type_label,
      object_id: target.object_id,
      name: target.name,
      path: target.path,
    },
    object_state_digest: objectStateDigest,
    desired_acl_digest: desiredAclDigest,
    directory_state_digest: directoryStateDigest,
    plan_digest: planDigest,
    current_permission_count: currentPermissions.length,
    desired_permission_count: desiredPermissions.length,
    change_count: operations.length,
    sensitive_action_count: operations.filter((operation) => operation.sensitive).length,
    effective_user_counts: effectiveImpact.counts,
    effective_user_changes: effectiveImpact.changes,
    last_owner_protection: {
      owner_count_before: currentOwnerCount,
      owner_count_after: desiredOwnerCount,
      current_user_owner_retained: true,
      protected: true,
    },
    counts,
    operations,
  };
}

function customSharingFields(permissionConfiguration) {
  return {
    shared: true,
    share_permissions: permissionConfiguration.permissions,
    share_recipients: permissionConfiguration.recipients,
    share_recipient_count: permissionConfiguration.recipients.length,
    share_permission_count: permissionConfiguration.permissions.length,
    share_permission_source: 'custom',
  };
}

function applyPermissionConfiguration(destinationPlan, permissionConfiguration) {
  if (permissionConfiguration.mode === 'inherited') {
    return { ...destinationPlan, permissionFailure: null };
  }
  const customFields = customSharingFields(permissionConfiguration);
  const expectedMaskHash = permissionMaskDigest(permissionConfiguration.permissions);
  const folders = destinationPlan.folders.map((folder) => {
    if (folder.action === 'create') {
      return {
        ...folder,
        ...customFields,
        share_inherited_from_folder_id: null,
        share_inherited_from_path: null,
      };
    }
    const existingMaskMatches = folder.shared
      && permissionMaskDigest(folder.share_permissions) === expectedMaskHash;
    return {
      ...folder,
      permission_template_conflict: !existingMaskMatches,
      permission_template_conflict_reason: folder.action === 'repair_share'
        ? `La cartella esistente ${folder.path} richiederebbe una modifica dei permessi. L’editor applica la ACL personalizzata soltanto a nuovi oggetti.`
        : `La cartella esistente ${folder.path} non possiede gia la stessa ACL personalizzata. Per sicurezza i suoi permessi non verranno modificati automaticamente.`,
      ...(existingMaskMatches ? { share_permission_source: 'custom_existing_match' } : {}),
    };
  });
  const byKey = new Map(folders.map((folder) => [folder.destination_key, folder]));
  const destinations = new Map();
  for (const [candidateId, destination] of destinationPlan.destinations.entries()) {
    if (destination.folder_action === 'root') {
      destinations.set(candidateId, { ...destination, ...customFields });
      continue;
    }
    const folder = byKey.get(destination.destination_key);
    if (destination.folder_action === 'create') {
      destinations.set(candidateId, {
        ...destination,
        ...customFields,
        share_inherited_from_folder_id: null,
        share_inherited_from_path: null,
      });
      continue;
    }
    destinations.set(candidateId, {
      ...destination,
      ...(folder?.permission_template_conflict ? {
        permission_template_conflict: true,
        permission_template_conflict_reason: folder.permission_template_conflict_reason,
      } : {}),
      ...(folder?.share_permission_source ? { share_permission_source: folder.share_permission_source } : {}),
    });
  }
  return { ...destinationPlan, folders, destinations, permissionFailure: null };
}

function normalizePermissionMode(value = 'inherited') {
  const mode = String(value ?? 'inherited').trim().toLowerCase();
  assert(['inherited', 'custom'].includes(mode), 'INVALID_PERMISSION_MODE', 'La modalita dei permessi deve essere Ereditata oppure Personalizzata.');
  return mode;
}

function normalizeCustomPermissionEntries(value, currentUserId) {
  assert(Array.isArray(value) && value.length <= 500, 'INVALID_PERMISSION_TEMPLATE', 'La configurazione dei permessi personalizzati non e valida.');
  const entries = [];
  const seen = new Set();
  for (const item of value) {
    assert(item && typeof item === 'object' && !Array.isArray(item), 'INVALID_PERMISSION_TEMPLATE', 'Una voce dei permessi personalizzati non e valida.');
    assert(Object.keys(item).every((key) => ['aro', 'aro_foreign_key', 'type'].includes(key)), 'INVALID_PERMISSION_TEMPLATE', 'Una voce dei permessi personalizzati contiene campi non supportati.');
    const aro = String(item.aro ?? '');
    const aroForeignKey = String(item.aro_foreign_key ?? '').trim();
    const type = normalizePermissionType(item.type);
    assert(['User', 'Group'].includes(aro), 'INVALID_PERMISSION_TEMPLATE', 'Un destinatario dei permessi non indica un tipo valido.');
    assert(aroForeignKey && aroForeignKey.length <= 128 && !/[\u0000-\u001f\u007f]/.test(aroForeignKey), 'INVALID_PERMISSION_TEMPLATE', 'Un destinatario dei permessi non contiene un identificatore valido.');
    assert(type !== null, 'INVALID_PERMISSION_TEMPLATE', 'Il livello di un permesso personalizzato non e valido.');
    assert(!(aro === 'User' && aroForeignKey === currentUserId), 'CURRENT_OWNER_PERMISSION_IMMUTABLE', 'Il proprietario autenticato e aggiunto automaticamente e non puo essere modificato dall’editor.');
    const key = `${aro}:${aroForeignKey}`;
    assert(!seen.has(key), 'DUPLICATE_PERMISSION_ENTRY', 'La configurazione contiene due permessi per lo stesso utente o gruppo.');
    seen.add(key);
    entries.push({ aro, aro_foreign_key: aroForeignKey, type });
  }
  return normalizeFolderPermissions(entries);
}

function normalizeRecoveryState(value, candidates) {
  assert(value && typeof value === 'object' && !Array.isArray(value), 'RECOVERY_STATE_INVALID', 'Il registro locale di recupero non e valido.');
  const batchId = normalizeReconciliationBatchId(value.batch_id);
  assert(batchId, 'RECOVERY_STATE_INVALID', 'L’identificativo del lotto di recupero non e valido.');
  assert(Number(value.schema_version) === 1, 'RECOVERY_SCHEMA_UNSUPPORTED', 'La versione del registro di recupero non e supportata.');
  assert(Array.isArray(value.candidates) && value.candidates.length === candidates.length, 'RECOVERY_CANDIDATES_MISMATCH', 'I candidati non corrispondono al lotto da recuperare.');
  const suppliedProofs = new Map(candidates.map((candidate) => [candidate.candidate_id, candidate.source_sha256]));
  for (const proof of value.candidates) {
    assert(proof && typeof proof === 'object', 'RECOVERY_CANDIDATES_MISMATCH', 'Le prove dei candidati non sono valide.');
    const candidateId = String(proof.candidate_id ?? '');
    assert(suppliedProofs.get(candidateId) === String(proof.source_sha256 ?? ''), 'RECOVERY_CANDIDATES_MISMATCH', 'Le prove dei candidati non corrispondono al lotto.');
  }
  assert(Array.isArray(value.operations), 'RECOVERY_STATE_INVALID', 'Le operazioni del registro non sono valide.');
  const operationIds = new Set();
  for (const operation of value.operations) {
    assert(operation && typeof operation === 'object', 'RECOVERY_STATE_INVALID', 'Un’operazione del registro non e valida.');
    const operationId = String(operation.operation_id ?? '');
    assert(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(operationId) && !operationIds.has(operationId), 'RECOVERY_STATE_INVALID', 'Un identificativo operazione del registro non e valido.');
    operationIds.add(operationId);
    assert(['folder', 'resource'].includes(String(operation.object_type ?? '')), 'RECOVERY_STATE_INVALID', 'Il tipo di un’operazione del registro non e valido.');
    assert(['create_folder', 'share_folder', 'reconcile_folder', 'create_resource', 'share_resource'].includes(String(operation.action ?? '')), 'RECOVERY_STATE_INVALID', 'L’azione di un’operazione del registro non e valida.');
  }
  const permissionMode = normalizePermissionMode(value.permission_mode ?? 'inherited');
  if (value.permission_configuration_hash !== undefined) {
    assert(/^[0-9a-f]{64}$/.test(String(value.permission_configuration_hash)), 'RECOVERY_STATE_INVALID', 'L’hash dei permessi del registro non e valido.');
  }
  return { ...value, batch_id: batchId, permission_mode: permissionMode };
}

function recordedRemoteId(operation) {
  const outcome = operation.recorded_outcome;
  if (!outcome || typeof outcome !== 'object') return null;
  const field = operation.object_type === 'folder' ? 'folder_id' : 'resource_id';
  return typeof outcome[field] === 'string' && outcome[field] ? outcome[field] : null;
}

function recordedSuccess(operation) {
  const eventType = String(operation.recorded_outcome?.event_type ?? '');
  return ['folder_created', 'folder_shared', 'resource_created', 'resource_shared'].includes(eventType);
}

function confirmedFailure(operation) {
  return operation.recorded_outcome?.event_type === 'operation_failed'
    && operation.recorded_outcome?.outcome === 'confirmed';
}

function recoveryConflict(operation, code) {
  return {
    operation_id: operation.operation_id,
    object_type: operation.object_type,
    action: operation.action,
    code,
  };
}

function operationVerification(operation, resolution, remoteId = null) {
  return {
    recovery_id: null,
    operation_id: operation.operation_id,
    object_type: operation.object_type,
    resolution,
    ...(operation.candidate_id ? { candidate_id: operation.candidate_id } : {}),
    ...(operation.destination_key_hash ? { destination_key_hash: operation.destination_key_hash } : {}),
    ...(remoteId && operation.object_type === 'folder' ? { folder_id: remoteId } : {}),
    ...(remoteId && operation.object_type === 'resource' ? { resource_id: remoteId } : {}),
  };
}

function classifyRecovery(recoveryValue, candidates, capabilities, runtime, currentUserId) {
  const recovery = normalizeRecoveryState(recoveryValue, candidates);
  const conflicts = [];
  if (String(recovery.resource_format) !== String(capabilities.resource_format_selected)
      || String(recovery.folder_format) !== String(capabilities.folder_format_selected ?? 'none')
      || String(recovery.destination_mode) !== String(capabilities.destination_mode)
      || String(recovery.destination_folder_id ?? '') !== String(capabilities.destination_folder_id ?? '')
      || String(recovery.permission_mode ?? 'inherited') !== String(capabilities.permission_mode ?? 'inherited')
      || (recovery.permission_configuration_hash
        && String(recovery.permission_configuration_hash) !== String(capabilities.permission_configuration_hash ?? ''))) {
    conflicts.push({ operation_id: null, object_type: null, action: null, code: 'RECOVERY_PLAN_CONTEXT_CHANGED' });
  }
  if (!capabilities.can_import) {
    conflicts.push({ operation_id: null, object_type: null, action: null, code: 'RECOVERY_REMOTE_STATE_UNAVAILABLE' });
  }
  for (const candidate of capabilities.candidates.filter((item) => item.action === 'blocked')) {
    conflicts.push({ operation_id: null, object_type: 'resource', action: null, candidate_id: candidate.candidate_id, code: 'RECOVERY_RESOURCE_ELSEWHERE' });
  }

  const candidatesById = new Map(capabilities.candidates.map((candidate) => [candidate.candidate_id, candidate]));
  const resourcesById = new Map(runtime.existingResources.map((resource) => [resource.id, resource]));
  const foldersById = new Map(runtime.existingFolders.map((folder) => [folder.id, folder]));
  const operationsById = new Map(
    recovery.operations.map((operation) => [operation.operation_id, operation]),
  );
  const resourcesByIdentityAndFolder = new Map();
  for (const resource of runtime.existingResources) {
    const key = credentialLocationKey(
      resource.name,
      resource.username,
      resource.uri,
      resource.folder_parent_id,
    );
    const matches = resourcesByIdentityAndFolder.get(key) ?? [];
    matches.push(resource);
    resourcesByIdentityAndFolder.set(key, matches);
  }
  const foldersByDestinationHash = new Map();
  for (const folder of runtime.destinationFolders) {
    const key = technicalDigest(folder.destination_key);
    if (foldersByDestinationHash.has(key)) {
      conflicts.push({ operation_id: null, object_type: 'folder', action: null, code: 'RECOVERY_FOLDER_DESTINATION_AMBIGUOUS' });
    } else {
      foldersByDestinationHash.set(key, folder);
    }
  }

  const classifications = [];
  for (const operation of recovery.operations) {
    const action = String(operation.action);
    const recordedId = recordedRemoteId(operation);
    const wasSuccessful = recordedSuccess(operation);
    const wasConfirmedFailure = confirmedFailure(operation);
    if (action === 'create_resource') {
      const planned = candidatesById.get(String(operation.candidate_id ?? ''));
      if (!planned) {
        conflicts.push(recoveryConflict(operation, 'RECOVERY_CANDIDATE_MISSING'));
        continue;
      }
      if (operation.permission_mask_hash && permissionMaskDigest(planned.share_permissions) !== operation.permission_mask_hash) {
        conflicts.push(recoveryConflict(operation, 'RECOVERY_INTENDED_PERMISSION_CHANGED'));
        continue;
      }
      const exactDestinationResources = resourcesByIdentityAndFolder.get(
        credentialLocationKey(
          planned.title,
          planned.username,
          planned.uri,
          planned.folder_action === 'root' ? null : planned.folder_id,
        ),
      ) ?? [];
      if (exactDestinationResources.length > 1) {
        conflicts.push(recoveryConflict(operation, 'RECOVERY_RESOURCE_DESTINATION_AMBIGUOUS'));
        continue;
      }
      const remoteId = planned.action === 'duplicate' && planned.duplicate_kind === 'server_destination'
        ? planned.duplicate_resource_id
        : null;
      if (wasSuccessful) {
        if (!recordedId || remoteId !== recordedId) conflicts.push(recoveryConflict(operation, 'RECOVERY_RECORDED_RESOURCE_CHANGED'));
        else classifications.push(operationVerification(operation, 'remote_success', remoteId));
      } else if (wasConfirmedFailure) {
        if (planned.action === 'create') classifications.push(operationVerification(operation, 'not_applied'));
        else conflicts.push(recoveryConflict(operation, 'RECOVERY_CONFIRMED_FAILURE_CONFLICT'));
      } else if (remoteId) {
        classifications.push(operationVerification(operation, 'remote_success', remoteId));
      } else if (planned.action === 'create') {
        classifications.push(operationVerification(operation, 'not_applied'));
      } else {
        conflicts.push(recoveryConflict(operation, 'RECOVERY_RESOURCE_STATE_AMBIGUOUS'));
      }
      continue;
    }

    if (action === 'create_folder') {
      const planned = foldersByDestinationHash.get(String(operation.destination_key_hash ?? ''));
      if (operation.permission_mask_hash && permissionMaskDigest(planned?.share_permissions) !== operation.permission_mask_hash) {
        conflicts.push(recoveryConflict(operation, 'RECOVERY_INTENDED_PERMISSION_CHANGED'));
        continue;
      }
      const remoteId = ['reuse', 'repair_share'].includes(planned?.action) ? planned.folder_id : null;
      if (wasSuccessful) {
        if (!recordedId || remoteId !== recordedId) conflicts.push(recoveryConflict(operation, 'RECOVERY_RECORDED_FOLDER_CHANGED'));
        else classifications.push(operationVerification(operation, 'remote_success', remoteId));
      } else if (wasConfirmedFailure) {
        if (planned?.action === 'create') classifications.push(operationVerification(operation, 'not_applied'));
        else conflicts.push(recoveryConflict(operation, 'RECOVERY_CONFIRMED_FAILURE_CONFLICT'));
      } else if (remoteId) {
        classifications.push(operationVerification(operation, 'remote_success', remoteId));
      } else if (planned?.action === 'create') {
        classifications.push(operationVerification(operation, 'not_applied'));
      } else {
        conflicts.push(recoveryConflict(operation, 'RECOVERY_FOLDER_STATE_AMBIGUOUS'));
      }
      continue;
    }

    const isFolder = operation.object_type === 'folder';
    const planned = isFolder
      ? foldersByDestinationHash.get(String(operation.destination_key_hash ?? ''))
      : candidatesById.get(String(operation.candidate_id ?? ''));
    const remoteId = recordedId
      || (isFolder ? planned?.folder_id : planned?.duplicate_resource_id)
      || null;
    const remote = isFolder ? foldersById.get(remoteId) : resourcesById.get(remoteId);
    if (!operation.permission_mask_hash) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_PERMISSION_PROOF_MISSING'));
    } else if (permissionMaskDigest(planned?.share_permissions) !== operation.permission_mask_hash) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_INTENDED_PERMISSION_CHANGED'));
    } else if (!remote) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_SHARE_OBJECT_MISSING'));
    } else if (remote.raw_permission_count !== remote.permissions.length || remote.permissions.length === 0) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_REMOTE_PERMISSION_MASK_INCOMPLETE'));
    } else if (permissionMaskDigest(remote.permissions) === operation.permission_mask_hash) {
      classifications.push(operationVerification(operation, 'remote_success', remoteId));
    } else if (!wasSuccessful && isSoleOwnerMask(remote.permissions, currentUserId)) {
      classifications.push(operationVerification(operation, 'not_applied', remoteId));
    } else {
      conflicts.push(recoveryConflict(operation, wasSuccessful ? 'RECOVERY_RECORDED_PERMISSIONS_CHANGED' : 'RECOVERY_PERMISSION_STATE_AMBIGUOUS'));
    }
  }

  const createOperations = recovery.operations.filter((operation) => operation.action === 'create_resource');
  const shareCandidateIds = new Set(recovery.operations.filter((operation) => operation.action === 'share_resource').map((operation) => operation.candidate_id));
  const repairResourceCandidateIds = classifications
    .filter((item) => item.resolution === 'not_applied' && operationsById.get(item.operation_id)?.action === 'share_resource')
    .map((item) => item.candidate_id);
  const repairResourceCandidateIdSet = new Set(repairResourceCandidateIds);
  for (const operation of createOperations) {
    const candidate = candidatesById.get(operation.candidate_id);
    if (!candidate?.shared || candidate.action !== 'duplicate' || candidate.duplicate_kind !== 'server_destination' || shareCandidateIds.has(operation.candidate_id)) continue;
    const remote = resourcesById.get(candidate.duplicate_resource_id);
    if (!operation.permission_mask_hash) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_PERMISSION_PROOF_MISSING'));
    } else if (permissionMaskDigest(candidate.share_permissions) !== operation.permission_mask_hash) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_INTENDED_PERMISSION_CHANGED'));
    } else if (!remote) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_SHARE_OBJECT_MISSING'));
    } else if (remote.raw_permission_count !== remote.permissions.length || remote.permissions.length === 0) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_REMOTE_PERMISSION_MASK_INCOMPLETE'));
    } else if (permissionMaskDigest(remote.permissions) === operation.permission_mask_hash) {
      continue;
    } else if (isSoleOwnerMask(remote.permissions, currentUserId)) {
      if (!repairResourceCandidateIdSet.has(operation.candidate_id)) {
        repairResourceCandidateIds.push(operation.candidate_id);
        repairResourceCandidateIdSet.add(operation.candidate_id);
      }
    } else {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_PERMISSION_STATE_AMBIGUOUS'));
    }
  }

  const createFolderOperations = recovery.operations.filter((operation) => operation.action === 'create_folder' && operation.permission_mask_hash);
  const explicitFolderShares = new Set(recovery.operations.filter((operation) => ['share_folder', 'reconcile_folder'].includes(operation.action)).map((operation) => operation.destination_key_hash));
  const repairFolderDestinationHashes = classifications
    .filter((item) => item.resolution === 'not_applied' && ['share_folder', 'reconcile_folder'].includes(operationsById.get(item.operation_id)?.action))
    .map((item) => item.destination_key_hash);
  const repairFolderDestinationHashSet = new Set(repairFolderDestinationHashes);
  for (const operation of createFolderOperations) {
    if (explicitFolderShares.has(operation.destination_key_hash)) continue;
    const planned = foldersByDestinationHash.get(operation.destination_key_hash);
    const remote = planned?.folder_id ? foldersById.get(planned.folder_id) : null;
    if (!remote || planned?.action === 'create') continue;
    if (permissionMaskDigest(planned.share_permissions) !== operation.permission_mask_hash) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_INTENDED_PERMISSION_CHANGED'));
      continue;
    }
    if (remote.raw_permission_count !== remote.permissions.length || remote.permissions.length === 0) {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_REMOTE_PERMISSION_MASK_INCOMPLETE'));
      continue;
    }
    if (permissionMaskDigest(remote.permissions) === operation.permission_mask_hash) continue;
    if (isSoleOwnerMask(remote.permissions, currentUserId) && planned.action === 'repair_share') {
      if (!repairFolderDestinationHashSet.has(operation.destination_key_hash)) {
        repairFolderDestinationHashes.push(operation.destination_key_hash);
        repairFolderDestinationHashSet.add(operation.destination_key_hash);
      }
    } else {
      conflicts.push(recoveryConflict(operation, 'RECOVERY_PERMISSION_STATE_AMBIGUOUS'));
    }
  }

  const createCandidateIds = capabilities.candidates.filter((candidate) => candidate.action === 'create').map((candidate) => candidate.candidate_id);
  const resourceCandidateIds = [...new Set([...createCandidateIds, ...repairResourceCandidateIds])].sort();
  const folderRetryKeys = new Set(capabilities.candidates.filter((candidate) => candidate.action === 'create').map((candidate) => candidate.destination_key));
  const retryFolders = runtime.destinationFolders.filter((folder) => (
    (folder.action === 'create' && folderRetryKeys.has(folder.destination_key))
    || (folder.action === 'repair_share' && (folderRetryKeys.has(folder.destination_key) || repairFolderDestinationHashSet.has(technicalDigest(folder.destination_key))))
  ));
  const verificationDigest = digestPlan(classifications.map(({ recovery_id: ignored, ...item }) => item));
  const recoveryPlanDigest = digestPlan({
    batch_id: recovery.batch_id,
    current_plan_digest: capabilities.plan_digest,
    verification_digest: verificationDigest,
    create_candidate_ids: createCandidateIds,
    repair_resource_candidate_ids: repairResourceCandidateIds,
    retry_folder_hashes: retryFolders.map((folder) => technicalDigest(folder.destination_key)).sort(),
  });
  return {
    recovery,
    classifications,
    conflicts,
    verificationDigest,
    recoveryPlanDigest,
    createCandidateIds,
    repairResourceCandidateIds,
    resourceCandidateIds,
    retryFolders,
    retryActionCount: createCandidateIds.length + repairResourceCandidateIds.length + retryFolders.length,
  };
}

async function analyzeCapabilities(
  session,
  user,
  candidates,
  keyMaterial = null,
  requestedFormatValue = 'auto',
  destinationModeValue = 'client_folders',
  requestedFolderFormatValue = 'auto',
  destinationFolderIdValue = null,
  clientDestinationMappingValue = null,
  permissionModeValue = 'inherited',
  permissionTemplateValue = null,
) {
  const requestedFormat = normalizeResourceFormat(requestedFormatValue);
  const destinationMode = normalizeDestinationMode(destinationModeValue);
  const requestedFolderFormat = normalizeResourceFormat(requestedFolderFormatValue);
  const suppliedDestinationFolderId = normalizeDestinationFolderId(destinationFolderIdValue);
  const destinationFolderId = ['root', 'client_mapping'].includes(destinationMode) ? null : suppliedDestinationFolderId;
  const clientDestinationMapping = destinationMode === 'client_mapping'
    ? normalizeClientDestinationMapping(clientDestinationMappingValue, candidates)
    : normalizeClientDestinationMapping(null, candidates);
  const needsFolderInventory = destinationMode !== 'root';
  const needsClientFolderMapping = destinationMode === 'client_folders'
    && candidates.some((candidate) => !candidate.source_at_root);
  const [settingsResponse, metadataResponse, resourceTypesResponse, resourcesResponse, foldersResponse, shareDirectoryResponse] = await Promise.all([
    session.request('/settings.json?api-version=v2', { allowError: true }),
    session.request('/metadata/types/settings.json?api-version=v2', { allowError: true }),
    session.request('/resource-types.json?api-version=v2', { allowError: true }),
    session.request('/resources.json?api-version=v2&contain[permission]=1&contain[permissions]=1&contain[permissions.user.profile]=1&contain[permissions.group]=1', { allowError: true }),
    session.request('/folders.json?api-version=v2&contain[permission]=1&contain[permissions]=1&contain[permissions.user.profile]=1&contain[permissions.group]=1', { allowError: true }),
    session.request('/share/search-aros.json?api-version=v2&contain[gpgkey]=1&contain[groups_users]=1', { allowError: true }),
  ]);
  assert(settingsResponse.status >= 200 && settingsResponse.status < 300, 'SETTINGS_READ_FAILED', apiMessage(settingsResponse.document, 'Impossibile leggere le impostazioni Passbolt.'));
  assert(resourceTypesResponse.status >= 200 && resourceTypesResponse.status < 300, 'RESOURCE_TYPES_READ_FAILED', apiMessage(resourceTypesResponse.document, 'Impossibile leggere i tipi di risorsa Passbolt.'));
  assert(resourcesResponse.status >= 200 && resourcesResponse.status < 300, 'RESOURCES_READ_FAILED', apiMessage(resourcesResponse.document, 'Impossibile leggere i metadati delle risorse Passbolt.'));
  assert(!needsFolderInventory || (foldersResponse.status >= 200 && foldersResponse.status < 300), 'FOLDERS_READ_FAILED', apiMessage(foldersResponse.document, 'Impossibile leggere le cartelle Passbolt.'));

  const settings = apiBody(settingsResponse.document) ?? {};
  const metadataEnabled = Boolean(settingsValue(settings, ['passbolt', 'plugins', 'metadata', 'enabled'], false));
  const metadataResponseSucceeded = metadataResponse.status >= 200 && metadataResponse.status < 300;
  assert(!metadataEnabled || metadataResponseSucceeded, 'METADATA_SETTINGS_READ_FAILED', apiMessage(metadataResponse.document, 'Il plugin metadata e attivo ma le relative impostazioni non sono leggibili.'));
  const metadataSettings = metadataResponseSucceeded ? (apiBody(metadataResponse.document) ?? {}) : null;
  const types = simplifyResourceTypes(resourceTypesResponse.document);
  const resourceEntries = rawExistingResources(resourcesResponse.document);
  const folderEntries = foldersResponse.status >= 200 && foldersResponse.status < 300
    ? rawExistingFolders(foldersResponse.document)
    : [];
  const jwtEnabled = Boolean(settingsValue(settings, ['passbolt', 'plugins', 'jwtAuthentication', 'enabled'], false));
  const allowV4 = metadataSettings === null ? true : Boolean(metadataSettings.allow_creation_of_v4_resources);
  const allowV5 = metadataSettings === null ? false : Boolean(metadataSettings.allow_creation_of_v5_resources);
  const allowV4Folders = metadataSettings === null ? true : Boolean(metadataSettings.allow_creation_of_v4_folders);
  const allowV5Folders = metadataSettings === null ? false : Boolean(metadataSettings.allow_creation_of_v5_folders);
  const defaultResourceTypes = metadataSettings && typeof metadataSettings.default_resource_types === 'string'
    ? metadataSettings.default_resource_types
    : 'v4';
  const defaultFolderType = metadataSettings && typeof metadataSettings.default_folder_type === 'string'
    ? metadataSettings.default_folder_type
    : 'v4';

  const formatOrder = requestedFormat === 'auto'
    ? [...new Set([defaultResourceTypes === 'v5' ? 'v5' : 'v4', defaultResourceTypes === 'v5' ? 'v4' : 'v5'])]
    : [requestedFormat];
  let selectedFormat = null;
  let resourceType = null;
  for (const format of formatOrder) {
    const allowed = format === 'v5' ? allowV5 : allowV4;
    const candidateType = selectResourceType(types, format);
    if (allowed && candidateType) {
      selectedFormat = format;
      resourceType = candidateType;
      break;
    }
  }

  const folderFormatOrder = requestedFolderFormat === 'auto'
    ? [...new Set([defaultFolderType === 'v5' ? 'v5' : 'v4', defaultFolderType === 'v5' ? 'v4' : 'v5'])]
    : [requestedFolderFormat];
  let selectedFolderFormat = null;
  if (needsClientFolderMapping) {
    selectedFolderFormat = folderFormatOrder.find((format) => (
      format === 'v5' ? allowV5Folders : allowV4Folders
    )) ?? null;
  }

  const needsMetadataSupport = selectedFormat === 'v5'
    || selectedFolderFormat === 'v5'
    || resourceEntries.some(isEncryptedMetadataResource)
    || (needsFolderInventory && folderEntries.some(isEncryptedMetadataFolder));
  let metadataKeySettings = null;
  let metadataKeyList = [];
  if (needsMetadataSupport) {
    const [keySettingsResponse, keysResponse] = await Promise.all([
      session.request('/metadata/keys/settings.json?api-version=v2', { allowError: true }),
      session.request('/metadata/keys.json?api-version=v2&contain[metadata_private_keys]=1', { allowError: true }),
    ]);
    if (keySettingsResponse.status >= 200 && keySettingsResponse.status < 300) {
      metadataKeySettings = apiBody(keySettingsResponse.document) ?? {};
    }
    if (keysResponse.status >= 200 && keysResponse.status < 300) {
      metadataKeyList = metadataKeyEntries(keysResponse.document);
    }
  }
  const sharedKeyEntries = new Map(metadataKeyList.map((entry) => [String(entry.id), entry]));
  const sharedKeyCache = new Map();
  let shareDirectory = null;
  if (shareDirectoryResponse.status >= 200 && shareDirectoryResponse.status < 300 && keyMaterial) {
    try {
      shareDirectory = await buildShareDirectory(shareDirectoryResponse.document, user, keyMaterial);
    } catch {
      shareDirectory = null;
    }
  }
  const permissionConfiguration = buildPermissionConfiguration(
    permissionModeValue,
    permissionTemplateValue,
    shareDirectory,
    String(user.id ?? ''),
  );
  let duplicateDetectionAvailable = true;
  let duplicateFailure = null;
  let existingResources = [];
  try {
    existingResources = await decryptExistingResources(resourceEntries, user, keyMaterial, session.baseUrl, sharedKeyEntries, sharedKeyCache);
  } catch (error) {
    duplicateDetectionAvailable = false;
    duplicateFailure = error instanceof SafeError ? error.message : 'I metadati esistenti non possono essere confrontati in sicurezza.';
  }

  let folderDetectionAvailable = !needsFolderInventory;
  let folderFailure = null;
  let existingFolders = [];
  if (needsFolderInventory) {
    try {
      existingFolders = await decryptExistingFolders(folderEntries, user, keyMaterial, session.baseUrl, sharedKeyEntries, sharedKeyCache, shareDirectory);
      folderDetectionAvailable = true;
    } catch (error) {
      folderFailure = error instanceof SafeError ? error.message : 'I metadati delle cartelle non possono essere letti in sicurezza.';
    }
  }

  let metadataEncryptionKey = null;
  let metadataKeyFailure = null;
  if (selectedFormat === 'v5' || selectedFolderFormat === 'v5') {
    if (!keyMaterial) {
      metadataKeyFailure = 'La chiave utente e necessaria per preparare contenuti v5.';
    } else if (!metadataKeySettings) {
      metadataKeyFailure = 'Le impostazioni delle chiavi metadati v5 non sono leggibili.';
    } else if (Boolean(metadataKeySettings.allow_usage_of_personal_keys)) {
      const userGpgKeyId = String(user.gpgkey?.id ?? '');
      if (!userGpgKeyId) {
        metadataKeyFailure = 'Passbolt non ha restituito l’identificatore della chiave personale dell’utente.';
      } else {
        metadataEncryptionKey = {
          id: userGpgKeyId,
          type: 'user_key',
          fingerprint: keyMaterial.fingerprint,
          publicKey: keyMaterial.publicKey,
        };
      }
    } else {
      const newest = newestMetadataKey(metadataKeyList);
      if (!newest) {
        metadataKeyFailure = 'Passbolt non ha restituito una chiave metadati condivisa attiva.';
      } else {
        try {
          metadataEncryptionKey = sharedKeyCache.get(String(newest.id))
            ?? await loadSharedMetadataKey(newest, user, keyMaterial, session.baseUrl);
          sharedKeyCache.set(String(newest.id), metadataEncryptionKey);
        } catch (error) {
          metadataKeyFailure = error instanceof SafeError ? error.message : 'La chiave metadati condivisa non puo essere verificata.';
        }
      }
    }
  }
  if (metadataKeyFailure) {
    if (selectedFormat === 'v5' && requestedFormat === 'auto') {
      const fallbackV4Type = allowV4 ? selectResourceType(types, 'v4') : null;
      if (fallbackV4Type) {
        selectedFormat = 'v4';
        resourceType = fallbackV4Type;
      }
    }
    if (selectedFolderFormat === 'v5' && requestedFolderFormat === 'auto' && allowV4Folders) {
      selectedFolderFormat = 'v4';
    }
    if (selectedFormat !== 'v5' && selectedFolderFormat !== 'v5') {
      metadataEncryptionKey = null;
      metadataKeyFailure = null;
    }
  }

  const folderCatalog = folderDetectionAvailable && needsFolderInventory
    ? buildFolderCatalog(existingFolders)
    : [];
  let destinationPlan = applyPermissionConfiguration(planDestinations(
    candidates,
    folderCatalog,
    existingResources,
    destinationMode,
    selectedFolderFormat,
    destinationFolderId,
    clientDestinationMapping,
  ), permissionConfiguration);
  let candidatePlan = buildCandidatePlan(candidates, existingResources, duplicateDetectionAvailable, destinationPlan.destinations);
  const activePermissionConflict = candidatePlan.find((item) => item.action === 'create' && item.permission_template_conflict);
  if (!destinationPlan.failure && activePermissionConflict) {
    destinationPlan.failure = activePermissionConflict.permission_template_conflict_reason;
  }
  let activeFolderKeys = new Set(candidatePlan.filter((item) => item.action === 'create').map((item) => item.destination_key));
  let folderPlan = destinationPlan.folders.filter((folder) => folder.action === 'reuse' || activeFolderKeys.has(folder.destination_key));
  let sharedCreateCount = candidatePlan.filter((item) => item.action === 'create' && item.shared).length;
  let sharedFolderCreateCount = folderPlan.filter((item) => item.action === 'create' && item.shared).length;
  let sharedMetadataEncryptionKey = metadataEncryptionKey?.type === 'shared_key' ? metadataEncryptionKey : null;
  let sharedMetadataKeyFailure = null;
  let sharedResourceMetadataRequired = selectedFormat === 'v5' && sharedCreateCount > 0;
  let sharedFolderMetadataRequired = selectedFolderFormat === 'v5' && sharedFolderCreateCount > 0;
  if ((sharedResourceMetadataRequired || sharedFolderMetadataRequired) && !sharedMetadataEncryptionKey) {
    const newest = newestMetadataKey(metadataKeyList);
    if (!newest) {
      sharedMetadataKeyFailure = 'I contenuti v5 condivisi richiedono una chiave metadati condivisa attiva, ma Passbolt non ne ha restituita una.';
    } else {
      try {
        sharedMetadataEncryptionKey = sharedKeyCache.get(String(newest.id))
          ?? await loadSharedMetadataKey(newest, user, keyMaterial, session.baseUrl);
        sharedKeyCache.set(String(newest.id), sharedMetadataEncryptionKey);
      } catch (error) {
        sharedMetadataKeyFailure = error instanceof SafeError ? error.message : 'La chiave metadati condivisa non puo essere verificata.';
      }
    }
    if (sharedMetadataKeyFailure && sharedResourceMetadataRequired && requestedFormat === 'auto') {
      const fallbackV4Type = allowV4 ? selectResourceType(types, 'v4') : null;
      if (fallbackV4Type) {
        selectedFormat = 'v4';
        resourceType = fallbackV4Type;
      }
    }
    if (sharedMetadataKeyFailure && sharedFolderMetadataRequired && requestedFolderFormat === 'auto' && allowV4Folders) {
      selectedFolderFormat = 'v4';
      destinationPlan = applyPermissionConfiguration(planDestinations(
        candidates,
        folderCatalog,
        existingResources,
        destinationMode,
        selectedFolderFormat,
        destinationFolderId,
        clientDestinationMapping,
      ), permissionConfiguration);
      candidatePlan = buildCandidatePlan(candidates, existingResources, duplicateDetectionAvailable, destinationPlan.destinations);
      const fallbackPermissionConflict = candidatePlan.find((item) => item.action === 'create' && item.permission_template_conflict);
      if (!destinationPlan.failure && fallbackPermissionConflict) {
        destinationPlan.failure = fallbackPermissionConflict.permission_template_conflict_reason;
      }
      activeFolderKeys = new Set(candidatePlan.filter((item) => item.action === 'create').map((item) => item.destination_key));
      folderPlan = destinationPlan.folders.filter((folder) => folder.action === 'reuse' || activeFolderKeys.has(folder.destination_key));
      sharedCreateCount = candidatePlan.filter((item) => item.action === 'create' && item.shared).length;
      sharedFolderCreateCount = folderPlan.filter((item) => item.action === 'create' && item.shared).length;
    }
    sharedResourceMetadataRequired = selectedFormat === 'v5' && sharedCreateCount > 0;
    sharedFolderMetadataRequired = selectedFolderFormat === 'v5' && sharedFolderCreateCount > 0;
    if (!sharedResourceMetadataRequired && !sharedFolderMetadataRequired) {
      sharedMetadataKeyFailure = null;
    }
  }
  if (selectedFormat !== 'v5' && selectedFolderFormat !== 'v5') {
    metadataEncryptionKey = null;
  }
  const sharedMetadataKeyInUse = sharedResourceMetadataRequired || sharedFolderMetadataRequired;
  const blockedCount = candidatePlan.filter((item) => item.action === 'blocked').length;
  const csrfAvailable = Boolean(session.csrfToken);
  const folderFormatAvailable = !needsClientFolderMapping || Boolean(selectedFolderFormat);
  const canImport = Boolean(resourceType)
    && folderFormatAvailable
    && duplicateDetectionAvailable
    && folderDetectionAvailable
    && !destinationPlan.failure
    && blockedCount === 0
    && csrfAvailable
    && !metadataKeyFailure
    && !sharedMetadataKeyFailure;
  let reason = null;
  if (!resourceType) {
    reason = requestedFormat === 'auto'
      ? 'Il server non consente alcun tipo password v4 o v5 compatibile.'
      : `Il server non consente un tipo password ${requestedFormat} compatibile.`;
  } else if (!folderFormatAvailable) {
    reason = requestedFolderFormat === 'auto'
      ? 'Il server non consente alcun formato cartella v4 o v5 compatibile.'
      : `Il server non consente cartelle ${requestedFolderFormat}.`;
  } else if (!duplicateDetectionAvailable) {
    reason = duplicateFailure;
  } else if (!folderDetectionAvailable) {
    reason = folderFailure;
  } else if (destinationPlan.failure) {
    reason = destinationPlan.failure;
  } else if (blockedCount > 0) {
    reason = `${blockedCount} credenziali esistono in una cartella diversa dalla destinazione prevista. Il piano e bloccato per evitare spostamenti impliciti.`;
  } else if (metadataKeyFailure) {
    reason = metadataKeyFailure;
  } else if (sharedMetadataKeyFailure) {
    reason = sharedMetadataKeyFailure;
  } else if (!csrfAvailable) {
    reason = 'Il server non ha fornito il token CSRF richiesto per una scrittura sicura.';
  }
  const permissionDirectoryRequired = permissionConfiguration.mode === 'custom'
    || candidatePlan.some((item) => item.action === 'create' && item.shared)
    || folderPlan.some((item) => ['create', 'repair_share'].includes(item.action) && item.shared);
  const metadataKeyRequired = selectedFormat === 'v5' || selectedFolderFormat === 'v5';
  const preflightChecks = [
    {
      id: 'authenticated_identity',
      label: 'Identita autenticata',
      status: 'passed',
      detail: 'Sessione GPGAuth e identita Passbolt verificate.',
    },
    {
      id: 'csrf_token',
      label: 'Protezione CSRF',
      status: csrfAvailable ? 'passed' : 'blocked',
      detail: csrfAvailable ? 'Token di scrittura disponibile.' : 'Token di scrittura non disponibile.',
    },
    {
      id: 'resource_format',
      label: 'Formato risorse',
      status: resourceType ? 'passed' : 'blocked',
      detail: resourceType
        ? `Formato ${selectedFormat}; tipo ${resourceType.slug}.`
        : 'Nessun tipo password compatibile e consentito dal server.',
    },
    {
      id: 'folder_format',
      label: 'Formato cartelle',
      status: needsClientFolderMapping ? (folderFormatAvailable ? 'passed' : 'blocked') : 'not_required',
      detail: needsClientFolderMapping
        ? (folderFormatAvailable ? `Formato ${selectedFolderFormat}.` : 'Nessun formato cartella compatibile disponibile.')
        : 'Il piano non deve creare cartelle per cliente.',
    },
    {
      id: 'metadata_key',
      label: 'Chiave metadati v5',
      status: metadataKeyRequired ? ((!metadataKeyFailure && !sharedMetadataKeyFailure) ? 'passed' : 'blocked') : 'not_required',
      detail: metadataKeyRequired
        ? ((!metadataKeyFailure && !sharedMetadataKeyFailure) ? 'Chiave v5 selezionata e verificata.' : (metadataKeyFailure || sharedMetadataKeyFailure))
        : 'Il piano usa esclusivamente contenuti v4.',
    },
    {
      id: 'resource_catalog',
      label: 'Catalogo risorse',
      status: duplicateDetectionAvailable ? 'passed' : 'blocked',
      detail: duplicateDetectionAvailable
        ? `${resourceEntries.length} risorse remote confrontate per i duplicati.`
        : (duplicateFailure || 'Confronto duplicati non disponibile.'),
    },
    {
      id: 'folder_catalog',
      label: 'Catalogo cartelle',
      status: needsFolderInventory ? (folderDetectionAvailable ? 'passed' : 'blocked') : 'not_required',
      detail: needsFolderInventory
        ? (folderDetectionAvailable ? `${folderEntries.length} cartelle remote verificate.` : (folderFailure || 'Catalogo cartelle non disponibile.'))
        : 'La destinazione e la radice personale.',
    },
    {
      id: 'permission_directory',
      label: 'Directory permessi',
      status: permissionDirectoryRequired ? (shareDirectory ? 'passed' : 'blocked') : (shareDirectory ? 'passed' : 'not_required'),
      detail: shareDirectory
        ? 'Utenti, gruppi e chiavi pubbliche sono disponibili.'
        : (permissionDirectoryRequired ? 'La condivisione richiede una directory autenticata leggibile.' : 'Nessuna condivisione richiede la directory nel piano corrente.'),
    },
    {
      id: 'destination_access',
      label: 'Accesso destinazione',
      status: destinationPlan.failure ? 'blocked' : 'passed',
      detail: destinationPlan.failure || 'Destinazioni risolte con diritto di creazione.',
    },
    {
      id: 'conflicts',
      label: 'Conflitti e duplicati',
      status: blockedCount > 0 ? 'blocked' : 'passed',
      detail: blockedCount > 0
        ? `${blockedCount} credenziali richiedono una decisione prima della scrittura.`
        : `${candidatePlan.filter((item) => item.action === 'duplicate').length} duplicati saranno saltati in sicurezza.`,
    },
  ];
  const preflightStatus = preflightChecks.some((item) => item.status === 'blocked')
    ? 'blocked'
    : (preflightChecks.some((item) => item.status === 'warning') ? 'warning' : 'passed');
  const digestPayload = {
    user_id: String(user.id),
    resource_format_requested: requestedFormat,
    resource_format_selected: selectedFormat,
    resource_type_id: resourceType?.id ?? null,
    resource_type_slug: resourceType?.slug ?? null,
    destination_mode: destinationMode,
    destination_folder_id: destinationFolderId,
    client_destination_mapping: clientDestinationMapping.entries,
    permission_mode: permissionConfiguration.mode,
    permission_template: permissionConfiguration.template,
    permission_configuration_hash: permissionConfiguration.configuration_hash,
    folder_format_requested: requestedFolderFormat,
    folder_format_selected: selectedFolderFormat,
    metadata_key_id: metadataEncryptionKey?.id ?? null,
    metadata_key_type: metadataEncryptionKey?.type ?? null,
    shared_metadata_key_id: sharedMetadataEncryptionKey?.id ?? null,
    shared_metadata_key_type: sharedMetadataEncryptionKey?.type ?? null,
    shared_create_count: sharedCreateCount,
    shared_folder_create_count: sharedFolderCreateCount,
    existing_resource_count: resourceEntries.length,
    existing_folder_count: folderEntries.length,
    folders: folderPlan,
    candidates: candidatePlan,
  };
  const capabilities = {
    settings: {
      metadata_enabled: metadataEnabled,
      jwt_enabled: jwtEnabled,
      default_resource_types: defaultResourceTypes,
      allow_creation_of_v4_resources: allowV4,
      allow_creation_of_v5_resources: allowV5,
      default_folder_type: defaultFolderType,
      allow_creation_of_v4_folders: allowV4Folders,
      allow_creation_of_v5_folders: allowV5Folders,
      allow_usage_of_personal_metadata_keys: metadataKeySettings === null ? null : Boolean(metadataKeySettings.allow_usage_of_personal_keys),
    },
    resource_format_requested: requestedFormat,
    resource_format_selected: selectedFormat,
    destination_mode: destinationMode,
    destination_folder_id: destinationFolderId,
    client_destination_mapping: clientDestinationMapping.entries,
    permission_mode: permissionConfiguration.mode,
    permission_configuration_hash: permissionConfiguration.configuration_hash,
    permission_template_entry_count: permissionConfiguration.template.length,
    required_clients: clientDestinationMapping.requiredClients,
    folder_format_requested: requestedFolderFormat,
    folder_format_selected: selectedFolderFormat,
    resource_type: resourceType ? { id: resourceType.id, slug: resourceType.slug, name: resourceType.name } : null,
    metadata_key: (selectedFormat === 'v5' || selectedFolderFormat === 'v5')
      ? (() => {
        const displayedKey = sharedMetadataKeyInUse ? sharedMetadataEncryptionKey : metadataEncryptionKey;
        return displayedKey ? { id: displayedKey.id, type: displayedKey.type, fingerprint: displayedKey.fingerprint } : null;
      })()
      : null,
    existing_resource_count: resourceEntries.length,
    existing_folder_count: folderEntries.length,
    folder_detection_available: folderDetectionAvailable,
    duplicate_detection_available: duplicateDetectionAvailable,
    csrf_token_available: csrfAvailable,
    preflight_status: preflightStatus,
    preflight_checks: preflightChecks,
    can_import: canImport,
    unavailable_reason: reason,
    available_folders: folderCatalog.filter((folder) => folder.can_create).map((folder) => ({
      id: folder.id,
      name: folder.name,
      folder_parent_id: folder.folder_parent_id,
      path: folder.path,
      permission_type: folder.permission_type,
      personal: folder.personal,
      shared: folder.shared,
      share_recipient_count: folder.share_recipients.length,
      share_permission_count: folder.share_permissions.length,
    })),
    folders: folderPlan,
    candidates: candidatePlan,
    create_count: candidatePlan.filter((item) => item.action === 'create').length,
    duplicate_count: candidatePlan.filter((item) => item.action === 'duplicate').length,
    blocked_count: blockedCount,
    shared_create_count: sharedCreateCount,
    encrypted_secret_copy_count: candidatePlan
      .filter((item) => item.action === 'create')
      .reduce((total, item) => total + (item.shared ? item.share_recipient_count : 1), 0),
    create_folder_count: folderPlan.filter((item) => item.action === 'create').length,
    create_shared_folder_count: sharedFolderCreateCount,
    reconcile_shared_folder_count: folderPlan.filter((item) => item.action === 'repair_share').length,
    reuse_folder_count: folderPlan.filter((item) => item.action === 'reuse').length,
    plan_digest: digestPlan(digestPayload),
  };
  return {
    capabilities,
    runtime: {
      resourceType,
      selectedFormat,
      selectedFolderFormat,
      metadataEncryptionKey,
      sharedMetadataEncryptionKey,
      shareDirectory,
      permissionConfiguration,
      folders: folderPlan,
      destinationFolders: destinationPlan.folders,
      existingFolders: folderCatalog,
      existingResources,
    },
  };
}

async function readCapabilities(session, user, candidates, keyMaterial = null, resourceFormat = 'auto', destinationMode = 'client_folders', folderFormat = 'auto', destinationFolderId = null, clientDestinationMapping = null, permissionMode = 'inherited', permissionTemplate = null) {
  return (await analyzeCapabilities(session, user, candidates, keyMaterial, resourceFormat, destinationMode, folderFormat, destinationFolderId, clientDestinationMapping, permissionMode, permissionTemplate)).capabilities;
}

async function inspectKey(input) {
  const key = await loadPrivateKey(input.private_key_path, input.passphrase);
  return {
    command: 'inspect-key',
    fingerprint: key.fingerprint,
    key_id: key.keyId,
    user_ids: key.userIds,
    key_was_encrypted: key.encrypted,
    private_key_valid: true,
  };
}

async function readiness(input) {
  const baseUrl = normalizeBaseUrl(input.base_url);
  const expectedFingerprint = normalizeFingerprint(input.expected_server_fingerprint, 'Fingerprint attesa del server');
  const candidates = safeCandidates(input.candidates);
  const key = await loadPrivateKey(input.private_key_path, input.passphrase);
  const session = new PassboltSession(baseUrl);
  try {
    const { user, mfaProvider } = await authenticate(session, key, expectedFingerprint, input.mfa_totp);
    const capabilities = await readCapabilities(
      session,
      user,
      candidates,
      key,
      input.resource_format,
      input.destination_mode,
      input.folder_format,
      input.destination_folder_id,
      input.client_destination_mapping,
      input.permission_mode,
      input.permission_template,
    );
    return {
      command: 'readiness',
      authentication: mfaProvider ? 'GPGAuth + TOTP' : 'GPGAuth',
      mfa_provider: mfaProvider,
      base_url: baseUrl,
      server_fingerprint: expectedFingerprint,
      user_key_fingerprint: key.fingerprint,
      user: safeUser(user),
      ...capabilities,
    };
  } finally {
    await logout(session);
  }
}

async function encryptSecret(password, description, resourceType, key, encryptionPublicKey = null) {
  const secretFields = { password };
  const descriptionInMetadata = resourceDescriptionIsMetadata(resourceType);
  if (!descriptionInMetadata && !resourceSecretIsString(resourceType)) {
    secretFields.description = description || '';
  }
  if (String(resourceType?.slug ?? '').startsWith('v5-') && !resourceSecretIsString(resourceType)) {
    secretFields.object_type = SECRET_DATA_OBJECT_TYPE;
  }
  const cleartext = resourceSecretIsString(resourceType) ? password : JSON.stringify(secretFields);
  return openpgp.encrypt({
    message: await openpgp.createMessage({ text: cleartext }),
    encryptionKeys: encryptionPublicKey ?? key.publicKey,
    signingKeys: key.privateKey,
    format: 'armored',
  });
}

async function buildFolderPayload(folder, runtime, keyMaterial) {
  assert(folder && folder.action === 'create', 'FOLDER_PLAN_INVALID', 'La cartella da creare non appartiene al piano.');
  assert(typeof folder.name === 'string' && folder.name.length > 0, 'FOLDER_PLAN_INVALID', 'La cartella da creare non contiene un nome valido.');
  assert(['v4', 'v5'].includes(folder.format), 'FOLDER_FORMAT_UNAVAILABLE', 'Il formato della cartella da creare non e disponibile.');
  if (folder.format === 'v4') {
    return {
      name: folder.name,
      folder_parent_id: folder.folder_parent_id ?? null,
    };
  }

  const metadataEncryptionKey = folder.shared
    ? runtime.sharedMetadataEncryptionKey
    : runtime.metadataEncryptionKey;
  assert(metadataEncryptionKey?.publicKey, 'METADATA_KEY_UNAVAILABLE', 'La chiave di cifratura dei metadati v5 non e disponibile.');
  const clearMetadata = JSON.stringify({
    object_type: FOLDER_METADATA_OBJECT_TYPE,
    name: folder.name,
  });
  const encryptedMetadata = await openpgp.encrypt({
    message: await openpgp.createMessage({ text: clearMetadata }),
    encryptionKeys: metadataEncryptionKey.publicKey,
    signingKeys: keyMaterial.privateKey,
    format: 'armored',
  });
  return {
    metadata: encryptedMetadata,
    metadata_key_id: metadataEncryptionKey.id,
    metadata_key_type: metadataEncryptionKey.type,
    folder_parent_id: folder.folder_parent_id ?? null,
  };
}

async function buildResourcePayload(resource, runtime, keyMaterial, folderParentId = null) {
  const resourceType = runtime.resourceType;
  assert(resourceType && runtime.selectedFormat, 'RESOURCE_TYPE_UNAVAILABLE', 'Il tipo di risorsa selezionato non e disponibile.');
  const v5 = runtime.selectedFormat === 'v5';
  const descriptionInMetadata = resourceDescriptionIsMetadata(resourceType);
  const metadataFields = {
    name: resource.title,
    username: resource.username,
    ...(v5 ? { uris: [resource.uri] } : { uri: resource.uri }),
    ...(descriptionInMetadata ? { description: resource.description || '' } : {}),
  };
  const encryptedSecret = await encryptSecret(resource.password, resource.description, resourceType, keyMaterial);

  if (!v5) {
    return {
      ...metadataFields,
      resource_type_id: resourceType.id,
      folder_parent_id: folderParentId,
      secrets: [{ data: encryptedSecret }],
    };
  }

  const metadataEncryptionKey = resource.shared
    ? runtime.sharedMetadataEncryptionKey
    : runtime.metadataEncryptionKey;
  assert(metadataEncryptionKey?.publicKey, 'METADATA_KEY_UNAVAILABLE', 'La chiave di cifratura dei metadati v5 non e disponibile.');
  const clearMetadata = JSON.stringify({
    ...metadataFields,
    object_type: RESOURCE_METADATA_OBJECT_TYPE,
    resource_type_id: resourceType.id,
  });
  const encryptedMetadata = await openpgp.encrypt({
    message: await openpgp.createMessage({ text: clearMetadata }),
    encryptionKeys: metadataEncryptionKey.publicKey,
    signingKeys: keyMaterial.privateKey,
    format: 'armored',
  });
  return {
    resource_type_id: resourceType.id,
    metadata_key_id: metadataEncryptionKey.id,
    metadata_key_type: metadataEncryptionKey.type,
    metadata: encryptedMetadata,
    folder_parent_id: folderParentId,
    expired: null,
    secrets: [{ data: encryptedSecret }],
  };
}

function buildPermissionChanges(createdPermission, targetPermissions, aco, foreignId) {
  const subjectLabel = aco === 'Folder' ? 'cartella' : 'risorsa';
  assert(createdPermission && typeof createdPermission === 'object', 'CREATED_PERMISSION_MISSING', `Passbolt non ha restituito il permesso della ${subjectLabel} appena creata.`);
  const currentId = String(createdPermission.id ?? '');
  const currentAro = String(createdPermission.aro ?? '');
  const currentAroForeignKey = String(createdPermission.aro_foreign_key ?? '');
  const currentType = normalizePermissionType(createdPermission.type);
  assert(currentId && ['User', 'Group'].includes(currentAro) && currentAroForeignKey && currentType !== null, 'CREATED_PERMISSION_INVALID', `Il permesso della ${subjectLabel} appena creata non e utilizzabile per applicare la maschera del contenitore.`);
  const expected = normalizeFolderPermissions(targetPermissions).map((permission) => ({
    aco,
    aco_foreign_key: foreignId,
    aro: permission.aro,
    aro_foreign_key: permission.aro_foreign_key,
    type: permission.type,
  }));
  assert(expected.length > 0, 'SHARE_PERMISSIONS_MISSING', 'Il contenitore condiviso non contiene una maschera di permessi valida.');
  const changes = [];
  let currentRetained = false;
  for (const permission of expected) {
    if (permission.aro === currentAro && permission.aro_foreign_key === currentAroForeignKey) {
      currentRetained = true;
      if (permission.type !== currentType) {
        changes.push({ ...permission, id: currentId });
      }
    } else {
      changes.push({ ...permission, is_new: true });
    }
  }
  if (!currentRetained) {
    changes.push({
      id: currentId,
      delete: true,
      aco,
      aco_foreign_key: foreignId,
      aro: currentAro,
      aro_foreign_key: currentAroForeignKey,
      type: currentType,
    });
  }
  return changes;
}

function buildResourcePermissionChanges(createdPermission, folderPermissions, resourceId) {
  return buildPermissionChanges(createdPermission, folderPermissions, 'Resource', resourceId);
}

function buildFolderPermissionChanges(createdPermission, parentPermissions, folderId) {
  return buildPermissionChanges(createdPermission, parentPermissions, 'Folder', folderId);
}

function simulatedUserChanges(document) {
  const body = apiBody(document);
  const changes = body && typeof body === 'object' ? body.changes : null;
  assert(changes && typeof changes === 'object', 'SHARE_SIMULATION_INVALID', 'La simulazione Passbolt non contiene il riepilogo delle modifiche.');
  const added = Array.isArray(changes.added) ? changes.added : [];
  const removed = Array.isArray(changes.removed) ? changes.removed : [];
  const userIds = (items, label) => {
    const ids = [];
    for (const item of items) {
      const id = String(item?.User?.id ?? '');
      assert(id, 'SHARE_SIMULATION_INVALID', `La simulazione Passbolt contiene un destinatario ${label} non riconoscibile.`);
      assert(!ids.includes(id), 'SHARE_SIMULATION_INVALID', `La simulazione Passbolt contiene due volte lo stesso destinatario ${label}.`);
      ids.push(id);
    }
    return ids.sort();
  };
  const addedUserIds = userIds(added, 'aggiunto');
  const removedUserIds = userIds(removed, 'rimosso');
  assert(!addedUserIds.some((id) => removedUserIds.includes(id)), 'SHARE_SIMULATION_INVALID', 'La simulazione Passbolt aggiunge e rimuove lo stesso destinatario.');
  return { addedUserIds, removedUserIds };
}

function sameStringSet(left, right) {
  const normalizedLeft = [...new Set(left.map(String))].sort();
  const normalizedRight = [...new Set(right.map(String))].sort();
  return normalizedLeft.length === normalizedRight.length
    && normalizedLeft.every((value, index) => value === normalizedRight[index]);
}

function buildExistingPermissionChanges(target, desiredPermissions, permissionRecords, currentUserId) {
  const objectType = normalizeAclObjectType(target?.object_type);
  const objectId = normalizeAclObjectId(target?.object_id);
  const aco = objectType === 'folder' ? 'Folder' : 'Resource';
  const currentPermissions = aclMaskFromRows(target?.permissions);
  const currentBySubject = new Map(currentPermissions.map((permission) => [`${permission.aro}:${permission.aro_foreign_key}`, permission]));
  const desired = normalizeFolderPermissions(desiredPermissions);
  const desiredBySubject = new Map(desired.map((permission) => [`${permission.aro}:${permission.aro_foreign_key}`, permission]));
  assert(
    currentBySubject.get(`User:${currentUserId}`)?.type === 15
    && desiredBySubject.get(`User:${currentUserId}`)?.type === 15,
    'ACL_APPLY_CURRENT_OWNER_AT_RISK',
    'Il proprietario autenticato non e conservato come Owner; nessuna modifica e stata applicata.',
  );
  assert(desired.some((permission) => permission.type === 15), 'ACL_APPLY_LAST_OWNER_BLOCKED', 'Il piano eliminerebbe l’ultimo proprietario dell’oggetto.');
  assert(Array.isArray(permissionRecords) && permissionRecords.length === currentPermissions.length, 'ACL_APPLY_PERMISSION_RECORDS_INCOMPLETE', 'Passbolt non ha restituito gli identificativi completi dei permessi correnti.');
  const recordBySubject = new Map();
  for (const record of permissionRecords) {
    assert(
      record?.id
      && record.aco === aco
      && record.aco_foreign_key === objectId
      && ['User', 'Group'].includes(record.aro)
      && record.aro_foreign_key
      && record.type !== null,
      'ACL_APPLY_PERMISSION_RECORD_INVALID',
      'Un permesso corrente non contiene gli identificativi tecnici necessari per un aggiornamento sicuro.',
    );
    const key = `${record.aro}:${record.aro_foreign_key}`;
    assert(!recordBySubject.has(key), 'ACL_APPLY_PERMISSION_RECORD_INVALID', 'Passbolt ha restituito due record per lo stesso soggetto ACL.');
    recordBySubject.set(key, record);
  }
  const changes = [];
  const keys = [...new Set([...currentBySubject.keys(), ...desiredBySubject.keys()])].sort();
  for (const key of keys) {
    const before = currentBySubject.get(key);
    const after = desiredBySubject.get(key);
    if (before && after && before.type === after.type) continue;
    if (!after) {
      const record = recordBySubject.get(key);
      assert(record?.id && before, 'ACL_APPLY_PERMISSION_RECORD_INVALID', 'La revoca non dispone dell’identificativo del permesso corrente.');
      changes.push({
        id: record.id,
        delete: true,
        aco,
        aco_foreign_key: objectId,
        aro: before.aro,
        aro_foreign_key: before.aro_foreign_key,
        type: before.type,
      });
      continue;
    }
    const base = {
      aco,
      aco_foreign_key: objectId,
      aro: after.aro,
      aro_foreign_key: after.aro_foreign_key,
      type: after.type,
    };
    if (before) {
      const record = recordBySubject.get(key);
      assert(record?.id, 'ACL_APPLY_PERMISSION_RECORD_INVALID', 'La modifica di livello non dispone dell’identificativo del permesso corrente.');
      changes.push({ ...base, id: record.id });
    } else {
      changes.push({ ...base, is_new: true });
    }
  }
  assert(changes.length > 0, 'ACL_APPLY_NOTHING_TO_DO', 'La ACL remota corrisponde gia alla ACL desiderata. Aggiornare il catalogo.');
  return changes;
}

async function encryptClearSecret(cleartext, keyMaterial, encryptionPublicKey) {
  assert(typeof cleartext === 'string' && Buffer.byteLength(cleartext, 'utf8') <= 1024 * 1024, 'ACL_RESOURCE_SECRET_TOO_LARGE', 'Il segreto della risorsa supera il limite sicuro di 1 MiB.');
  return openpgp.encrypt({
    message: await openpgp.createMessage({ text: cleartext }),
    encryptionKeys: encryptionPublicKey,
    signingKeys: keyMaterial.privateKey,
    format: 'armored',
  });
}

async function readExistingResourceSecret(session, resourceId, keyMaterial, currentUserId) {
  const response = await session.request(`/secrets/resource/${resourceId}.json?api-version=v2`, { allowError: true });
  if (response.status < 200 || response.status >= 300) {
    throw new SafeError(
      'ACL_RESOURCE_SECRET_READ_FAILED',
      apiMessage(response.document, `Lettura del segreto esistente non riuscita (HTTP ${response.status}).`),
      { http_status: response.status },
    );
  }
  const body = apiBody(response.document);
  const secret = Array.isArray(body)
    ? body.find((entry) => String(entry?.resource_id ?? '') === resourceId && String(entry?.user_id ?? '') === currentUserId)
    : body;
  assert(
    secret
    && typeof secret === 'object'
    && String(secret.resource_id ?? resourceId) === resourceId
    && String(secret.user_id ?? '') === currentUserId,
    'ACL_RESOURCE_SECRET_INVALID',
    'Passbolt non ha restituito il segreto della risorsa per l’utente autenticato.',
  );
  const armored = String(secret.data ?? '');
  assert(armored.includes('-----BEGIN PGP MESSAGE-----'), 'ACL_RESOURCE_SECRET_INVALID', 'Il segreto restituito da Passbolt non e un messaggio OpenPGP valido.');
  const cleartext = await decryptMessageText(
    armored,
    keyMaterial.privateKey,
    undefined,
    false,
    'ACL_RESOURCE_SECRET_DECRYPT_FAILED',
    'Il segreto esistente non puo essere decifrato con la chiave della sessione.',
  );
  assert(Buffer.byteLength(cleartext, 'utf8') <= 1024 * 1024, 'ACL_RESOURCE_SECRET_TOO_LARGE', 'Il segreto della risorsa supera il limite sicuro di 1 MiB.');
  return cleartext;
}

async function simulateExistingAclChange(session, objectType, objectId, permissionChanges) {
  const simulation = await session.request(`/share/simulate/${objectType}/${objectId}.json?api-version=v2`, {
    method: 'POST',
    body: { permissions: permissionChanges },
    allowError: true,
  });
  if (simulation.status < 200 || simulation.status >= 300) {
    throw new SafeError(
      'ACL_APPLY_SIMULATION_FAILED',
      apiMessage(simulation.document, `La simulazione ACL ha restituito HTTP ${simulation.status}.`),
      { http_status: simulation.status },
    );
  }
  return simulatedUserChanges(simulation.document);
}

async function applyExistingAcl(session, target, desiredPermissions, runtime, keyMaterial, currentUserId, planCounts, progress) {
  const objectType = normalizeAclObjectType(target.object_type);
  const objectId = normalizeAclObjectId(target.object_id);
  const permissionRecords = runtime.permissionRecordsByObject.get(`${objectType}:${objectId}`);
  const permissionChanges = buildExistingPermissionChanges(target, desiredPermissions, permissionRecords, String(currentUserId));
  const currentPermissions = aclMaskFromRows(target.permissions);
  const currentEffective = aclEffectiveUserAccess(currentPermissions, runtime.shareDirectory);
  const desiredEffective = aclEffectiveUserAccess(desiredPermissions, runtime.shareDirectory);
  assert(desiredEffective.get(String(currentUserId)) === 15, 'ACL_APPLY_CURRENT_OWNER_AT_RISK', 'Il proprietario autenticato perderebbe il livello Owner.');
  const expectedAddedUserIds = [...desiredEffective.keys()].filter((id) => !currentEffective.has(id)).sort();
  const expectedRemovedUserIds = [...currentEffective.keys()].filter((id) => !desiredEffective.has(id)).sort();
  const { addedUserIds, removedUserIds } = await simulateExistingAclChange(session, objectType, objectId, permissionChanges);
  assert(
    sameStringSet(addedUserIds, expectedAddedUserIds) && sameStringSet(removedUserIds, expectedRemovedUserIds),
    'ACL_APPLY_SIMULATION_MISMATCH',
    'La simulazione Passbolt non coincide con gli utenti effettivi aggiunti o rimossi dal piano confermato.',
  );
  const plannedRecipientIds = new Set(desiredEffective.keys());
  const restrictiveChangeCount = Number(planCounts?.downgrade ?? 0) + Number(planCounts?.revoke ?? 0);
  const secrets = [];
  let cleartext = null;
  try {
    if (objectType === 'resource' && addedUserIds.length) {
      cleartext = await readExistingResourceSecret(session, objectId, keyMaterial, String(currentUserId));
      for (const userId of addedUserIds) {
        assert(plannedRecipientIds.has(userId), 'ACL_APPLY_SIMULATION_MISMATCH', 'La simulazione richiede il segreto per un destinatario esterno al piano confermato.');
        const recipient = runtime.shareDirectory.users.get(userId);
        assert(recipient?.active && recipient.publicKey && !recipient.key_error, 'ACL_APPLY_RECIPIENT_KEY_UNAVAILABLE', `La chiave pubblica del destinatario ${recipient?.username || userId} non e disponibile.`);
        secrets.push({ user_id: userId, data: await encryptClearSecret(cleartext, keyMaterial, recipient.publicKey) });
      }
    }
    assert(objectType === 'resource' || addedUserIds.length === 0 || addedUserIds.every((id) => plannedRecipientIds.has(id)), 'ACL_APPLY_SIMULATION_MISMATCH', 'La simulazione della cartella contiene destinatari esterni al piano confermato.');
    const operationId = randomUUID();
    await progress('acl_operation_intent', {
      operation_id: operationId,
      object_type: objectType,
      object_id: objectId,
      permission_change_count: permissionChanges.length,
      added_user_count: addedUserIds.length,
      removed_user_count: removedUserIds.length,
      restrictive_change_count: restrictiveChangeCount,
    });
    const endpoint = `/share/${objectType}/${objectId}.json?api-version=v2`;
    let response;
    try {
      response = await session.request(endpoint, {
        method: 'PUT',
        body: objectType === 'resource' ? { permissions: permissionChanges, secrets } : { permissions: permissionChanges },
        allowError: true,
      });
    } catch (error) {
      await progress('acl_operation_failed', {
        operation_id: operationId,
        object_type: objectType,
        object_id: objectId,
        error_code: error instanceof SafeError ? error.code : 'ACL_APPLY_FAILED',
        outcome: 'unknown',
      });
      throw error;
    }
    if (response.status < 200 || response.status >= 300) {
      await progress('acl_operation_failed', {
        operation_id: operationId,
        object_type: objectType,
        object_id: objectId,
        error_code: 'ACL_APPLY_FAILED',
        outcome: 'unknown',
        http_status: response.status,
      });
      throw new SafeError('ACL_APPLY_FAILED', apiMessage(response.document, `Applicazione ACL non riuscita (HTTP ${response.status}).`), { http_status: response.status });
    }
    await progress('acl_operation_applied', {
      operation_id: operationId,
      object_type: objectType,
      object_id: objectId,
      permission_change_count: permissionChanges.length,
      added_user_count: addedUserIds.length,
      removed_user_count: removedUserIds.length,
      restrictive_change_count: restrictiveChangeCount,
    });
    return {
      permissionChangeCount: permissionChanges.length,
      addedUserCount: addedUserIds.length,
      removedUserCount: removedUserIds.length,
      restrictiveChangeCount,
    };
  } finally {
    cleartext = null;
    secrets.length = 0;
  }
}

async function shareCreatedResource(session, resourceId, createdPermission, planned, resource, runtime, keyMaterial) {
  const permissionChanges = buildResourcePermissionChanges(createdPermission, planned.share_permissions, resourceId);
  const simulation = await session.request(`/share/simulate/resource/${resourceId}.json?api-version=v2`, {
    method: 'POST',
    body: { permissions: permissionChanges },
    allowError: true,
  });
  if (simulation.status < 200 || simulation.status >= 300) {
    throw new SafeError(
      'SHARE_SIMULATION_FAILED',
      apiMessage(simulation.document, `La simulazione della condivisione ha restituito HTTP ${simulation.status}.`),
      { http_status: simulation.status },
    );
  }

  const { addedUserIds, removedUserIds } = simulatedUserChanges(simulation.document);
  assert(removedUserIds.length === 0, 'SHARE_SIMULATION_RESTRICTIVE', 'La simulazione della nuova risorsa contiene rimozioni impreviste.');
  const plannedRecipientIds = new Set((Array.isArray(planned.share_recipients) ? planned.share_recipients : []).map((entry) => String(entry.user_id)));
  const secrets = [];
  for (const userId of addedUserIds) {
    assert(plannedRecipientIds.has(userId), 'SHARE_SIMULATION_MISMATCH', 'La simulazione richiede una copia del segreto per un destinatario diverso dal piano confermato.');
    const recipient = runtime.shareDirectory?.users?.get(userId);
    assert(recipient?.active && recipient.publicKey && !recipient.key_error, 'SHARE_RECIPIENT_KEY_UNAVAILABLE', `La chiave pubblica del destinatario ${recipient?.username || userId} non e disponibile.`);
    const data = await encryptSecret(resource.password, resource.description, runtime.resourceType, keyMaterial, recipient.publicKey);
    secrets.push({ user_id: userId, data });
  }

  const shared = await session.request(`/share/resource/${resourceId}.json?api-version=v2`, {
    method: 'PUT',
    body: { permissions: permissionChanges, secrets },
    allowError: true,
  });
  if (shared.status < 200 || shared.status >= 300) {
    throw new SafeError(
      'SHARE_APPLY_FAILED',
      apiMessage(shared.document, `La condivisione ha restituito HTTP ${shared.status}.`),
      { http_status: shared.status },
    );
  }
  return { encrypted_secret_copies: addedUserIds.length, permission_changes: permissionChanges.length };
}

async function shareCreatedFolder(session, folderId, createdPermission, planned) {
  const permissionChanges = buildFolderPermissionChanges(createdPermission, planned.share_permissions, folderId);
  const endpoint = `/share/folder/${folderId}.json?api-version=v2`;
  const shared = await session.request(endpoint, {
    method: 'PUT',
    body: { permissions: permissionChanges },
    allowError: true,
  });
  if (shared.status < 200 || shared.status >= 300) {
    throw new SafeError(
      'FOLDER_SHARE_APPLY_FAILED',
      `Applicazione dei permessi della cartella non riuscita su PUT ${endpoint} (HTTP ${shared.status}): ${apiMessage(shared.document, 'errore non specificato')}`,
      { http_status: shared.status, operation: 'folder_share_apply', endpoint },
    );
  }
  const currentUserId = String(createdPermission.aro === 'User' ? createdPermission.aro_foreign_key ?? '' : '');
  const addedUserCount = (Array.isArray(planned.share_recipients) ? planned.share_recipients : [])
    .filter((recipient) => String(recipient.user_id ?? '') !== currentUserId)
    .length;
  return { permission_changes: permissionChanges.length, added_user_count: addedUserCount };
}

function importResources(value, candidates) {
  assert(Array.isArray(value), 'IMPORT_DATA_REQUIRED', 'I dati da importare non sono presenti.');
  assert(value.length === candidates.length, 'IMPORT_DATA_MISMATCH', 'I dati estratti non corrispondono al piano confermato.');
  const candidateMap = new Map(candidates.map((item) => [item.candidate_id, item]));
  return value.map((item) => {
    assert(item && typeof item === 'object', 'INVALID_IMPORT_DATA', 'Un elemento da importare non e valido.');
    const candidateId = String(item.candidate_id ?? '');
    const candidate = candidateMap.get(candidateId);
    assert(candidate, 'IMPORT_DATA_MISMATCH', 'Un elemento estratto non appartiene al piano confermato.');
    assert(String(item.title ?? '') === candidate.title && String(item.username ?? '') === candidate.username && String(item.uri ?? '') === candidate.uri, 'IMPORT_DATA_MISMATCH', 'I metadati estratti sono cambiati dopo il dry-run.');
    assert(typeof item.password === 'string' && item.password.length > 0, 'PASSWORD_MISSING', `La password di ${candidate.title} non e disponibile.`);
    assert(item.password.length <= 65_536, 'PASSWORD_TOO_LONG', `La password di ${candidate.title} supera il limite consentito.`);
    const description = typeof item.description === 'string' ? item.description.slice(0, 65_536) : '';
    return { ...candidate, password: item.password, description };
  });
}

function permissionMaskDigest(value) {
  return digestPlan(normalizeFolderPermissions(value));
}

function isSoleOwnerMask(value, currentUserId) {
  const permissions = normalizeFolderPermissions(value);
  return permissions.length === 1
    && permissions[0].aro === 'User'
    && permissions[0].aro_foreign_key === String(currentUserId ?? '')
    && permissions[0].type === 15;
}

function technicalDigest(value) {
  return createHash('sha256').update(String(value ?? ''), 'utf8').digest('hex');
}

async function createPlannedContent(session, createPlan, resources, runtime, keyMaterial, progress = async () => {}) {
  assert(typeof progress === 'function', 'INVALID_PROGRESS_WRITER', 'Il canale di avanzamento non e valido.');
  const created = [];
  const createdFolders = [];
  const reconciledFolders = [];
  const resourceMap = new Map(resources.map((item) => [item.candidate_id, item]));
  const folderIds = new Map();
  for (const folder of runtime.folders) {
    if (folder.action === 'reuse') {
      folderIds.set(folder.destination_key, folder.folder_id);
      continue;
    }
    if (folder.action === 'repair_share') {
      folderIds.set(folder.destination_key, folder.folder_id);
      const operationId = randomUUID();
      await progress('operation_intent', {
        operation_id: operationId,
        object_type: 'folder',
        action: 'reconcile_folder',
        destination_key_hash: technicalDigest(folder.destination_key),
        permission_mask_hash: permissionMaskDigest(folder.share_permissions),
      });
      try {
        const shareResult = await shareCreatedFolder(session, folder.folder_id, folder.existing_permission, folder);
        reconciledFolders.push({
          destination_key: folder.destination_key,
          folder_name: folder.name,
          folder_id: folder.folder_id,
          folder_parent_id: folder.folder_parent_id ?? null,
          status: 'reconciled_shared',
          shared: true,
          permission_changes: shareResult.permission_changes,
          added_user_count: shareResult.added_user_count,
          share_recipient_count: Number(folder.share_recipient_count ?? 0),
          share_inherited_from_folder_id: folder.share_inherited_from_folder_id ?? null,
        });
        await progress('folder_shared', {
          operation_id: operationId,
          folder_id: folder.folder_id,
          status: 'reconciled_shared',
          added_user_count: Number(shareResult.added_user_count ?? 0),
          permission_change_count: Number(shareResult.permission_changes ?? 0),
        });
      } catch (error) {
        await progress('operation_failed', {
          operation_id: operationId,
          object_type: 'folder',
          folder_id: folder.folder_id,
          error_code: error instanceof SafeError ? error.code : 'INTERNAL_ERROR',
          outcome: 'unknown',
          ...(error instanceof SafeError && Number.isInteger(error.details?.http_status)
            ? { http_status: error.details.http_status }
            : {}),
        });
        const failureMessage = error instanceof SafeError ? error.message : 'La riconciliazione della cartella non e stata completata.';
        throw new SafeError(
          'IMPORT_PARTIAL_FAILURE',
          `La cartella personale esistente ${folder.name} non ha ricevuto i permessi del contenitore condiviso: ${failureMessage}`,
          {
            created_folders: createdFolders,
            reconciled_folders: reconciledFolders,
            created,
            failed_folder_name: folder.name,
            existing_personal_folder_id: folder.folder_id,
            sharing_failed: true,
            folder_reconciliation_failed: true,
            cause_code: error instanceof SafeError ? error.code : 'INTERNAL_ERROR',
            http_status: error instanceof SafeError ? error.details?.http_status : undefined,
          },
        );
      }
      continue;
    }
    const payload = await buildFolderPayload(folder, runtime, keyMaterial);
    const createFolderOperationId = randomUUID();
    await progress('operation_intent', {
      operation_id: createFolderOperationId,
      object_type: 'folder',
      action: 'create_folder',
      destination_key_hash: technicalDigest(folder.destination_key),
      ...(folder.shared ? { permission_mask_hash: permissionMaskDigest(folder.share_permissions) } : {}),
    });
    const response = await session.request('/folders.json?api-version=v2&contain[permission]=1', {
      method: 'POST',
      body: payload,
      allowError: true,
    });
    if (response.status < 200 || response.status >= 300) {
      await progress('operation_failed', {
        operation_id: createFolderOperationId,
        object_type: 'folder',
        error_code: 'FOLDER_CREATE_FAILED',
        outcome: 'confirmed',
        http_status: response.status,
      });
      throw new SafeError(
        'IMPORT_PARTIAL_FAILURE',
        apiMessage(response.document, `Creazione della cartella ${folder.name} non riuscita (HTTP ${response.status}).`),
        { created_folders: createdFolders, reconciled_folders: reconciledFolders, created, failed_folder_name: folder.name, http_status: response.status },
      );
    }
    const body = apiBody(response.document);
    const folderId = body && typeof body === 'object' && typeof body.id === 'string' ? body.id : '';
    if (!folderId) {
      await progress('operation_failed', {
        operation_id: createFolderOperationId,
        object_type: 'folder',
        error_code: 'FOLDER_ID_MISSING',
        outcome: 'unknown',
        http_status: response.status,
      });
      throw new SafeError(
        'IMPORT_PARTIAL_FAILURE',
        `Passbolt ha creato la cartella ${folder.name} senza restituire un identificatore utilizzabile.`,
        { created_folders: createdFolders, reconciled_folders: reconciledFolders, created, failed_folder_name: folder.name, http_status: response.status },
      );
    }
    const createdFolder = {
      destination_key: folder.destination_key,
      folder_name: folder.name,
      folder_id: folderId,
      folder_parent_id: folder.folder_parent_id ?? null,
      status: folder.shared ? 'created_unshared' : 'created',
      shared: Boolean(folder.shared),
      share_recipient_count: Number(folder.share_recipient_count ?? 0),
      share_inherited_from_folder_id: folder.share_inherited_from_folder_id ?? null,
    };
    createdFolders.push(createdFolder);
    await progress('folder_created', {
      operation_id: createFolderOperationId,
      folder_id: folderId,
      parent_folder_id: folder.folder_parent_id ?? null,
      destination_key_hash: technicalDigest(folder.destination_key),
      status: folder.shared ? 'created_unshared' : 'created',
    });
    if (folder.shared) {
      const shareFolderOperationId = randomUUID();
      await progress('operation_intent', {
        operation_id: shareFolderOperationId,
        object_type: 'folder',
        action: 'share_folder',
        destination_key_hash: technicalDigest(folder.destination_key),
        permission_mask_hash: permissionMaskDigest(folder.share_permissions),
      });
      try {
        const shareResult = await shareCreatedFolder(session, folderId, body.permission, folder);
        createdFolder.status = 'created_shared';
        createdFolder.permission_changes = shareResult.permission_changes;
        createdFolder.added_user_count = shareResult.added_user_count;
        await progress('folder_shared', {
          operation_id: shareFolderOperationId,
          folder_id: folderId,
          status: 'created_shared',
          added_user_count: Number(shareResult.added_user_count ?? 0),
          permission_change_count: Number(shareResult.permission_changes ?? 0),
        });
      } catch (error) {
        await progress('operation_failed', {
          operation_id: shareFolderOperationId,
          object_type: 'folder',
          folder_id: folderId,
          error_code: error instanceof SafeError ? error.code : 'INTERNAL_ERROR',
          outcome: 'partial',
          ...(error instanceof SafeError && Number.isInteger(error.details?.http_status)
            ? { http_status: error.details.http_status }
            : {}),
        });
        const failureMessage = error instanceof SafeError ? error.message : 'La condivisione della cartella non e stata completata.';
        throw new SafeError(
          'IMPORT_PARTIAL_FAILURE',
          `La cartella ${folder.name} e stata creata, ma non e stato possibile applicare i permessi ereditati: ${failureMessage}`,
          {
            created_folders: createdFolders,
            reconciled_folders: reconciledFolders,
            created,
            failed_folder_name: folder.name,
            created_unshared_folder_id: folderId,
            sharing_failed: true,
            folder_sharing_failed: true,
            cause_code: error instanceof SafeError ? error.code : 'INTERNAL_ERROR',
            http_status: error instanceof SafeError ? error.details?.http_status : undefined,
          },
        );
      }
    }
    folderIds.set(folder.destination_key, folderId);
  }

  for (const planned of createPlan) {
    const resource = resourceMap.get(planned.candidate_id);
    assert(resource, 'IMPORT_DATA_MISMATCH', 'Manca un candidato confermato.');
    const folderParentId = planned.folder_action === 'root'
      ? null
      : folderIds.get(planned.destination_key);
    assert(planned.folder_action === 'root' || typeof folderParentId === 'string', 'FOLDER_DESTINATION_MISSING', `La destinazione di ${resource.title} non e disponibile.`);
    const payload = await buildResourcePayload(resource, runtime, keyMaterial, folderParentId ?? null);
    const createResourceOperationId = randomUUID();
    await progress('operation_intent', {
      operation_id: createResourceOperationId,
      object_type: 'resource',
      action: 'create_resource',
      candidate_id: resource.candidate_id,
      destination_key_hash: technicalDigest(planned.destination_key),
      ...(planned.shared ? { permission_mask_hash: permissionMaskDigest(planned.share_permissions) } : {}),
    });
    const response = await session.request('/resources.json?api-version=v2&contain[permission]=1', {
      method: 'POST',
      body: payload,
      allowError: true,
    });
    if (response.status < 200 || response.status >= 300) {
      await progress('operation_failed', {
        operation_id: createResourceOperationId,
        object_type: 'resource',
        candidate_id: resource.candidate_id,
        error_code: 'RESOURCE_CREATE_FAILED',
        outcome: 'confirmed',
        http_status: response.status,
      });
      throw new SafeError(
        'IMPORT_PARTIAL_FAILURE',
        apiMessage(response.document, `Creazione di ${resource.title} non riuscita (HTTP ${response.status}).`),
        { created_folders: createdFolders, reconciled_folders: reconciledFolders, created, failed_candidate_id: resource.candidate_id, http_status: response.status },
      );
    }
    const body = apiBody(response.document);
    const resourceId = body && typeof body === 'object' && typeof body.id === 'string' ? body.id : '';
    if (!resourceId) {
      await progress('operation_failed', {
        operation_id: createResourceOperationId,
        object_type: 'resource',
        candidate_id: resource.candidate_id,
        error_code: 'RESOURCE_ID_MISSING',
        outcome: 'unknown',
        http_status: response.status,
      });
      throw new SafeError(
        'IMPORT_PARTIAL_FAILURE',
        `Passbolt ha creato ${resource.title} senza restituire un identificatore utilizzabile.`,
        { created_folders: createdFolders, reconciled_folders: reconciledFolders, created, failed_candidate_id: resource.candidate_id, http_status: response.status },
      );
    }
    const createdEntry = {
      candidate_id: resource.candidate_id,
      resource_id: resourceId,
      folder_parent_id: folderParentId ?? null,
      status: planned.shared ? 'created_unshared' : 'created',
      shared: Boolean(planned.shared),
      share_recipient_count: Number(planned.share_recipient_count ?? 0),
    };
    created.push(createdEntry);
    await progress('resource_created', {
      operation_id: createResourceOperationId,
      resource_id: resourceId,
      candidate_id: resource.candidate_id,
      status: planned.shared ? 'created_unshared' : 'created',
    });
    if (planned.shared) {
      const shareResourceOperationId = randomUUID();
      await progress('operation_intent', {
        operation_id: shareResourceOperationId,
        object_type: 'resource',
        action: 'share_resource',
        candidate_id: resource.candidate_id,
        destination_key_hash: technicalDigest(planned.destination_key),
        permission_mask_hash: permissionMaskDigest(planned.share_permissions),
      });
      try {
        const shareResult = await shareCreatedResource(session, resourceId, body.permission, planned, resource, runtime, keyMaterial);
        createdEntry.status = 'created_shared';
        createdEntry.encrypted_secret_copies = shareResult.encrypted_secret_copies;
        createdEntry.permission_changes = shareResult.permission_changes;
        await progress('resource_shared', {
          operation_id: shareResourceOperationId,
          resource_id: resourceId,
          candidate_id: resource.candidate_id,
          status: 'created_shared',
          recipient_count: Number(planned.share_recipient_count ?? 0),
          permission_change_count: Number(shareResult.permission_changes ?? 0),
        });
      } catch (error) {
        await progress('operation_failed', {
          operation_id: shareResourceOperationId,
          object_type: 'resource',
          candidate_id: resource.candidate_id,
          resource_id: resourceId,
          error_code: error instanceof SafeError ? error.code : 'INTERNAL_ERROR',
          outcome: 'partial',
          ...(error instanceof SafeError && Number.isInteger(error.details?.http_status)
            ? { http_status: error.details.http_status }
            : {}),
        });
        const failureMessage = error instanceof SafeError ? error.message : 'La condivisione non e stata completata.';
        throw new SafeError(
          'IMPORT_PARTIAL_FAILURE',
          `${resource.title} e stata creata, ma non e stato possibile applicare la condivisione: ${failureMessage}`,
          {
            created_folders: createdFolders,
            reconciled_folders: reconciledFolders,
            created,
            failed_candidate_id: resource.candidate_id,
            created_unshared_resource_id: resourceId,
            sharing_failed: true,
            cause_code: error instanceof SafeError ? error.code : 'INTERNAL_ERROR',
            http_status: error instanceof SafeError ? error.details?.http_status : undefined,
          },
        );
      }
    }
  }
  return { created, createdFolders, reconciledFolders };
}

async function verifyCreatedResources(
  session,
  created,
  createPlan,
  resources,
  runtime,
  keyMaterial,
  currentUserId,
  progress = async () => {},
  failureContext = {},
) {
  const planByCandidate = new Map(createPlan.map((item) => [item.candidate_id, item]));
  const resourceByCandidate = new Map(resources.map((item) => [item.candidate_id, item]));
  const results = [];
  for (const createdEntry of created) {
    const candidateId = String(createdEntry.candidate_id);
    const planned = planByCandidate.get(candidateId);
    const source = resourceByCandidate.get(candidateId);
    try {
      assert(planned && source, 'POST_IMPORT_PLAN_MISSING', 'La verifica finale non trova il candidato nel piano confermato.');
      const resourceResponse = await session.request(
        `/resources/${encodeURIComponent(createdEntry.resource_id)}.json?api-version=v2&contain[permission]=1&contain[permissions]=1`,
        { allowError: true },
      );
      assert(
        resourceResponse.status >= 200 && resourceResponse.status < 300,
        'POST_IMPORT_RESOURCE_READ_FAILED',
        `La risorsa appena creata non puo essere riletta (HTTP ${resourceResponse.status}).`,
        { http_status: resourceResponse.status },
      );
      const remote = apiBody(resourceResponse.document);
      assert(remote && typeof remote === 'object' && String(remote.id ?? '') === String(createdEntry.resource_id), 'POST_IMPORT_RESOURCE_ID_MISMATCH', 'La risorsa riletta non corrisponde a quella creata.');
      assert(String(remote.resource_type_id ?? '') === String(runtime.resourceType?.id ?? ''), 'POST_IMPORT_RESOURCE_TYPE_MISMATCH', 'Il tipo della risorsa riletta non corrisponde al piano.');

      let metadata;
      if (runtime.selectedFormat === 'v5') {
        const metadataKey = planned.shared ? runtime.sharedMetadataEncryptionKey : runtime.metadataEncryptionKey;
        assert(metadataKey, 'POST_IMPORT_METADATA_KEY_MISSING', 'La chiave metadati della verifica finale non e disponibile.');
        assert(
          String(remote.metadata_key_id ?? '') === String(metadataKey.id)
            && String(remote.metadata_key_type ?? '') === String(metadataKey.type),
          'POST_IMPORT_METADATA_KEY_MISMATCH',
          'La risorsa riletta usa una chiave metadati diversa dal piano.',
        );
        const clearMetadata = await decryptMessageText(
          String(remote.metadata ?? ''),
          metadataKey.type === 'user_key' ? keyMaterial.privateKey : metadataKey.privateKey,
          keyMaterial.publicKey,
          true,
          'POST_IMPORT_METADATA_DECRYPT_FAILED',
          'I metadati della risorsa appena creata non possono essere decifrati o verificati.',
        );
        try {
          metadata = JSON.parse(clearMetadata);
        } catch {
          throw new SafeError('POST_IMPORT_METADATA_INVALID', 'I metadati riletti non contengono JSON valido.');
        }
        assert(metadata && typeof metadata === 'object' && metadata.object_type === RESOURCE_METADATA_OBJECT_TYPE, 'POST_IMPORT_METADATA_INVALID', 'Il tipo dei metadati riletti non e valido.');
        assert(String(metadata.resource_type_id ?? '') === String(runtime.resourceType.id), 'POST_IMPORT_METADATA_TYPE_MISMATCH', 'Il tipo dichiarato nei metadati riletti non corrisponde al piano.');
      } else {
        metadata = remote;
      }
      const remoteUri = runtime.selectedFormat === 'v5'
        ? (Array.isArray(metadata.uris) && typeof metadata.uris[0] === 'string' ? metadata.uris[0] : '')
        : String(metadata.uri ?? '');
      assert(
        String(metadata.name ?? '') === source.title
          && String(metadata.username ?? '') === source.username
          && remoteUri === source.uri,
        'POST_IMPORT_METADATA_MISMATCH',
        'Titolo, username o URL riletti non corrispondono al piano confermato.',
      );
      if (resourceDescriptionIsMetadata(runtime.resourceType)) {
        assert(String(metadata.description ?? '') === String(source.description ?? ''), 'POST_IMPORT_DESCRIPTION_MISMATCH', 'La descrizione riletta non corrisponde al piano confermato.');
      }

      const secretResponse = await session.request(
        `/secrets/resource/${encodeURIComponent(createdEntry.resource_id)}.json?api-version=v2`,
        { allowError: true },
      );
      assert(
        secretResponse.status >= 200 && secretResponse.status < 300,
        'POST_IMPORT_CONTENT_READ_FAILED',
        `Il contenuto cifrato appena creato non puo essere riletto (HTTP ${secretResponse.status}).`,
        { http_status: secretResponse.status },
      );
      const secretBody = apiBody(secretResponse.document);
      const remoteSecret = Array.isArray(secretBody)
        ? secretBody.find((entry) => (
          String(entry?.resource_id ?? '') === String(createdEntry.resource_id)
          && String(entry?.user_id ?? '') === String(currentUserId)
        ))
        : secretBody;
      assert(
        remoteSecret
          && typeof remoteSecret === 'object'
          && String(remoteSecret.resource_id ?? createdEntry.resource_id) === String(createdEntry.resource_id)
          && String(remoteSecret.user_id ?? '') === String(currentUserId)
          && typeof remoteSecret.data === 'string'
          && remoteSecret.data.includes('-----BEGIN PGP MESSAGE-----'),
        'POST_IMPORT_CONTENT_INVALID',
        'Passbolt non ha restituito il contenuto cifrato della risorsa appena creata per l’utente autenticato.',
      );
      const clearContent = await decryptMessageText(
        remoteSecret.data,
        keyMaterial.privateKey,
        keyMaterial.publicKey,
        true,
        'POST_IMPORT_CONTENT_DECRYPT_FAILED',
        'Il contenuto della risorsa appena creata non puo essere decifrato o verificato.',
      );
      assert(Buffer.byteLength(clearContent, 'utf8') <= 1024 * 1024, 'POST_IMPORT_CONTENT_TOO_LARGE', 'Il contenuto riletto supera il limite sicuro di 1 MiB.');
      if (resourceSecretIsString(runtime.resourceType)) {
        assert(clearContent === source.password, 'POST_IMPORT_CONTENT_MISMATCH', 'Il contenuto riletto non corrisponde al valore importato.');
      } else {
        let contentDocument;
        try {
          contentDocument = JSON.parse(clearContent);
        } catch {
          throw new SafeError('POST_IMPORT_CONTENT_INVALID', 'Il contenuto riletto non contiene JSON valido.');
        }
        assert(contentDocument && typeof contentDocument === 'object', 'POST_IMPORT_CONTENT_INVALID', 'Il contenuto riletto non e valido.');
        assert(String(contentDocument.password ?? '') === source.password, 'POST_IMPORT_CONTENT_MISMATCH', 'Il contenuto riletto non corrisponde al valore importato.');
        if (!resourceDescriptionIsMetadata(runtime.resourceType)) {
          assert(String(contentDocument.description ?? '') === String(source.description ?? ''), 'POST_IMPORT_DESCRIPTION_MISMATCH', 'La descrizione cifrata riletta non corrisponde al piano.');
        }
        if (runtime.selectedFormat === 'v5') {
          assert(contentDocument.object_type === SECRET_DATA_OBJECT_TYPE, 'POST_IMPORT_CONTENT_TYPE_MISMATCH', 'Il tipo del contenuto v5 riletto non e valido.');
        }
      }

      const remoteFolderParentId = typeof remote.folder_parent_id === 'string' ? remote.folder_parent_id : null;
      assert(remoteFolderParentId === (createdEntry.folder_parent_id ?? null), 'POST_IMPORT_DESTINATION_MISMATCH', 'La risorsa riletta si trova in una cartella diversa dal piano.');
      const expectedPermissions = planned.shared
        ? normalizeFolderPermissions(planned.share_permissions)
        : [{ aro: 'User', aro_foreign_key: String(currentUserId), type: 15 }];
      const actualPermissions = normalizeFolderPermissions(remote.permissions);
      const rawPermissionCount = Array.isArray(remote.permissions)
        ? remote.permissions.filter((permission) => permission && typeof permission === 'object').length
        : 0;
      assert(
        actualPermissions.length > 0
          && rawPermissionCount === actualPermissions.length
          && canonicalJson(actualPermissions) === canonicalJson(expectedPermissions),
        'POST_IMPORT_ACL_MISMATCH',
        'I permessi riletti non corrispondono alla maschera confermata.',
      );
      const effectivePermissionType = normalizePermissionType(remote.permission?.type);
      assert(effectivePermissionType === 15, 'POST_IMPORT_OWNER_MISMATCH', 'L’utente autenticato non risulta proprietario della risorsa riletta.');

      const verified = {
        candidate_id: candidateId,
        resource_id: String(createdEntry.resource_id),
        status: 'verified',
        metadata_match: true,
        content_match: true,
        destination_match: true,
        acl_match: true,
      };
      results.push(verified);
      await progress('resource_verified', {
        resource_id: verified.resource_id,
        candidate_id: candidateId,
        metadata_match: true,
        content_match: true,
        destination_match: true,
        acl_match: true,
      });
    } catch (error) {
      throw new SafeError(
        'POST_IMPORT_VERIFICATION_FAILED',
        'La verifica automatica successiva alla scrittura non ha confermato tutte le risorse create. Il lotto richiede una riconciliazione autenticata.',
        {
          ...failureContext,
          created,
          failed_candidate_id: candidateId,
          verified_resource_count: results.length,
          cause_code: error instanceof SafeError ? error.code : 'INTERNAL_ERROR',
          ...(error instanceof SafeError && Number.isInteger(error.details?.http_status)
            ? { http_status: error.details.http_status }
            : {}),
        },
      );
    }
  }
  return results;
}

async function executeImport(input) {
  const baseUrl = normalizeBaseUrl(input.base_url);
  const expectedFingerprint = normalizeFingerprint(input.expected_server_fingerprint, 'Fingerprint attesa del server');
  const candidates = safeCandidates(input.candidates);
  const key = await loadPrivateKey(input.private_key_path, input.passphrase);
  const session = new PassboltSession(baseUrl);
  try {
    const { user, mfaProvider } = await authenticate(session, key, expectedFingerprint, input.mfa_totp);
    const analysis = await analyzeCapabilities(
      session,
      user,
      candidates,
      key,
      input.resource_format,
      input.destination_mode,
      input.folder_format,
      input.destination_folder_id,
      input.client_destination_mapping,
      input.permission_mode,
      input.permission_template,
    );
    const { capabilities, runtime } = analysis;
    assert(capabilities.can_import, 'IMPORT_NOT_SUPPORTED', capabilities.unavailable_reason || 'Importazione non disponibile su questa istanza.');
    assert(String(input.plan_digest ?? '') === capabilities.plan_digest, 'STALE_PLAN', 'Il contenuto di Passbolt o il piano sono cambiati dopo il dry-run. Ripetere la verifica.');
    const createPlan = capabilities.candidates.filter((item) => item.action === 'create');
    assert(createPlan.length > 0, 'NOTHING_TO_IMPORT', 'Tutti i candidati selezionati risultano gia presenti.');
    assert(String(input.confirmation ?? '') === `IMPORTA ${createPlan.length}`, 'CONFIRMATION_MISMATCH', `Conferma richiesta: IMPORTA ${createPlan.length}`);
    const resources = importResources(input.resources, createPlan);
    const { created, createdFolders, reconciledFolders } = await createPlannedContent(session, createPlan, resources, runtime, key);
    const verificationResults = await verifyCreatedResources(
      session,
      created,
      createPlan,
      resources,
      runtime,
      key,
      String(user.id),
      async () => {},
      { created_folders: createdFolders, reconciled_folders: reconciledFolders },
    );
    return {
      command: 'import',
      authentication: mfaProvider ? 'GPGAuth + TOTP' : 'GPGAuth',
      mfa_provider: mfaProvider,
      created_count: created.length,
      shared_created_count: created.filter((item) => item.status === 'created_shared').length,
      encrypted_secret_copy_count: capabilities.encrypted_secret_copy_count,
      skipped_duplicate_count: capabilities.duplicate_count,
      created_folder_count: createdFolders.length,
      shared_created_folder_count: createdFolders.filter((item) => item.status === 'created_shared').length,
      reconciled_shared_folder_count: reconciledFolders.length,
      reused_folder_count: capabilities.reuse_folder_count,
      resource_format: capabilities.resource_format_selected,
      folder_format: capabilities.folder_format_selected,
      resource_type: capabilities.resource_type,
      created_folders: createdFolders,
      reconciled_folders: reconciledFolders,
      created,
      verification_status: 'verified',
      verified_resource_count: verificationResults.length,
      verification_failed_count: 0,
      verification_results: verificationResults,
      complete: true,
    };
  } finally {
    await logout(session);
  }
}

async function verifyPersistentSession(session, expectedUserId) {
  let response;
  try {
    response = await session.request('/users/me.json?api-version=v2', { allowError: true });
  } catch (error) {
    if (error instanceof SafeError && ['API_INVALID_JSON', 'API_HTTP_ERROR'].includes(error.code)) {
      throw new SafeError('IMPORT_SESSION_EXPIRED', 'La sessione Passbolt non e piu valida. Chiuderla e avviarne una nuova.');
    }
    throw error;
  }
  if (isMfaChallengeResponse(response)) {
    throw new SafeError('IMPORT_SESSION_MFA_EXPIRED', 'L’autorizzazione MFA della sessione e scaduta. Chiudere la sessione e avviarne una nuova con un codice TOTP corrente.');
  }
  if (response.status === 401 || response.status === 403) {
    throw new SafeError('IMPORT_SESSION_EXPIRED', 'La sessione Passbolt e scaduta. Chiuderla e avviarne una nuova.');
  }
  assert(response.status >= 200 && response.status < 300, 'IMPORT_SESSION_CHECK_FAILED', apiMessage(response.document, 'Impossibile verificare la sessione Passbolt attiva.'));
  const user = apiBody(response.document);
  assert(user && typeof user === 'object' && String(user.id ?? '') === expectedUserId, 'IMPORT_SESSION_IDENTITY_CHANGED', 'L’identita della sessione Passbolt e cambiata. Sessione interrotta.');
}

class PersistentImportSession {
  constructor(progressWriter = null) {
    this.state = null;
    this.progressWriter = typeof progressWriter === 'function' ? progressWriter : null;
  }

  async emitProgress(batchId, eventType, payload) {
    if (!batchId || !this.progressWriter) return;
    await this.progressWriter({
      type: 'progress',
      batch_id: batchId,
      event_type: eventType,
      payload,
    });
  }

  async open(input) {
    assert(!this.state, 'IMPORT_SESSION_ALREADY_OPEN', 'Una sessione di importazione e gia attiva.');
    const baseUrl = normalizeBaseUrl(input.base_url);
    const expectedFingerprint = normalizeFingerprint(input.expected_server_fingerprint, 'Fingerprint attesa del server');
    const key = await loadPrivateKey(input.private_key_path, input.passphrase);
    const session = new PassboltSession(baseUrl);
    try {
      const { user, mfaProvider } = await authenticate(session, key, expectedFingerprint, input.mfa_totp);
      const sessionId = randomUUID();
      this.state = {
        sessionId,
        baseUrl,
        expectedFingerprint,
        session,
        key,
        user,
        mfaProvider,
      };
      return {
        command: 'session-open',
        session_id: sessionId,
        authentication: mfaProvider ? 'GPGAuth + TOTP' : 'GPGAuth',
        mfa_provider: mfaProvider,
        base_url: baseUrl,
        server_fingerprint: expectedFingerprint,
        user_key_fingerprint: key.fingerprint,
        user: safeUser(user),
        secrets_serialized: false,
      };
    } catch (error) {
      await logout(session);
      throw error;
    } finally {
      input.passphrase = null;
      input.mfa_totp = null;
    }
  }

  requireState(input) {
    assert(this.state, 'IMPORT_SESSION_NOT_OPEN', 'Avviare prima la sessione sicura di importazione.');
    assert(String(input.session_id ?? '') === this.state.sessionId, 'IMPORT_SESSION_ID_MISMATCH', 'L’identificatore della sessione locale non corrisponde.');
    return this.state;
  }

  async readiness(input) {
    const state = this.requireState(input);
    await verifyPersistentSession(state.session, String(state.user.id));
    const candidates = safeCandidates(input.candidates);
    const capabilities = await readCapabilities(
      state.session,
      state.user,
      candidates,
      state.key,
      input.resource_format,
      input.destination_mode,
      input.folder_format,
      input.destination_folder_id,
      input.client_destination_mapping,
      input.permission_mode,
      input.permission_template,
    );
    return {
      command: 'readiness',
      session_id: state.sessionId,
      authentication: state.mfaProvider ? 'GPGAuth + TOTP' : 'GPGAuth',
      mfa_provider: state.mfaProvider,
      base_url: state.baseUrl,
      server_fingerprint: state.expectedFingerprint,
      user_key_fingerprint: state.key.fingerprint,
      user: safeUser(state.user),
      ...capabilities,
    };
  }

  async permissions(input) {
    const state = this.requireState(input);
    await verifyPersistentSession(state.session, String(state.user.id));
    const response = await state.session.request('/share/search-aros.json?api-version=v2&contain[gpgkey]=1&contain[groups_users]=1', { allowError: true });
    assert(response.status >= 200 && response.status < 300, 'PERMISSION_DIRECTORY_READ_FAILED', apiMessage(response.document, 'Impossibile leggere l’elenco autenticato degli utenti e dei gruppi Passbolt.'));
    const shareDirectory = await buildShareDirectory(response.document, state.user, state.key);
    return {
      command: 'permission-catalog',
      session_id: state.sessionId,
      owner: safeUser(state.user),
      permission_types: [
        { type: 1, label: 'Lettura' },
        { type: 7, label: 'Aggiornamento' },
        { type: 15, label: 'Proprietario' },
      ],
      entries: permissionCatalog(shareDirectory, String(state.user.id)),
    };
  }

  async aclCatalog(input) {
    const state = this.requireState(input);
    await verifyPersistentSession(state.session, String(state.user.id));
    state.aclPlan = null;
    state.aclRecovery = null;
    const catalog = await readAclCatalog(state.session, state.user, state.key);
    return {
      command: 'acl-catalog',
      session_id: state.sessionId,
      read_only: true,
      write_requests: 0,
      owner: safeUser(state.user),
      ...catalog,
    };
  }

  async aclPlan(input) {
    const state = this.requireState(input);
    state.aclRecovery = null;
    await verifyPersistentSession(state.session, String(state.user.id));
    const objectType = normalizeAclObjectType(input.object_type);
    const objectId = normalizeAclObjectId(input.object_id);
    const analysis = await analyzeAclCatalog(state.session, state.user, state.key);
    const matches = analysis.catalog.objects.filter((entry) => entry.object_type === objectType && entry.object_id === objectId);
    assert(matches.length === 1, 'ACL_PLAN_OBJECT_NOT_FOUND', 'L’oggetto selezionato non e piu presente in modo univoco su Passbolt. Aggiornare il catalogo ACL.');
    const plan = buildAclChangePlan(matches[0], input.desired_permissions, analysis.runtime.shareDirectory, String(state.user.id));
    const desiredTemplate = normalizeCustomPermissionEntries(input.desired_permissions, String(state.user.id));
    const desiredPermissions = normalizeFolderPermissions([
      ...desiredTemplate,
      { aro: 'User', aro_foreign_key: String(state.user.id), type: 15 },
    ]);
    const additiveOnly = plan.change_count > 0 && plan.counts.downgrade === 0 && plan.counts.revoke === 0;
    const restrictiveCount = plan.counts.downgrade + plan.counts.revoke;
    const applyMode = restrictiveCount === 0 ? 'additive' : ((plan.counts.add + plan.counts.upgrade) > 0 ? 'mixed' : 'restrictive');
    const confirmationRequired = plan.change_count === 0
      ? null
      : (additiveOnly
        ? `APPLICA ACL ${plan.change_count} ${plan.plan_digest.slice(0, 8).toUpperCase()}`
        : `CONFERMO RIDUZIONE ACL ${restrictiveCount} ${plan.effective_user_counts.loss} ${plan.plan_digest.slice(0, 8).toUpperCase()}`);
    state.aclPlan = {
      planId: plan.plan_id,
      objectType,
      objectId,
      objectStateDigest: plan.object_state_digest,
      desiredAclDigest: plan.desired_acl_digest,
      directoryStateDigest: plan.directory_state_digest,
      planDigest: plan.plan_digest,
      desiredTemplate,
      desiredPermissions,
      changeCount: plan.change_count,
      counts: { ...plan.counts },
      applyMode,
      confirmationRequired,
    };
    return {
      command: 'acl-plan',
      session_id: state.sessionId,
      read_only: true,
      write_requests: 0,
      remote_writes_planned: 0,
      complete: true,
      generated_from_fresh_remote_state: true,
      apply_available: plan.change_count > 0,
      additive_apply_available: additiveOnly,
      restrictive_apply_available: restrictiveCount > 0,
      restrictive_change_count: restrictiveCount,
      restrictive_changes_blocked: 0,
      apply_mode: applyMode,
      destructive_actions_planned: restrictiveCount > 0,
      confirmation_required: confirmationRequired,
      desired_permissions: desiredTemplate,
      owner: safeUser(state.user),
      ...plan,
    };
  }

  async aclApply(input) {
    const state = this.requireState(input);
    const saved = state.aclPlan;
    assert(saved, 'ACL_APPLY_PLAN_REQUIRED', 'Calcolare nuovamente il piano ACL prima dell’applicazione.');
    const batchId = normalizeReconciliationBatchId(input.acl_batch_id);
    assert(batchId, 'ACL_APPLY_BATCH_REQUIRED', 'Il journal ACL locale non e stato inizializzato.');
    assert(this.progressWriter, 'PROGRESS_WRITER_REQUIRED', 'Il canale durevole ACL non e disponibile.');
    assert(String(input.plan_id ?? '') === saved.planId, 'ACL_APPLY_PLAN_MISMATCH', 'Il piano selezionato non corrisponde all’ultimo dry-run.');
    assert(String(input.object_state_digest ?? '') === saved.objectStateDigest, 'ACL_APPLY_PLAN_MISMATCH', 'Il digest dello snapshot non corrisponde all’ultimo dry-run.');
    assert(String(input.desired_acl_digest ?? '') === saved.desiredAclDigest, 'ACL_APPLY_PLAN_MISMATCH', 'Il digest della ACL desiderata non corrisponde all’ultimo dry-run.');
    assert(String(input.directory_state_digest ?? '') === saved.directoryStateDigest, 'ACL_APPLY_PLAN_MISMATCH', 'Il digest della directory non corrisponde all’ultimo dry-run.');
    assert(String(input.plan_digest ?? '') === saved.planDigest, 'ACL_APPLY_PLAN_MISMATCH', 'Il digest del piano non corrisponde all’ultimo dry-run.');
    assert(saved.changeCount > 0 && saved.confirmationRequired, 'ACL_APPLY_NOTHING_TO_DO', 'Il piano non contiene modifiche applicabili.');
    assert(String(input.confirmation ?? '') === saved.confirmationRequired, 'CONFIRMATION_MISMATCH', `Conferma richiesta: ${saved.confirmationRequired}`);
    await verifyPersistentSession(state.session, String(state.user.id));
    const analysis = await analyzeAclCatalog(state.session, state.user, state.key);
    const matches = analysis.catalog.objects.filter((entry) => entry.object_type === saved.objectType && entry.object_id === saved.objectId);
    assert(matches.length === 1, 'ACL_APPLY_OBJECT_NOT_FOUND', 'L’oggetto del piano non e piu presente in modo univoco su Passbolt.');
    const freshPlan = buildAclChangePlan(matches[0], saved.desiredTemplate, analysis.runtime.shareDirectory, String(state.user.id));
    assert(
      freshPlan.object_state_digest === saved.objectStateDigest
      && freshPlan.desired_acl_digest === saved.desiredAclDigest
      && freshPlan.directory_state_digest === saved.directoryStateDigest
      && freshPlan.plan_digest === saved.planDigest,
      'ACL_APPLY_STALE_PLAN',
      'La ACL remota e cambiata dopo il dry-run. Aggiornare il catalogo e preparare un nuovo piano.',
    );
    assert(
      freshPlan.counts.add === saved.counts.add
      && freshPlan.counts.upgrade === saved.counts.upgrade
      && freshPlan.counts.downgrade === saved.counts.downgrade
      && freshPlan.counts.revoke === saved.counts.revoke,
      'ACL_APPLY_STALE_PLAN',
      'La classificazione delle modifiche ACL non corrisponde piu al piano confermato.',
    );
    const progress = async (eventType, payload) => this.emitProgress(batchId, eventType, payload);
    const applied = await applyExistingAcl(
      state.session,
      matches[0],
      saved.desiredPermissions,
      analysis.runtime,
      state.key,
      String(state.user.id),
      saved.counts,
      progress,
    );
    await progress('acl_batch_completed', {
      object_type: saved.objectType,
      object_id: saved.objectId,
      resulting_acl_digest: saved.desiredAclDigest,
      applied_change_count: saved.changeCount,
      permission_change_count: applied.permissionChangeCount,
      added_user_count: applied.addedUserCount,
      removed_user_count: applied.removedUserCount,
      restrictive_change_count: applied.restrictiveChangeCount,
      destructive_actions_performed: applied.restrictiveChangeCount > 0,
      recovered: false,
    });
    state.aclPlan = null;
    return {
      command: 'acl-apply',
      session_id: state.sessionId,
      acl_batch_id: batchId,
      object_type: saved.objectType,
      object_id: saved.objectId,
      resulting_acl_digest: saved.desiredAclDigest,
      applied_change_count: saved.changeCount,
      permission_change_count: applied.permissionChangeCount,
      added_user_count: applied.addedUserCount,
      removed_user_count: applied.removedUserCount,
      restrictive_change_count: applied.restrictiveChangeCount,
      apply_mode: saved.applyMode,
      destructive_actions_performed: applied.restrictiveChangeCount > 0,
      complete: true,
    };
  }

  async aclRecoveryReadiness(input) {
    const state = this.requireState(input);
    const recovery = input.acl_recovery_state;
    assert(recovery && typeof recovery === 'object' && !Array.isArray(recovery), 'ACL_RECOVERY_STATE_REQUIRED', 'Il journal ACL non contiene uno stato di recupero valido.');
    const batchId = normalizeReconciliationBatchId(input.acl_batch_id);
    assert(batchId && batchId === normalizeReconciliationBatchId(recovery.batch_id), 'ACL_RECOVERY_BATCH_MISMATCH', 'Il journal ACL non corrisponde al lotto richiesto.');
    assert(this.progressWriter, 'PROGRESS_WRITER_REQUIRED', 'Il canale durevole ACL non e disponibile.');
    const objectType = normalizeAclObjectType(recovery.object_type);
    const objectId = normalizeAclObjectId(recovery.object_id);
    for (const [value, code] of [
      [recovery.object_state_digest, 'ACL_RECOVERY_STATE_DIGEST_INVALID'],
      [recovery.desired_acl_digest, 'ACL_RECOVERY_DESIRED_DIGEST_INVALID'],
      [recovery.plan_digest, 'ACL_RECOVERY_PLAN_DIGEST_INVALID'],
    ]) {
      assert(/^[0-9a-f]{64}$/.test(String(value ?? '')), code, 'Il journal ACL contiene un digest non valido.');
    }
    const desiredTemplate = normalizeCustomPermissionEntries(recovery.desired_permissions, String(state.user.id));
    await verifyPersistentSession(state.session, String(state.user.id));
    const analysis = await analyzeAclCatalog(state.session, state.user, state.key);
    const matches = analysis.catalog.objects.filter((entry) => entry.object_type === objectType && entry.object_id === objectId);
    assert(matches.length === 1, 'ACL_RECOVERY_OBJECT_NOT_FOUND', 'L’oggetto del journal ACL non e piu presente in modo univoco su Passbolt.');
    const freshPlan = buildAclChangePlan(matches[0], desiredTemplate, analysis.runtime.shareDirectory, String(state.user.id));
    assert(freshPlan.desired_acl_digest === String(recovery.desired_acl_digest), 'ACL_RECOVERY_DESIRED_CHANGED', 'La ACL desiderata ricostruita non corrisponde al journal locale.');
    let resolution;
    if (freshPlan.object_state_digest === String(recovery.desired_acl_digest)) {
      resolution = 'remote_success';
    } else if (freshPlan.object_state_digest === String(recovery.object_state_digest)) {
      assert(
        freshPlan.plan_digest === String(recovery.plan_digest)
        && freshPlan.change_count === Number(recovery.change_count)
        && freshPlan.counts.add === Number(recovery.add_count)
        && freshPlan.counts.upgrade === Number(recovery.upgrade_count)
        && freshPlan.counts.downgrade === Number(recovery.downgrade_count ?? 0)
        && freshPlan.counts.revoke === Number(recovery.revoke_count ?? 0),
        'ACL_RECOVERY_PLAN_CHANGED',
        'Il piano ACL ricostruito non corrisponde al journal locale.',
      );
      resolution = 'not_applied';
    } else {
      throw new SafeError(
        'ACL_RECOVERY_CONFLICT',
        'La ACL remota non coincide ne con lo snapshot originale ne con il risultato atteso. E richiesta una verifica manuale.',
        { destructive_actions_planned: false },
      );
    }
    const recoveryId = randomUUID();
    const recoveryPlanDigest = digestPlan({
      batch_id: batchId,
      object_type: objectType,
      object_id: objectId,
      remote_acl_digest: freshPlan.object_state_digest,
      desired_acl_digest: recovery.desired_acl_digest,
      resolution,
    });
    await this.emitProgress(batchId, 'acl_recovery_verified', {
      recovery_id: recoveryId,
      resolution,
      remote_acl_digest: freshPlan.object_state_digest,
      recovery_plan_digest: recoveryPlanDigest,
    });
    const restrictiveCount = Number(recovery.downgrade_count ?? 0) + Number(recovery.revoke_count ?? 0);
    const applyMode = String(recovery.apply_mode ?? (restrictiveCount > 0 ? 'restrictive' : 'additive'));
    assert(['additive', 'mixed', 'restrictive'].includes(applyMode), 'ACL_RECOVERY_PLAN_CHANGED', 'La modalita del piano ACL nel journal non e valida.');
    const expectedMode = restrictiveCount === 0 ? 'additive' : ((Number(recovery.add_count ?? 0) + Number(recovery.upgrade_count ?? 0)) > 0 ? 'mixed' : 'restrictive');
    assert(applyMode === expectedMode, 'ACL_RECOVERY_PLAN_CHANGED', 'La modalita del piano ACL non corrisponde ai conteggi del journal.');
    const confirmationRequired = resolution === 'remote_success'
      ? `CHIUDI ACL ${recoveryPlanDigest.slice(0, 8).toUpperCase()}`
      : (restrictiveCount > 0
        ? `RECUPERA RIDUZIONE ACL ${restrictiveCount} ${recoveryPlanDigest.slice(0, 8).toUpperCase()}`
        : `RECUPERA ACL ${freshPlan.change_count} ${recoveryPlanDigest.slice(0, 8).toUpperCase()}`);
    state.aclRecovery = {
      batchId,
      recoveryId,
      recoveryPlanDigest,
      resolution,
      confirmationRequired,
      objectType,
      objectId,
      desiredTemplate,
      desiredPermissions: normalizeFolderPermissions([
        ...desiredTemplate,
        { aro: 'User', aro_foreign_key: String(state.user.id), type: 15 },
      ]),
      recovery: {
        objectStateDigest: String(recovery.object_state_digest),
        desiredAclDigest: String(recovery.desired_acl_digest),
        planDigest: String(recovery.plan_digest),
      },
      changeCount: freshPlan.change_count,
      counts: {
        add: Number(recovery.add_count ?? 0),
        upgrade: Number(recovery.upgrade_count ?? 0),
        downgrade: Number(recovery.downgrade_count ?? 0),
        revoke: Number(recovery.revoke_count ?? 0),
      },
      applyMode,
    };
    return {
      command: 'acl-recovery-readiness',
      session_id: state.sessionId,
      acl_batch_id: batchId,
      recovery_id: recoveryId,
      recovery_plan_digest: recoveryPlanDigest,
      resolution,
      can_recover: true,
      retry_write_required: resolution === 'not_applied',
      change_count: freshPlan.change_count,
      confirmation_required: confirmationRequired,
      restrictive_change_count: restrictiveCount,
      apply_mode: applyMode,
      destructive_actions_planned: resolution === 'not_applied' && restrictiveCount > 0,
    };
  }

  async aclRecoveryApply(input) {
    const state = this.requireState(input);
    const saved = state.aclRecovery;
    assert(saved, 'ACL_RECOVERY_READINESS_REQUIRED', 'Verificare prima il journal ACL nella sessione autenticata.');
    const batchId = normalizeReconciliationBatchId(input.acl_batch_id);
    assert(batchId === saved.batchId, 'ACL_RECOVERY_BATCH_MISMATCH', 'Il lotto non corrisponde all’ultima verifica ACL.');
    assert(String(input.recovery_id ?? '') === saved.recoveryId, 'ACL_RECOVERY_ID_MISMATCH', 'La verifica ACL selezionata non corrisponde.');
    assert(String(input.recovery_plan_digest ?? '') === saved.recoveryPlanDigest, 'ACL_RECOVERY_PLAN_CHANGED', 'Il digest del recupero ACL non corrisponde.');
    assert(String(input.confirmation ?? '') === saved.confirmationRequired, 'CONFIRMATION_MISMATCH', `Conferma richiesta: ${saved.confirmationRequired}`);
    assert(this.progressWriter, 'PROGRESS_WRITER_REQUIRED', 'Il canale durevole ACL non e disponibile.');
    await verifyPersistentSession(state.session, String(state.user.id));
    const analysis = await analyzeAclCatalog(state.session, state.user, state.key);
    const matches = analysis.catalog.objects.filter((entry) => entry.object_type === saved.objectType && entry.object_id === saved.objectId);
    assert(matches.length === 1, 'ACL_RECOVERY_OBJECT_NOT_FOUND', 'L’oggetto del journal ACL non e piu presente in modo univoco su Passbolt.');
    const freshPlan = buildAclChangePlan(matches[0], saved.desiredTemplate, analysis.runtime.shareDirectory, String(state.user.id));
    const resolutionNow = freshPlan.object_state_digest === saved.recovery.desiredAclDigest
      ? 'remote_success'
      : (freshPlan.object_state_digest === saved.recovery.objectStateDigest ? 'not_applied' : 'conflict');
    const digestNow = digestPlan({
      batch_id: batchId,
      object_type: saved.objectType,
      object_id: saved.objectId,
      remote_acl_digest: freshPlan.object_state_digest,
      desired_acl_digest: saved.recovery.desiredAclDigest,
      resolution: resolutionNow,
    });
    assert(resolutionNow === saved.resolution && digestNow === saved.recoveryPlanDigest, 'ACL_RECOVERY_PLAN_CHANGED', 'La ACL remota e cambiata dopo la verifica di recupero. Ripetere il controllo.');
    let permissionChangeCount = 0;
    let addedUserCount = 0;
    let removedUserCount = 0;
    let restrictiveChangeCount = 0;
    if (resolutionNow === 'not_applied') {
      assert(
        freshPlan.plan_digest === saved.recovery.planDigest
        && freshPlan.counts.add === saved.counts.add
        && freshPlan.counts.upgrade === saved.counts.upgrade
        && freshPlan.counts.downgrade === saved.counts.downgrade
        && freshPlan.counts.revoke === saved.counts.revoke,
        'ACL_RECOVERY_PLAN_CHANGED',
        'Il piano di recupero non corrisponde piu alle modifiche confermate.',
      );
      const progress = async (eventType, payload) => this.emitProgress(batchId, eventType, payload);
      const applied = await applyExistingAcl(
        state.session,
        matches[0],
        saved.desiredPermissions,
        analysis.runtime,
        state.key,
        String(state.user.id),
        saved.counts,
        progress,
      );
      permissionChangeCount = applied.permissionChangeCount;
      addedUserCount = applied.addedUserCount;
      removedUserCount = applied.removedUserCount;
      restrictiveChangeCount = applied.restrictiveChangeCount;
    }
    await this.emitProgress(batchId, 'acl_batch_completed', {
      object_type: saved.objectType,
      object_id: saved.objectId,
      resulting_acl_digest: saved.recovery.desiredAclDigest,
      applied_change_count: resolutionNow === 'not_applied' ? saved.changeCount : 0,
      permission_change_count: permissionChangeCount,
      added_user_count: addedUserCount,
      removed_user_count: removedUserCount,
      restrictive_change_count: restrictiveChangeCount,
      destructive_actions_performed: restrictiveChangeCount > 0,
      recovered: true,
    });
    state.aclRecovery = null;
    return {
      command: 'acl-recovery-apply',
      session_id: state.sessionId,
      acl_batch_id: batchId,
      recovery_id: saved.recoveryId,
      resolution: resolutionNow,
      remote_write_performed: resolutionNow === 'not_applied',
      permission_change_count: permissionChangeCount,
      added_user_count: addedUserCount,
      removed_user_count: removedUserCount,
      restrictive_change_count: restrictiveChangeCount,
      apply_mode: saved.applyMode,
      destructive_actions_performed: restrictiveChangeCount > 0,
      complete: true,
    };
  }

  async recoveryReadiness(input) {
    const state = this.requireState(input);
    const reconciliationBatchId = normalizeReconciliationBatchId(input.reconciliation_batch_id);
    assert(reconciliationBatchId, 'RECONCILIATION_BATCH_REQUIRED', 'Il lotto locale da recuperare non e valido.');
    assert(this.progressWriter, 'PROGRESS_WRITER_REQUIRED', 'Il canale durevole di recupero non e disponibile.');
    await verifyPersistentSession(state.session, String(state.user.id));
    const candidates = safeCandidates(input.candidates);
    const { capabilities, runtime } = await analyzeCapabilities(
      state.session,
      state.user,
      candidates,
      state.key,
      input.resource_format,
      input.destination_mode,
      input.folder_format === 'none' ? 'auto' : input.folder_format,
      input.destination_folder_id,
      input.client_destination_mapping,
      input.permission_mode,
      input.permission_template,
    );
    const plan = classifyRecovery(input.recovery_state, candidates, capabilities, runtime, String(state.user.id));
    assert(plan.recovery.batch_id === reconciliationBatchId, 'RECOVERY_BATCH_MISMATCH', 'Il registro locale non appartiene al lotto richiesto.');
    if (plan.conflicts.length) {
      throw new SafeError(
        'RECOVERY_CONFLICT',
        'Lo stato remoto non consente una ripresa automatica sicura. Il lotto richiede una verifica manuale.',
        {
          conflict_count: plan.conflicts.length,
          conflict_codes: [...new Set(plan.conflicts.map((item) => item.code))].sort(),
          destructive_actions_planned: false,
        },
      );
    }
    const recoveryId = randomUUID();
    for (const classification of plan.classifications) {
      await this.emitProgress(reconciliationBatchId, 'operation_verified', {
        ...classification,
        recovery_id: recoveryId,
      });
    }
    const remoteSuccessCount = plan.classifications.filter((item) => item.resolution === 'remote_success').length;
    const notAppliedCount = plan.classifications.length - remoteSuccessCount;
    await this.emitProgress(reconciliationBatchId, 'recovery_verified', {
      recovery_id: recoveryId,
      verification_digest: plan.verificationDigest,
      verified_operation_count: plan.classifications.length,
      remote_success_count: remoteSuccessCount,
      retry_count: notAppliedCount,
    });
    state.recoveryReadiness = {
      batchId: reconciliationBatchId,
      recoveryId,
      recoveryPlanDigest: plan.recoveryPlanDigest,
      resourceCandidateIds: plan.resourceCandidateIds,
    };
    return {
      command: 'recovery-readiness',
      session_id: state.sessionId,
      reconciliation_batch_id: reconciliationBatchId,
      recovery_id: recoveryId,
      recovery_plan_digest: plan.recoveryPlanDigest,
      verified_operation_count: plan.classifications.length,
      remote_success_count: remoteSuccessCount,
      not_applied_count: notAppliedCount,
      retry_action_count: plan.retryActionCount,
      resource_candidate_ids: plan.resourceCandidateIds,
      conflict_count: 0,
      can_recover: true,
      destructive_actions_planned: false,
      confirmation_required: `RECUPERA ${plan.retryActionCount}`,
    };
  }

  async recoveryImport(input) {
    const state = this.requireState(input);
    const saved = state.recoveryReadiness;
    assert(saved, 'RECOVERY_READINESS_REQUIRED', 'Eseguire prima la verifica autenticata del lotto.');
    const reconciliationBatchId = normalizeReconciliationBatchId(input.reconciliation_batch_id);
    assert(reconciliationBatchId === saved.batchId, 'RECOVERY_BATCH_MISMATCH', 'Il lotto non corrisponde all’ultima verifica di recupero.');
    assert(String(input.recovery_id ?? '') === saved.recoveryId, 'RECOVERY_ID_MISMATCH', 'La verifica di recupero non corrisponde.');
    assert(String(input.recovery_plan_digest ?? '') === saved.recoveryPlanDigest, 'RECOVERY_PLAN_CHANGED', 'Il piano di recupero non corrisponde all’ultima verifica.');
    assert(this.progressWriter, 'PROGRESS_WRITER_REQUIRED', 'Il canale durevole di recupero non e disponibile.');
    await verifyPersistentSession(state.session, String(state.user.id));
    const candidates = safeCandidates(input.candidates);
    const { capabilities, runtime } = await analyzeCapabilities(
      state.session,
      state.user,
      candidates,
      state.key,
      input.resource_format,
      input.destination_mode,
      input.folder_format === 'none' ? 'auto' : input.folder_format,
      input.destination_folder_id,
      input.client_destination_mapping,
      input.permission_mode,
      input.permission_template,
    );
    const plan = classifyRecovery(input.recovery_state, candidates, capabilities, runtime, String(state.user.id));
    assert(plan.conflicts.length === 0, 'RECOVERY_PLAN_CHANGED', 'Lo stato remoto e cambiato dopo la verifica; ripetere il controllo del lotto.');
    assert(plan.recoveryPlanDigest === saved.recoveryPlanDigest, 'RECOVERY_PLAN_CHANGED', 'Lo stato remoto e cambiato dopo la verifica; ripetere il controllo del lotto.');
    assert(canonicalJson(plan.resourceCandidateIds) === canonicalJson(saved.resourceCandidateIds), 'RECOVERY_PLAN_CHANGED', 'Le risorse richieste dal recupero sono cambiate.');
    assert(String(input.confirmation ?? '') === `RECUPERA ${plan.retryActionCount}`, 'CONFIRMATION_MISMATCH', `Conferma richiesta: RECUPERA ${plan.retryActionCount}`);
    const resourceCandidateIdSet = new Set(plan.resourceCandidateIds);
    const createCandidateIdSet = new Set(plan.createCandidateIds);
    const recoveryCandidates = capabilities.candidates.filter((candidate) => resourceCandidateIdSet.has(candidate.candidate_id));
    const resources = importResources(input.resources, recoveryCandidates);
    const resourceMap = new Map(resources.map((resource) => [resource.candidate_id, resource]));
    const plannedCandidatesById = new Map(
      capabilities.candidates.map((candidate) => [candidate.candidate_id, candidate]),
    );
    const existingResourcesById = new Map(
      runtime.existingResources.map((resource) => [resource.id, resource]),
    );
    const recoveryOperationsById = new Map(
      plan.recovery.operations.map((operation) => [operation.operation_id, operation]),
    );
    const progress = async (eventType, payload) => this.emitProgress(reconciliationBatchId, eventType, payload);
    try {
      const createPlan = capabilities.candidates.filter((candidate) => createCandidateIdSet.has(candidate.candidate_id));
      const recoveryRuntime = { ...runtime, folders: plan.retryFolders };
      const { created, createdFolders, reconciledFolders } = await createPlannedContent(
        state.session,
        createPlan,
        resources,
        recoveryRuntime,
        state.key,
        progress,
      );
      const repairedResources = [];
      for (const candidateId of plan.repairResourceCandidateIds) {
        const planned = plannedCandidatesById.get(candidateId);
        const resource = resourceMap.get(candidateId);
        const existing = existingResourcesById.get(planned?.duplicate_resource_id);
        assert(planned && resource && existing?.permission, 'RECOVERY_RESOURCE_SHARE_UNAVAILABLE', 'La risorsa da riconciliare non espone un permesso proprietario valido.');
        const operationId = randomUUID();
        await progress('operation_intent', {
          operation_id: operationId,
          object_type: 'resource',
          action: 'share_resource',
          candidate_id: candidateId,
          destination_key_hash: technicalDigest(planned.destination_key),
          permission_mask_hash: permissionMaskDigest(planned.share_permissions),
        });
        try {
          const shareResult = await shareCreatedResource(state.session, existing.id, existing.permission, planned, resource, runtime, state.key);
          repairedResources.push({ candidate_id: candidateId, resource_id: existing.id, status: 'created_shared' });
          await progress('resource_shared', {
            operation_id: operationId,
            resource_id: existing.id,
            candidate_id: candidateId,
            status: 'created_shared',
            recipient_count: Number(planned.share_recipient_count ?? 0),
            permission_change_count: Number(shareResult.permission_changes ?? 0),
          });
        } catch (error) {
          await progress('operation_failed', {
            operation_id: operationId,
            object_type: 'resource',
            candidate_id: candidateId,
            resource_id: existing.id,
            error_code: error instanceof SafeError ? error.code : 'INTERNAL_ERROR',
            outcome: 'unknown',
            ...(error instanceof SafeError && Number.isInteger(error.details?.http_status) ? { http_status: error.details.http_status } : {}),
          });
          throw error;
        }
      }
      let verifiedFolderCreates = 0;
      let verifiedResourceCreates = 0;
      let verifiedResourceShares = 0;
      let remoteSuccessCount = 0;
      for (const classification of plan.classifications) {
        if (classification.resolution !== 'remote_success') continue;
        remoteSuccessCount += 1;
        const action = recoveryOperationsById.get(classification.operation_id)?.action;
        if (action === 'create_folder') verifiedFolderCreates += 1;
        else if (action === 'create_resource') verifiedResourceCreates += 1;
        else if (action === 'share_resource') verifiedResourceShares += 1;
      }
      await progress('batch_completed', {
        created_folder_count: verifiedFolderCreates + createdFolders.length,
        reconciled_folder_count: reconciledFolders.length,
        created_resource_count: verifiedResourceCreates + created.length,
        shared_resource_count: verifiedResourceShares + repairedResources.length + created.filter((item) => item.status === 'created_shared').length,
        skipped_duplicate_count: plan.recovery.duplicate_candidates.length,
      });
      state.recoveryReadiness = null;
      return {
        command: 'recovery-import',
        session_id: state.sessionId,
        reconciliation_batch_id: reconciliationBatchId,
        recovery_id: saved.recoveryId,
        created_count: created.length,
        repaired_resource_count: repairedResources.length,
        created_folder_count: createdFolders.length,
        reconciled_folder_count: reconciledFolders.length,
        remote_success_count: remoteSuccessCount,
        destructive_actions_performed: false,
        complete: true,
      };
    } finally {
      resources.length = 0;
      if (Array.isArray(input.resources)) input.resources.length = 0;
    }
  }

  async import(input) {
    const state = this.requireState(input);
    const reconciliationBatchId = normalizeReconciliationBatchId(input.reconciliation_batch_id);
    assert(reconciliationBatchId, 'RECONCILIATION_BATCH_REQUIRED', 'Il registro locale di riconciliazione non e stato inizializzato.');
    assert(this.progressWriter, 'PROGRESS_WRITER_REQUIRED', 'Il canale durevole di avanzamento non e disponibile.');
    const progress = async (eventType, payload) => this.emitProgress(reconciliationBatchId, eventType, payload);
    await verifyPersistentSession(state.session, String(state.user.id));
    const candidates = safeCandidates(input.candidates);
    const { capabilities, runtime } = await analyzeCapabilities(
      state.session,
      state.user,
      candidates,
      state.key,
      input.resource_format,
      input.destination_mode,
      input.folder_format,
      input.destination_folder_id,
      input.client_destination_mapping,
      input.permission_mode,
      input.permission_template,
    );
    assert(capabilities.can_import, 'IMPORT_NOT_SUPPORTED', capabilities.unavailable_reason || 'Importazione non disponibile su questa istanza.');
    assert(String(input.plan_digest ?? '') === capabilities.plan_digest, 'STALE_PLAN', 'Il contenuto di Passbolt o il piano sono cambiati dopo il dry-run. Ripetere la verifica.');
    const createPlan = capabilities.candidates.filter((item) => item.action === 'create');
    assert(createPlan.length > 0, 'NOTHING_TO_IMPORT', 'Tutti i candidati selezionati risultano gia presenti.');
    assert(String(input.confirmation ?? '') === `IMPORTA ${createPlan.length}`, 'CONFIRMATION_MISMATCH', `Conferma richiesta: IMPORTA ${createPlan.length}`);
    const resources = importResources(input.resources, createPlan);
    try {
      for (const duplicate of capabilities.candidates.filter((item) => item.action === 'duplicate')) {
        await progress('duplicate_skipped', {
          candidate_id: duplicate.candidate_id,
          duplicate_kind: duplicate.duplicate_kind,
          ...(duplicate.duplicate_resource_id ? { resource_id: duplicate.duplicate_resource_id } : {}),
        });
      }
      const { created, createdFolders, reconciledFolders } = await createPlannedContent(
        state.session,
        createPlan,
        resources,
        runtime,
        state.key,
        progress,
      );
      const verificationResults = await verifyCreatedResources(
        state.session,
        created,
        createPlan,
        resources,
        runtime,
        state.key,
        String(state.user.id),
        progress,
        { created_folders: createdFolders, reconciled_folders: reconciledFolders },
      );
      const result = {
        command: 'import',
        session_id: state.sessionId,
        authentication: state.mfaProvider ? 'GPGAuth + TOTP' : 'GPGAuth',
        mfa_provider: state.mfaProvider,
        created_count: created.length,
        shared_created_count: created.filter((item) => item.status === 'created_shared').length,
        encrypted_secret_copy_count: capabilities.encrypted_secret_copy_count,
        skipped_duplicate_count: capabilities.duplicate_count,
        created_folder_count: createdFolders.length,
        shared_created_folder_count: createdFolders.filter((item) => item.status === 'created_shared').length,
        reconciled_shared_folder_count: reconciledFolders.length,
        reused_folder_count: capabilities.reuse_folder_count,
        resource_format: capabilities.resource_format_selected,
        folder_format: capabilities.folder_format_selected,
        resource_type: capabilities.resource_type,
        created_folders: createdFolders,
        reconciled_folders: reconciledFolders,
        created,
        verification_status: 'verified',
        verified_resource_count: verificationResults.length,
        verification_failed_count: 0,
        verification_results: verificationResults,
        complete: true,
      };
      await progress('batch_completed', {
        created_folder_count: createdFolders.length,
        reconciled_folder_count: reconciledFolders.length,
        created_resource_count: created.length,
        shared_resource_count: created.filter((item) => item.status === 'created_shared').length,
        skipped_duplicate_count: capabilities.duplicate_count,
        verified_resource_count: verificationResults.length,
      });
      return result;
    } finally {
      resources.length = 0;
      if (Array.isArray(input.resources)) input.resources.length = 0;
    }
  }

  async close(input = {}) {
    if (!this.state) {
      return { command: 'session-close', closed: true };
    }
    if (input.session_id !== undefined) {
      assert(String(input.session_id) === this.state.sessionId, 'IMPORT_SESSION_ID_MISMATCH', 'L’identificatore della sessione locale non corrisponde.');
    }
    const sessionId = this.state.sessionId;
    const session = this.state.session;
    this.state = null;
    await logout(session);
    return { command: 'session-close', session_id: sessionId, closed: true };
  }

  async dispatch(input) {
    switch (input.command) {
      case 'session-open':
        return this.open(input);
      case 'session-readiness':
        return this.readiness(input);
      case 'session-permissions':
        return this.permissions(input);
      case 'session-acl-catalog':
        return this.aclCatalog(input);
      case 'session-acl-plan':
        return this.aclPlan(input);
      case 'session-acl-apply':
        return this.aclApply(input);
      case 'session-acl-recovery-readiness':
        return this.aclRecoveryReadiness(input);
      case 'session-acl-recovery-apply':
        return this.aclRecoveryApply(input);
      case 'session-import':
        return this.import(input);
      case 'session-recovery-readiness':
        return this.recoveryReadiness(input);
      case 'session-recovery-import':
        return this.recoveryImport(input);
      case 'session-close':
        return this.close(input);
      default:
        throw new SafeError('UNKNOWN_SESSION_COMMAND', 'Comando della sessione di importazione non riconosciuto.');
    }
  }
}

async function selfTest() {
  const bomInputProbe = JSON.parse(stripUtf8Bom('\ufeff{"ok":true}'));
  assert(bomInputProbe.ok === true, 'SELF_TEST_FAILED', 'La normalizzazione del BOM UTF-8 non e disponibile.');
  const passphrase = `self-test-${randomUUID()}`;
  const unlimitedCandidateProbe = safeCandidates(Array.from({ length: 64 }, (_, index) => ({
    candidate_id: `unlimited-candidate-${index}`,
    client: '(radice)',
    source_at_root: true,
    title: `Candidato ${index}`,
    username: `utente-${index}`,
    uri: `https://example.test/${index}`,
  })));
  assert(unlimitedCandidateProbe.length === 64, 'SELF_TEST_FAILED', 'La selezione senza limite numerico non e disponibile.');
  const indexedPlanningCandidates = Array.from({ length: 512 }, (_, index) => ({
    candidate_id: `indexed-candidate-${index}`,
    title: `Candidato indicizzato ${index}`,
    username: `indexed-user-${index}`,
    uri: `https://indexed-${index}.example.test`,
  }));
  const indexedPlanningResources = indexedPlanningCandidates.slice(0, 256).map((candidate, index) => ({
    id: `indexed-resource-${index}`,
    name: candidate.title,
    username: candidate.username,
    uri: candidate.uri,
    folder_parent_id: null,
  }));
  const indexedPlanningProbe = buildCandidatePlan(
    indexedPlanningCandidates,
    indexedPlanningResources,
    true,
  );
  assert(indexedPlanningProbe.filter((item) => item.action === 'duplicate').length === 256, 'SELF_TEST_FAILED', 'La pianificazione indicizzata dei duplicati non e disponibile.');
  assert(indexedPlanningProbe.filter((item) => item.action === 'create').length === 256, 'SELF_TEST_FAILED', 'La pianificazione indicizzata delle creazioni non e disponibile.');
  const generated = await openpgp.generateKey({
    type: 'ecc',
    curve: 'curve25519',
    userIDs: [{ name: 'Passbolt Migration Self Test', email: 'self-test@example.invalid' }],
    passphrase,
    format: 'armored',
  });
  let privateKey = await openpgp.readPrivateKey({ armoredKey: generated.privateKey });
  privateKey = await openpgp.decryptKey({ privateKey, passphrase });
  const publicKey = await openpgp.readKey({ armoredKey: generated.publicKey });
  const marker = `openpgp-self-test-${randomUUID()}`;
  const encrypted = await openpgp.encrypt({
    message: await openpgp.createMessage({ text: marker }),
    encryptionKeys: publicKey,
    signingKeys: privateKey,
    format: 'armored',
  });
  const decrypted = await openpgp.decrypt({
    message: await openpgp.readMessage({ armoredMessage: encrypted }),
    decryptionKeys: privateKey,
    verificationKeys: publicKey,
    format: 'utf8',
  });
  await Promise.all(decrypted.signatures.map((signature) => signature.verified));
  assert(decrypted.data === marker, 'SELF_TEST_FAILED', 'Il test OpenPGP locale non e riuscito.');
  const formEncodedArmor = encodeURIComponent(encrypted).replace(/%20/g, '+');
  assert(decodeHeaderValue(formEncodedArmor) === encrypted, 'SELF_TEST_FAILED', 'La decodifica form-urlencoded degli header GPGAuth non e riuscita.');
  const secretMessage = await encryptSecret(
    'self-test-secret',
    'self-test-description',
    { slug: 'password-and-description' },
    { privateKey, publicKey },
  );
  const secretResult = await openpgp.decrypt({
    message: await openpgp.readMessage({ armoredMessage: secretMessage }),
    decryptionKeys: privateKey,
    verificationKeys: publicKey,
    format: 'utf8',
  });
  await Promise.all(secretResult.signatures.map((signature) => signature.verified));
  const secretDocument = JSON.parse(secretResult.data);
  assert(secretDocument.password === 'self-test-secret' && secretDocument.description === 'self-test-description', 'SELF_TEST_FAILED', 'Lo schema del segreto Passbolt non e valido.');
  const legacyPayload = await buildResourcePayload(
    {
      title: 'Self test legacy',
      username: 'self-test-user',
      uri: 'https://self-test.example.invalid',
      password: 'self-test-string-secret',
      description: 'self-test-clear-description',
    },
    {
      selectedFormat: 'v4',
      resourceType: { id: 'self-test-v4-string', slug: 'password-string', definition: null },
      metadataEncryptionKey: null,
    },
    { privateKey, publicKey },
  );
  assert(legacyPayload.description === 'self-test-clear-description', 'SELF_TEST_FAILED', 'La descrizione del tipo v4 password-string non e stata instradata nei metadati.');
  const legacySecret = await decryptMessageText(legacyPayload.secrets[0].data, privateKey, publicKey, true);
  assert(legacySecret === 'self-test-string-secret', 'SELF_TEST_FAILED', 'Il segreto del tipo v4 password-string non e valido.');
  const duplicatePlan = buildCandidatePlan(
    [{ candidate_id: 'candidate-a', title: 'Portale', username: 'utente', uri: 'https://example.test' }],
    [{ id: 'resource-a', name: ' portale ', username: 'UTENTE', uri: 'https://example.test' }],
    true,
  );
  assert(duplicatePlan[0].action === 'duplicate' && duplicatePlan[0].duplicate_resource_id === 'resource-a', 'SELF_TEST_FAILED', 'Il test di rilevamento duplicati non e riuscito.');
  const batchDuplicatePlan = buildCandidatePlan(
    [
      { candidate_id: 'candidate-a', title: 'Portale', username: 'utente', uri: 'https://example.test' },
      { candidate_id: 'candidate-b', title: ' portale ', username: 'UTENTE', uri: 'https://example.test' },
    ],
    [],
    true,
  );
  assert(batchDuplicatePlan[0].action === 'create' && batchDuplicatePlan[1].duplicate_kind === 'batch', 'SELF_TEST_FAILED', 'Il test dei duplicati interni al lotto non e riuscito.');
  return {
    command: 'self-test',
    openpgp_version: '6.3.1',
    encryption: true,
    decryption: true,
    signature_verification: true,
    gpgauth_header_form_decoding: true,
    official_wrapped_gpgauth_payload_contract: true,
    official_minimal_totp_payload_contract: true,
    unlimited_candidate_selection: true,
    indexed_large_batch_planning: true,
    passbolt_secret_schema: true,
    passbolt_string_secret_schema: true,
    duplicate_detection: true,
    utf8_bom_input: true,
    persistent_session_protocol: true,
    reconciliation_progress_protocol: true,
    batch_dashboard_progress_protocol: true,
    authenticated_preflight_protocol: true,
    post_import_verification_protocol: true,
    authenticated_recovery_protocol: true,
    permission_editor_protocol: true,
    existing_acl_viewer_protocol: true,
    existing_acl_dry_run_protocol: true,
    existing_acl_additive_apply_protocol: true,
    existing_acl_restrictive_apply_protocol: true,
    existing_acl_recovery_protocol: true,
    secrets_serialized: false,
  };
}

async function dispatch(input) {
  switch (input.command) {
    case 'self-test':
      return selfTest();
    case 'inspect-key':
      return inspectKey(input);
    case 'readiness':
      return readiness(input);
    case 'import':
      return executeImport(input);
    default:
      throw new SafeError('UNKNOWN_COMMAND', 'Comando crittografico locale non riconosciuto.');
  }
}

function safeFailure(error) {
  if (error instanceof SafeError) {
    return {
      ok: false,
      error: {
        code: error.code,
        message: error.message,
        ...(error.details === undefined ? {} : { details: error.details }),
      },
    };
  }
  return {
    ok: false,
    error: {
      code: 'INTERNAL_ERROR',
      message: 'Errore interno nella procedura crittografica locale.',
    },
  };
}

async function main() {
  try {
    const input = await readInput();
    const result = await dispatch(input);
    process.stdout.write(`${JSON.stringify({ ok: true, result })}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify(safeFailure(error))}\n`);
    process.exitCode = 2;
  }
}

async function writeSessionEnvelope(document) {
  const encoded = `${JSON.stringify(document)}\n`;
  assert(Buffer.byteLength(encoded, 'utf8') <= RESPONSE_LIMIT, 'SESSION_RESPONSE_TOO_LARGE', 'La risposta della sessione locale e troppo grande.');
  if (!process.stdout.write(encoded)) {
    await once(process.stdout, 'drain');
  }
}

async function mainPersistentSession() {
  const worker = new PersistentImportSession(writeSessionEnvelope);
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity, terminal: false });
  try {
    for await (let line of lines) {
      if (!line.trim()) continue;
      let input = null;
      let closeRequested = false;
      try {
        assert(Buffer.byteLength(line, 'utf8') <= INPUT_LIMIT, 'INPUT_TOO_LARGE', 'Richiesta della sessione locale troppo grande.');
        try {
          input = JSON.parse(stripUtf8Bom(line));
        } catch {
          throw new SafeError('INVALID_INPUT', 'La richiesta della sessione locale non contiene JSON valido.');
        }
        assert(input && typeof input === 'object' && !Array.isArray(input), 'INVALID_INPUT', 'La richiesta della sessione locale deve essere un oggetto JSON.');
        closeRequested = input.command === 'session-close';
        const result = await worker.dispatch(input);
        await writeSessionEnvelope({ ok: true, result });
      } catch (error) {
        await writeSessionEnvelope(safeFailure(error));
      } finally {
        if (input && typeof input === 'object') {
          input.passphrase = null;
          input.mfa_totp = null;
          if (Array.isArray(input.resources)) input.resources.length = 0;
        }
        input = null;
        line = '';
      }
      if (closeRequested) break;
    }
  } finally {
    await worker.close();
    lines.close();
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : '';
if (import.meta.url === invokedPath) {
  if (process.argv.includes('--session')) {
    await mainPersistentSession();
  } else {
    await main();
  }
}

export {
  PassboltSession,
  PersistentImportSession,
  analyzeCapabilities,
  authenticate,
  buildCandidatePlan,
  buildFolderPayload,
  buildResourcePayload,
  classifyRecovery,
  createPlannedContent,
  verifyCreatedResources,
  encryptSecret,
  buildAclObjectCatalog,
  buildAclChangePlan,
  permissionMaskDigest,
  readCapabilities,
};
