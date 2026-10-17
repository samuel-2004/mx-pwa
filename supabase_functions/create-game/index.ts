import {
  adminClient,
  buildLoginEmail,
  corsHeaders,
  enforceIpRateLimit,
  isValidPassword,
  json,
  normalize,
  readJsonBody,
  serverError,
} from './common.ts';

// Public endpoint (verify_jwt = false): the caller has no account yet.
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });

  try {
    const rateLimitResponse = await enforceIpRateLimit(
      req,
      'create-game',
      3,
      900,
    );
    if (rateLimitResponse) return rateLimitResponse;

    const parsedBody = await readJsonBody(req);
    if (!parsedBody.ok) {
      return json(parsedBody.tooLarge ? 413 : 400, { error: 'invalid_input' });
    }
    const body = parsedBody.value;

    const gameName = typeof body.game_name === 'string' ? body.game_name.trim() : '';
    const gameCode = normalize(body.game_code);
    const username = normalize(body.username);
    const password = body.password;
    const email = buildLoginEmail(username, gameCode);
    if (!gameName || gameName.length > 100 || !email || !isValidPassword(password)) {
      return json(400, { error: 'invalid_input' });
    }

    const admin = adminClient();

    // Cheap pre-check so a taken code never gets an auth user created in its
    // namespace. The unique index still decides races.
    const existing = await admin
      .from('games')
      .select('id')
      .eq('game_code', gameCode)
      .is('deleted_at', null)
      .maybeSingle();
    if (existing.error) return serverError(existing.error);
    if (existing.data) return json(409, { error: 'game_code_taken' });

    const created = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (created.error || !created.data.user) {
      const e = created.error as { code?: string; message?: string } | null;
      // The code is free but the address exists: a leftover or a racing
      // request owns this namespace, so the code cannot be used.
      const inUse =
        e?.code === 'email_exists' || /already.*registered/i.test(e?.message ?? '');
      return inUse ? json(409, { error: 'game_code_taken' }) : serverError(e);
    }
    const userId = created.data.user.id;

    // Game and admin profile are inserted in one transaction.
    const result = await admin.rpc('create_game_with_admin', {
      p_user_id: userId,
      p_uname: username,
      p_game_code: gameCode,
      p_name: gameName,
    });
    if (result.error) {
      // The only thing left to undo by hand is the auth user.
      const cleanup = await admin.auth.admin.deleteUser(userId);
      if (cleanup.error) console.error('cleanup failed', userId, cleanup.error);
      // 23505 = unique violation: someone took the code first.
      if (result.error.code === '23505') return json(409, { error: 'game_code_taken' });
      return serverError(result.error);
    }

    return json(201, { game_id: result.data });
  } catch (error) {
    return serverError(error);
  }
});
