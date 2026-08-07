#!/usr/bin/env node

import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import * as openpgp from 'openpgp';
import {
  PassboltSession,
  PersistentImportSession,
  analyzeCapabilities,
  authenticate,
  buildFolderPayload,
  buildResourcePayload,
  createPlannedContent,
  encryptSecret,
  readCapabilities,
} from './passbolt_crypto.mjs';

function apiSuccess(body) {
  return JSON.stringify({ header: { status: 'success' }, body });
}

function apiError(message) {
  return JSON.stringify({ header: { status: 'error', message }, body: null });
}

async function requestJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  if (!chunks.length) return null;
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function send(response, status, document, headers = {}) {
  response.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  response.end(document);
}

function redirect(response, location, headers = {}) {
  response.writeHead(302, { Location: location, ...headers });
  response.end();
}

function assertNewPermissionMarkers(payload) {
  assert.equal(Array.isArray(payload?.permissions), true);
  const additions = payload.permissions.filter((permission) => !permission.id && permission.delete !== true);
  assert.equal(additions.length > 0, true);
  for (const permission of additions) assert.equal(permission.is_new, true);
  for (const permission of payload.permissions.filter((permission) => permission.id)) {
    assert.equal(Object.hasOwn(permission, 'is_new'), false);
  }
}

function encodeGpgAuthHeader(value) {
  // Mirror PHP/form-style URL encoding: spaces are represented as '+', while
  // literal plus signs in the armored base64 remain percent-encoded as %2B.
  return encodeURIComponent(value).replace(/%20/g, '+');
}

