#!/usr/bin/env node

/**
 * Ephemeral, localhost-only Passbolt protocol simulator.
 *
 * The server is intentionally separate from the production application. It
 * never accepts a non-loopback bind address, never logs request bodies and
 * writes all generated key material into a caller-provided temporary folder.
 */

import { randomBytes, randomUUID } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:https';
import { resolve } from 'node:path';
import * as openpgp from 'openpgp';

const APP_VERSION = '0.26.0';
const INPUT_LIMIT = 8 * 1024 * 1024;
const PROFILES = new Set(['v4', 'v5']);
const SCENARIOS = new Set(['healthy', 'mfa-rejected', 'session-expired']);
const FAULTS = new Set([
  'none',
  'next-resource-create-500',
  'next-resource-create-after-commit-500',
  'next-resource-create-disconnect',
  'next-resource-create-after-commit-disconnect',
  'next-folder-create-500',
  'next-folder-create-after-commit-500',
  'next-folder-create-disconnect',
  'next-folder-create-after-commit-disconnect',
  'next-share-500',
  'next-share-after-commit-500',
  'next-share-disconnect',
  'next-share-after-commit-disconnect',
  'expire-session',
]);

function fail(message) {
  throw new Error(message);
}

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (name === '--self-test') {
      result.selfTest = true;
      continue;
    }
    if (!name.startsWith('--') || index + 1 >= argv.length) fail(`Argomento non valido: ${name}`);
    result[name.slice(2)] = argv[index + 1];
    index += 1;
  }
  return result;
}

function apiSuccess(body) {
  return JSON.stringify({ header: { status: 'success' }, body });
}

function apiError(message, code = 400, extra = {}) {
  return JSON.stringify({
    header: { status: 'error', code, message, ...extra },
    body: null,
  });
}

function send(response, status, document, headers = {}) {
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...headers,
  });
  response.end(document);
}

function redirect(response, location, headers = {}) {
  response.writeHead(302, { Location: location, 'Cache-Control': 'no-store', ...headers });
  response.end();
}

async function requestJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > INPUT_LIMIT) fail('Richiesta oltre il limite del laboratorio.');
    chunks.push(chunk);
  }
  if (!chunks.length) return null;
  const text = Buffer.concat(chunks).toString('utf8').replace(/^\ufeff/, '');
  const parsed = JSON.parse(text);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) fail('JSON non valido.');
  return parsed;
}

function encodeGpgAuthHeader(value) {
  return encodeURIComponent(value).replace(/%20/g, '+');
}

function randomLabPassphrase() {
  return `LAB-ONLY-${randomBytes(18).toString('hex')}`;
}

function randomTotp() {
  return String(Number.parseInt(randomBytes(4).toString('hex'), 16) % 1_000_000).padStart(6, '0');
}

function ownerPermission(objectType, objectId, userId, id = randomUUID()) {
  return {
    id,
    aco: objectType,
    aco_foreign_key: objectId,
    aro: 'User',
    aro_foreign_key: userId,
    type: 15,
  };
}

function sanitizeResource(entry) {
  return {
    id: entry.id,
    resource_type_id: entry.resource_type_id,
    folder_parent_id: entry.folder_parent_id ?? null,
    permission: entry.permission,
    permissions: entry.permissions,
    ...(entry.metadata ? {
      metadata: entry.metadata,
      metadata_key_id: entry.metadata_key_id,
      metadata_key_type: entry.metadata_key_type,
    } : {
      name: entry.name,
      username: entry.username,
      uri: entry.uri,
    }),
  };
}

function sanitizeFolder(entry) {
  return {
    id: entry.id,
    folder_parent_id: entry.folder_parent_id ?? null,
    personal: entry.personal,
    permission: entry.permission,
    permissions: entry.permissions,
    ...(entry.metadata ? {
      metadata: entry.metadata,
      metadata_key_id: entry.metadata_key_id,
      metadata_key_type: entry.metadata_key_type,
    } : { name: entry.name }),
  };
}

