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

const INPUT_LIMIT = 8 * 1024 * 1024;
const KEY_FILE_LIMIT = 2 * 1024 * 1024;
const RESPONSE_LIMIT = 12 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 25_000;
const MAX_REDIRECTS = 5;
const MAX_IMPORT_RESOURCES = 25;
const USER_AGENT = 'Passbolt-Migration-Assistant/0.12.5';
const RESOURCE_METADATA_OBJECT_TYPE = 'PASSBOLT_RESOURCE_METADATA';
const FOLDER_METADATA_OBJECT_TYPE = 'PASSBOLT_FOLDER_METADATA';
const SECRET_DATA_OBJECT_TYPE = 'PASSBOLT_SECRET_DATA';
const METADATA_PRIVATE_KEY_OBJECT_TYPE = 'PASSBOLT_METADATA_PRIVATE_KEY';
const TOKEN_PATTERN = /^gpgauthv1\.3\.0\|36\|[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\|gpgauthv1\.3\.0$/i;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

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
    value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
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
  const response = await session.request('/mfa/verify/totp.json?api-version=v2', {
    method: 'POST',
    body: { totp, remember: 0 },
    allowError: true,
  });
  const responseHeader = response.document && typeof response.document === 'object' ? response.document.header : null;
  const apiFailed = responseHeader && typeof responseHeader === 'object' && responseHeader.status === 'error';
  if (response.status === 429) {
    throw new SafeError('MFA_RATE_LIMITED', 'Troppi tentativi MFA. Attendere e riprovare con un nuovo codice TOTP.', { http_status: response.status });
  }
  if (response.status < 200 || response.status >= 300 || apiFailed) {
    throw new SafeError(
      'MFA_TOTP_REJECTED',
      'Il codice MFA TOTP non e stato accettato. Generare un nuovo codice e riprovare.',
      { http_status: response.status },
    );
  }
  assert(session.getCookie('passbolt_mfa'), 'MFA_COOKIE_MISSING', 'Passbolt ha accettato il codice MFA ma non ha restituito il cookie di autorizzazione atteso.');
  return 'totp';
}

