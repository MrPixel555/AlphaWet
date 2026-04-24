const PLAY_INTEGRITY_SCOPE = 'https://www.googleapis.com/auth/playintegrity';
const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const DEFAULT_REQUIRED_LABEL = 'MEETS_DEVICE_INTEGRITY';
const DEFAULT_MAX_TOKEN_AGE_MS = 120000;

let cachedAccessToken = null;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/healthz') {
      return jsonResponse({
        ok: true,
        service: 'alphawet-play-integrity-worker',
      });
    }

    if (request.method === 'POST' && url.pathname === '/decode') {
      return handleDecode(request, env);
    }

    return jsonResponse({ok: false, error: 'Not found'}, 404);
  },
};

async function handleDecode(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ok: false, error: 'Invalid JSON body'}, 400);
  }

  const integrityToken = stringValue(body.integrityToken);
  const requestHash = stringValue(body.requestHash);
  const packageName = stringValue(body.packageName);

  if (!integrityToken) {
    return jsonResponse({ok: false, error: 'integrityToken is required'}, 400);
  }
  if (!requestHash) {
    return jsonResponse({ok: false, error: 'requestHash is required'}, 400);
  }
  if (!packageName) {
    return jsonResponse({ok: false, error: 'packageName is required'}, 400);
  }

  const expectedPackageName = stringValue(env.ALPHAWET_EXPECTED_PACKAGE_NAME) || packageName;
  if (expectedPackageName !== packageName) {
    return jsonResponse({ok: false, error: 'packageName mismatch with service policy'}, 403);
  }

  try {
    const accessToken = await getGoogleAccessToken(env);
    const decodeResponse = await fetch(
      `https://playintegrity.googleapis.com/v1/${encodeURIComponent(packageName)}:decodeIntegrityToken`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          integrity_token: integrityToken,
        }),
      },
    );

    const responseText = await decodeResponse.text();
    let decodedResponse;
    try {
      decodedResponse = responseText ? JSON.parse(responseText) : {};
    } catch {
      decodedResponse = {rawText: responseText};
    }

    if (!decodeResponse.ok) {
      return jsonResponse({
        ok: false,
        error: 'decodeIntegrityToken failed',
        statusCode: decodeResponse.status,
        details: decodedResponse,
      }, 502);
    }

    const verdict = evaluateDecodedVerdict({
      decodedResponse,
      env,
      packageName,
      requestHash,
    });

    return jsonResponse(verdict);
  } catch (error) {
    return jsonResponse({
      ok: false,
      error: error instanceof Error ? error.message : 'Unexpected worker failure',
    }, 500);
  }
}

function evaluateDecodedVerdict({decodedResponse, env, packageName, requestHash}) {
  const payload = decodedResponse?.tokenPayloadExternal ?? {};
  const requestDetails = payload?.requestDetails ?? {};
  const appIntegrity = payload?.appIntegrity ?? {};
  const deviceIntegrity = payload?.deviceIntegrity ?? {};
  const accountDetails = payload?.accountDetails ?? {};

  const expectedPackageName = stringValue(env.ALPHAWET_EXPECTED_PACKAGE_NAME) || packageName;
  const requiredLabel = stringValue(env.ALPHAWET_REQUIRED_DEVICE_LABEL) || DEFAULT_REQUIRED_LABEL;
  const expectedCertSha256 = stringValue(env.ALPHAWET_EXPECTED_CERT_SHA256).toUpperCase();
  const requirePlayRecognized = !isFalsey(env.ALPHAWET_REQUIRE_PLAY_RECOGNIZED);
  const maxTokenAgeMs = positiveInteger(env.ALPHAWET_MAX_TOKEN_AGE_MS, DEFAULT_MAX_TOKEN_AGE_MS);

  const requestPackageName = stringValue(requestDetails.requestPackageName);
  const decodedRequestHash = stringValue(requestDetails.requestHash || requestDetails.nonce);
  const requestTimestampMillis = numberValue(requestDetails.timestampMillis);
  const deviceLabels = stringArray(deviceIntegrity.deviceRecognitionVerdict);
  const appLabels = stringArray(appIntegrity.appRecognitionVerdict);
  const certificateDigests = stringArray(appIntegrity.certificateSha256Digest).map((item) =>
    item.toUpperCase(),
  );
  const nowMs = Date.now();

  const packageMatches = requestPackageName === expectedPackageName;
  const requestHashMatches = decodedRequestHash === requestHash;
  const freshEnough =
    requestTimestampMillis > 0 && nowMs - requestTimestampMillis >= 0 && nowMs - requestTimestampMillis <= maxTokenAgeMs;
  const meetsRequiredDeviceIntegrity = deviceLabels.includes(requiredLabel);
  const appRecognized = !requirePlayRecognized || appLabels.includes('PLAY_RECOGNIZED');
  const certificateMatches =
    !expectedCertSha256 || certificateDigests.includes(expectedCertSha256);
  const allowed = [
    packageMatches,
    requestHashMatches,
    freshEnough,
    meetsRequiredDeviceIntegrity,
    appRecognized,
    certificateMatches,
  ].every(Boolean);

  return {
    ok: true,
    allowed,
    requestPackageName,
    requestHash: decodedRequestHash,
    requestTimestampMillis,
    meetsRequiredDeviceIntegrity,
    deviceRecognitionVerdict: deviceLabels,
    appRecognitionVerdict: appLabels,
    certificateSha256Digest: certificateDigests,
    packageMatches,
    requestHashMatches,
    freshEnough,
    appRecognized,
    certificateMatches,
    requiredDeviceLabel: requiredLabel,
    licensingVerdict: accountDetails.appLicensingVerdict ?? null,
    raw: decodedResponse,
  };
}

