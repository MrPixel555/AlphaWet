# AlphaWet Play Integrity verifier on Cloudflare Workers Free

This project expects a server-side decode endpoint for Android Play Integrity verdicts.
The Android client locks itself if:
- `PLAY_CLOUD_PROJECT_NUMBER` is missing
- `PLAY_INTEGRITY_VERDICT_URL` is missing
- the decoded verdict is below `MEETS_DEVICE_INTEGRITY`
- app recognition is not `PLAY_RECOGNIZED`
- the verdict is stale or the request hash does not match

## What changed

Use `cloudflare-worker/` instead of the old Cloud Run verifier.
This keeps the verifier on a free-tier service and avoids requiring Cloud Run billing.

## Worker secrets

Create these Cloudflare Worker secrets:

- `GCP_SERVICE_ACCOUNT_EMAIL`
- `GCP_SERVICE_ACCOUNT_PRIVATE_KEY`
- `GCP_TOKEN_URI`

How to fill them:

- `GCP_SERVICE_ACCOUNT_EMAIL`: the `client_email` value from your Google service account JSON
- `GCP_SERVICE_ACCOUNT_PRIVATE_KEY`: the `private_key` value from your Google service account JSON
- `GCP_TOKEN_URI`: usually `https://oauth2.googleapis.com/token`

For `GCP_SERVICE_ACCOUNT_PRIVATE_KEY`, keep the full multiline PEM exactly as it appears in the JSON, including:

- `-----BEGIN PRIVATE KEY-----`
- `-----END PRIVATE KEY-----`

## Quick deployment flow

1. In Google Cloud, create a service account in the same project as Play Integrity.
2. Generate a JSON key for that service account.
3. In Cloudflare, create a Worker on the free plan.
4. Add the three secrets above to that Worker.
5. Add these Worker environment variables:
   - `ALPHAWET_EXPECTED_PACKAGE_NAME`
   - `ALPHAWET_REQUIRED_DEVICE_LABEL`
   - `ALPHAWET_EXPECTED_CERT_SHA256`
   - `ALPHAWET_MAX_TOKEN_AGE_MS`
   - `ALPHAWET_REQUIRE_PLAY_RECOGNIZED`
6. Deploy the Worker.
7. Copy the Worker URL and append `/decode`.
8. Put that full URL into:
   - `ORG_GRADLE_PROJECT_PLAY_INTEGRITY_VERDICT_URL`
9. Build Android again.

Recommended values for Worker environment variables:

- `ALPHAWET_EXPECTED_PACKAGE_NAME=ir.alphacraft.alphawet`
- `ALPHAWET_REQUIRED_DEVICE_LABEL=MEETS_DEVICE_INTEGRITY`
- `ALPHAWET_EXPECTED_CERT_SHA256=<your release signing cert SHA-256 in uppercase>`
- `ALPHAWET_MAX_TOKEN_AGE_MS=120000`
- `ALPHAWET_REQUIRE_PLAY_RECOGNIZED=true`

## Android build config

After deploying the Worker, set:

- `ORG_GRADLE_PROJECT_PLAY_INTEGRITY_VERDICT_URL=https://YOUR-WORKER.workers.dev/decode`

The Android workflow already exposes `ORG_GRADLE_PROJECT_PLAY_INTEGRITY_VERDICT_URL`.

## Notes

- The Worker exchanges the Google service account for an OAuth token, then calls `decodeIntegrityToken`.
- The app still requests the standard Play Integrity token locally on-device.
- The Worker is only for verdict decoding and policy enforcement.
- The app keeps the same lock behavior: if the backend says the verdict is below `MEETS_DEVICE_INTEGRITY`, the app stops runtime, stores the lock, and blocks future launches.
