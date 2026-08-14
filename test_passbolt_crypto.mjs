#!/usr/bin/env node

import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import * as openpgp from 'openpgp';
import {
  PassboltSession,
  PersistentImportSession,
  analyzeCapabilities,
  authenticate,
  buildCandidatePlan,
  buildFolderPayload,
  buildResourcePayload,
  classifyRecovery,
  createPlannedContent,
  encryptSecret,
  permissionMaskDigest,
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
  const recoveryCandidate = {
    candidate_id: '0123456789abcdef',
    source_sha256: '1'.repeat(64),
    client: '(radice)',
    source_at_root: true,
    title: 'Portale recupero',
    username: 'recovery-user',
    uri: 'https://recovery.example.test',
  };
  const recoveryState = {
    schema_version: 1,
    batch_id: '1b697c90-2870-4d88-8740-54055a09946c',
    resource_format: 'v4',
    folder_format: 'none',
    destination_mode: 'root',
    destination_folder_id: null,
    candidates: [{ candidate_id: recoveryCandidate.candidate_id, source_sha256: recoveryCandidate.source_sha256 }],
    operations: [{
      operation_id: '8122c7fa-178c-486a-a428-cd74c959699b',
      object_type: 'resource',
      action: 'create_resource',
      candidate_id: recoveryCandidate.candidate_id,
      destination_key_hash: '2'.repeat(64),
      recorded_outcome: null,
    }],
    duplicate_candidates: [],
  };
  const recoveryCapabilities = {
    resource_format_selected: 'v4',
    folder_format_selected: null,
    destination_mode: 'root',
    destination_folder_id: null,
    can_import: true,
    plan_digest: '3'.repeat(64),
    candidates: [{
      ...recoveryCandidate,
      action: 'create',
      destination_key: 'root',
      folder_action: 'root',
      shared: false,
      duplicate_kind: null,
      duplicate_resource_id: null,
    }],
  };
  const recoveryRuntime = { destinationFolders: [], existingFolders: [], existingResources: [] };
  const retryRecovery = classifyRecovery(recoveryState, [recoveryCandidate], recoveryCapabilities, recoveryRuntime, 'current-user-id');
  assert.equal(retryRecovery.conflicts.length, 0);
  assert.equal(retryRecovery.classifications[0].resolution, 'not_applied');
  assert.deepEqual(retryRecovery.resourceCandidateIds, [recoveryCandidate.candidate_id]);

  const remoteResourceId = 'remote-recovery-resource';
  const remoteCapabilities = {
    ...recoveryCapabilities,
    candidates: [{
      ...recoveryCapabilities.candidates[0],
      action: 'duplicate',
      duplicate_kind: 'server_destination',
      duplicate_resource_id: remoteResourceId,
    }],
  };
  const remoteRuntime = {
    ...recoveryRuntime,
    existingResources: [{ id: remoteResourceId, permissions: [] }],
  };
  const successfulRecovery = classifyRecovery(recoveryState, [recoveryCandidate], remoteCapabilities, remoteRuntime, 'current-user-id');
  assert.equal(successfulRecovery.conflicts.length, 0);
  assert.equal(successfulRecovery.classifications[0].resolution, 'remote_success');
  assert.equal(successfulRecovery.classifications[0].resource_id, remoteResourceId);
  assert.deepEqual(successfulRecovery.resourceCandidateIds, []);

  const recordedSuccessState = structuredClone(recoveryState);
  recordedSuccessState.operations[0].recorded_outcome = {
    event_type: 'resource_created',
    operation_id: recordedSuccessState.operations[0].operation_id,
    resource_id: remoteResourceId,
    candidate_id: recoveryCandidate.candidate_id,
    status: 'created',
  };
  const missingRecordedResource = classifyRecovery(recordedSuccessState, [recoveryCandidate], recoveryCapabilities, recoveryRuntime, 'current-user-id');
  assert.equal(missingRecordedResource.conflicts.some((item) => item.code === 'RECOVERY_RECORDED_RESOURCE_CHANGED'), true);

  const intendedPermissions = [
    { aro: 'User', aro_foreign_key: 'current-user-id', type: 15 },
    { aro: 'User', aro_foreign_key: 'recipient-id', type: 1 },
  ];
  const shareRecoveryState = structuredClone(recoveryState);
  shareRecoveryState.operations = [{
    operation_id: '32016a35-0be3-45cd-8e1b-6af14925216c',
    object_type: 'resource',
    action: 'share_resource',
    candidate_id: recoveryCandidate.candidate_id,
    destination_key_hash: '2'.repeat(64),
    permission_mask_hash: permissionMaskDigest(intendedPermissions),
    recorded_outcome: {
      event_type: 'operation_failed',
      operation_id: '32016a35-0be3-45cd-8e1b-6af14925216c',
      object_type: 'resource',
      candidate_id: recoveryCandidate.candidate_id,
      resource_id: remoteResourceId,
      error_code: 'SHARE_FAILED',
      outcome: 'partial',
    },
  }];
  const shareCapabilities = {
    ...remoteCapabilities,
    candidates: [{
      ...remoteCapabilities.candidates[0],
      shared: true,
      share_permissions: intendedPermissions,
    }],
  };
  const ownerOnlyRuntime = {
    ...remoteRuntime,
    existingResources: [{
      id: remoteResourceId,
      permission: { id: 'owner-permission-id', aro: 'User', aro_foreign_key: 'current-user-id', type: 15 },
      permissions: [{ aro: 'User', aro_foreign_key: 'current-user-id', type: 15 }],
      raw_permission_count: 1,
    }],
  };
  const shareRetry = classifyRecovery(shareRecoveryState, [recoveryCandidate], shareCapabilities, ownerOnlyRuntime, 'current-user-id');
  assert.equal(shareRetry.conflicts.length, 0);
  assert.equal(shareRetry.classifications[0].resolution, 'not_applied');
  assert.deepEqual(shareRetry.repairResourceCandidateIds, [recoveryCandidate.candidate_id]);
  const changedShareCapabilities = structuredClone(shareCapabilities);
  changedShareCapabilities.candidates[0].share_permissions[1].aro_foreign_key = 'different-recipient-id';
  const changedPermissionPlan = classifyRecovery(shareRecoveryState, [recoveryCandidate], changedShareCapabilities, ownerOnlyRuntime, 'current-user-id');
  assert.equal(changedPermissionPlan.conflicts.some((item) => item.code === 'RECOVERY_INTENDED_PERMISSION_CHANGED'), true);

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
  const existingResourceClearSecret = JSON.stringify({
    password: 'existing-resource-password',
    description: 'existing resource description',
  });
  const existingResourceSecret = await openpgp.encrypt({
    message: await openpgp.createMessage({ text: existingResourceClearSecret }),
    encryptionKeys: userPublicKey,
    signingKeys: userPrivateKey,
    format: 'armored',
  });
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
  let includeDuplicatePersonalChild = false;
  let sharedSimulationPayload = null;
  let sharedApplyPayload = null;
  let folderShareSimulationRequestCount = 0;
  let sharedFolderApplyPayload = null;
  let resourceAclMode = 'none';
  let existingAclSimulationMode = 'normal';
  let existingResourceSecretReadCount = 0;
  let authenticatedMutationCount = 0;
  let officialWrappedGpgAuthPayloadCount = 0;
  let officialMinimalTotpPayloadCount = 0;

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
        const auth = document?.data?.gpg_auth;
        if (!auth || auth.keyid !== userFingerprint) {
          send(response, 400, apiError('Unknown user key.'));
          return;
        }
        officialWrappedGpgAuthPayloadCount += 1;
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
      if (!['GET', 'HEAD'].includes(String(request.method))) authenticatedMutationCount += 1;
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
            servertime: Math.floor(Date.now() / 1000),
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
        if (document?.totp !== '654321' || Object.keys(document ?? {}).length !== 1) {
          send(response, 400, apiError('Invalid TOTP code.'));
          return;
        }
        officialMinimalTotpPayloadCount += 1;
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
        const rotatedGroupRecipientKey = shareDirectoryMode === 'rotated-group-key';
        const groupRecipientGpgKey = shareDirectoryMode === 'missing-key' ? null : {
          id: 'group-recipient-gpg-key-id',
          user_id: 'group-recipient-id',
          armored_key: rotatedGroupRecipientKey ? directRecipientGenerated.publicKey : groupRecipientGenerated.publicKey,
          fingerprint: rotatedGroupRecipientKey ? directRecipientFingerprint : groupRecipientFingerprint,
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
          ...(resourceAclMode === 'none' ? {} : {
            permission: {
              id: 'resource-current-permission-id',
              aco: 'Resource',
              aco_foreign_key: 'existing-resource-id',
              aro: 'User',
              aro_foreign_key: 'user-id',
              type: 15,
            },
            permissions: [{
              id: 'resource-current-permission-id',
              aco: 'Resource',
              aco_foreign_key: 'existing-resource-id',
              aro: 'User',
              aro_foreign_key: 'user-id',
              type: 15,
            }, ...(['shared', 'direct'].includes(resourceAclMode) ? [{
              id: 'resource-direct-permission-id',
              aco: 'Resource',
              aco_foreign_key: 'existing-resource-id',
              aro: 'User',
              aro_foreign_key: 'direct-recipient-id',
              type: 1,
            }, ...(resourceAclMode === 'shared' ? [{
              id: 'resource-group-permission-id',
              aco: 'Resource',
              aco_foreign_key: 'existing-resource-id',
              aro: 'Group',
              aro_foreign_key: 'shared-group-id',
              type: 7,
            }] : []),
            ] : []),
            ],
          }),
        }]));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/secrets/resource/existing-resource-id.json') {
        existingResourceSecretReadCount += 1;
        send(response, 200, apiSuccess({
          id: 'existing-resource-secret-id',
          user_id: 'user-id',
          resource_id: 'existing-resource-id',
          data: existingResourceSecret,
        }));
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
            }, ...(sharedFolderPermissionMode === 'restricted' ? [] : [{
              id: 'folder-group-permission-id',
              aco: 'Folder',
              aco_foreign_key: 'folder-shared-id',
              aro: 'Group',
              aro_foreign_key: 'shared-group-id',
              type: 7,
            }])],
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
          if (includeDuplicatePersonalChild) {
            sharedFolders.push({
              id: 'second-created-unshared-folder-id',
              name: 'Cliente Nuovo Condiviso',
              folder_parent_id: 'folder-shared-id',
              personal: true,
              permission: { type: 15 },
              permissions: [{
                id: 'second-created-unshared-owner-permission-id',
                aco: 'Folder',
                aco_foreign_key: 'second-created-unshared-folder-id',
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
        if (url.pathname === '/share/simulate/resource/existing-resource-id.json') {
          const permission = sharedSimulationPayload.permissions[0];
          assert.equal(sharedSimulationPayload.permissions.length, 1);
          assert.equal(permission.aro_foreign_key, 'direct-recipient-id');
          if (existingAclSimulationMode === 'mismatch') {
            send(response, 200, apiSuccess({ changes: { added: [], removed: [{ User: { id: 'group-recipient-id' } }] } }));
            return;
          }
          if (permission.delete === true) {
            assert.equal(permission.id, 'resource-direct-permission-id');
            send(response, 200, apiSuccess({ changes: { added: [], removed: [{ User: { id: 'direct-recipient-id' } }] } }));
            return;
          }
          assert.equal(permission.is_new, true);
          send(response, 200, apiSuccess({
            changes: { added: [{ User: { id: 'direct-recipient-id' } }], removed: [] },
          }));
          return;
        }
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
        folderShareSimulationRequestCount += 1;
        if (url.pathname === '/share/simulate/folder/folder-shared-id.json') {
          const payload = await requestJson(request);
          if (payload.permissions.length === 1) {
            assert.equal(payload.permissions[0].id, 'folder-direct-permission-id');
            assert.equal(payload.permissions[0].type, 7);
            assert.equal(Object.hasOwn(payload.permissions[0], 'delete'), false);
            send(response, 200, apiSuccess({ changes: { added: [], removed: [] } }));
          } else {
            assert.equal(payload.permissions.length, 2);
            const downgrade = payload.permissions.find((permission) => permission.id === 'folder-direct-permission-id');
            const revoke = payload.permissions.find((permission) => permission.id === 'folder-group-permission-id');
            assert.equal(downgrade?.type, 1);
            assert.equal(Object.hasOwn(downgrade, 'delete'), false);
            assert.equal(revoke?.delete, true);
            send(response, 200, apiSuccess({ changes: { added: [], removed: [{ User: { id: 'group-recipient-id' } }] } }));
          }
          return;
        }
        send(response, 404, apiError('Not Found'));
        return;
      }
      if (request.method === 'PUT' && url.pathname.startsWith('/share/folder/')) {
        sharedFolderApplyPayload = await requestJson(request);
        if (folderShareApplyMode === 'failure') {
          send(response, 400, apiError('Mock folder sharing failure.'));
          return;
        }
        if (url.pathname === '/share/folder/folder-shared-id.json') {
          if (sharedFolderApplyPayload.permissions.length === 1) {
            assert.equal(sharedFolderApplyPayload.permissions[0].id, 'folder-direct-permission-id');
            assert.equal(sharedFolderApplyPayload.permissions[0].type, 7);
            sharedFolderPermissionMode = 'changed';
          } else {
            assert.equal(sharedFolderApplyPayload.permissions.length, 2);
            assert.equal(sharedFolderApplyPayload.permissions.some((permission) => permission.id === 'folder-group-permission-id' && permission.delete === true), true);
            sharedFolderPermissionMode = 'restricted';
          }
          send(response, 200, apiSuccess(null));
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
        if (url.pathname === '/share/resource/existing-resource-id.json') {
          assert.equal(sharedApplyPayload.permissions.length, 1);
          if (sharedApplyPayload.permissions[0].delete === true) {
            assert.equal(sharedApplyPayload.permissions[0].id, 'resource-direct-permission-id');
            assert.deepEqual(sharedApplyPayload.secrets, []);
            resourceAclMode = 'owner';
            send(response, 200, apiSuccess(null));
            return;
          }
          assert.equal(sharedApplyPayload.permissions[0].is_new, true);
          assert.equal(sharedApplyPayload.secrets.length, 1);
          assert.equal(sharedApplyPayload.secrets[0].user_id, 'direct-recipient-id');
          const decrypted = await openpgp.decrypt({
            message: await openpgp.readMessage({ armoredMessage: sharedApplyPayload.secrets[0].data }),
            decryptionKeys: directRecipientPrivateKey,
            verificationKeys: userPublicKey,
            format: 'utf8',
          });
          await Promise.all(decrypted.signatures.map((signature) => signature.verified));
          assert.equal(decrypted.data, existingResourceClearSecret);
          resourceAclMode = 'direct';
          send(response, 200, apiSuccess(null));
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

    const extendedCandidates = Array.from({ length: 64 }, (_, index) => ({
      candidate_id: `candidate-extended-${index}`,
      client: '(radice)',
      source_at_root: true,
      title: `Nuovo portale ${index}`,
      username: `new-user-${index}`,
      uri: `https://new-${index}.example.test`,
    }));
    const extendedCapabilities = await readCapabilities(session, user, extendedCandidates);
    assert.equal(extendedCapabilities.create_count, 64);
    assert.equal(extendedCapabilities.duplicate_count, 0);

    const scaleCandidates = Array.from({ length: 1024 }, (_, index) => ({
      candidate_id: `candidate-scale-${index}`,
      title: `Accesso indicizzato ${index}`,
      username: `indexed-user-${index}`,
      uri: `https://indexed-${index}.example.test`,
    }));
    scaleCandidates.push({
      ...scaleCandidates[700],
      candidate_id: 'candidate-scale-batch-duplicate',
    });
    const scaleExistingResources = scaleCandidates.slice(0, 512).map((candidate, index) => ({
      id: `existing-scale-${index}`,
      name: candidate.title,
      username: candidate.username,
      uri: candidate.uri,
      folder_parent_id: null,
    }));
    const scalePlan = buildCandidatePlan(scaleCandidates, scaleExistingResources, true);
    assert.equal(scalePlan.length, 1025);
    assert.equal(scalePlan.filter((item) => item.duplicate_kind === 'server_destination').length, 512);
    assert.equal(scalePlan.filter((item) => item.action === 'create').length, 512);
    assert.equal(scalePlan.at(-1).duplicate_kind, 'batch');
    assert.equal(scalePlan.at(-1).duplicate_candidate_id, 'candidate-scale-700');

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
    assert.equal(folderShareSimulationRequestCount, 0);
    assert.equal(sharedFolderApplyPayload.permissions.some((permission) => permission.aco_foreign_key === 'created-folder-id'), true);
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
        && error?.details?.cause_code === 'FOLDER_SHARE_APPLY_FAILED'
        && error?.details?.http_status === 400
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

    includeDuplicatePersonalChild = true;
    const ambiguousPersonalChildren = await analyzeCapabilities(
      session,
      user,
      sharedChildCandidate,
      keyMaterial,
      'v4',
      'client_folders',
      'v4',
      'folder-shared-id',
    );
    assert.equal(ambiguousPersonalChildren.capabilities.can_import, false);
    assert.match(ambiguousPersonalChildren.capabilities.unavailable_reason, /created-unshared-folder-id/);
    assert.match(ambiguousPersonalChildren.capabilities.unavailable_reason, /second-created-unshared-folder-id/);
    assert.match(ambiguousPersonalChildren.capabilities.unavailable_reason, /copie personali vuote in eccesso/i);
    includeDuplicatePersonalChild = false;
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
    const simulatedProgress = [];
    const simulatedCreation = await createPlannedContent(
      simulatedSession,
      newFolderAnalysis.capabilities.candidates,
      [plannedResource],
      newFolderAnalysis.runtime,
      keyMaterial,
      async (eventType, payload) => simulatedProgress.push({ eventType, payload }),
    );
    assert.equal(simulatedCalls.length, 2);
    assert.equal(simulatedCreation.createdFolders.length, 1);
    assert.equal(simulatedCreation.created.length, 1);
    assert.deepEqual(
      simulatedProgress.map((event) => event.eventType),
      ['operation_intent', 'folder_created', 'operation_intent', 'resource_created'],
    );
    assert.deepEqual(
      simulatedProgress.filter((event) => event.eventType === 'operation_intent').map((event) => event.payload.action),
      ['create_folder', 'create_resource'],
    );
    assert.match(simulatedProgress[0].payload.operation_id, /^[0-9a-f-]{36}$/i);
    assert.match(simulatedProgress[0].payload.destination_key_hash, /^[0-9a-f]{64}$/);
    assert.equal(JSON.stringify(simulatedProgress).includes('beta-password'), false);

    const failingSession = {
      async request(path) {
        if (path.startsWith('/folders.json')) {
          return { status: 200, document: { body: { id: 'partial-folder-id' } } };
        }
        return { status: 500, document: { header: { message: 'Simulated resource failure.' } } };
      },
    };
    const failingProgress = [];
    await assert.rejects(
      createPlannedContent(
        failingSession,
        newFolderAnalysis.capabilities.candidates,
        [plannedResource],
        newFolderAnalysis.runtime,
        keyMaterial,
        async (eventType, payload) => failingProgress.push({ eventType, payload }),
      ),
      (error) => error?.code === 'IMPORT_PARTIAL_FAILURE'
        && error?.details?.created_folders?.length === 1
        && error?.details?.created?.length === 0,
    );
    assert.deepEqual(
      failingProgress.map((event) => event.eventType),
      ['operation_intent', 'folder_created', 'operation_intent', 'operation_failed'],
    );
    assert.equal(failingProgress.at(-1).payload.error_code, 'RESOURCE_CREATE_FAILED');
    assert.equal(failingProgress.at(-1).payload.outcome, 'confirmed');
    assert.equal(failingProgress.at(-1).payload.http_status, 500);

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
    folderMode = 'v5';
    existingResourceFolderId = 'folder-alpha-v5-id';
    const v5AclWorker = new PersistentImportSession();
    v5AclWorker.state = {
      sessionId: 'v5-acl-session',
      baseUrl,
      expectedFingerprint: serverFingerprint,
      session: v5Session,
      key: keyMaterial,
      user: v5Authentication.user,
      mfaProvider: null,
    };
    const v5AclCatalog = await v5AclWorker.dispatch({
      command: 'session-acl-catalog',
      session_id: 'v5-acl-session',
    });
    assert.equal(v5AclCatalog.objects.some((entry) => entry.object_type === 'folder' && entry.path === 'Cliente Alfa'), true);
    assert.equal(v5AclCatalog.objects.some((entry) => entry.object_type === 'resource' && entry.path === 'Cliente Alfa / Portale v5 esistente'), true);
    assert.equal(JSON.stringify(v5AclCatalog).includes('BEGIN PGP'), false);
    folderMode = 'empty';
    existingResourceFolderId = null;
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
    const persistentProgress = [];
    const persistentWorker = new PersistentImportSession(
      async (envelope) => persistentProgress.push(envelope),
    );
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
    const persistentPermissionCatalog = await persistentWorker.permissions({
      command: 'session-permissions',
      session_id: 'persistent-test-session',
    });
    assert.equal(persistentPermissionCatalog.command, 'permission-catalog');
    assert.equal(persistentPermissionCatalog.entries.some((entry) => entry.aro === 'User' && entry.aro_foreign_key === 'direct-recipient-id' && entry.available), true);
    assert.equal(persistentPermissionCatalog.entries.some((entry) => entry.aro === 'Group' && entry.aro_foreign_key === 'shared-group-id' && entry.available), true);
    assert.equal(persistentPermissionCatalog.entries.some((entry) => entry.aro_foreign_key === 'user-id'), false);
    folderMode = 'shared-v4';
    resourceAclMode = 'shared';
    existingResourceFolderId = 'folder-shared-id';
    const mutationCountBeforeAclCatalog = authenticatedMutationCount;
    const persistentAclCatalog = await persistentWorker.dispatch({
      command: 'session-acl-catalog',
      session_id: 'persistent-test-session',
    });
    assert.equal(persistentAclCatalog.command, 'acl-catalog');
    assert.equal(persistentAclCatalog.read_only, true);
    assert.equal(persistentAclCatalog.write_requests, 0);
    assert.equal(persistentAclCatalog.folder_count, 1);
    assert.equal(persistentAclCatalog.resource_count, 1);
    assert.equal(persistentAclCatalog.shared_count, 2);
    assert.equal(persistentAclCatalog.verified_count, 2);
    assert.equal(persistentAclCatalog.warning_count, 0);
    const aclFolder = persistentAclCatalog.objects.find((entry) => entry.object_type === 'folder');
    const aclResource = persistentAclCatalog.objects.find((entry) => entry.object_type === 'resource');
    assert.equal(aclFolder.path, 'Cartella condivisa');
    assert.equal(aclFolder.acl_complete, true);
    assert.equal(aclResource.path, 'Cartella condivisa / Portale esistente');
    assert.equal(aclResource.permissions.some((entry) => entry.subject_kind === 'User' && entry.subject_id === 'direct-recipient-id' && entry.permission_label === 'Lettura' && entry.verified), true);
    assert.equal(aclResource.permissions.some((entry) => entry.subject_kind === 'Group' && entry.subject_id === 'shared-group-id' && entry.permission_label === 'Aggiornamento' && entry.recipient_count === 2 && entry.verified), true);
    assert.equal(aclResource.permissions.some((entry) => entry.current_user && entry.permission_label === 'Proprietario'), true);
    assert.equal(authenticatedMutationCount, mutationCountBeforeAclCatalog);
    assert.equal(JSON.stringify(persistentAclCatalog).includes('BEGIN PGP'), false);
    assert.equal(JSON.stringify(persistentAclCatalog).includes('mock-resource-password'), false);

    const changedAclPlan = await persistentWorker.dispatch({
      command: 'session-acl-plan',
      session_id: 'persistent-test-session',
      object_type: 'resource',
      object_id: 'existing-resource-id',
      desired_permissions: [
        { aro: 'User', aro_foreign_key: 'direct-recipient-id', type: 7 },
        { aro: 'Group', aro_foreign_key: 'shared-group-id', type: 1 },
      ],
    });
    assert.equal(changedAclPlan.command, 'acl-plan');
    assert.equal(changedAclPlan.read_only, true);
    assert.equal(changedAclPlan.write_requests, 0);
    assert.equal(changedAclPlan.remote_writes_planned, 0);
    assert.equal(changedAclPlan.complete, true);
    assert.equal(changedAclPlan.generated_from_fresh_remote_state, true);
    assert.equal(changedAclPlan.change_count, 2);
    assert.equal(changedAclPlan.counts.upgrade, 1);
    assert.equal(changedAclPlan.counts.downgrade, 1);
    assert.equal(changedAclPlan.counts.unchanged, 1);
    assert.equal(changedAclPlan.sensitive_action_count, 1);
    assert.equal(changedAclPlan.operations.some((entry) => entry.action === 'upgrade' && entry.subject_id === 'direct-recipient-id' && entry.before_permission_type === 1 && entry.after_permission_type === 7), true);
    assert.equal(changedAclPlan.operations.some((entry) => entry.action === 'downgrade' && entry.subject_id === 'shared-group-id' && entry.before_permission_type === 7 && entry.after_permission_type === 1 && entry.sensitive), true);
    assert.match(changedAclPlan.object_state_digest, /^[0-9a-f]{64}$/);
    assert.match(changedAclPlan.desired_acl_digest, /^[0-9a-f]{64}$/);
    assert.match(changedAclPlan.plan_digest, /^[0-9a-f]{64}$/);
    assert.equal(changedAclPlan.apply_available, true);
    assert.equal(changedAclPlan.additive_apply_available, false);
    assert.equal(changedAclPlan.restrictive_apply_available, true);
    assert.equal(changedAclPlan.restrictive_change_count, 1);
    assert.equal(changedAclPlan.restrictive_changes_blocked, 0);
    assert.equal(changedAclPlan.apply_mode, 'mixed');
    assert.equal(changedAclPlan.destructive_actions_planned, true);
    assert.equal(changedAclPlan.effective_user_counts.downgrade, 1);
    assert.equal(changedAclPlan.effective_user_counts.loss, 0);
    assert.equal(changedAclPlan.last_owner_protection.current_user_owner_retained, true);
    assert.equal(changedAclPlan.last_owner_protection.owner_count_after, 1);
    assert.match(changedAclPlan.confirmation_required, /^CONFERMO RIDUZIONE ACL 1 0 [0-9A-F]{8}$/);
    await assert.rejects(
      persistentWorker.dispatch({
        command: 'session-acl-apply',
        session_id: 'persistent-test-session',
        acl_batch_id: '11111111-1111-4111-8111-111111111111',
        plan_id: changedAclPlan.plan_id,
        object_state_digest: changedAclPlan.object_state_digest,
        desired_acl_digest: changedAclPlan.desired_acl_digest,
        directory_state_digest: changedAclPlan.directory_state_digest,
        plan_digest: changedAclPlan.plan_digest,
        confirmation: '',
      }),
      (error) => error?.code === 'CONFIRMATION_MISMATCH',
    );
    const repeatedAclPlan = await persistentWorker.dispatch({
      command: 'session-acl-plan',
      session_id: 'persistent-test-session',
      object_type: 'resource',
      object_id: 'existing-resource-id',
      desired_permissions: [
        { aro: 'User', aro_foreign_key: 'direct-recipient-id', type: 7 },
        { aro: 'Group', aro_foreign_key: 'shared-group-id', type: 1 },
      ],
    });
    assert.equal(repeatedAclPlan.plan_digest, changedAclPlan.plan_digest);
    assert.notEqual(repeatedAclPlan.plan_id, changedAclPlan.plan_id);

    const revokeAclPlan = await persistentWorker.dispatch({
      command: 'session-acl-plan',
      session_id: 'persistent-test-session',
      object_type: 'resource',
      object_id: 'existing-resource-id',
      desired_permissions: [{ aro: 'Group', aro_foreign_key: 'shared-group-id', type: 7 }],
    });
    assert.equal(revokeAclPlan.counts.revoke, 1);
    assert.equal(revokeAclPlan.operations.some((entry) => entry.action === 'revoke' && entry.subject_id === 'direct-recipient-id' && entry.after_permission_type === null), true);
    assert.notEqual(revokeAclPlan.plan_digest, changedAclPlan.plan_digest);

    resourceAclMode = 'owner';
    const addAclPlan = await persistentWorker.dispatch({
      command: 'session-acl-plan',
      session_id: 'persistent-test-session',
      object_type: 'resource',
      object_id: 'existing-resource-id',
      desired_permissions: [{ aro: 'User', aro_foreign_key: 'direct-recipient-id', type: 1 }],
    });
    assert.equal(addAclPlan.counts.add, 1);
    assert.equal(addAclPlan.counts.unchanged, 1);
    assert.equal(addAclPlan.operations.some((entry) => entry.action === 'add' && entry.before_permission_type === null && entry.after_permission_type === 1), true);

    resourceAclMode = 'shared';
    await assert.rejects(
      persistentWorker.dispatch({
        command: 'session-acl-plan',
        session_id: 'persistent-test-session',
        object_type: 'resource',
        object_id: 'existing-resource-id',
        desired_permissions: [{ aro: 'User', aro_foreign_key: 'user-id', type: 1 }],
      }),
      (error) => error?.code === 'CURRENT_OWNER_PERMISSION_IMMUTABLE',
    );
    shareDirectoryMode = 'missing-key';
    await assert.rejects(
      persistentWorker.dispatch({
        command: 'session-acl-plan',
        session_id: 'persistent-test-session',
        object_type: 'resource',
        object_id: 'existing-resource-id',
        desired_permissions: [],
      }),
      (error) => error?.code === 'ACL_PLAN_SUBJECTS_UNVERIFIED',
    );
    shareDirectoryMode = 'valid';
    assert.equal(authenticatedMutationCount, mutationCountBeforeAclCatalog);
    assert.equal(JSON.stringify(changedAclPlan).includes('BEGIN PGP'), false);
    assert.equal(JSON.stringify(changedAclPlan).includes('fingerprint'), false);
    const additiveProgressStart = persistentProgress.length;
    const additiveFolderPlan = await persistentWorker.dispatch({
      command: 'session-acl-plan',
      session_id: 'persistent-test-session',
      object_type: 'folder',
      object_id: 'folder-shared-id',
      desired_permissions: [
        { aro: 'User', aro_foreign_key: 'direct-recipient-id', type: 7 },
        { aro: 'Group', aro_foreign_key: 'shared-group-id', type: 7 },
      ],
    });
    assert.equal(additiveFolderPlan.additive_apply_available, true);
    assert.equal(additiveFolderPlan.counts.upgrade, 1);
    assert.match(additiveFolderPlan.confirmation_required, /^APPLICA ACL 1 [0-9A-F]{8}$/);
    assert.match(additiveFolderPlan.directory_state_digest, /^[0-9a-f]{64}$/);
    const mutationCountBeforeDirectoryChange = authenticatedMutationCount;
    shareDirectoryMode = 'rotated-group-key';
    await assert.rejects(
      persistentWorker.dispatch({
        command: 'session-acl-apply',
        session_id: 'persistent-test-session',
        acl_batch_id: '22222222-2222-4222-8222-222222222222',
        plan_id: additiveFolderPlan.plan_id,
        object_state_digest: additiveFolderPlan.object_state_digest,
        desired_acl_digest: additiveFolderPlan.desired_acl_digest,
        directory_state_digest: additiveFolderPlan.directory_state_digest,
        plan_digest: additiveFolderPlan.plan_digest,
        confirmation: additiveFolderPlan.confirmation_required,
      }),
      (error) => error?.code === 'ACL_APPLY_STALE_PLAN',
    );
    assert.equal(authenticatedMutationCount, mutationCountBeforeDirectoryChange);
    shareDirectoryMode = 'valid';
    const appliedFolderAcl = await persistentWorker.dispatch({
      command: 'session-acl-apply',
      session_id: 'persistent-test-session',
      acl_batch_id: '22222222-2222-4222-8222-222222222222',
      plan_id: additiveFolderPlan.plan_id,
      object_state_digest: additiveFolderPlan.object_state_digest,
      desired_acl_digest: additiveFolderPlan.desired_acl_digest,
      directory_state_digest: additiveFolderPlan.directory_state_digest,
      plan_digest: additiveFolderPlan.plan_digest,
      confirmation: additiveFolderPlan.confirmation_required,
    });
    assert.equal(appliedFolderAcl.complete, true);
    assert.equal(appliedFolderAcl.permission_change_count, 1);
    assert.equal(appliedFolderAcl.added_user_count, 0);
    assert.equal(appliedFolderAcl.destructive_actions_performed, false);
    assert.deepEqual(
      persistentProgress.slice(additiveProgressStart).map((entry) => entry.event_type),
      ['acl_operation_intent', 'acl_operation_applied', 'acl_batch_completed'],
    );
    const mutationCountBeforeAclRecovery = authenticatedMutationCount;
    const aclRecoveryProgressStart = persistentProgress.length;
    const aclRecoveryReadiness = await persistentWorker.dispatch({
      command: 'session-acl-recovery-readiness',
      session_id: 'persistent-test-session',
      acl_batch_id: '22222222-2222-4222-8222-222222222222',
      acl_recovery_state: {
        batch_id: '22222222-2222-4222-8222-222222222222',
        object_type: 'folder',
        object_id: 'folder-shared-id',
        object_state_digest: additiveFolderPlan.object_state_digest,
        desired_acl_digest: additiveFolderPlan.desired_acl_digest,
        plan_digest: additiveFolderPlan.plan_digest,
        desired_permissions: additiveFolderPlan.desired_permissions,
        change_count: additiveFolderPlan.change_count,
        add_count: additiveFolderPlan.counts.add,
        upgrade_count: additiveFolderPlan.counts.upgrade,
      },
    });
    assert.equal(aclRecoveryReadiness.resolution, 'remote_success');
    assert.equal(aclRecoveryReadiness.retry_write_required, false);
    assert.match(aclRecoveryReadiness.confirmation_required, /^CHIUDI ACL [0-9A-F]{8}$/);
    const recoveredFolderAcl = await persistentWorker.dispatch({
      command: 'session-acl-recovery-apply',
      session_id: 'persistent-test-session',
      acl_batch_id: '22222222-2222-4222-8222-222222222222',
      recovery_id: aclRecoveryReadiness.recovery_id,
      recovery_plan_digest: aclRecoveryReadiness.recovery_plan_digest,
      confirmation: aclRecoveryReadiness.confirmation_required,
    });
    assert.equal(recoveredFolderAcl.remote_write_performed, false);
    assert.equal(recoveredFolderAcl.complete, true);
    assert.equal(authenticatedMutationCount, mutationCountBeforeAclRecovery);
    assert.deepEqual(
      persistentProgress.slice(aclRecoveryProgressStart).map((entry) => entry.event_type),
      ['acl_recovery_verified', 'acl_batch_completed'],
    );
    const restrictiveFolderProgressStart = persistentProgress.length;
    const restrictiveFolderPlan = await persistentWorker.dispatch({
      command: 'session-acl-plan',
      session_id: 'persistent-test-session',
      object_type: 'folder',
      object_id: 'folder-shared-id',
      desired_permissions: [{ aro: 'User', aro_foreign_key: 'direct-recipient-id', type: 1 }],
    });
    assert.equal(restrictiveFolderPlan.apply_mode, 'restrictive');
    assert.equal(restrictiveFolderPlan.counts.downgrade, 1);
    assert.equal(restrictiveFolderPlan.counts.revoke, 1);
    assert.equal(restrictiveFolderPlan.effective_user_counts.downgrade, 1);
    assert.equal(restrictiveFolderPlan.effective_user_counts.loss, 1);
    assert.match(restrictiveFolderPlan.confirmation_required, /^CONFERMO RIDUZIONE ACL 2 1 [0-9A-F]{8}$/);
    const appliedRestrictiveFolderAcl = await persistentWorker.dispatch({
      command: 'session-acl-apply',
      session_id: 'persistent-test-session',
      acl_batch_id: '44444444-4444-4444-8444-444444444444',
      plan_id: restrictiveFolderPlan.plan_id,
      object_state_digest: restrictiveFolderPlan.object_state_digest,
      desired_acl_digest: restrictiveFolderPlan.desired_acl_digest,
      directory_state_digest: restrictiveFolderPlan.directory_state_digest,
      plan_digest: restrictiveFolderPlan.plan_digest,
      confirmation: restrictiveFolderPlan.confirmation_required,
    });
    assert.equal(appliedRestrictiveFolderAcl.permission_change_count, 2);
    assert.equal(appliedRestrictiveFolderAcl.removed_user_count, 1);
    assert.equal(appliedRestrictiveFolderAcl.restrictive_change_count, 2);
    assert.equal(appliedRestrictiveFolderAcl.destructive_actions_performed, true);
    assert.equal(sharedFolderPermissionMode, 'restricted');
    assert.equal(sharedFolderApplyPayload.permissions.some((permission) => permission.id === 'folder-group-permission-id' && permission.delete === true), true);
    assert.deepEqual(
      persistentProgress.slice(restrictiveFolderProgressStart).map((entry) => entry.event_type),
      ['acl_operation_intent', 'acl_operation_applied', 'acl_batch_completed'],
    );
    resourceAclMode = 'owner';
    const additiveResourcePlan = await persistentWorker.dispatch({
      command: 'session-acl-plan',
      session_id: 'persistent-test-session',
      object_type: 'resource',
      object_id: 'existing-resource-id',
      desired_permissions: [
        { aro: 'User', aro_foreign_key: 'direct-recipient-id', type: 1 },
      ],
    });
    const resourceAclProgressStart = persistentProgress.length;
    const appliedResourceAcl = await persistentWorker.dispatch({
      command: 'session-acl-apply',
      session_id: 'persistent-test-session',
      acl_batch_id: '33333333-3333-4333-8333-333333333333',
      plan_id: additiveResourcePlan.plan_id,
      object_state_digest: additiveResourcePlan.object_state_digest,
      desired_acl_digest: additiveResourcePlan.desired_acl_digest,
      directory_state_digest: additiveResourcePlan.directory_state_digest,
      plan_digest: additiveResourcePlan.plan_digest,
      confirmation: additiveResourcePlan.confirmation_required,
    });
    assert.equal(appliedResourceAcl.permission_change_count, 1);
    assert.equal(appliedResourceAcl.added_user_count, 1);
    assert.equal(resourceAclMode, 'direct');
    assert.deepEqual(
      persistentProgress.slice(resourceAclProgressStart).map((entry) => entry.event_type),
      ['acl_operation_intent', 'acl_operation_applied', 'acl_batch_completed'],
    );
    assert.equal(JSON.stringify(persistentProgress).includes('existing-resource-password'), false);
    const revokeResourcePlan = await persistentWorker.dispatch({
      command: 'session-acl-plan',
      session_id: 'persistent-test-session',
      object_type: 'resource',
      object_id: 'existing-resource-id',
      desired_permissions: [],
    });
    assert.equal(revokeResourcePlan.counts.revoke, 1);
    assert.equal(revokeResourcePlan.effective_user_counts.loss, 1);
    assert.equal(revokeResourcePlan.last_owner_protection.owner_count_after, 1);
    const secretReadsBeforeRestrictiveApply = existingResourceSecretReadCount;
    existingAclSimulationMode = 'mismatch';
    await assert.rejects(
      persistentWorker.dispatch({
        command: 'session-acl-apply',
        session_id: 'persistent-test-session',
        acl_batch_id: '55555555-5555-4555-8555-555555555555',
        plan_id: revokeResourcePlan.plan_id,
        object_state_digest: revokeResourcePlan.object_state_digest,
        desired_acl_digest: revokeResourcePlan.desired_acl_digest,
        directory_state_digest: revokeResourcePlan.directory_state_digest,
        plan_digest: revokeResourcePlan.plan_digest,
        confirmation: revokeResourcePlan.confirmation_required,
      }),
      (error) => error?.code === 'ACL_APPLY_SIMULATION_MISMATCH',
    );
    assert.equal(resourceAclMode, 'direct');
    existingAclSimulationMode = 'normal';
    const restrictiveRecoveryProgressStart = persistentProgress.length;
    const restrictiveRecoveryReadiness = await persistentWorker.dispatch({
      command: 'session-acl-recovery-readiness',
      session_id: 'persistent-test-session',
      acl_batch_id: '55555555-5555-4555-8555-555555555555',
      acl_recovery_state: {
        batch_id: '55555555-5555-4555-8555-555555555555',
        object_type: 'resource',
        object_id: 'existing-resource-id',
        object_state_digest: revokeResourcePlan.object_state_digest,
        desired_acl_digest: revokeResourcePlan.desired_acl_digest,
        plan_digest: revokeResourcePlan.plan_digest,
        desired_permissions: revokeResourcePlan.desired_permissions,
        change_count: revokeResourcePlan.change_count,
        add_count: revokeResourcePlan.counts.add,
        upgrade_count: revokeResourcePlan.counts.upgrade,
        downgrade_count: revokeResourcePlan.counts.downgrade,
        revoke_count: revokeResourcePlan.counts.revoke,
        apply_mode: revokeResourcePlan.apply_mode,
      },
    });
    assert.equal(restrictiveRecoveryReadiness.resolution, 'not_applied');
    assert.equal(restrictiveRecoveryReadiness.destructive_actions_planned, true);
    assert.match(restrictiveRecoveryReadiness.confirmation_required, /^RECUPERA RIDUZIONE ACL 1 [0-9A-F]{8}$/);
    const recoveredRestrictiveResourceAcl = await persistentWorker.dispatch({
      command: 'session-acl-recovery-apply',
      session_id: 'persistent-test-session',
      acl_batch_id: '55555555-5555-4555-8555-555555555555',
      recovery_id: restrictiveRecoveryReadiness.recovery_id,
      recovery_plan_digest: restrictiveRecoveryReadiness.recovery_plan_digest,
      confirmation: restrictiveRecoveryReadiness.confirmation_required,
    });
    assert.equal(recoveredRestrictiveResourceAcl.remote_write_performed, true);
    assert.equal(recoveredRestrictiveResourceAcl.removed_user_count, 1);
    assert.equal(recoveredRestrictiveResourceAcl.restrictive_change_count, 1);
    assert.equal(recoveredRestrictiveResourceAcl.destructive_actions_performed, true);
    assert.equal(resourceAclMode, 'owner');
    assert.equal(existingResourceSecretReadCount, secretReadsBeforeRestrictiveApply);
    assert.deepEqual(
      persistentProgress.slice(restrictiveRecoveryProgressStart).map((entry) => entry.event_type),
      ['acl_recovery_verified', 'acl_operation_intent', 'acl_operation_applied', 'acl_batch_completed'],
    );
    folderMode = 'v4';
    resourceAclMode = 'none';
    existingResourceFolderId = 'folder-alpha-id';
    const mutationCountBeforeIncompleteAclCatalog = authenticatedMutationCount;
    const incompleteAclCatalog = await persistentWorker.dispatch({
      command: 'session-acl-catalog',
      session_id: 'persistent-test-session',
    });
    assert.equal(incompleteAclCatalog.warning_count, 2);
    assert.equal(incompleteAclCatalog.objects.every((entry) => entry.inspection_status === 'incomplete' && entry.warnings.length > 0), true);
    assert.equal(authenticatedMutationCount, mutationCountBeforeIncompleteAclCatalog);
    await assert.rejects(
      persistentWorker.dispatch({
        command: 'session-acl-plan',
        session_id: 'persistent-test-session',
        object_type: 'resource',
        object_id: 'existing-resource-id',
        desired_permissions: [],
      }),
      (error) => error?.code === 'ACL_PLAN_OBJECT_INCOMPLETE',
    );
    folderMode = 'empty';
    resourceAclMode = 'none';
    existingResourceFolderId = null;
    const persistentCandidates = [{
      candidate_id: 'persistent-session-candidate',
      source_sha256: '7'.repeat(64),
      client: '(radice)',
      source_at_root: true,
      title: 'Risorsa sessione persistente',
      username: 'persistent-user',
      uri: 'https://persistent.example.test',
    }];
    const customPermissionTemplate = [
      { aro: 'User', aro_foreign_key: 'direct-recipient-id', type: 7 },
      { aro: 'Group', aro_foreign_key: 'shared-group-id', type: 1 },
    ];
    const customPermissionReadiness = await persistentWorker.readiness({
      command: 'session-readiness',
      session_id: 'persistent-test-session',
      candidates: persistentCandidates,
      resource_format: 'v4',
      destination_mode: 'root',
      folder_format: 'auto',
      permission_mode: 'custom',
      permission_template: customPermissionTemplate,
    });
    assert.equal(customPermissionReadiness.can_import, true);
    assert.equal(customPermissionReadiness.permission_mode, 'custom');
    assert.equal(customPermissionReadiness.permission_template_entry_count, 2);
    assert.equal(customPermissionReadiness.shared_create_count, 1);
    assert.equal(customPermissionReadiness.encrypted_secret_copy_count, 3);
    assert.equal(customPermissionReadiness.candidates[0].share_permissions.some((permission) => permission.aro === 'User' && permission.aro_foreign_key === 'user-id' && permission.type === 15), true);
    const customPermissionAnalysis = await analyzeCapabilities(
      mfaSession,
      mfaAuthentication.user,
      persistentCandidates,
      keyMaterial,
      'v4',
      'root',
      'auto',
      null,
      null,
      'custom',
      customPermissionTemplate,
    );
    const customPermissionCreated = await createPlannedContent(
      mfaSession,
      customPermissionAnalysis.capabilities.candidates,
      [{ ...persistentCandidates[0], password: 'mock-resource-password', description: 'mock description' }],
      customPermissionAnalysis.runtime,
      keyMaterial,
    );
    assert.equal(customPermissionCreated.created[0].status, 'created_shared');
    assert.equal(customPermissionCreated.created[0].encrypted_secret_copies, 2);
    assert.equal(sharedApplyPayload.permissions.some((permission) => permission.aro === 'User' && permission.aro_foreign_key === 'direct-recipient-id' && permission.type === 7), true);
    assert.equal(JSON.stringify(sharedApplyPayload).includes('mock-resource-password'), false);
    const customFolderCandidates = [{
      ...persistentCandidates[0],
      candidate_id: 'custom-folder-permission-candidate',
      client: 'Cliente ACL',
      source_at_root: false,
      title: 'Risorsa in cartella ACL',
    }];
    const customFolderAnalysis = await analyzeCapabilities(
      mfaSession,
      mfaAuthentication.user,
      customFolderCandidates,
      keyMaterial,
      'v4',
      'client_folders',
      'v4',
      null,
      null,
      'custom',
      customPermissionTemplate,
    );
    assert.equal(customFolderAnalysis.capabilities.create_shared_folder_count, 1);
    const customFolderCreated = await createPlannedContent(
      mfaSession,
      customFolderAnalysis.capabilities.candidates,
      [{ ...customFolderCandidates[0], password: 'mock-resource-password', description: 'mock description' }],
      customFolderAnalysis.runtime,
      keyMaterial,
    );
    assert.equal(customFolderCreated.createdFolders[0].status, 'created_shared');
    assert.equal(customFolderCreated.created[0].status, 'created_shared');
    assert.equal(sharedFolderApplyPayload.permissions.some((permission) => permission.aro === 'User' && permission.aro_foreign_key === 'direct-recipient-id' && permission.type === 7), true);
    assert.equal(sharedFolderApplyPayload.permissions.some((permission) => permission.aro === 'Group' && permission.aro_foreign_key === 'shared-group-id' && permission.type === 1), true);
    folderMode = 'shared-v4';
    const customExistingFolderBlocked = await persistentWorker.readiness({
      command: 'session-readiness',
      session_id: 'persistent-test-session',
      candidates: persistentCandidates,
      resource_format: 'v4',
      destination_mode: 'direct_folder',
      folder_format: 'auto',
      destination_folder_id: 'folder-shared-id',
      permission_mode: 'custom',
      permission_template: customPermissionTemplate,
    });
    assert.equal(customExistingFolderBlocked.can_import, false);
    assert.match(customExistingFolderBlocked.unavailable_reason, /ACL personalizzata|oggetti esistenti/i);
    folderMode = 'empty';
    await assert.rejects(
      persistentWorker.readiness({
        command: 'session-readiness',
        session_id: 'persistent-test-session',
        candidates: persistentCandidates,
        resource_format: 'v4',
        destination_mode: 'root',
        folder_format: 'auto',
        permission_mode: 'custom',
        permission_template: [{ aro: 'User', aro_foreign_key: 'user-id', type: 1 }],
      }),
      (error) => error?.code === 'CURRENT_OWNER_PERMISSION_IMMUTABLE',
    );
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
    const persistentBatchId = 'd688ad13-eef7-4ee4-89ce-13f574fbcfaa';
    const persistentImportProgressStart = persistentProgress.length;
    const persistentImport = await persistentWorker.import({
      command: 'session-import',
      session_id: 'persistent-test-session',
      reconciliation_batch_id: persistentBatchId,
      candidates: persistentCandidates,
      resources: [{
        ...persistentCandidates[0],
        password: 'mock-resource-password',
        description: 'mock description',
      }],
      resource_format: 'v4',
      destination_mode: 'root',
      folder_format: 'auto',
      plan_digest: secondPersistentReadiness.plan_digest,
      confirmation: 'IMPORTA 1',
    });
    assert.equal(persistentImport.complete, true);
    assert.deepEqual(
      persistentProgress.slice(persistentImportProgressStart).map((envelope) => envelope.event_type),
      ['operation_intent', 'resource_created', 'batch_completed'],
    );
    assert.equal(persistentProgress.every((envelope) => envelope.type === 'progress'), true);
    assert.equal(persistentProgress.slice(persistentImportProgressStart).every((envelope) => envelope.batch_id === persistentBatchId), true);
    assert.equal(JSON.stringify(persistentProgress).includes('mock-resource-password'), false);
    const verifiedRecoveryBatchId = 'e7553061-fc00-4a2e-a84f-fabef14ac16e';
    const verifiedRecoveryState = {
      schema_version: 1,
      batch_id: verifiedRecoveryBatchId,
      resource_format: 'v4',
      folder_format: 'none',
      destination_mode: 'root',
      destination_folder_id: null,
      candidates: [{
        candidate_id: persistentCandidates[0].candidate_id,
        source_sha256: persistentCandidates[0].source_sha256,
      }],
      operations: [{
        operation_id: 'e4a3c866-cc9b-46ea-a1a8-a9c48d6b9acd',
        object_type: 'resource',
        action: 'create_resource',
        candidate_id: persistentCandidates[0].candidate_id,
        destination_key_hash: '8'.repeat(64),
        recorded_outcome: null,
      }],
      duplicate_candidates: [],
    };
    const recoveryProgressStart = persistentProgress.length;
    const recoveryReadiness = await persistentWorker.recoveryReadiness({
      command: 'session-recovery-readiness',
      session_id: 'persistent-test-session',
      reconciliation_batch_id: verifiedRecoveryBatchId,
      candidates: persistentCandidates,
      recovery_state: verifiedRecoveryState,
      resource_format: 'v4',
      destination_mode: 'root',
      folder_format: 'none',
    });
    assert.equal(recoveryReadiness.remote_success_count, 0);
    assert.equal(recoveryReadiness.not_applied_count, 1);
    assert.equal(recoveryReadiness.retry_action_count, 1);
    assert.deepEqual(recoveryReadiness.resource_candidate_ids, [persistentCandidates[0].candidate_id]);
    const recovered = await persistentWorker.recoveryImport({
      command: 'session-recovery-import',
      session_id: 'persistent-test-session',
      reconciliation_batch_id: verifiedRecoveryBatchId,
      recovery_id: recoveryReadiness.recovery_id,
      recovery_plan_digest: recoveryReadiness.recovery_plan_digest,
      candidates: persistentCandidates,
      recovery_state: verifiedRecoveryState,
      resources: [{
        ...persistentCandidates[0],
        password: 'mock-resource-password',
        description: 'mock description',
      }],
      resource_format: 'v4',
      destination_mode: 'root',
      folder_format: 'none',
      confirmation: 'RECUPERA 1',
    });
    assert.equal(recovered.complete, true);
    assert.equal(recovered.destructive_actions_performed, false);
    assert.deepEqual(
      persistentProgress.slice(recoveryProgressStart).map((envelope) => envelope.event_type),
      ['operation_verified', 'recovery_verified', 'operation_intent', 'resource_created', 'batch_completed'],
    );
    assert.equal(JSON.stringify(persistentProgress).includes('mock-resource-password'), false);
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
        official_wrapped_gpgauth_payload: officialWrappedGpgAuthPayloadCount >= 2,
        same_origin_redirect: true,
        cross_origin_redirect_blocked: true,
        mfa_redirect_detected: true,
        mfa_totp_required: true,
        mfa_totp_rejected: true,
        mfa_totp_authenticated: true,
        official_minimal_totp_payload: officialMinimalTotpPayloadCount >= 1,
        persistent_authenticated_session: true,
        reconciliation_progress_envelopes: true,
        authenticated_recovery_classification: true,
        recovery_conflicts_blocked: true,
        mfa_reused_without_reprompt: true,
        csrf: true,
        unlimited_candidate_selection: true,
        indexed_large_batch_planning: true,
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
        authenticated_permission_catalog: true,
        existing_acl_readonly_viewer: true,
        existing_acl_readonly_dry_run: true,
        existing_acl_additive_apply: true,
        existing_acl_restrictive_apply: true,
        existing_acl_resource_secret_reencryption: true,
        existing_acl_idempotent_recovery: true,
        custom_permission_editor_plan: true,
        custom_permissions_bound_to_new_objects: true,
        current_owner_permission_immutable: true,
        shared_group_recipient_expansion: true,
        shared_recipient_deduplication: true,
        shared_recipient_key_validation: true,
        shared_secret_multi_recipient_encryption: true,
        shared_v5_metadata_key_enforced: true,
        shared_simulation_before_apply: true,
        shared_partial_failure_reconciliation: true,
        shared_child_folder_permission_inheritance: true,
        shared_child_folder_permission_mask_in_digest: true,
        shared_child_folder_direct_apply: true,
        shared_child_folder_partial_failure_reconciliation: true,
        new_share_permissions_marked: true,
        empty_personal_child_folder_reconciled: true,
        nonempty_personal_child_folder_blocked: true,
        duplicate_personal_child_folders_identified: true,
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