async function main() {
  const serverGenerated = await openpgp.generateKey({
    type: 'ecc',
    curve: 'curve25519',
    userIDs: [{ name: 'Mock Passbolt Server', email: 'server@example.invalid' }],
    format: 'armored',
  });
  const userGenerated = await openpgp.generateKey({
    type: 'ecc',
    curve: 'curve25519',
    userIDs: [{ name: 'Mock User', email: 'user@example.invalid' }],
    format: 'armored',
  });
  const directRecipientGenerated = await openpgp.generateKey({
    type: 'ecc',
    curve: 'curve25519',
    userIDs: [{ name: 'Direct Recipient', email: 'direct@example.invalid' }],
    format: 'armored',
  });
  const groupRecipientGenerated = await openpgp.generateKey({
    type: 'ecc',
    curve: 'curve25519',
    userIDs: [{ name: 'Group Recipient', email: 'group@example.invalid' }],
    format: 'armored',
  });
  const metadataGenerated = await openpgp.generateKey({
    type: 'ecc',
    curve: 'curve25519',
    userIDs: [{ name: 'Mock Metadata Key', email: 'metadata@example.invalid' }],
    format: 'armored',
  });
  const serverPrivateKey = await openpgp.readPrivateKey({ armoredKey: serverGenerated.privateKey });
  const serverPublicKey = await openpgp.readKey({ armoredKey: serverGenerated.publicKey });
  const userPrivateKey = await openpgp.readPrivateKey({ armoredKey: userGenerated.privateKey });
  const userPublicKey = await openpgp.readKey({ armoredKey: userGenerated.publicKey });
  const directRecipientPrivateKey = await openpgp.readPrivateKey({ armoredKey: directRecipientGenerated.privateKey });
  const directRecipientPublicKey = await openpgp.readKey({ armoredKey: directRecipientGenerated.publicKey });
  const groupRecipientPrivateKey = await openpgp.readPrivateKey({ armoredKey: groupRecipientGenerated.privateKey });
  const groupRecipientPublicKey = await openpgp.readKey({ armoredKey: groupRecipientGenerated.publicKey });
  const metadataPrivateKey = await openpgp.readPrivateKey({ armoredKey: metadataGenerated.privateKey });
  const metadataPublicKey = await openpgp.readKey({ armoredKey: metadataGenerated.publicKey });
  const serverFingerprint = serverPublicKey.getFingerprint().toUpperCase();
  const userFingerprint = userPublicKey.getFingerprint().toUpperCase();
  const directRecipientFingerprint = directRecipientPublicKey.getFingerprint().toUpperCase();
  const groupRecipientFingerprint = groupRecipientPublicKey.getFingerprint().toUpperCase();
  const metadataFingerprint = metadataPublicKey.getFingerprint().toUpperCase();
  const authToken = 'gpgauthv1.3.0|36|11111111-1111-4111-8111-111111111111|gpgauthv1.3.0';
  let authenticated = false;
  let completedLoginCount = 0;
  let identityMode = 'redirect-success';
  let resourceMode = 'v4';
  let folderMode = 'empty';
  let personalMetadataMode = false;
  let existingResourceFolderId = null;
  let createdPayload = null;
  let createdPayloadV5 = null;
  let createdFolderPayload = null;
  let createdFolderRequestCount = 0;
  let metadataPrivateKeyEnvelope = null;
  let existingV5Metadata = null;
  let existingV5FolderMetadata = null;
  let shareDirectoryMode = 'valid';
  let shareApplyMode = 'success';
  let folderShareApplyMode = 'success';
  let sharedFolderPermissionMode = 'normal';
  let includePersonalChildInSharedContainer = false;
  let sharedSimulationPayload = null;
  let sharedApplyPayload = null;
  let sharedFolderSimulationPayload = null;
  let sharedFolderApplyPayload = null;

  const mockServer = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://127.0.0.1');
      if (request.method === 'GET' && url.pathname === '/auth/verify.json') {
        send(response, 200, apiSuccess({
          fingerprint: serverFingerprint,
          keydata: serverGenerated.publicKey,
        }));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/auth/verify.json') {
        const document = await requestJson(request);
        const auth = document?.data?.gpg_auth;
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
        const auth = document?.gpg_auth ?? document?.data?.gpg_auth;
        if (!auth || auth.keyid !== userFingerprint) {
          send(response, 400, apiError('Unknown user key.'));
          return;
        }
        if (!auth.user_token_result) {
          const challenge = await openpgp.encrypt({
            message: await openpgp.createMessage({ text: authToken }),
            encryptionKeys: userPublicKey,
            signingKeys: serverPrivateKey,
            format: 'armored',
          });
          send(response, 400, apiError('The authentication failed.'), {
            'X-GPGAuth-User-Auth-Token': encodeGpgAuthHeader(challenge),
          });
          return;
        }
        if (auth.user_token_result !== authToken) {
          send(response, 401, apiError('Invalid authentication token.'));
          return;
        }
        authenticated = true;
        completedLoginCount += 1;
        send(response, 200, apiSuccess('OK'), {
          'X-GPGAuth-Authenticated': 'true',
          'Set-Cookie': [
            'passbolt_session=mock-session; Path=/; HttpOnly',
            'csrfToken=mock-csrf; Path=/; SameSite=Lax',
          ],
        });
        return;
      }

      const cookie = request.headers.cookie ?? '';
      if (!authenticated || !cookie.includes('passbolt_session=mock-session')) {
        send(response, 401, apiError('Authentication required.'));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/users/me.json') {
        if (identityMode === 'mfa' && !cookie.includes('passbolt_mfa=mock-mfa')) {
          redirect(response, '/mfa/verify/error.json');
          return;
        }
        redirect(response, '/redirected/users/me.json?api-version=v2', {
          'Set-Cookie': 'redirectCookie=redirect-value; Path=/; HttpOnly',
        });
        return;
      }
      if (request.method === 'GET' && url.pathname === '/redirected/users/me.json') {
        if (!cookie.includes('redirectCookie=redirect-value')) {
          send(response, 401, apiError('Redirect cookie missing.'));
          return;
        }
        send(response, 200, apiSuccess({
          id: 'user-id',
          username: 'user@example.invalid',
          active: true,
          profile: { first_name: 'Mock', last_name: 'User' },
          gpgkey: { id: 'user-gpg-key-id', fingerprint: userFingerprint },
        }));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/mfa/verify/error.json') {
        send(response, 403, JSON.stringify({
          header: {
            status: 'error',
            code: 403,
            message: 'MFA authentication is required.',
            url: '/mfa/verify/error.json',
          },
          body: { mfa_providers: ['totp'] },
        }));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/mfa/verify/totp.json') {
        const document = await requestJson(request);
        if (request.headers['x-csrf-token'] !== 'mock-csrf') {
          send(response, 403, apiError('Invalid CSRF token.'));
          return;
        }
        if (document?.totp !== '654321' || document?.remember !== 0) {
          send(response, 400, apiError('Invalid TOTP code.'));
          return;
        }
        send(response, 200, apiSuccess(null), {
          'Set-Cookie': 'passbolt_mfa=mock-mfa; Path=/; HttpOnly; SameSite=Lax',
        });
        return;
      }
      if (request.method === 'GET' && url.pathname === '/redirect/cross-origin.json') {
        redirect(response, 'https://example.invalid/exfil');
        return;
      }
      if (request.method === 'GET' && url.pathname === '/settings.json') {
        send(response, 200, apiSuccess({
          passbolt: { plugins: { metadata: { enabled: resourceMode === 'v5' }, jwtAuthentication: { enabled: false } } },
        }));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/metadata/types/settings.json') {
        if (resourceMode === 'v4') {
          send(response, 404, apiError('Route not available.'));
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
        send(response, 200, apiSuccess({
          allow_usage_of_personal_keys: personalMetadataMode,
          zero_knowledge_key_share: true,
        }));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/metadata/keys.json') {
        send(response, 200, apiSuccess([{
          id: 'metadata-key-id',
          fingerprint: metadataFingerprint,
          armored_key: metadataGenerated.publicKey,
          created: '2026-01-02T00:00:00Z',
          expired: null,
          deleted: null,
          metadata_private_keys: [{
            id: 'metadata-private-key-id',
            metadata_key_id: 'metadata-key-id',
            user_id: 'user-id',
            data: metadataPrivateKeyEnvelope,
          }],
        }]));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/resource-types.json') {
        const types = [{
          id: 'resource-type-id',
          slug: 'password-and-description',
          name: 'Password with description',
          definition: {
            resource: { type: 'object', properties: { name: {}, username: {}, uri: {} } },
            secret: { type: 'object', properties: { password: {}, description: {} } },
          },
        }];
        if (resourceMode === 'v5') {
          types.push({
            id: 'v5-resource-type-id',
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
        const groupRecipientGpgKey = shareDirectoryMode === 'missing-key' ? null : {
          id: 'group-recipient-gpg-key-id',
          user_id: 'group-recipient-id',
          armored_key: groupRecipientGenerated.publicKey,
          fingerprint: groupRecipientFingerprint,
          deleted: false,
          expires: null,
        };
        send(response, 200, apiSuccess([{
          id: 'user-id',
          role_id: 'user-role-id',
          username: 'user@example.invalid',
          active: true,
          deleted: false,
          disabled: null,
          groups_users: [],
          gpgkey: {
            id: 'user-gpg-key-id',
            user_id: 'user-id',
            armored_key: userGenerated.publicKey,
            fingerprint: userFingerprint,
            deleted: false,
            expires: null,
          },
        }, {
          id: 'direct-recipient-id',
          role_id: 'user-role-id',
          username: 'direct@example.invalid',
          active: true,
          deleted: false,
          disabled: null,
          groups_users: [{ id: 'membership-direct-id', group_id: 'shared-group-id', user_id: 'direct-recipient-id', is_admin: false }],
          gpgkey: {
            id: 'direct-recipient-gpg-key-id',
            user_id: 'direct-recipient-id',
            armored_key: directRecipientGenerated.publicKey,
            fingerprint: directRecipientFingerprint,
            deleted: false,
            expires: null,
          },
        }, {
          id: 'group-recipient-id',
          role_id: 'user-role-id',
          username: 'group@example.invalid',
          active: true,
          deleted: false,
          disabled: null,
          groups_users: [{ id: 'membership-group-id', group_id: 'shared-group-id', user_id: 'group-recipient-id', is_admin: false }],
          gpgkey: groupRecipientGpgKey,
        }, {
          id: 'shared-group-id',
          name: 'Team condiviso',
          user_count: 2,
          deleted: false,
        }]));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/resources.json') {
        send(response, 200, apiSuccess(resourceMode === 'v5' ? [{
          id: 'existing-v5-resource-id',
          resource_type_id: 'v5-resource-type-id',
          metadata_key_id: 'metadata-key-id',
          metadata_key_type: 'shared_key',
          metadata: existingV5Metadata,
          folder_parent_id: existingResourceFolderId,
        }] : [{
          id: 'existing-resource-id',
          name: 'Portale esistente',
          username: 'existing-user',
          uri: 'https://existing.example.test',
          folder_parent_id: existingResourceFolderId,
        }]));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/folders.json') {
        if (folderMode === 'v4') {
          send(response, 200, apiSuccess([{
            id: 'folder-alpha-id',
            name: 'Cliente Alfa',
            folder_parent_id: null,
          }]));
        } else if (folderMode === 'nested-v4') {
          send(response, 200, apiSuccess([{
            id: 'folder-container-id',
            name: 'Clienti',
            folder_parent_id: null,
            personal: true,
          }, {
            id: 'folder-alpha-nested-id',
            name: 'Cliente Alfa',
            folder_parent_id: 'folder-container-id',
            personal: true,
          }]));
        } else if (folderMode === 'readonly-v4') {
          send(response, 200, apiSuccess([{
            id: 'folder-readonly-id',
            name: 'Sola lettura',
            folder_parent_id: null,
            permission: { type: 1 },
          }]));
        } else if (folderMode === 'shared-v4') {
          const sharedFolders = [{
            id: 'folder-shared-id',
            name: 'Cartella condivisa',
            folder_parent_id: null,
            personal: false,
            permission: { type: 15 },
            permissions: [{
              id: 'folder-current-permission-id',
              aco: 'Folder',
              aco_foreign_key: 'folder-shared-id',
              aro: 'User',
              aro_foreign_key: 'user-id',
              type: 15,
            }, {
              id: 'folder-direct-permission-id',
              aco: 'Folder',
              aco_foreign_key: 'folder-shared-id',
              aro: 'User',
              aro_foreign_key: 'direct-recipient-id',
              type: sharedFolderPermissionMode === 'changed' ? 7 : 1,
            }, {
              id: 'folder-group-permission-id',
              aco: 'Folder',
              aco_foreign_key: 'folder-shared-id',
              aro: 'Group',
              aro_foreign_key: 'shared-group-id',
              type: 7,
            }],
          }];
          if (includePersonalChildInSharedContainer) {
            sharedFolders.push({
              id: 'created-unshared-folder-id',
              name: 'Cliente Nuovo Condiviso',
              folder_parent_id: 'folder-shared-id',
              personal: true,
              permission: { type: 15 },
              permissions: [{
                id: 'created-unshared-owner-permission-id',
                aco: 'Folder',
                aco_foreign_key: 'created-unshared-folder-id',
                aro: 'User',
                aro_foreign_key: 'user-id',
                type: 15,
              }],
            });
          }
          send(response, 200, apiSuccess(sharedFolders));
        } else if (folderMode === 'v5') {
          send(response, 200, apiSuccess([{
            id: 'folder-alpha-v5-id',
            metadata_key_id: 'metadata-key-id',
            metadata_key_type: 'shared_key',
            metadata: existingV5FolderMetadata,
            folder_parent_id: null,
            personal: true,
          }]));
        } else {
          send(response, 200, apiSuccess([]));
        }
        return;
      }
      if (request.method === 'POST' && url.pathname === '/folders.json') {
        if (request.headers['x-csrf-token'] !== 'mock-csrf') {
          send(response, 403, apiError('Invalid CSRF token.'));
          return;
        }
        createdFolderPayload = await requestJson(request);
        createdFolderRequestCount += 1;
        send(response, 200, apiSuccess({
          id: 'created-folder-id',
          permission: {
            id: 'created-folder-permission-id',
            aco: 'Folder',
            aco_foreign_key: 'created-folder-id',
            aro: 'User',
            aro_foreign_key: 'user-id',
            type: 15,
          },
        }));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/resources.json') {
        if (request.headers['x-csrf-token'] !== 'mock-csrf') {
          send(response, 403, apiError('Invalid CSRF token.'));
          return;
        }
        const requestPayload = await requestJson(request);
        if (resourceMode === 'v5') {
          createdPayloadV5 = requestPayload;
          assert.equal(Object.hasOwn(createdPayloadV5, 'name'), false);
          assert.equal(Object.hasOwn(createdPayloadV5, 'username'), false);
          assert.equal(Object.hasOwn(createdPayloadV5, 'uri'), false);
          assert.equal(createdPayloadV5.metadata_key_id, 'metadata-key-id');
          assert.equal(createdPayloadV5.metadata_key_type, 'shared_key');
          const decryptedMetadata = await openpgp.decrypt({
            message: await openpgp.readMessage({ armoredMessage: createdPayloadV5.metadata }),
            decryptionKeys: metadataPrivateKey,
            verificationKeys: userPublicKey,
            format: 'utf8',
          });
          await Promise.all(decryptedMetadata.signatures.map((signature) => signature.verified));
          const clearMetadata = JSON.parse(decryptedMetadata.data);
          assert.deepEqual(clearMetadata.uris, ['https://new-v5.example.test']);
          assert.equal(clearMetadata.name, 'Nuovo portale v5');
          assert.equal(clearMetadata.username, 'new-v5-user');
          assert.equal(clearMetadata.object_type, 'PASSBOLT_RESOURCE_METADATA');
          assert.equal(clearMetadata.resource_type_id, 'v5-resource-type-id');

          const decryptedSecret = await openpgp.decrypt({
            message: await openpgp.readMessage({ armoredMessage: createdPayloadV5.secrets[0].data }),
            decryptionKeys: userPrivateKey,
            verificationKeys: userPublicKey,
            format: 'utf8',
          });
          await Promise.all(decryptedSecret.signatures.map((signature) => signature.verified));
          const clearSecret = JSON.parse(decryptedSecret.data);
          assert.equal(clearSecret.password, 'mock-v5-password');
          assert.equal(clearSecret.description, 'mock v5 description');
          assert.equal(clearSecret.object_type, 'PASSBOLT_SECRET_DATA');
          send(response, 200, apiSuccess({
            id: 'created-v5-resource-id',
            permission: {
              id: 'created-v5-resource-permission-id',
              aco: 'Resource',
              aco_foreign_key: 'created-v5-resource-id',
              aro: 'User',
              aro_foreign_key: 'user-id',
              type: 15,
            },
          }));
          return;
        }

        createdPayload = requestPayload;
        const decrypted = await openpgp.decrypt({
          message: await openpgp.readMessage({ armoredMessage: createdPayload.secrets[0].data }),
          decryptionKeys: userPrivateKey,
          verificationKeys: userPublicKey,
          format: 'utf8',
        });
        await Promise.all(decrypted.signatures.map((signature) => signature.verified));
        const clearSecret = JSON.parse(decrypted.data);
        assert.equal(clearSecret.password, 'mock-resource-password');
        assert.equal(clearSecret.description, 'mock description');
        send(response, 200, apiSuccess({
          id: 'created-resource-id',
          permission: {
            id: 'created-resource-permission-id',
            aco: 'Resource',
            aco_foreign_key: 'created-resource-id',
            aro: 'User',
            aro_foreign_key: 'user-id',
            type: 15,
          },
        }));
        return;
      }
      if (request.method === 'POST' && url.pathname.startsWith('/share/simulate/resource/')) {
        sharedSimulationPayload = await requestJson(request);
        assertNewPermissionMarkers(sharedSimulationPayload);
        assert.equal(sharedSimulationPayload.permissions.some((permission) => permission.aro === 'User' && permission.aro_foreign_key === 'direct-recipient-id'), true);
        assert.equal(sharedSimulationPayload.permissions.some((permission) => permission.aro === 'Group' && permission.aro_foreign_key === 'shared-group-id'), true);
        send(response, 200, apiSuccess({
          changes: {
            added: [{ User: { id: 'direct-recipient-id' } }, { User: { id: 'group-recipient-id' } }],
            removed: [],
          },
        }));
        return;
      }
      if (request.method === 'POST' && url.pathname.startsWith('/share/simulate/folder/')) {
        sharedFolderSimulationPayload = await requestJson(request);
        assertNewPermissionMarkers(sharedFolderSimulationPayload);
        assert.equal(sharedFolderSimulationPayload.permissions.some((permission) => permission.aco === 'Folder' && permission.aro === 'User' && permission.aro_foreign_key === 'direct-recipient-id'), true);
        assert.equal(sharedFolderSimulationPayload.permissions.some((permission) => permission.aco === 'Folder' && permission.aro === 'Group' && permission.aro_foreign_key === 'shared-group-id'), true);
        send(response, 200, apiSuccess({
          changes: {
            added: [{ User: { id: 'direct-recipient-id' } }, { User: { id: 'group-recipient-id' } }],
            removed: [],
          },
        }));
        return;
      }
      if (request.method === 'PUT' && url.pathname.startsWith('/share/folder/')) {
        sharedFolderApplyPayload = await requestJson(request);
        if (folderShareApplyMode === 'failure') {
          send(response, 400, apiError('Mock folder sharing failure.'));
          return;
        }
        assertNewPermissionMarkers(sharedFolderApplyPayload);
        assert.equal(Object.hasOwn(sharedFolderApplyPayload, 'secrets'), false);
        send(response, 200, apiSuccess(null));
        return;
      }
      if (request.method === 'PUT' && url.pathname.startsWith('/share/resource/')) {
        sharedApplyPayload = await requestJson(request);
        if (shareApplyMode === 'failure') {
          send(response, 400, apiError('Mock sharing failure.'));
          return;
        }
        assert.equal(sharedApplyPayload.secrets.length, 2);
        assertNewPermissionMarkers(sharedApplyPayload);
        const recipientPrivateKeys = new Map([
          ['direct-recipient-id', directRecipientPrivateKey],
          ['group-recipient-id', groupRecipientPrivateKey],
        ]);
        for (const secret of sharedApplyPayload.secrets) {
          const decrypted = await openpgp.decrypt({
            message: await openpgp.readMessage({ armoredMessage: secret.data }),
            decryptionKeys: recipientPrivateKeys.get(secret.user_id),
            verificationKeys: userPublicKey,
            format: 'utf8',
          });
          await Promise.all(decrypted.signatures.map((signature) => signature.verified));
          assert.equal(JSON.parse(decrypted.data).password, 'mock-resource-password');
        }
        send(response, 200, apiSuccess(null));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/auth/logout.json') {
        authenticated = false;
        send(response, 200, apiSuccess('OK'));
        return;
      }
      send(response, 404, apiError('Unknown test route.'));
    } catch {
      send(response, 500, apiError('Mock server internal error.'));
    }
  });

  await new Promise((resolve, reject) => {
    mockServer.once('error', reject);
    mockServer.listen(0, '127.0.0.1', resolve);
  });
  try {
    const address = mockServer.address();
    assert(address && typeof address === 'object');
    const baseUrl = `http://127.0.0.1:${address.port}`;
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
    existingV5Metadata = await openpgp.encrypt({
      message: await openpgp.createMessage({ text: JSON.stringify({
        object_type: 'PASSBOLT_RESOURCE_METADATA',
        resource_type_id: 'v5-resource-type-id',
        name: 'Portale v5 esistente',
        username: 'existing-v5-user',
        uris: ['https://existing-v5.example.test'],
      }) }),
      encryptionKeys: metadataPublicKey,
      signingKeys: userPrivateKey,
      format: 'armored',
    });
    existingV5FolderMetadata = await openpgp.encrypt({
      message: await openpgp.createMessage({ text: JSON.stringify({
        object_type: 'PASSBOLT_FOLDER_METADATA',
        name: 'Cliente Alfa',
      }) }),
      encryptionKeys: metadataPublicKey,
      signingKeys: userPrivateKey,
      format: 'armored',
    });

    const session = new PassboltSession(baseUrl);
    const keyMaterial = {
      privateKey: userPrivateKey,
      publicKey: userPublicKey,
      fingerprint: userFingerprint,
      keyId: userPublicKey.getKeyID().toHex().toUpperCase(),
      userIds: userPublicKey.getUserIDs(),
      encrypted: false,
    };
    const { user } = await authenticate(session, keyMaterial, serverFingerprint);
    assert.equal(user.id, 'user-id');
    assert.equal(session.csrfToken, 'mock-csrf');
    assert.equal(session.getCookie('redirectCookie'), 'redirect-value');
    await assert.rejects(
      session.request('/redirect/cross-origin.json'),
      (error) => error?.code === 'API_REDIRECT_CROSS_ORIGIN',
    );

    const candidates = [
      { candidate_id: 'candidate-duplicate', client: '(radice)', source_at_root: true, title: ' portale esistente ', username: 'EXISTING-USER', uri: 'https://existing.example.test' },
      { candidate_id: 'candidate-new', client: '(radice)', source_at_root: true, title: 'Nuovo portale', username: 'new-user', uri: 'https://new.example.test' },
    ];
    const capabilities = await readCapabilities(session, user, candidates);
    assert.equal(capabilities.can_import, true);
    assert.equal(capabilities.create_count, 1);
    assert.equal(capabilities.duplicate_count, 1);
    assert.equal(capabilities.csrf_token_available, true);

    const encryptedSecret = await encryptSecret(
      'mock-resource-password',
      'mock description',
      capabilities.resource_type,
      keyMaterial,
    );
    const createResponse = await session.request('/resources.json?api-version=v2', {
      method: 'POST',
      body: {
        name: 'Nuovo portale',
        username: 'new-user',
        uri: 'https://new.example.test',
        resource_type_id: capabilities.resource_type.id,
        secrets: [{ data: encryptedSecret }],
      },
    });
    assert.equal(createResponse.status, 200);
    assert.equal(createdPayload.name, 'Nuovo portale');
    assert.equal(createdPayload.secrets[0].data.includes('mock-resource-password'), false);

    folderMode = 'v4';
    const destinationCandidate = [{
      candidate_id: 'candidate-folder-v4',
      client: 'Cliente Alfa',
      source_at_root: false,
      title: 'Portale esistente',
      username: 'existing-user',
      uri: 'https://existing.example.test',
    }];
    existingResourceFolderId = 'folder-alpha-id';
    const duplicateInDestination = await analyzeCapabilities(session, user, destinationCandidate, keyMaterial, 'v4', 'client_folders', 'auto');
    assert.equal(duplicateInDestination.capabilities.can_import, true);
    assert.equal(duplicateInDestination.capabilities.duplicate_count, 1);
    assert.equal(duplicateInDestination.capabilities.candidates[0].duplicate_kind, 'server_destination');
    assert.equal(duplicateInDestination.capabilities.reuse_folder_count, 1);

    existingResourceFolderId = 'some-other-folder-id';
    const duplicateElsewhere = await analyzeCapabilities(session, user, destinationCandidate, keyMaterial, 'v4', 'client_folders', 'auto');
    assert.equal(duplicateElsewhere.capabilities.can_import, false);
    assert.equal(duplicateElsewhere.capabilities.blocked_count, 1);
    assert.equal(duplicateElsewhere.capabilities.candidates[0].duplicate_kind, 'server_elsewhere');
    assert.notEqual(duplicateElsewhere.capabilities.plan_digest, duplicateInDestination.capabilities.plan_digest);

    existingResourceFolderId = null;
    const rootDestination = await analyzeCapabilities(session, user, destinationCandidate, keyMaterial, 'v4', 'root', 'v5');
    assert.equal(rootDestination.capabilities.can_import, true);
    assert.equal(rootDestination.capabilities.destination_mode, 'root');
    assert.equal(rootDestination.capabilities.folder_format_selected, null);
    assert.equal(rootDestination.capabilities.create_folder_count, 0);
    assert.equal(rootDestination.capabilities.candidates[0].folder_action, 'root');

    folderMode = 'nested-v4';
    existingResourceFolderId = 'folder-alpha-nested-id';
    const nestedContainerAnalysis = await analyzeCapabilities(
      session,
      user,
      destinationCandidate,
      keyMaterial,
      'v4',
      'client_folders',
      'auto',
      'folder-container-id',
    );
    assert.equal(nestedContainerAnalysis.capabilities.can_import, true);
    assert.equal(nestedContainerAnalysis.capabilities.destination_folder_id, 'folder-container-id');
    assert.equal(nestedContainerAnalysis.capabilities.candidates[0].folder_id, 'folder-alpha-nested-id');
    assert.equal(nestedContainerAnalysis.capabilities.candidates[0].folder_path, 'Clienti / Cliente Alfa');
    assert.equal(nestedContainerAnalysis.capabilities.available_folders[1].path, 'Clienti / Cliente Alfa');

    const directFolderAnalysis = await analyzeCapabilities(
      session,
      user,
      destinationCandidate,
      keyMaterial,
      'v4',
      'direct_folder',
      'auto',
      'folder-alpha-nested-id',
    );
    assert.equal(directFolderAnalysis.capabilities.can_import, true);
    assert.equal(directFolderAnalysis.capabilities.duplicate_count, 1);
    assert.equal(directFolderAnalysis.capabilities.candidates[0].folder_path, 'Clienti / Cliente Alfa');

    existingResourceFolderId = null;
    const mappedCandidates = [
      {
        candidate_id: 'candidate-mapped-alpha',
        client: 'Cliente Alfa',
        source_at_root: false,
        title: 'Portale mappato Alfa',
        username: 'mapped-alpha-user',
        uri: 'https://mapped-alpha.example.test',
      },
      {
        candidate_id: 'candidate-mapped-beta',
        client: 'Cliente Beta',
        source_at_root: false,
        title: 'Portale mappato Beta',
        username: 'mapped-beta-user',
        uri: 'https://mapped-beta.example.test',
      },
    ];
    const incompleteClientMapping = await analyzeCapabilities(
      session,
      user,
      mappedCandidates,
      keyMaterial,
      'v4',
      'client_mapping',
      'v5',
      null,
      [{ client: 'Cliente Alfa', folder_id: 'folder-alpha-nested-id' }],
    );
    assert.equal(incompleteClientMapping.capabilities.can_import, false);
    assert.deepEqual(incompleteClientMapping.capabilities.required_clients, ['Cliente Alfa', 'Cliente Beta']);
    assert.match(incompleteClientMapping.capabilities.unavailable_reason, /Cliente Beta/);
    assert.equal(incompleteClientMapping.capabilities.available_folders.length, 2);

    const clientMapping = [
      { client: 'Cliente Alfa', folder_id: 'folder-alpha-nested-id' },
      { client: 'Cliente Beta', folder_id: 'folder-container-id' },
    ];
    const mappedAnalysis = await analyzeCapabilities(
      session,
      user,
      mappedCandidates,
      keyMaterial,
      'v4',
      'client_mapping',
      'v5',
      'ignored-common-folder-id',
      clientMapping,
    );
    assert.equal(mappedAnalysis.capabilities.can_import, true);
    assert.equal(mappedAnalysis.capabilities.destination_folder_id, null);
    assert.equal(mappedAnalysis.capabilities.folder_format_selected, null);
    assert.equal(mappedAnalysis.capabilities.create_folder_count, 0);
    assert.equal(mappedAnalysis.capabilities.reuse_folder_count, 2);
    assert.equal(mappedAnalysis.capabilities.candidates[0].folder_id, 'folder-alpha-nested-id');
    assert.equal(mappedAnalysis.capabilities.candidates[0].folder_path, 'Clienti / Cliente Alfa');
    assert.equal(mappedAnalysis.capabilities.candidates[1].folder_id, 'folder-container-id');
    assert.equal(mappedAnalysis.capabilities.candidates[1].folder_path, 'Clienti');
    assert.equal(mappedAnalysis.capabilities.available_folders.every((folder) => folder.personal === true), true);
    assert.deepEqual(mappedAnalysis.capabilities.client_destination_mapping, clientMapping);

    const swappedMappingAnalysis = await analyzeCapabilities(
      session,
      user,
      mappedCandidates,
      keyMaterial,
      'v4',
      'client_mapping',
      'auto',
      null,
      [
        { client: 'Cliente Alfa', folder_id: 'folder-container-id' },
        { client: 'Cliente Beta', folder_id: 'folder-alpha-nested-id' },
      ],
    );
    assert.notEqual(swappedMappingAnalysis.capabilities.plan_digest, mappedAnalysis.capabilities.plan_digest);

    const mappedWrites = [];
    const mappedSession = {
      async request(path, options) {
        mappedWrites.push({ path, body: options.body });
        return { status: 200, document: { body: { id: `mapped-resource-${mappedWrites.length}` } } };
      },
    };
    await createPlannedContent(
      mappedSession,
      mappedAnalysis.capabilities.candidates,
      mappedCandidates.map((candidate) => ({ ...candidate, password: `password-${candidate.candidate_id}`, description: '' })),
      mappedAnalysis.runtime,
      keyMaterial,
    );
    assert.equal(mappedWrites.length, 2);
    assert.deepEqual(mappedWrites.map((entry) => entry.body.folder_parent_id), ['folder-alpha-nested-id', 'folder-container-id']);

    const mappingWithRoot = await analyzeCapabilities(
      session,
      user,
      mappedCandidates,
      keyMaterial,
      'v4',
      'client_mapping',
      'auto',
      null,
      [
        { client: 'Cliente Alfa', folder_id: 'folder-alpha-nested-id' },
        { client: 'Cliente Beta', folder_id: null },
      ],
    );
    assert.equal(mappingWithRoot.capabilities.can_import, true);
    assert.equal(mappingWithRoot.capabilities.candidates[1].folder_action, 'root');

    const directFolderMissingSelection = await analyzeCapabilities(
      session,
      user,
      destinationCandidate,
      keyMaterial,
      'v4',
      'direct_folder',
      'auto',
      null,
    );
    assert.equal(directFolderMissingSelection.capabilities.can_import, false);
    assert.equal(directFolderMissingSelection.capabilities.available_folders.length, 2);
    assert.match(directFolderMissingSelection.capabilities.unavailable_reason, /Selezionare la cartella Passbolt/);

    folderMode = 'readonly-v4';
    const readOnlyDestination = await analyzeCapabilities(
      session,
      user,
      destinationCandidate,
      keyMaterial,
      'v4',
      'direct_folder',
      'auto',
      'folder-readonly-id',
    );
    assert.equal(readOnlyDestination.capabilities.can_import, false);
    assert.equal(readOnlyDestination.capabilities.available_folders.length, 0);
    assert.match(readOnlyDestination.capabilities.unavailable_reason, /permesso necessario/);
    const readOnlyMapping = await analyzeCapabilities(
      session,
      user,
      destinationCandidate,
      keyMaterial,
      'v4',
      'client_mapping',
      'auto',
      null,
      [{ client: 'Cliente Alfa', folder_id: 'folder-readonly-id' }],
    );
    assert.equal(readOnlyMapping.capabilities.can_import, false);
    assert.match(readOnlyMapping.capabilities.unavailable_reason, /permesso necessario/);

    folderMode = 'shared-v4';
    const sharedCandidate = [{
      candidate_id: 'candidate-shared-v4',
      client: 'Cliente Condiviso',
      source_at_root: false,
      title: 'Portale condiviso',
      username: 'shared-user',
      uri: 'https://shared.example.test',
    }];
    const sharedMapping = await analyzeCapabilities(
      session,
      user,
      sharedCandidate,
      keyMaterial,
      'v4',
      'client_mapping',
      'auto',
      null,
      [{ client: 'Cliente Condiviso', folder_id: 'folder-shared-id' }],
    );
    assert.equal(sharedMapping.capabilities.can_import, true);
    assert.equal(sharedMapping.capabilities.available_folders.length, 1);
    assert.equal(sharedMapping.capabilities.available_folders[0].shared, true);
    assert.equal(sharedMapping.capabilities.available_folders[0].share_recipient_count, 3);
    assert.equal(sharedMapping.capabilities.shared_create_count, 1);
    assert.equal(sharedMapping.capabilities.encrypted_secret_copy_count, 3);
    assert.equal(sharedMapping.capabilities.candidates[0].share_permission_count, 3);
    assert.equal(sharedMapping.capabilities.candidates[0].share_recipients.find((entry) => entry.user_id === 'direct-recipient-id').permission_type, 7);

    const sharedCreated = await createPlannedContent(
      session,
      sharedMapping.capabilities.candidates,
      [{ ...sharedCandidate[0], password: 'mock-resource-password', description: 'mock description' }],
      sharedMapping.runtime,
      keyMaterial,
    );
    assert.equal(sharedCreated.created.length, 1);
    assert.equal(sharedCreated.created[0].status, 'created_shared');
    assert.equal(sharedCreated.created[0].encrypted_secret_copies, 2);
    assert.equal(sharedApplyPayload.secrets.length, 2);
    assert.equal(sharedApplyPayload.secrets.some((secret) => secret.user_id === 'direct-recipient-id'), true);
    assert.equal(sharedApplyPayload.secrets.some((secret) => secret.user_id === 'group-recipient-id'), true);
    assert.equal(JSON.stringify(sharedApplyPayload).includes('mock-resource-password'), false);

    shareApplyMode = 'failure';
    await assert.rejects(
      createPlannedContent(
        session,
        sharedMapping.capabilities.candidates,
        [{ ...sharedCandidate[0], password: 'mock-resource-password', description: 'mock description' }],
        sharedMapping.runtime,
        keyMaterial,
      ),
      (error) => error?.code === 'IMPORT_PARTIAL_FAILURE'
        && error?.details?.sharing_failed === true
        && error?.details?.created?.[0]?.status === 'created_unshared',
    );
    shareApplyMode = 'success';

    const sharedChildCandidate = [{
      candidate_id: 'candidate-shared-child-v4',
      client: 'Cliente Nuovo Condiviso',
      source_at_root: false,
      title: 'Portale nella nuova cartella condivisa',
      username: 'shared-child-user',
      uri: 'https://shared-child.example.test',
    }];
    const sharedChildAnalysis = await analyzeCapabilities(
      session,
      user,
      sharedChildCandidate,
      keyMaterial,
      'v4',
      'client_folders',
      'v4',
      'folder-shared-id',
    );
    assert.equal(sharedChildAnalysis.capabilities.can_import, true);
    assert.equal(sharedChildAnalysis.capabilities.create_folder_count, 1);
    assert.equal(sharedChildAnalysis.capabilities.create_shared_folder_count, 1);
    assert.equal(sharedChildAnalysis.capabilities.shared_create_count, 1);
    assert.equal(sharedChildAnalysis.capabilities.encrypted_secret_copy_count, 3);
    assert.equal(sharedChildAnalysis.runtime.folders[0].shared, true);
    assert.equal(sharedChildAnalysis.runtime.folders[0].folder_parent_id, 'folder-shared-id');
    assert.equal(sharedChildAnalysis.runtime.folders[0].share_inherited_from_folder_id, 'folder-shared-id');
    assert.equal(sharedChildAnalysis.runtime.folders[0].share_inherited_from_path, 'Cartella condivisa');
    assert.equal(sharedChildAnalysis.runtime.folders[0].share_permission_count, 3);
    assert.equal(sharedChildAnalysis.capabilities.candidates[0].folder_action, 'create');
    assert.equal(sharedChildAnalysis.capabilities.candidates[0].shared, true);

    sharedFolderPermissionMode = 'changed';
    const changedSharedChildAnalysis = await analyzeCapabilities(
      session,
      user,
      sharedChildCandidate,
      keyMaterial,
      'v4',
      'client_folders',
      'v4',
      'folder-shared-id',
    );
    assert.notEqual(changedSharedChildAnalysis.capabilities.plan_digest, sharedChildAnalysis.capabilities.plan_digest);
    sharedFolderPermissionMode = 'normal';

    const sharedChildCreated = await createPlannedContent(
      session,
      sharedChildAnalysis.capabilities.candidates,
      [{ ...sharedChildCandidate[0], password: 'mock-resource-password', description: 'mock description' }],
      sharedChildAnalysis.runtime,
      keyMaterial,
    );
    assert.equal(sharedChildCreated.createdFolders.length, 1);
    assert.equal(sharedChildCreated.createdFolders[0].status, 'created_shared');
    assert.equal(sharedChildCreated.createdFolders[0].added_user_count, 2);
    assert.equal(sharedChildCreated.created[0].status, 'created_shared');
    assert.equal(createdFolderPayload.folder_parent_id, 'folder-shared-id');
    assert.equal(createdPayload.folder_parent_id, 'created-folder-id');
    assert.equal(sharedFolderSimulationPayload.permissions.some((permission) => permission.aco_foreign_key === 'created-folder-id'), true);
    assert.equal(sharedFolderApplyPayload.permissions.some((permission) => permission.aro === 'Group' && permission.aro_foreign_key === 'shared-group-id'), true);

    folderShareApplyMode = 'failure';
    await assert.rejects(
      createPlannedContent(
        session,
        sharedChildAnalysis.capabilities.candidates,
        [{ ...sharedChildCandidate[0], password: 'mock-resource-password', description: 'mock description' }],
        sharedChildAnalysis.runtime,
        keyMaterial,
      ),
      (error) => error?.code === 'IMPORT_PARTIAL_FAILURE'
        && error?.details?.folder_sharing_failed === true
        && error?.details?.created_unshared_folder_id === 'created-folder-id'
        && error?.details?.created_folders?.[0]?.status === 'created_unshared'
        && error?.details?.created?.length === 0,
    );
    folderShareApplyMode = 'success';

    includePersonalChildInSharedContainer = true;
    const unsharedChildReconciliation = await analyzeCapabilities(
      session,
      user,
      sharedChildCandidate,
      keyMaterial,
      'v4',
      'client_folders',
      'v4',
      'folder-shared-id',
    );
    assert.equal(unsharedChildReconciliation.capabilities.can_import, true);
    assert.equal(unsharedChildReconciliation.capabilities.create_folder_count, 0);
    assert.equal(unsharedChildReconciliation.capabilities.reconcile_shared_folder_count, 1);
    assert.equal(unsharedChildReconciliation.capabilities.candidates[0].folder_action, 'repair_share');
    assert.equal(unsharedChildReconciliation.capabilities.candidates[0].folder_id, 'created-unshared-folder-id');
    assert.equal(unsharedChildReconciliation.runtime.folders[0].existing_permission.id, 'created-unshared-owner-permission-id');

    const folderRequestsBeforeReconciliation = createdFolderRequestCount;
    folderShareApplyMode = 'failure';
    await assert.rejects(
      createPlannedContent(
        session,
        unsharedChildReconciliation.capabilities.candidates,
        [{ ...sharedChildCandidate[0], password: 'mock-resource-password', description: 'mock description' }],
        unsharedChildReconciliation.runtime,
        keyMaterial,
      ),
      (error) => error?.code === 'IMPORT_PARTIAL_FAILURE'
        && error?.details?.folder_reconciliation_failed === true
        && error?.details?.existing_personal_folder_id === 'created-unshared-folder-id'
        && error?.details?.created_folders?.length === 0
        && error?.details?.created?.length === 0,
    );
    assert.equal(createdFolderRequestCount, folderRequestsBeforeReconciliation);
    folderShareApplyMode = 'success';

    const reconciledChildCreated = await createPlannedContent(
      session,
      unsharedChildReconciliation.capabilities.candidates,
      [{ ...sharedChildCandidate[0], password: 'mock-resource-password', description: 'mock description' }],
      unsharedChildReconciliation.runtime,
      keyMaterial,
    );
    assert.equal(createdFolderRequestCount, folderRequestsBeforeReconciliation);
    assert.equal(reconciledChildCreated.createdFolders.length, 0);
    assert.equal(reconciledChildCreated.reconciledFolders.length, 1);
    assert.equal(reconciledChildCreated.reconciledFolders[0].folder_id, 'created-unshared-folder-id');
    assert.equal(reconciledChildCreated.reconciledFolders[0].status, 'reconciled_shared');
    assert.equal(reconciledChildCreated.created[0].status, 'created_shared');
    assert.equal(createdPayload.folder_parent_id, 'created-unshared-folder-id');
    assert.equal(sharedFolderApplyPayload.permissions.every((permission) => permission.id || permission.is_new === true), true);

    existingResourceFolderId = 'created-unshared-folder-id';
    const nonEmptyPersonalChild = await analyzeCapabilities(
      session,
      user,
      sharedChildCandidate,
      keyMaterial,
      'v4',
      'client_folders',
      'v4',
      'folder-shared-id',
    );
    assert.equal(nonEmptyPersonalChild.capabilities.can_import, false);
    assert.match(nonEmptyPersonalChild.capabilities.unavailable_reason, /vuota/i);
    assert.match(nonEmptyPersonalChild.capabilities.unavailable_reason, /created-unshared-folder-id/);
    existingResourceFolderId = null;
    includePersonalChildInSharedContainer = false;

    shareDirectoryMode = 'missing-key';
    const sharedMissingKey = await analyzeCapabilities(
      session,
      user,
      sharedCandidate,
      keyMaterial,
      'v4',
      'direct_folder',
      'auto',
      'folder-shared-id',
    );
    assert.equal(sharedMissingKey.capabilities.can_import, false);
    assert.equal(sharedMissingKey.capabilities.available_folders.length, 0);
    assert.match(sharedMissingKey.capabilities.unavailable_reason, /chiave pubblica/i);
    shareDirectoryMode = 'valid';

    folderMode = 'nested-v4';
    const nestedNewCandidate = [{
      candidate_id: 'candidate-nested-new-folder-v4',
      client: 'Cliente Beta',
      source_at_root: false,
      title: 'Portale annidato Cliente Beta',
      username: 'nested-beta-user',
      uri: 'https://nested-beta.example.test',
    }];
    const nestedNewAnalysis = await analyzeCapabilities(
      session,
      user,
      nestedNewCandidate,
      keyMaterial,
      'v4',
      'client_folders',
      'auto',
      'folder-container-id',
    );
    assert.equal(nestedNewAnalysis.capabilities.create_folder_count, 1);
    assert.equal(nestedNewAnalysis.runtime.folders[0].folder_parent_id, 'folder-container-id');
    assert.equal(nestedNewAnalysis.runtime.folders[0].path, 'Clienti / Cliente Beta');
    const nestedFolderPayload = await buildFolderPayload(nestedNewAnalysis.runtime.folders[0], nestedNewAnalysis.runtime, keyMaterial);
    assert.equal(nestedFolderPayload.folder_parent_id, 'folder-container-id');
    assert.notEqual(nestedNewAnalysis.capabilities.plan_digest, rootDestination.capabilities.plan_digest);

    const directNewAnalysis = await analyzeCapabilities(
      session,
      user,
      nestedNewCandidate,
      keyMaterial,
      'v4',
      'direct_folder',
      'auto',
      'folder-container-id',
    );
    assert.equal(directNewAnalysis.capabilities.create_count, 1);
    assert.equal(directNewAnalysis.capabilities.create_folder_count, 0);
    const directWrites = [];
    const directSession = {
      async request(path, options) {
        directWrites.push({ path, body: options.body });
        assert.equal(path.startsWith('/resources.json'), true);
        assert.equal(options.body.folder_parent_id, 'folder-container-id');
        return { status: 200, document: { body: { id: 'direct-resource-id' } } };
      },
    };
    await createPlannedContent(
      directSession,
      directNewAnalysis.capabilities.candidates,
      [{ ...nestedNewCandidate[0], password: 'direct-password', description: '' }],
      directNewAnalysis.runtime,
      keyMaterial,
    );
    assert.equal(directWrites.length, 1);

    existingResourceFolderId = null;
    folderMode = 'empty';
    const newFolderCandidates = [{
      candidate_id: 'candidate-new-folder-v4',
      client: 'Cliente Beta',
      source_at_root: false,
      title: 'Portale Cliente Beta',
      username: 'beta-user',
      uri: 'https://beta.example.test',
    }];
    const newFolderAnalysis = await analyzeCapabilities(session, user, newFolderCandidates, keyMaterial, 'v4', 'client_folders', 'auto');
    assert.equal(newFolderAnalysis.capabilities.can_import, true);
    assert.equal(newFolderAnalysis.capabilities.create_folder_count, 1);
    assert.equal(newFolderAnalysis.capabilities.folder_format_selected, 'v4');
    const v4FolderPayload = await buildFolderPayload(newFolderAnalysis.runtime.folders[0], newFolderAnalysis.runtime, keyMaterial);
    assert.deepEqual(v4FolderPayload, { name: 'Cliente Beta', folder_parent_id: null });
    const crossFolderBatchAnalysis = await analyzeCapabilities(session, user, [
      newFolderCandidates[0],
      { ...newFolderCandidates[0], candidate_id: 'candidate-same-secret-other-client', client: 'Cliente Gamma' },
    ], keyMaterial, 'v4', 'client_folders', 'auto');
    assert.equal(crossFolderBatchAnalysis.capabilities.create_count, 2);
    assert.equal(crossFolderBatchAnalysis.capabilities.duplicate_count, 0);
    assert.equal(crossFolderBatchAnalysis.capabilities.create_folder_count, 2);

    const plannedResource = {
      ...newFolderCandidates[0],
      password: 'beta-password',
      description: '',
    };
    const simulatedCalls = [];
    const simulatedSession = {
      async request(path, options) {
        simulatedCalls.push({ path, body: options.body });
        if (path.startsWith('/folders.json')) {
          return { status: 200, document: { body: { id: 'simulated-folder-id' } } };
        }
        assert.equal(options.body.folder_parent_id, 'simulated-folder-id');
        return { status: 200, document: { body: { id: 'simulated-resource-id' } } };
      },
    };
    const simulatedCreation = await createPlannedContent(
      simulatedSession,
      newFolderAnalysis.capabilities.candidates,
      [plannedResource],
      newFolderAnalysis.runtime,
      keyMaterial,
    );
    assert.equal(simulatedCalls.length, 2);
    assert.equal(simulatedCreation.createdFolders.length, 1);
    assert.equal(simulatedCreation.created.length, 1);

    const failingSession = {
      async request(path) {
        if (path.startsWith('/folders.json')) {
          return { status: 200, document: { body: { id: 'partial-folder-id' } } };
        }
        return { status: 500, document: { header: { message: 'Simulated resource failure.' } } };
      },
    };
    await assert.rejects(
      createPlannedContent(
        failingSession,
        newFolderAnalysis.capabilities.candidates,
        [plannedResource],
        newFolderAnalysis.runtime,
        keyMaterial,
      ),
      (error) => error?.code === 'IMPORT_PARTIAL_FAILURE'
        && error?.details?.created_folders?.length === 1
        && error?.details?.created?.length === 0,
    );

    await session.request('/auth/logout.json?api-version=v2', { method: 'POST' });
    assert.equal(authenticated, false);

    resourceMode = 'v5';
    const v5Session = new PassboltSession(baseUrl);
    const v5Authentication = await authenticate(v5Session, keyMaterial, serverFingerprint);
    const v5Candidates = [
      { candidate_id: 'candidate-v5-duplicate', client: '(radice)', source_at_root: true, title: ' portale v5 esistente ', username: 'EXISTING-V5-USER', uri: 'https://existing-v5.example.test' },
      { candidate_id: 'candidate-v5-new', client: '(radice)', source_at_root: true, title: 'Nuovo portale v5', username: 'new-v5-user', uri: 'https://new-v5.example.test' },
    ];
    const v5Analysis = await analyzeCapabilities(v5Session, v5Authentication.user, v5Candidates, keyMaterial, 'auto');
    assert.equal(v5Analysis.capabilities.can_import, true);
    assert.equal(v5Analysis.capabilities.resource_format_selected, 'v5');
    assert.equal(v5Analysis.capabilities.resource_type.slug, 'v5-default');
    assert.equal(v5Analysis.capabilities.metadata_key.type, 'shared_key');
    assert.equal(v5Analysis.capabilities.duplicate_count, 1);
    assert.equal(v5Analysis.capabilities.create_count, 1);
    assert.equal(JSON.stringify(v5Analysis.capabilities).includes('PRIVATE KEY BLOCK'), false);

    folderMode = 'v5';
    const v5FolderCandidate = [{
      candidate_id: 'candidate-folder-v5',
      client: 'Cliente Alfa',
      source_at_root: false,
      title: 'Portale Cliente Alfa v5',
      username: 'alpha-v5-user',
      uri: 'https://alpha-v5.example.test',
    }];
    const v5FolderReuseAnalysis = await analyzeCapabilities(v5Session, v5Authentication.user, v5FolderCandidate, keyMaterial, 'v5', 'client_folders', 'auto');
    assert.equal(v5FolderReuseAnalysis.capabilities.can_import, true);
    assert.equal(v5FolderReuseAnalysis.capabilities.reuse_folder_count, 1);
    assert.equal(v5FolderReuseAnalysis.capabilities.candidates[0].folder_id, 'folder-alpha-v5-id');
    const v5ClientMappingAnalysis = await analyzeCapabilities(
      v5Session,
      v5Authentication.user,
      v5FolderCandidate,
      keyMaterial,
      'v5',
      'client_mapping',
      'v5',
      null,
      [{ client: 'Cliente Alfa', folder_id: 'folder-alpha-v5-id' }],
    );
    assert.equal(v5ClientMappingAnalysis.capabilities.can_import, true);
    assert.equal(v5ClientMappingAnalysis.capabilities.folder_format_selected, null);
    assert.equal(v5ClientMappingAnalysis.capabilities.candidates[0].folder_id, 'folder-alpha-v5-id');
    const v5MappedResourcePayload = await buildResourcePayload({
      title: 'Portale Cliente Alfa v5',
      username: 'alpha-v5-user',
      uri: 'https://alpha-v5.example.test',
      password: 'alpha-v5-password',
      description: '',
    }, v5FolderReuseAnalysis.runtime, keyMaterial, 'folder-alpha-v5-id');
    assert.equal(v5MappedResourcePayload.folder_parent_id, 'folder-alpha-v5-id');

    const v5NestedFolderAnalysis = await analyzeCapabilities(v5Session, v5Authentication.user, [{
      ...v5FolderCandidate[0],
      candidate_id: 'candidate-folder-v5-nested',
      client: 'Cliente Gamma',
    }], keyMaterial, 'v5', 'client_folders', 'v5', 'folder-alpha-v5-id');
    assert.equal(v5NestedFolderAnalysis.capabilities.create_folder_count, 1);
    assert.equal(v5NestedFolderAnalysis.runtime.folders[0].folder_parent_id, 'folder-alpha-v5-id');
    assert.equal(v5NestedFolderAnalysis.runtime.folders[0].path, 'Cliente Alfa / Cliente Gamma');
    const v5NestedFolderPayload = await buildFolderPayload(v5NestedFolderAnalysis.runtime.folders[0], v5NestedFolderAnalysis.runtime, keyMaterial);
    assert.equal(v5NestedFolderPayload.folder_parent_id, 'folder-alpha-v5-id');

    folderMode = 'empty';
    const v5FolderCreateAnalysis = await analyzeCapabilities(v5Session, v5Authentication.user, [{
      ...v5FolderCandidate[0],
      candidate_id: 'candidate-folder-v5-create',
      client: 'Cliente Gamma',
    }], keyMaterial, 'v5', 'client_folders', 'v5');
    assert.equal(v5FolderCreateAnalysis.capabilities.create_folder_count, 1);
    assert.equal(v5FolderCreateAnalysis.capabilities.folder_format_selected, 'v5');
    const v5FolderPayload = await buildFolderPayload(v5FolderCreateAnalysis.runtime.folders[0], v5FolderCreateAnalysis.runtime, keyMaterial);
    assert.equal(Object.hasOwn(v5FolderPayload, 'name'), false);
    const decryptedFolderMetadata = await openpgp.decrypt({
      message: await openpgp.readMessage({ armoredMessage: v5FolderPayload.metadata }),
      decryptionKeys: metadataPrivateKey,
      verificationKeys: userPublicKey,
      format: 'utf8',
    });
    await Promise.all(decryptedFolderMetadata.signatures.map((signature) => signature.verified));
    assert.deepEqual(JSON.parse(decryptedFolderMetadata.data), {
      object_type: 'PASSBOLT_FOLDER_METADATA',
      name: 'Cliente Gamma',
    });

    const v5Payload = await buildResourcePayload({
      title: 'Nuovo portale v5',
      username: 'new-v5-user',
      uri: 'https://new-v5.example.test',
      password: 'mock-v5-password',
      description: 'mock v5 description',
    }, v5Analysis.runtime, keyMaterial);
    const v5CreateResponse = await v5Session.request('/resources.json?api-version=v2&contain[permission]=1', {
      method: 'POST',
      body: v5Payload,
    });
    assert.equal(v5CreateResponse.status, 200);
    assert.equal(createdPayloadV5.metadata.includes('Nuovo portale v5'), false);
    assert.equal(createdPayloadV5.secrets[0].data.includes('mock-v5-password'), false);

    personalMetadataMode = true;
    const personalV5Analysis = await analyzeCapabilities(v5Session, v5Authentication.user, v5Candidates, keyMaterial, 'v5');
    assert.equal(personalV5Analysis.capabilities.metadata_key.type, 'user_key');
    assert.equal(personalV5Analysis.capabilities.metadata_key.id, 'user-gpg-key-id');
    const personalV5Payload = await buildResourcePayload({
      title: 'Risorsa v5 personale',
      username: 'personal-user',
      uri: 'https://personal-v5.example.test',
      password: 'personal-v5-password',
      description: 'personal v5 description',
    }, personalV5Analysis.runtime, keyMaterial);
    const personalMetadata = await openpgp.decrypt({
      message: await openpgp.readMessage({ armoredMessage: personalV5Payload.metadata }),
      decryptionKeys: userPrivateKey,
      verificationKeys: userPublicKey,
      format: 'utf8',
    });
    await Promise.all(personalMetadata.signatures.map((signature) => signature.verified));
    assert.equal(JSON.parse(personalMetadata.data).name, 'Risorsa v5 personale');
    assert.equal(personalV5Payload.metadata_key_type, 'user_key');

    folderMode = 'shared-v4';
    const sharedV5Candidate = [{
      candidate_id: 'candidate-shared-v5',
      client: 'Cliente Condiviso v5',
      source_at_root: false,
      title: 'Risorsa v5 condivisa',
      username: 'shared-v5-user',
      uri: 'https://shared-v5.example.test',
    }];
    const sharedV5Analysis = await analyzeCapabilities(
      v5Session,
      v5Authentication.user,
      sharedV5Candidate,
      keyMaterial,
      'v5',
      'client_mapping',
      'auto',
      null,
      [{ client: 'Cliente Condiviso v5', folder_id: 'folder-shared-id' }],
    );
    assert.equal(sharedV5Analysis.capabilities.can_import, true);
    assert.equal(sharedV5Analysis.capabilities.metadata_key.type, 'shared_key');
    const sharedV5Payload = await buildResourcePayload({
      ...sharedV5Analysis.capabilities.candidates[0],
      password: 'shared-v5-password',
      description: 'shared v5 description',
    }, sharedV5Analysis.runtime, keyMaterial, 'folder-shared-id');
    assert.equal(sharedV5Payload.metadata_key_type, 'shared_key');
    const sharedV5Metadata = await openpgp.decrypt({
      message: await openpgp.readMessage({ armoredMessage: sharedV5Payload.metadata }),
      decryptionKeys: metadataPrivateKey,
      verificationKeys: userPublicKey,
      format: 'utf8',
    });
    await Promise.all(sharedV5Metadata.signatures.map((signature) => signature.verified));
    assert.equal(JSON.parse(sharedV5Metadata.data).name, 'Risorsa v5 condivisa');

    const sharedV5ChildAnalysis = await analyzeCapabilities(
      v5Session,
      v5Authentication.user,
      [{ ...sharedV5Candidate[0], candidate_id: 'candidate-shared-v5-child', client: 'Cliente Nuovo v5' }],
      keyMaterial,
      'v5',
      'client_folders',
      'v5',
      'folder-shared-id',
    );
    assert.equal(sharedV5ChildAnalysis.capabilities.can_import, true);
    assert.equal(sharedV5ChildAnalysis.capabilities.create_shared_folder_count, 1);
    assert.equal(sharedV5ChildAnalysis.capabilities.metadata_key.type, 'shared_key');
    const sharedV5FolderPayload = await buildFolderPayload(sharedV5ChildAnalysis.runtime.folders[0], sharedV5ChildAnalysis.runtime, keyMaterial);
    assert.equal(sharedV5FolderPayload.metadata_key_type, 'shared_key');
    assert.equal(sharedV5FolderPayload.metadata_key_id, 'metadata-key-id');
    const sharedV5FolderMetadata = await openpgp.decrypt({
      message: await openpgp.readMessage({ armoredMessage: sharedV5FolderPayload.metadata }),
      decryptionKeys: metadataPrivateKey,
      verificationKeys: userPublicKey,
      format: 'utf8',
    });
    await Promise.all(sharedV5FolderMetadata.signatures.map((signature) => signature.verified));
    assert.equal(JSON.parse(sharedV5FolderMetadata.data).name, 'Cliente Nuovo v5');
    folderMode = 'empty';
    personalMetadataMode = false;
    await v5Session.request('/auth/logout.json?api-version=v2', { method: 'POST' });
    assert.equal(authenticated, false);

    resourceMode = 'v4';
    identityMode = 'mfa';
    const missingMfaSession = new PassboltSession(baseUrl);
    await assert.rejects(
      authenticate(missingMfaSession, keyMaterial, serverFingerprint),
      (error) => error?.code === 'MFA_TOTP_REQUIRED',
    );

    const rejectedMfaSession = new PassboltSession(baseUrl);
    await assert.rejects(
      authenticate(rejectedMfaSession, keyMaterial, serverFingerprint, '000000'),
      (error) => error?.code === 'MFA_TOTP_REJECTED',
    );

    const mfaSession = new PassboltSession(baseUrl);
    const mfaAuthentication = await authenticate(mfaSession, keyMaterial, serverFingerprint, '654321');
    assert.equal(mfaAuthentication.user.id, 'user-id');
    assert.equal(mfaAuthentication.mfaProvider, 'totp');
    assert.equal(mfaSession.getCookie('passbolt_mfa'), 'mock-mfa');
    const persistentWorker = new PersistentImportSession();
    persistentWorker.state = {
      sessionId: 'persistent-test-session',
      baseUrl,
      expectedFingerprint: serverFingerprint,
      session: mfaSession,
      key: keyMaterial,
      user: mfaAuthentication.user,
      mfaProvider: mfaAuthentication.mfaProvider,
    };
    const loginCountBeforePersistentRequests = completedLoginCount;
    const persistentCandidates = [{
      candidate_id: 'persistent-session-candidate',
      client: '(radice)',
      source_at_root: true,
      title: 'Risorsa sessione persistente',
      username: 'persistent-user',
      uri: 'https://persistent.example.test',
    }];
    const firstPersistentReadiness = await persistentWorker.readiness({
      command: 'session-readiness',
      session_id: 'persistent-test-session',
      candidates: persistentCandidates,
      resource_format: 'v4',
      destination_mode: 'root',
      folder_format: 'auto',
    });
    const secondPersistentReadiness = await persistentWorker.readiness({
      command: 'session-readiness',
      session_id: 'persistent-test-session',
      candidates: persistentCandidates,
      resource_format: 'v4',
      destination_mode: 'root',
      folder_format: 'auto',
    });
    assert.equal(firstPersistentReadiness.session_id, 'persistent-test-session');
    assert.equal(secondPersistentReadiness.authentication, 'GPGAuth + TOTP');
    assert.equal(completedLoginCount, loginCountBeforePersistentRequests);
    await assert.rejects(
      persistentWorker.readiness({
        session_id: 'wrong-session-id',
        candidates: persistentCandidates,
      }),
      (error) => error?.code === 'IMPORT_SESSION_ID_MISMATCH',
    );
    await persistentWorker.close({ session_id: 'persistent-test-session' });
    assert.equal(authenticated, false);
    process.stdout.write(`${JSON.stringify({
      ok: true,
      result: {
        gpgauth_stage0: true,
        gpgauth_stage1: true,
        gpgauth_stage2: true,
        same_origin_redirect: true,
        cross_origin_redirect_blocked: true,
        mfa_redirect_detected: true,
        mfa_totp_required: true,
        mfa_totp_rejected: true,
        mfa_totp_authenticated: true,
        persistent_authenticated_session: true,
        mfa_reused_without_reprompt: true,
        csrf: true,
        duplicate_detection: true,
        v4_resource_creation: true,
        v5_shared_metadata_key_verified: true,
        v5_personal_metadata_key: true,
        v5_duplicate_metadata_decryption: true,
        v5_resource_creation: true,
        v5_metadata_and_secret_encrypted: true,
        v4_folder_creation: true,
        v5_folder_metadata_decryption: true,
        v5_folder_creation: true,
        folder_parent_id_assignment: true,
        folder_catalog_paths: true,
        selected_parent_folder: true,
        direct_existing_folder_destination: true,
        per_client_destination_mapping: true,
        per_client_mapping_in_digest: true,
        per_client_root_destination: true,
        v5_per_client_destination_mapping: true,
        destination_folder_in_digest: true,
        readonly_destination_filtered: true,
        shared_destination_permission_mask: true,
        shared_group_recipient_expansion: true,
        shared_recipient_deduplication: true,
        shared_recipient_key_validation: true,
        shared_secret_multi_recipient_encryption: true,
        shared_v5_metadata_key_enforced: true,
        shared_simulation_before_apply: true,
        shared_partial_failure_reconciliation: true,
        shared_child_folder_permission_inheritance: true,
        shared_child_folder_permission_mask_in_digest: true,
        shared_child_folder_simulation_before_apply: true,
        shared_child_folder_partial_failure_reconciliation: true,
        new_share_permissions_marked: true,
        empty_personal_child_folder_reconciled: true,
        nonempty_personal_child_folder_blocked: true,
        shared_v5_folder_metadata_key_enforced: true,
        duplicate_destination_classification: true,
        duplicate_elsewhere_blocked: true,
        partial_failure_reconciliation: true,
        cleartext_in_payload: false,
      },
    })}\n`);
  } finally {
    await new Promise((resolve) => mockServer.close(resolve));
  }
}

await main();