async function createLab(options) {
  const profile = String(options.profile ?? 'v5').toLowerCase();
  const scenario = String(options.scenario ?? 'healthy').toLowerCase();
  const initialFault = String(options.fault ?? 'none').toLowerCase();
  if (!PROFILES.has(profile)) fail('Profilo offline non supportato.');
  if (!SCENARIOS.has(scenario)) fail('Scenario offline non supportato.');
  if (!FAULTS.has(initialFault)) fail('Fault injection offline non supportata.');
  for (const required of ['cert', 'key', 'workspace', 'ready-file', 'dataset-root']) {
    if (!options[required]) fail(`Argomento --${required} mancante.`);
  }

  const workspace = resolve(options.workspace);
  const readyFile = resolve(options['ready-file']);
  const datasetRoot = resolve(options['dataset-root']);
  const certificatePath = resolve(options.cert);
  const tlsKeyPath = resolve(options.key);
  const userPrivateKeyPath = resolve(workspace, 'offline-lab-user.asc');
  if (!readyFile.startsWith(`${workspace}\\`) && readyFile !== resolve(workspace, 'ready.json')) {
    fail('Il file ready deve appartenere al workspace del laboratorio.');
  }

  const [tlsCertificate, tlsPrivateKey] = await Promise.all([
    readFile(certificatePath),
    readFile(tlsKeyPath),
  ]);
  const userPassphrase = randomLabPassphrase();
  const mfaTotp = randomTotp();
  const labToken = randomBytes(24).toString('hex');
  const sessionCookie = randomBytes(24).toString('hex');
  const csrfToken = randomBytes(18).toString('hex');
  const mfaCookie = randomBytes(18).toString('hex');
  const authToken = `gpgauthv1.3.0|36|${randomUUID()}|gpgauthv1.3.0`;

  const [serverGenerated, userGenerated, recipientGenerated, metadataGenerated] = await Promise.all([
    openpgp.generateKey({
      type: 'ecc',
      curve: 'curve25519',
      userIDs: [{ name: 'Offline Lab Server', email: 'server@offline-lab.example.invalid' }],
      format: 'armored',
    }),
    openpgp.generateKey({
      type: 'ecc',
      curve: 'curve25519',
      userIDs: [{ name: 'Offline Lab User', email: 'user@offline-lab.example.invalid' }],
      passphrase: userPassphrase,
      format: 'armored',
    }),
    openpgp.generateKey({
      type: 'ecc',
      curve: 'curve25519',
      userIDs: [{ name: 'Offline Lab Recipient', email: 'recipient@offline-lab.example.invalid' }],
      format: 'armored',
    }),
    openpgp.generateKey({
      type: 'ecc',
      curve: 'curve25519',
      userIDs: [{ name: 'Offline Lab Metadata', email: 'metadata@offline-lab.example.invalid' }],
      format: 'armored',
    }),
  ]);
  await writeFile(userPrivateKeyPath, userGenerated.privateKey, { encoding: 'utf8', flag: 'wx', mode: 0o600 });

  const serverPrivateKey = await openpgp.readPrivateKey({ armoredKey: serverGenerated.privateKey });
  const serverPublicKey = await openpgp.readKey({ armoredKey: serverGenerated.publicKey });
  const userPublicKey = await openpgp.readKey({ armoredKey: userGenerated.publicKey });
  const userPrivateKey = await openpgp.decryptKey({
    privateKey: await openpgp.readPrivateKey({ armoredKey: userGenerated.privateKey }),
    passphrase: userPassphrase,
  });
  const recipientPublicKey = await openpgp.readKey({ armoredKey: recipientGenerated.publicKey });
  const metadataPublicKey = await openpgp.readKey({ armoredKey: metadataGenerated.publicKey });
  const serverFingerprint = serverPublicKey.getFingerprint().toUpperCase();
  const userFingerprint = userPublicKey.getFingerprint().toUpperCase();
  const recipientFingerprint = recipientPublicKey.getFingerprint().toUpperCase();
  const metadataFingerprint = metadataPublicKey.getFingerprint().toUpperCase();
  const metadataKeyId = '77777777-7777-4777-8777-777777777777';
  let metadataPrivateKeyEnvelope = '';

  const userId = '11111111-1111-4111-8111-111111111111';
  const userGpgKeyId = '22222222-2222-4222-8222-222222222222';
  const recipientId = '33333333-3333-4333-8333-333333333333';
  const groupId = '44444444-4444-4444-8444-444444444444';
  const state = {
    authenticated: false,
    fault: initialFault,
    resources: [],
    folders: [],
    requestCount: 0,
    mutationCount: 0,
    createdResourceCount: 0,
    createdFolderCount: 0,
  };

  function consumeFault(name) {
    if (state.fault !== name) return false;
    state.fault = 'none';
    return true;
  }

  function sharedTarget(objectType, objectId) {
    const collection = objectType === 'resource'
      ? state.resources
      : (objectType === 'folder' ? state.folders : null);
    return collection?.find((item) => item.id === objectId) ?? null;
  }

  function effectiveUsers(permissions) {
    const result = new Set();
    for (const permission of Array.isArray(permissions) ? permissions : []) {
      if (!permission || Number(permission.type) < 1) continue;
      if (permission.aro === 'User' && permission.aro_foreign_key) {
        result.add(String(permission.aro_foreign_key));
      } else if (permission.aro === 'Group' && permission.aro_foreign_key === groupId) {
        // The synthetic directory contains exactly one member in this group.
        result.add(recipientId);
      }
    }
    return result;
  }

  function permissionsAfterChanges(currentPermissions, rawChanges, objectType, objectId) {
    const permissions = Array.isArray(currentPermissions)
      ? currentPermissions.map((permission) => ({ ...permission }))
      : [];
    for (const change of Array.isArray(rawChanges) ? rawChanges : []) {
      if (!change || typeof change !== 'object') continue;
      const matchIndex = permissions.findIndex((permission) => (
        (change.id && permission.id === change.id)
        || (permission.aro === change.aro && permission.aro_foreign_key === change.aro_foreign_key)
      ));
      if (change.delete === true) {
        if (matchIndex >= 0) permissions.splice(matchIndex, 1);
        continue;
      }
      const normalized = {
        id: matchIndex >= 0 ? permissions[matchIndex].id : randomUUID(),
        aco: objectType === 'resource' ? 'Resource' : 'Folder',
        aco_foreign_key: objectId,
        aro: change.aro,
        aro_foreign_key: change.aro_foreign_key,
        type: Number(change.type),
      };
      if (matchIndex >= 0) permissions[matchIndex] = normalized;
      else permissions.push(normalized);
    }
    return permissions;
  }

  const server = createServer({ key: tlsPrivateKey, cert: tlsCertificate }, async (request, response) => {
    try {
      const url = new URL(request.url, 'https://localhost');
      state.requestCount += 1;

      if (url.pathname === '/__lab/status.json' && request.method === 'GET') {
        if (request.headers['x-offline-lab-token'] !== labToken) {
          send(response, 403, apiError('Offline lab token required.', 403));
          return;
        }
        send(response, 200, apiSuccess({
          profile,
          scenario,
          authenticated: state.authenticated,
          resource_count: state.resources.length,
          folder_count: state.folders.length,
          request_count: state.requestCount,
          mutation_count: state.mutationCount,
          active_fault: state.fault,
        }));
        return;
      }
      if (url.pathname === '/__lab/fault.json' && request.method === 'PUT') {
        if (request.headers['x-offline-lab-token'] !== labToken) {
          send(response, 403, apiError('Offline lab token required.', 403));
          return;
        }
        const document = await requestJson(request);
        const fault = String(document?.fault ?? '');
        if (!FAULTS.has(fault)) {
          send(response, 400, apiError('Offline lab fault not supported.'));
          return;
        }
        state.fault = fault;
        send(response, 200, apiSuccess({ fault }));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/healthcheck/status.json') {
        send(response, 200, apiSuccess('OK'));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/auth/verify.json') {
        send(response, 200, apiSuccess({ fingerprint: serverFingerprint, keydata: serverGenerated.publicKey }));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/auth/verify.json') {
        const document = await requestJson(request);
        const auth = document?.data?.gpg_auth ?? document?.gpg_auth;
        if (!auth || auth.keyid !== userFingerprint) {
          send(response, 400, apiError('Invalid server verification request.'));
          return;
        }
        const decrypted = await openpgp.decrypt({
          message: await openpgp.readMessage({ armoredMessage: auth.server_verify_token }),
          decryptionKeys: serverPrivateKey,
          format: 'utf8',
        });
        send(response, 200, apiSuccess('OK'), {
          'X-GPGAuth-Verify-Response': encodeGpgAuthHeader(decrypted.data),
        });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/auth/login.json') {
        const document = await requestJson(request);
        const auth = document?.data?.gpg_auth ?? document?.gpg_auth;
        if (!auth || auth.keyid !== userFingerprint) {
          send(response, 400, apiError('Unknown offline-lab user key.'));
          return;
        }
        if (!auth.user_token_result) {
          const challenge = await openpgp.encrypt({
            message: await openpgp.createMessage({ text: authToken }),
            encryptionKeys: userPublicKey,
            signingKeys: serverPrivateKey,
            format: 'armored',
          });
          send(response, 400, apiError('Authentication challenge required.'), {
            'X-GPGAuth-User-Auth-Token': encodeGpgAuthHeader(challenge),
          });
          return;
        }
        if (auth.user_token_result !== authToken) {
          send(response, 401, apiError('Invalid authentication token.', 401));
          return;
        }
        state.authenticated = true;
        send(response, 200, apiSuccess('OK'), {
          'X-GPGAuth-Authenticated': 'true',
          'Set-Cookie': [
            `passbolt_session=${sessionCookie}; Path=/; HttpOnly`,
            `csrfToken=${csrfToken}; Path=/; SameSite=Lax`,
          ],
        });
        return;
      }

      const cookies = String(request.headers.cookie ?? '');
      if (!state.authenticated || !cookies.includes(`passbolt_session=${sessionCookie}`)) {
        send(response, 401, apiError('Authentication required.', 401));
        return;
      }
      if (scenario === 'session-expired' || consumeFault('expire-session')) {
        state.authenticated = false;
        send(response, 401, apiError('Offline lab session expired.', 401));
        return;
      }
      if (!['GET', 'HEAD'].includes(String(request.method))) state.mutationCount += 1;

      if (request.method === 'GET' && url.pathname === '/users/me.json') {
        if (!cookies.includes(`passbolt_mfa=${mfaCookie}`)) {
          redirect(response, '/mfa/verify/error.json');
          return;
        }
        redirect(response, '/redirected/users/me.json', {
          'Set-Cookie': 'offlineLabRedirect=1; Path=/; HttpOnly',
        });
        return;
      }
      if (request.method === 'GET' && url.pathname === '/mfa/verify/error.json') {
        send(response, 403, JSON.stringify({
          header: {
            status: 'error',
            code: 403,
            message: 'MFA authentication is required.',
            url: '/mfa/verify/error.json',
            servertime: Math.floor(Date.now() / 1000),
          },
          body: { mfa_providers: ['totp'] },
        }));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/mfa/verify/totp.json') {
        const document = await requestJson(request);
        if (request.headers['x-csrf-token'] !== csrfToken) {
          send(response, 403, apiError('Invalid CSRF token.', 403));
          return;
        }
        if (scenario === 'mfa-rejected' || document?.totp !== mfaTotp || Object.keys(document ?? {}).length !== 1) {
          send(response, 400, apiError('Invalid TOTP code.'));
          return;
        }
        send(response, 200, apiSuccess(null), {
          'Set-Cookie': `passbolt_mfa=${mfaCookie}; Path=/; HttpOnly; SameSite=Lax`,
        });
        return;
      }
      if (request.method === 'GET' && url.pathname === '/redirected/users/me.json') {
        if (!cookies.includes('offlineLabRedirect=1')) {
          send(response, 401, apiError('Redirect cookie missing.', 401));
          return;
        }
        send(response, 200, apiSuccess({
          id: userId,
          username: 'user@offline-lab.example.invalid',
          active: true,
          profile: { first_name: 'Offline', last_name: 'Lab' },
          gpgkey: { id: userGpgKeyId, fingerprint: userFingerprint },
        }));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/settings.json') {
        send(response, 200, apiSuccess({
          passbolt: { plugins: { metadata: { enabled: profile === 'v5' }, jwtAuthentication: { enabled: false } } },
        }));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/metadata/types/settings.json') {
        if (profile === 'v4') {
          send(response, 404, apiError('Route not available.', 404));
        } else {
          send(response, 200, apiSuccess({
            default_resource_types: 'v5',
            default_folder_type: 'v5',
            allow_creation_of_v4_resources: true,
            allow_creation_of_v5_resources: true,
            allow_creation_of_v4_folders: true,
            allow_creation_of_v5_folders: true,
          }));
        }
        return;
      }
      if (request.method === 'GET' && url.pathname === '/metadata/keys/settings.json') {
        send(response, 200, apiSuccess({ allow_usage_of_personal_keys: true, zero_knowledge_key_share: true }));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/metadata/keys.json') {
        send(response, 200, apiSuccess(profile === 'v5' ? [{
          id: metadataKeyId,
          fingerprint: metadataFingerprint,
          armored_key: metadataGenerated.publicKey,
          created: '2026-01-02T00:00:00Z',
          expired: null,
          deleted: null,
          metadata_private_keys: [{
            id: '88888888-8888-4888-8888-888888888888',
            metadata_key_id: metadataKeyId,
            user_id: userId,
            data: metadataPrivateKeyEnvelope,
          }],
        }] : []));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/resource-types.json') {
        const types = [{
          id: '55555555-5555-4555-8555-555555555555',
          slug: 'password-and-description',
          name: 'Password with description',
          definition: {
            resource: { type: 'object', properties: { name: {}, username: {}, uri: {} } },
            secret: { type: 'object', properties: { password: {}, description: {} } },
          },
        }];
        if (profile === 'v5') {
          types.push({
            id: '66666666-6666-4666-8666-666666666666',
            slug: 'v5-default',
            name: 'V5 default',
            definition: JSON.stringify({
              resource: { type: 'object', properties: { name: {}, username: {}, uris: {}, object_type: {}, resource_type_id: {} } },
              secret: { type: 'object', properties: { password: {}, description: {}, object_type: {} } },
            }),
          });
        }
        send(response, 200, apiSuccess(types));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/share/search-aros.json') {
        send(response, 200, apiSuccess([
          {
            id: userId,
            username: 'user@offline-lab.example.invalid',
            active: true,
            deleted: false,
            disabled: null,
            groups_users: [],
            gpgkey: {
              id: userGpgKeyId,
              user_id: userId,
              armored_key: userGenerated.publicKey,
              fingerprint: userFingerprint,
              deleted: false,
              expires: null,
            },
          },
          {
            id: recipientId,
            username: 'recipient@offline-lab.example.invalid',
            active: true,
            deleted: false,
            disabled: null,
            groups_users: [{ id: randomUUID(), group_id: groupId, user_id: recipientId, is_admin: false }],
            gpgkey: {
              id: randomUUID(),
              user_id: recipientId,
              armored_key: recipientGenerated.publicKey,
              fingerprint: recipientFingerprint,
              deleted: false,
              expires: null,
            },
          },
          { id: groupId, name: 'Team Offline Lab', user_count: 1, deleted: false },
        ]));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/resources.json') {
        send(response, 200, apiSuccess(state.resources.map(sanitizeResource)));
        return;
      }
      if (request.method === 'GET' && url.pathname.startsWith('/resources/') && url.pathname.endsWith('.json')) {
        const id = url.pathname.split('/')[2]?.replace(/\.json$/, '');
        const resource = state.resources.find((item) => item.id === id);
        if (!resource) {
          send(response, 404, apiError('Offline-lab resource not found.', 404));
          return;
        }
        send(response, 200, apiSuccess(sanitizeResource(resource)));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/folders.json') {
        send(response, 200, apiSuccess(state.folders.map(sanitizeFolder)));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/folders.json') {
        if (request.headers['x-csrf-token'] !== csrfToken) {
          send(response, 403, apiError('Invalid CSRF token.', 403));
          return;
        }
        if (consumeFault('next-folder-create-500')) {
          send(response, 500, apiError('Injected offline-lab folder failure.', 500));
          return;
        }
        if (consumeFault('next-folder-create-disconnect')) {
          response.destroy();
          return;
        }
        const payload = await requestJson(request);
        const id = randomUUID();
        const permission = ownerPermission('Folder', id, userId);
        state.folders.push({
          id,
          folder_parent_id: payload?.folder_parent_id ?? null,
          personal: true,
          permission,
          permissions: [permission],
          ...(payload?.metadata ? {
            metadata: payload.metadata,
            metadata_key_id: payload.metadata_key_id,
            metadata_key_type: payload.metadata_key_type,
          } : { name: String(payload?.name ?? '') }),
        });
        state.createdFolderCount += 1;
        if (consumeFault('next-folder-create-after-commit-500')) {
          send(response, 500, apiError('Injected offline-lab folder response failure after commit.', 500));
          return;
        }
        if (consumeFault('next-folder-create-after-commit-disconnect')) {
          response.destroy();
          return;
        }
        send(response, 200, apiSuccess({ id, permission }));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/resources.json') {
        if (request.headers['x-csrf-token'] !== csrfToken) {
          send(response, 403, apiError('Invalid CSRF token.', 403));
          return;
        }
        if (consumeFault('next-resource-create-500')) {
          send(response, 500, apiError('Injected offline-lab resource failure.', 500));
          return;
        }
        if (consumeFault('next-resource-create-disconnect')) {
          response.destroy();
          return;
        }
        const payload = await requestJson(request);
        const id = randomUUID();
        const permission = ownerPermission('Resource', id, userId);
        state.resources.push({
          id,
          resource_type_id: payload?.resource_type_id,
          folder_parent_id: payload?.folder_parent_id ?? null,
          permission,
          permissions: [permission],
          secrets: Array.isArray(payload?.secrets) ? payload.secrets : [],
          ...(payload?.metadata ? {
            metadata: payload.metadata,
            metadata_key_id: payload.metadata_key_id,
            metadata_key_type: payload.metadata_key_type,
          } : {
            name: String(payload?.name ?? ''),
            username: String(payload?.username ?? ''),
            uri: String(payload?.uri ?? ''),
          }),
        });
        state.createdResourceCount += 1;
        if (consumeFault('next-resource-create-after-commit-500')) {
          send(response, 500, apiError('Injected offline-lab resource response failure after commit.', 500));
          return;
        }
        if (consumeFault('next-resource-create-after-commit-disconnect')) {
          response.destroy();
          return;
        }
        send(response, 200, apiSuccess({ id, permission }));
        return;
      }
      if (request.method === 'GET' && url.pathname.startsWith('/secrets/resource/')) {
        const id = url.pathname.split('/')[3]?.replace(/\.json$/, '');
        const resource = state.resources.find((item) => item.id === id);
        const secret = resource?.secrets?.find((item) => item.user_id === userId) ?? resource?.secrets?.[0];
        if (!secret) {
          send(response, 404, apiError('Offline-lab secret not found.', 404));
          return;
        }
        send(response, 200, apiSuccess({ id: randomUUID(), user_id: userId, resource_id: id, data: secret.data }));
        return;
      }
      if (request.method === 'POST' && url.pathname.startsWith('/share/simulate/')) {
        const payload = await requestJson(request);
        const pathParts = url.pathname.split('/');
        const objectType = pathParts[3];
        const objectId = pathParts[4]?.replace(/\.json$/, '');
        const target = sharedTarget(objectType, objectId);
        if (!target) {
          send(response, 404, apiError('Offline-lab simulation target not found.', 404));
          return;
        }
        const before = effectiveUsers(target.permissions);
        const simulatedPermissions = permissionsAfterChanges(
          target.permissions,
          payload?.permissions,
          objectType,
          objectId,
        );
        const after = effectiveUsers(simulatedPermissions);
        const additions = [...after]
          .filter((userIdValue) => !before.has(userIdValue))
          .sort()
          .map((userIdValue) => ({ User: { id: userIdValue } }));
        const removals = [...before]
          .filter((userIdValue) => !after.has(userIdValue))
          .sort()
          .map((userIdValue) => ({ User: { id: userIdValue } }));
        send(response, 200, apiSuccess({ changes: { added: additions, removed: removals } }));
        return;
      }
      if (request.method === 'PUT' && url.pathname.startsWith('/share/')) {
        if (consumeFault('next-share-500')) {
          send(response, 500, apiError('Injected offline-lab sharing failure.', 500));
          return;
        }
        if (consumeFault('next-share-disconnect')) {
          response.destroy();
          return;
        }
        const payload = await requestJson(request);
        const pathParts = url.pathname.split('/');
        const objectType = pathParts[2];
        const objectId = pathParts[3]?.replace(/\.json$/, '');
        const target = sharedTarget(objectType, objectId);
        if (!target) {
          send(response, 404, apiError('Offline-lab share target not found.', 404));
          return;
        }
        target.permissions = permissionsAfterChanges(
          target.permissions,
          payload?.permissions,
          objectType,
          objectId,
        );
        if (objectType === 'resource' && Array.isArray(payload?.secrets)) {
          for (const secret of payload.secrets) {
            const existingIndex = target.secrets.findIndex((item) => item.user_id === secret.user_id);
            if (existingIndex >= 0) target.secrets[existingIndex] = secret;
            else target.secrets.push(secret);
          }
        }
        if (consumeFault('next-share-after-commit-500')) {
          send(response, 500, apiError('Injected offline-lab sharing response failure after commit.', 500));
          return;
        }
        if (consumeFault('next-share-after-commit-disconnect')) {
          response.destroy();
          return;
        }
        send(response, 200, apiSuccess(null));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/auth/logout.json') {
        state.authenticated = false;
        send(response, 200, apiSuccess('OK'));
        return;
      }
      send(response, 404, apiError('Unknown offline-lab route.', 404));
    } catch {
      if (!response.destroyed) {
        send(response, 500, apiError('Offline lab internal error.', 500));
      }
    }
  });

  await new Promise((resolveListen, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolveListen);
  });
  const address = server.address();
  if (!address || typeof address !== 'object') fail('Indirizzo del laboratorio non disponibile.');
  const baseUrl = `https://localhost:${address.port}`;
  metadataPrivateKeyEnvelope = await openpgp.encrypt({
    message: await openpgp.createMessage({ text: JSON.stringify({
      object_type: 'PASSBOLT_METADATA_PRIVATE_KEY',
      domain: baseUrl,
      fingerprint: metadataFingerprint,
      armored_key: metadataGenerated.privateKey,
      passphrase: '',
      signed: '2026-01-02T00:00:00Z',
    }) }),
    encryptionKeys: userPublicKey,
    signingKeys: userPrivateKey,
    format: 'armored',
  });
  const ready = {
    schema_version: 1,
    app_version: APP_VERSION,
    profile,
    scenario,
    fault: initialFault,
    base_url: baseUrl,
    server_fingerprint: serverFingerprint,
    private_key_path: userPrivateKeyPath,
    passphrase: userPassphrase,
    mfa_totp: mfaTotp,
    certificate_path: certificatePath,
    dataset_root: datasetRoot,
    workspace,
    lab_token: labToken,
    contains_real_credentials: false,
  };
  await writeFile(readyFile, `${JSON.stringify(ready, null, 2)}\n`, { encoding: 'utf8', flag: 'wx', mode: 0o600 });
  process.stdout.write(`OFFLINE_LAB_READY ${baseUrl} ${profile} ${scenario}\n`);
  return server;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfTest) {
    process.stdout.write(`${JSON.stringify({
      app: 'Passbolt Migration Assistant Offline Lab',
      version: APP_VERSION,
      profiles: [...PROFILES],
      scenarios: [...SCENARIOS],
      faults: [...FAULTS],
      stateful_acceptance_scenarios: 9,
      stateful_recovery_fault_paths: 12,
      effective_acl_simulation: true,
      shared_v5_metadata_key: true,
      loopback_only: true,
      request_bodies_logged: false,
      contains_real_credentials: false,
      status: 'OK',
    })}\n`);
    return;
  }
  const server = await createLab(options);
  const shutdown = () => server.close(() => process.exit(0));
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

try {
  await main();
} catch (error) {
  process.stderr.write(`Offline lab non avviato: ${error instanceof Error ? error.message : 'errore interno'}\n`);
  process.exitCode = 2;
}
