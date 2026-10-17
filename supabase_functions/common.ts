import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

// Keep these rules identical to lib/auth/validators.dart.
const USERNAME_PATTERN = /^[a-z0-9_-]{1,64}$/;
const GAME_CODE_PATTERN = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MIN_PASSWORD_LENGTH = 8;
// bcrypt ignores everything past 72 bytes.
const MAX_PASSWORD_BYTES = 72;
const MAX_PUBLIC_REQUEST_BYTES = 8_192;
const CLIENT_IP_PATTERN = /^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]{2,45})$/;

type JsonBodyResult =
  | { ok: true; value: Record<string, unknown> }
  | { ok: false; tooLarge: boolean };

type PublicRateLimitScope = 'create-game' | 'join-game';

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Expose-Headers': 'Retry-After',
};

/**
 * Builds a JSON response with CORS headers.
 * @param status HTTP response status.
 * @param body JSON response object.
 * @param extraHeaders Additional response headers.
 * @returns A JSON response.
 * @throws If the response cannot be constructed from the supplied headers.
 */
export function json(
  status: number,
  body: Record<string, unknown>,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json',
      ...extraHeaders,
    },
  });
}

/**
 * Reads a bounded JSON object and rejects oversized or malformed bodies.
 * @param req Incoming request to read.
 * @returns Parsed object or a failure state indicating whether it was oversized.
 * @throws If the request stream fails while being read.
 */
export async function readJsonBody(req: Request): Promise<JsonBodyResult> {
  const contentLength = req.headers.get('content-length');
  if (
    contentLength !== null &&
    /^\d+$/.test(contentLength) &&
    Number(contentLength) > MAX_PUBLIC_REQUEST_BYTES
  ) {
    return { ok: false, tooLarge: true };
  }

  if (req.body === null) return { ok: false, tooLarge: false };

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      totalBytes += result.value.byteLength;
      if (totalBytes > MAX_PUBLIC_REQUEST_BYTES) {
        await reader.cancel();
        return { ok: false, tooLarge: true };
      }
      chunks.push(result.value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    const parsed: unknown = JSON.parse(
      new TextDecoder('utf-8', { fatal: true }).decode(bytes),
    );
    if (
      typeof parsed !== 'object' ||
      parsed === null ||
      Array.isArray(parsed)
    ) {
      return { ok: false, tooLarge: false };
    }
    return { ok: true, value: parsed as Record<string, unknown> };
  } catch {
    return { ok: false, tooLarge: false };
  }
}

/**
 * Enforces an atomic, shared per-IP limit for a public endpoint.
 * @param req Incoming request used to resolve the gateway client IP.
 * @param scope Rate-limit bucket name.
 * @param maxRequests Maximum requests allowed per window.
 * @param windowSeconds Fixed-window duration in seconds.
 * @returns A 429 or 503 response when blocked or unavailable, otherwise null.
 * @throws Does not throw; limiter failures return 503.
 */
export async function enforceIpRateLimit(
  req: Request,
  scope: PublicRateLimitScope,
  maxRequests: number,
  windowSeconds: number,
): Promise<Response | null> {
  // Supabase's gateway supplies these client-IP headers; do not trust the
  // caller-controlled X-Forwarded-For chain for abuse controls.
  const clientIp = (
    req.headers.get('cf-connecting-ip') ?? req.headers.get('x-real-ip') ?? ''
  ).trim();
  if (!CLIENT_IP_PATTERN.test(clientIp)) {
    return json(503, { error: 'temporarily_unavailable' });
  }

  try {
    const identifierHash = await hashRateLimitIdentifier(clientIp);
    const { data, error } = await adminClient().rpc(
      'consume_public_endpoint_rate_limit',
      {
        p_scope: scope,
        p_identifier_hash: identifierHash,
        p_max_requests: maxRequests,
        p_window_seconds: windowSeconds,
      },
    );
    if (error) {
      console.error('Public endpoint rate limiter unavailable');
      return json(503, { error: 'temporarily_unavailable' });
    }

    const result: unknown = Array.isArray(data) ? data[0] : data;
    if (
      typeof result !== 'object' ||
      result === null ||
      !('allowed' in result) ||
      typeof result.allowed !== 'boolean' ||
      !('retry_after_seconds' in result) ||
      typeof result.retry_after_seconds !== 'number'
    ) {
      console.error('Public endpoint rate limiter returned an invalid response');
      return json(503, { error: 'temporarily_unavailable' });
    }

    if (result.allowed) return null;
    const retryAfterSeconds = Math.max(1, Math.ceil(result.retry_after_seconds));
    return json(
      429,
      { error: 'rate_limited' },
      { 'Retry-After': String(retryAfterSeconds) },
    );
  } catch (error) {
    console.error(
      'Public endpoint rate limiter unavailable',
      error instanceof Error ? error.name : 'unknown error',
    );
    return json(503, { error: 'temporarily_unavailable' });
  }
}

async function hashRateLimitIdentifier(clientIp: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secretKey()),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(`mx-public-rate-limit:v1:${clientIp}`),
  );
  return Array.from(new Uint8Array(signature), (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('');
}

/** Logs the real error server-side and returns a generic 500. */
export function serverError(error: unknown): Response {
  console.error(error);
  return json(500, { error: 'server_error' });
}

/** Trims and lowercases a string field; returns '' for non-strings. */
export function normalize(value: unknown): string {
  return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

/** Returns username@gamecode.com, or null if either part is invalid. */
export function buildLoginEmail(
  username: string,
  gameCode: string,
): string | null {
  if (!USERNAME_PATTERN.test(username)) return null;
  if (!GAME_CODE_PATTERN.test(gameCode)) return null;
  return `${username}@${gameCode}.com`;
}

export function isValidPassword(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  if (value.length < MIN_PASSWORD_LENGTH) return false;
  return new TextEncoder().encode(value).length <= MAX_PASSWORD_BYTES;
}

export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

function secretKey(): string {
  // Prefer the new named secret keys; fall back to the legacy variable.
  const named = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (named) {
    const keys = JSON.parse(named) as Record<string, string>;
    if (keys.default) return keys.default;
  }
  const legacy = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (legacy) return legacy;
  throw new Error('No Supabase secret key is available to this function');
}

/** A client that bypasses RLS. Never expose it or its key to callers. */
export function adminClient(): SupabaseClient {
  const url = Deno.env.get('SUPABASE_URL');
  if (!url) throw new Error('SUPABASE_URL is not set');
  return createClient(url, secretKey(), {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
