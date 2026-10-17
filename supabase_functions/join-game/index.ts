import {
  adminClient,
  corsHeaders,
  enforceIpRateLimit,
  json,
  normalize,
  buildLoginEmail,
  isValidPassword,
  readJsonBody,
  serverError,
} from './common.ts';

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return json(405, { error: 'method_not_allowed' });
  }

  try {
    const rateLimitResponse = await enforceIpRateLimit(
      req,
      'join-game',
      20,
      900,
    );
    if (rateLimitResponse) return rateLimitResponse;

    const parsedBody = await readJsonBody(req);
    if (!parsedBody.ok) {
      return json(parsedBody.tooLarge ? 413 : 400, { error: 'invalid_input' });
    }
    const body = parsedBody.value;

    const username = normalize(body.username);
    const gameCode = normalize(body.game_code);
    const password = body.password;

    const email = buildLoginEmail(username, gameCode);

    if (!email || !isValidPassword(password)) {
      return json(400, { error: 'invalid_input' });
    }

    const admin = adminClient();

    const game = await admin
      .from('games')
      .select('id, game_options')
      .eq('game_code', gameCode)
      .is('deleted_at', null)
      .maybeSingle();

    if (game.error) return serverError(game.error);

    if (!game.data) {
      return json(404, { error: 'game_not_found' });
    }

    const gameOptions = game.data.game_options;

    // Allow when allow_unregistered_users_to_join is null or undefined
    if (!(gameOptions?.allow_unregistered_users_to_join !== false)) {
      // Technically the game was found, but the user does not need to know this
      return json(403, { error: 'game_not_found' });
    }

    const gameId = game.data.id as string;

    const existing = await admin
      .from('users')
      .select('id')
      .eq('game_id', gameId)
      .eq('uname', username)
      .maybeSingle();

    if (existing.error) return serverError(existing.error);

    if (existing.data) {
      return json(409, { error: 'username_taken' });
    }

    const created = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });

    if (created.error || !created.data.user) {
      if (
        created.error?.message
          .toLowerCase()
          .includes('already registered')
      ) {
        return json(409, { error: 'username_taken' });
      }

      return serverError(created.error);
    }

    const userId = created.data.user.id;

    const inserted = await admin
      .from('users')
      .insert({
        id: userId,
        game_id: gameId,
        uname: username,
        is_admin: false,
        is_subsection_admin: false,
      });

    if (inserted.error) {
      const deleted = await admin.auth.admin.deleteUser(userId);

      if (deleted.error) {
        console.error('Failed to roll back Auth user:', deleted.error);
      }

      return serverError(inserted.error);
    }

    return json(201, { id: userId });
  } catch (error) {
    return serverError(error);
  }
});