async function authenticate(session, keyMaterial, expectedFingerprint, mfaTotp = '') {
  const serverPublicKey = await getServerKey(session, expectedFingerprint);
  await verifyServerOwnership(session, serverPublicKey, keyMaterial.fingerprint);

  let wrappedPayload = false;
  let stageOne = await session.request('/auth/login.json?api-version=v2', {
    method: 'POST',
    body: { gpg_auth: { keyid: keyMaterial.fingerprint } },
    allowError: true,
  });
  let challengeHeader = stageOne.headers.get('x-gpgauth-user-auth-token');
  if (!challengeHeader) {
    wrappedPayload = true;
    stageOne = await session.request('/auth/login.json?api-version=v2', {
      method: 'POST',
      body: { data: { gpg_auth: { keyid: keyMaterial.fingerprint } } },
      allowError: true,
    });
    challengeHeader = stageOne.headers.get('x-gpgauth-user-auth-token');
  }
  assert(challengeHeader, 'AUTH_CHALLENGE_MISSING', apiMessage(stageOne.document, 'Passbolt non ha restituito la sfida GPGAuth per questo utente.'));
  const challenge = decodeHeaderValue(challengeHeader);
  const token = await decryptServerChallenge(challenge, keyMaterial.privateKey, serverPublicKey);

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
  const hasSession = ['passbolt_session', 'CAKEPHP', 'PHPSESSID'].some((name) => Boolean(session.getCookie(name)));
  assert(hasSession, 'AUTH_SESSION_MISSING', 'Il login non ha restituito un cookie di sessione Passbolt.');

  let mfaProvider = null;
  let meResponse = await session.request('/users/me.json?api-version=v2', { allowError: true });
  if (isMfaChallengeResponse(meResponse)) {
    mfaProvider = await completeTotpMfa(session, meResponse, mfaTotp);
    meResponse = await session.request('/users/me.json?api-version=v2', { allowError: true });
    if (isMfaChallengeResponse(meResponse)) {
      throw new SafeError('MFA_TOTP_REJECTED', 'La verifica MFA non ha autorizzato la sessione. Generare un nuovo codice TOTP e riprovare.');
    }
  }
  if (meResponse.status < 200 || meResponse.status >= 300) {
    const redirectNote = meResponse.redirects.length ? ` dopo ${meResponse.redirects.length} redirect interno` : '';
    throw new SafeError('AUTH_IDENTITY_FAILED', apiMessage(meResponse.document, `Lettura dell'identita utente non riuscita (HTTP ${meResponse.status}${redirectNote}).`));
  }
  const user = apiBody(meResponse.document);
  assert(user && typeof user === 'object' && typeof user.id === 'string', 'AUTH_IDENTITY_INVALID', "Passbolt non ha restituito un'identita utente valida.");
  const accountFingerprint = user.gpgkey && typeof user.gpgkey === 'object' && typeof user.gpgkey.fingerprint === 'string'
    ? normalizeFingerprint(user.gpgkey.fingerprint, "Fingerprint dell'account Passbolt")
    : null;
  assert(!accountFingerprint || accountFingerprint === keyMaterial.fingerprint, 'AUTH_KEY_IDENTITY_MISMATCH', "La chiave privata non corrisponde alla chiave dell'identita Passbolt autenticata.");
  return { user, serverPublicKey, mfaProvider };
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
  assert(value.length <= MAX_IMPORT_RESOURCES, 'TOO_MANY_CANDIDATES', `Importare al massimo ${MAX_IMPORT_RESOURCES} credenziali per volta.`);
  const seen = new Set();
  return value.map((item) => {
    assert(item && typeof item === 'object', 'INVALID_CANDIDATE', 'Un candidato del piano non e valido.');
    const candidateId = String(item.candidate_id ?? '').trim();
    const title = String(item.title ?? '').trim();
    const username = String(item.username ?? '').trim();
    const uri = String(item.uri ?? '').trim();
    const client = String(item.client ?? '').trim();
    const sourceAtRoot = item.source_at_root;
    assert(candidateId && candidateId.length <= 200, 'INVALID_CANDIDATE', 'Un candidato non contiene un identificatore valido.');
    assert(!seen.has(candidateId), 'DUPLICATE_CANDIDATE_ID', 'Il piano contiene due volte lo stesso candidato.');
    assert(title && title.length <= 255, 'INVALID_TITLE', 'Ogni candidato deve avere un titolo di massimo 255 caratteri.');
    assert(username.length <= 255 && uri.length <= 2048, 'INVALID_CANDIDATE', 'Username o URL superano i limiti consentiti.');
    assert(client && client.length <= 256, 'INVALID_CLIENT', 'Ogni candidato deve indicare un cliente valido.');
    assert(typeof sourceAtRoot === 'boolean', 'INVALID_CLIENT', 'Ogni candidato deve indicare se il documento si trova nella radice sorgente.');
    assert(!/[\u0000-\u001f\u007f]/.test(title + username + uri + client), 'INVALID_CANDIDATE', 'Titolo, username, URL o cliente contengono caratteri di controllo non consentiti.');
    seen.add(candidateId);
    return { candidate_id: candidateId, client, source_at_root: sourceAtRoot, title, username, uri };
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
  const resolvePath = (folder, ancestors = new Set()) => {
    if (pathCache.has(folder.id)) return pathCache.get(folder.id);
    assert(!ancestors.has(folder.id), 'FOLDER_TREE_INVALID', 'La struttura delle cartelle Passbolt contiene un ciclo non valido.');
    const nextAncestors = new Set(ancestors);
    nextAncestors.add(folder.id);
    const parent = folder.folder_parent_id ? byId.get(folder.folder_parent_id) : null;
    const path = parent
      ? `${resolvePath(parent, nextAncestors)} / ${folder.name}`
      : folder.name;
    pathCache.set(folder.id, path);
    return path;
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
      const folder = existingFolders.find((entry) => entry.id === mapping.folder_id) ?? null;
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
    ? existingFolders.find((folder) => folder.id === destinationFolderId) ?? null
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
    const destinationKey = `client:${parentId ?? 'root'}:${normalizeComparable(candidate.client)}`;
    if (folderPlans.has(destinationKey)) continue;
    const matches = existingFolders.filter((folder) => (
      folder.folder_parent_id === parentId
      && normalizeComparable(folder.name) === normalizeComparable(candidate.client)
    ));
    if (matches.length > 1) {
      const matchingIds = matches.map((folder) => folder.id).join(', ');
      failure = `Esistono ${matches.length} cartelle chiamate ${candidate.client} nello stesso contenitore Passbolt (ID: ${matchingIds}). La destinazione non e univoca: eliminare in Passbolt le copie personali vuote in eccesso, lasciarne una sola e ripetere il dry-run.`;
    }
    const match = matches.length === 1 ? matches[0] : null;
    let reconcilePersonalFolder = false;
    if (match && selectedFolder?.shared && !match.shared) {
      const containsResources = existingResources.some((resource) => resource.folder_parent_id === match.id);
      const containsFolders = existingFolders.some((folder) => folder.folder_parent_id === match.id);
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

function buildCandidatePlan(candidates, existingResources, duplicateDetectionAvailable, destinations = null) {
  const planned = [];
  for (const candidate of candidates) {
    const destination = destinations?.get(candidate.candidate_id) ?? {
      destination_key: 'root',
      folder_action: 'root',
      folder_id: null,
      folder_name: null,
      folder_path: 'Radice Passbolt',
    };
    const exactMatches = duplicateDetectionAvailable
      ? existingResources.filter((resource) => (
        normalizeComparable(resource.name) === normalizeComparable(candidate.title)
        && normalizeComparable(resource.username) === normalizeComparable(candidate.username)
        && normalizeComparable(resource.uri) === normalizeComparable(candidate.uri)
      ))
      : [];
    const inDestination = exactMatches.find((resource) => (
      destination.folder_action === 'root'
        ? resource.folder_parent_id === null || resource.folder_parent_id === undefined
        : ['reuse', 'repair_share'].includes(destination.folder_action) && resource.folder_parent_id === destination.folder_id
    ));
    const elsewhere = !inDestination ? exactMatches[0] : null;
    const batchMatch = planned.find((item) => (
      item.action === 'create'
      &&
      normalizeComparable(item.title) === normalizeComparable(candidate.title)
      && normalizeComparable(item.username) === normalizeComparable(candidate.username)
      && normalizeComparable(item.uri) === normalizeComparable(candidate.uri)
      && item.destination_key === destination.destination_key
    ));
    const action = inDestination || batchMatch ? 'duplicate' : elsewhere ? 'blocked' : 'create';
    planned.push({
      ...candidate,
      ...destination,
      action,
      duplicate_kind: inDestination ? 'server_destination' : batchMatch ? 'batch' : elsewhere ? 'server_elsewhere' : null,
      duplicate_resource_id: inDestination?.id ?? elsewhere?.id ?? null,
      duplicate_candidate_id: !inDestination && batchMatch ? batchMatch.candidate_id : null,
    });
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
    session.request('/resources.json?api-version=v2', { allowError: true }),
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
  let destinationPlan = planDestinations(
    candidates,
    folderCatalog,
    existingResources,
    destinationMode,
    selectedFolderFormat,
    destinationFolderId,
    clientDestinationMapping,
  );
  let candidatePlan = buildCandidatePlan(candidates, existingResources, duplicateDetectionAvailable, destinationPlan.destinations);
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
      destinationPlan = planDestinations(
        candidates,
        folderCatalog,
        existingResources,
        destinationMode,
        selectedFolderFormat,
        destinationFolderId,
        clientDestinationMapping,
      );
      candidatePlan = buildCandidatePlan(candidates, existingResources, duplicateDetectionAvailable, destinationPlan.destinations);
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
  const digestPayload = {
    user_id: String(user.id),
    resource_format_requested: requestedFormat,
    resource_format_selected: selectedFormat,
    resource_type_id: resourceType?.id ?? null,
    resource_type_slug: resourceType?.slug ?? null,
    destination_mode: destinationMode,
    destination_folder_id: destinationFolderId,
    client_destination_mapping: clientDestinationMapping.entries,
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
      folders: folderPlan,
    },
  };
}

async function readCapabilities(session, user, candidates, keyMaterial = null, resourceFormat = 'auto', destinationMode = 'client_folders', folderFormat = 'auto', destinationFolderId = null, clientDestinationMapping = null) {
  return (await analyzeCapabilities(session, user, candidates, keyMaterial, resourceFormat, destinationMode, folderFormat, destinationFolderId, clientDestinationMapping)).capabilities;
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

function simulatedAddedUserIds(document) {
  const body = apiBody(document);
  const changes = body && typeof body === 'object' ? body.changes : null;
  assert(changes && typeof changes === 'object', 'SHARE_SIMULATION_INVALID', 'La simulazione Passbolt non contiene il riepilogo delle modifiche.');
  const added = Array.isArray(changes.added) ? changes.added : [];
  const ids = [];
  for (const item of added) {
    const id = String(item?.User?.id ?? '');
    assert(id, 'SHARE_SIMULATION_INVALID', 'La simulazione Passbolt contiene un destinatario non riconoscibile.');
    if (!ids.includes(id)) ids.push(id);
  }
  return ids.sort();
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

  const addedUserIds = simulatedAddedUserIds(simulation.document);
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

async function createPlannedContent(session, createPlan, resources, runtime, keyMaterial) {
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
      } catch (error) {
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
    const response = await session.request('/folders.json?api-version=v2&contain[permission]=1', {
      method: 'POST',
      body: payload,
      allowError: true,
    });
    if (response.status < 200 || response.status >= 300) {
      throw new SafeError(
        'IMPORT_PARTIAL_FAILURE',
        apiMessage(response.document, `Creazione della cartella ${folder.name} non riuscita (HTTP ${response.status}).`),
        { created_folders: createdFolders, reconciled_folders: reconciledFolders, created, failed_folder_name: folder.name, http_status: response.status },
      );
    }
    const body = apiBody(response.document);
    const folderId = body && typeof body === 'object' && typeof body.id === 'string' ? body.id : '';
    if (!folderId) {
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
    if (folder.shared) {
      try {
        const shareResult = await shareCreatedFolder(session, folderId, body.permission, folder);
        createdFolder.status = 'created_shared';
        createdFolder.permission_changes = shareResult.permission_changes;
        createdFolder.added_user_count = shareResult.added_user_count;
      } catch (error) {
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
    const response = await session.request('/resources.json?api-version=v2&contain[permission]=1', {
      method: 'POST',
      body: payload,
      allowError: true,
    });
    if (response.status < 200 || response.status >= 300) {
      throw new SafeError(
        'IMPORT_PARTIAL_FAILURE',
        apiMessage(response.document, `Creazione di ${resource.title} non riuscita (HTTP ${response.status}).`),
        { created_folders: createdFolders, reconciled_folders: reconciledFolders, created, failed_candidate_id: resource.candidate_id, http_status: response.status },
      );
    }
    const body = apiBody(response.document);
    const resourceId = body && typeof body === 'object' && typeof body.id === 'string' ? body.id : '';
    if (!resourceId) {
      throw new SafeError(
        'IMPORT_PARTIAL_FAILURE',
        `Passbolt ha creato ${resource.title} senza restituire un identificatore utilizzabile.`,
        { created_folders: createdFolders, reconciled_folders: reconciledFolders, created, failed_candidate_id: resource.candidate_id, http_status: response.status },
      );
    }
    const createdEntry = {
      candidate_id: resource.candidate_id,
      resource_id: resourceId,
      status: planned.shared ? 'created_unshared' : 'created',
      shared: Boolean(planned.shared),
      share_recipient_count: Number(planned.share_recipient_count ?? 0),
    };
    created.push(createdEntry);
    if (planned.shared) {
      try {
        const shareResult = await shareCreatedResource(session, resourceId, body.permission, planned, resource, runtime, keyMaterial);
        createdEntry.status = 'created_shared';
        createdEntry.encrypted_secret_copies = shareResult.encrypted_secret_copies;
        createdEntry.permission_changes = shareResult.permission_changes;
      } catch (error) {
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
    );
    const { capabilities, runtime } = analysis;
    assert(capabilities.can_import, 'IMPORT_NOT_SUPPORTED', capabilities.unavailable_reason || 'Importazione non disponibile su questa istanza.');
    assert(String(input.plan_digest ?? '') === capabilities.plan_digest, 'STALE_PLAN', 'Il contenuto di Passbolt o il piano sono cambiati dopo il dry-run. Ripetere la verifica.');
    const createPlan = capabilities.candidates.filter((item) => item.action === 'create');
    assert(createPlan.length > 0, 'NOTHING_TO_IMPORT', 'Tutti i candidati selezionati risultano gia presenti.');
    assert(String(input.confirmation ?? '') === `IMPORTA ${createPlan.length}`, 'CONFIRMATION_MISMATCH', `Conferma richiesta: IMPORTA ${createPlan.length}`);
    const resources = importResources(input.resources, createPlan);
    const { created, createdFolders, reconciledFolders } = await createPlannedContent(session, createPlan, resources, runtime, key);
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
  constructor() {
    this.state = null;
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

  async import(input) {
    const state = this.requireState(input);
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
    );
    assert(capabilities.can_import, 'IMPORT_NOT_SUPPORTED', capabilities.unavailable_reason || 'Importazione non disponibile su questa istanza.');
    assert(String(input.plan_digest ?? '') === capabilities.plan_digest, 'STALE_PLAN', 'Il contenuto di Passbolt o il piano sono cambiati dopo il dry-run. Ripetere la verifica.');
    const createPlan = capabilities.candidates.filter((item) => item.action === 'create');
    assert(createPlan.length > 0, 'NOTHING_TO_IMPORT', 'Tutti i candidati selezionati risultano gia presenti.');
    assert(String(input.confirmation ?? '') === `IMPORTA ${createPlan.length}`, 'CONFIRMATION_MISMATCH', `Conferma richiesta: IMPORTA ${createPlan.length}`);
    const resources = importResources(input.resources, createPlan);
    try {
      const { created, createdFolders, reconciledFolders } = await createPlannedContent(state.session, createPlan, resources, runtime, state.key);
      return {
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
        complete: true,
      };
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
      case 'session-import':
        return this.import(input);
      case 'session-close':
        return this.close(input);
      default:
        throw new SafeError('UNKNOWN_SESSION_COMMAND', 'Comando della sessione di importazione non riconosciuto.');
    }
  }
}

async function selfTest() {
  const passphrase = `self-test-${randomUUID()}`;
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
    passbolt_secret_schema: true,
    passbolt_string_secret_schema: true,
    duplicate_detection: true,
    persistent_session_protocol: true,
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
  const worker = new PersistentImportSession();
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity, terminal: false });
  try {
    for await (let line of lines) {
      if (!line.trim()) continue;
      let input = null;
      let closeRequested = false;
      try {
        assert(Buffer.byteLength(line, 'utf8') <= INPUT_LIMIT, 'INPUT_TOO_LARGE', 'Richiesta della sessione locale troppo grande.');
        try {
          input = JSON.parse(line);
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
  createPlannedContent,
  encryptSecret,
  readCapabilities,
};