async function getGoogleAccessToken(env) {
  if (cachedAccessToken && cachedAccessToken.expiresAtMs - Date.now() > 60_000) {
    return cachedAccessToken.token;
  }

  const clientEmail = requiredEnv(env, 'GCP_SERVICE_ACCOUNT_EMAIL');
  const privateKey = requiredEnv(env, 'GCP_SERVICE_ACCOUNT_PRIVATE_KEY');
  const tokenUri = stringValue(env.GCP_TOKEN_URI) || GOOGLE_TOKEN_URL;
  const nowSeconds = Math.floor(Date.now() / 1000);
  const jwt = await signServiceAccountJwt({
    clientEmail,
    privateKey,
    tokenUri,
    issuedAtSeconds: nowSeconds,
    expirationSeconds: nowSeconds + 3600,
  });

  const tokenResponse = await fetch(tokenUri, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });

  const tokenJson = await tokenResponse.json();
  if (!tokenResponse.ok || !tokenJson.access_token) {
    throw new Error(`Failed to obtain Google access token: ${JSON.stringify(tokenJson)}`);
  }

  cachedAccessToken = {
    token: tokenJson.access_token,
    expiresAtMs: Date.now() + numberValue(tokenJson.expires_in, 3600) * 1000,
  };
  return cachedAccessToken.token;
}

async function signServiceAccountJwt({
  clientEmail,
  privateKey,
  tokenUri,
  issuedAtSeconds,
  expirationSeconds,
}) {
  const header = {
    alg: 'RS256',
    typ: 'JWT',
  };
  const claimSet = {
    iss: clientEmail,
    scope: PLAY_INTEGRITY_SCOPE,
    aud: tokenUri,
    iat: issuedAtSeconds,
    exp: expirationSeconds,
  };

  const encodedHeader = base64UrlEncode(JSON.stringify(header));
  const encodedClaimSet = base64UrlEncode(JSON.stringify(claimSet));
  const signingInput = `${encodedHeader}.${encodedClaimSet}`;

  const cryptoKey = await importPrivateKey(privateKey);
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const encodedSignature = base64UrlEncode(signature);
  return `${signingInput}.${encodedSignature}`;
}

async function importPrivateKey(pem) {
  const sanitized = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');
  const binary = Uint8Array.from(atob(sanitized), (character) => character.charCodeAt(0));
  return crypto.subtle.importKey(
    'pkcs8',
    binary.buffer,
    {
      name: 'RSASSA-PKCS1-v1_5',
      hash: 'SHA-256',
    },
    false,
    ['sign'],
  );
}

function requiredEnv(env, name) {
  const value = stringValue(env[name]);
  if (!value) {
    throw new Error(`${name} is missing`);
  }
  return value;
}

function stringValue(value) {
  return String(value ?? '').trim();
}

function stringArray(value) {
  return Array.isArray(value)
    ? value.map((item) => String(item ?? '').trim()).filter(Boolean)
    : [];
}

function numberValue(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function positiveInteger(value, fallback) {
  const parsed = Math.trunc(numberValue(value, fallback));
  return parsed > 0 ? parsed : fallback;
}

function isFalsey(value) {
  return ['0', 'false', 'no', 'off'].includes(stringValue(value).toLowerCase());
}

function base64UrlEncode(value) {
  const bytes =
    typeof value === 'string'
      ? new TextEncoder().encode(value)
      : value instanceof ArrayBuffer
        ? new Uint8Array(value)
        : new Uint8Array(value);
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function jsonResponse(payload, status = 200) {
  return new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  });
}
