import {
  adminClient,
  corsHeaders,
  json,
  serverError,
  buildLoginEmail
} from './common.ts';

type Row = Record<string, any>;

/**
 * Retires Auth access while preserving the public user row and linked history.
 * @param admin Service-role Supabase client.
 * @param userId Auth user ID to retire.
 * @returns A server error response, or null when the user is retired.
 * @throws If the Auth or database client throws while processing the request.
 */
async function retireUserAuth(
  admin: ReturnType<typeof adminClient>,
  userId: string,
): Promise<Response | null> {
  let authUpdateFailed = false;
  let authUpdateError: unknown;

  try {
    const retired = await admin.auth.admin.updateUserById(userId, {
      email: 'deleted+' + userId + '@deleted.invalid',
      email_confirm: true,
      ban_duration: '876000h',
    });

    if (retired.error) {
      authUpdateFailed = true;
      authUpdateError = retired.error;
    }
  } catch (error) {
    authUpdateFailed = true;
    authUpdateError = error;
  }

  // Revoke sessions even if retiring the Auth profile failed.
  const revoked = await admin.rpc('revoke_user_sessions', {
    p_user_id: userId,
  });

  if (revoked.error) return serverError(revoked.error);
  if (authUpdateFailed) return serverError(authUpdateError);
  return null;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return json(405, { error: 'method_not_allowed' });
  }

  try {
    // -----------------------------------------------------------------------
    // Authenticate caller
    // -----------------------------------------------------------------------

    const token = req.headers
      .get('Authorization')
      ?.replace(/^Bearer\s+/i, '');

    if (!token) {
      return json(401, { error: 'unauthorized' });
    }

    const admin = adminClient();

    const auth = await admin.auth.getUser(token);

    if (auth.error || !auth.data.user) {
      return json(401, { error: 'unauthorized' });
    }

    const callerId = auth.data.user.id;

    // -----------------------------------------------------------------------
    // Load caller
    // -----------------------------------------------------------------------

    const caller = await admin
      .from('users')
      .select('game_id, is_admin')
      .eq('id', callerId)
      .is('deleted_at', null)
      .maybeSingle();

    if (caller.error) {
      return serverError(caller.error);
    }

    if (!caller.data) {
      return json(403, { error: 'forbidden' });
    }

    const gameId = caller.data.game_id as string;
    const isAdmin = Boolean(caller.data.is_admin);

    // Only full admins can manage users.
    if (!isAdmin) {
      return json(403, { error: 'forbidden' });
    }

    // -----------------------------------------------------------------------
    // Parse request
    // -----------------------------------------------------------------------

    let body: Record<string, unknown>;

    try {
      body = await req.json();
    } catch {
      return json(400, { error: 'invalid_input' });
    }

    const action = body.action;

    if (typeof action !== 'string') {
      return json(400, { error: 'invalid_input' });
    }

    // -----------------------------------------------------------------------
    // LIST USERS
    // -----------------------------------------------------------------------

    if (action === 'list') {
      const usersRes = await admin
        .from('users')
        .select('id, uname, is_admin')
        .eq('game_id', gameId)
        .is('deleted_at', null)
        .order('uname');

      if (usersRes.error) {
        return serverError(usersRes.error);
      }

      const subsectionRes = await admin
        .from('subsections')
        .select('id, name, subsection_order')
        .eq('game_id', gameId)
        .is('deleted_at', null)
        .order('subsection_order', { ascending: true });

      if (subsectionRes.error) {
        return serverError(subsectionRes.error);
      }

      const userIds = (usersRes.data as Row[]).map(
        (user) => user.id as string,
      );

      const subsectionIdsByUser = new Map<string, string[]>();

      if (userIds.length > 0) {
        const grantsRes = await admin
          .from('subsection_admins')
          .select('user_id, subsection_id')
          .in('user_id', userIds)
          .is('deleted_at', null);

        if (grantsRes.error) {
          return serverError(grantsRes.error);
        }

        for (const grant of grantsRes.data as Row[]) {
          const userId = grant.user_id as string;
          const subsectionId = grant.subsection_id as string;

          const existing = subsectionIdsByUser.get(userId) ?? [];
          existing.push(subsectionId);
          subsectionIdsByUser.set(userId, existing);
        }
      }

      return json(200, {
        users: (usersRes.data as Row[]).map((user) => ({
          id: user.id,
          uname: user.uname,
          is_admin: user.is_admin === true,
          subsection_ids: subsectionIdsByUser.get(user.id) ?? [],
        })),
        subsections: (subsectionRes.data as Row[]).map((subsection) => ({
          id: subsection.id,
          name: subsection.name,
        })),
      });
    }

    // -----------------------------------------------------------------------
    // CREATE USER
    // -----------------------------------------------------------------------

    if (action === 'create') {
      if (
        typeof body.username !== 'string' ||
        typeof body.password !== 'string'
      ) {
        return json(400, { error: 'invalid_input' });
      }

      const username = body.username.trim().toLowerCase();
      const password = body.password;

      if (username.length === 0 || password.length === 0) {
        return json(400, { error: 'invalid_input' });
      }

      // Check whether this username already exists in this game.
      const existing = await admin
        .from('users')
        .select('id')
        .eq('game_id', gameId)
        .eq('uname', username)
        .is('deleted_at', null)
        .maybeSingle();

      if (existing.error) {
        return serverError(existing.error);
      }

      if (existing.data) {
        return json(409, { error: 'username_taken' });
      }

      /*
       * Supabase Auth requires an email address.
       *
       * The email is synthetic because the application uses usernames.
       * Including the game ID means the same username can exist in different
       * games without violating Supabase Auth's email uniqueness requirement.
       */
      const gameRes = await admin
        .from('games')
        .select('game_code')
        .eq('id', gameId)
        .maybeSingle();

      if (gameRes.error) {
        return serverError(gameRes.error);
      }

      if (!gameRes.data?.game_code) {
        return json(400, { error: 'invalid_game' });
      }

      const gameCode = gameRes.data.game_code as string;
      const email = buildLoginEmail(username, gameCode);

      // Earlier removals kept their Auth email, so retire those accounts
      // before reusing the username and its synthetic email address.
      const deletedUsers = await admin
        .from('users')
        .select('id')
        .eq('game_id', gameId)
        .eq('uname', username)
        .not('deleted_at', 'is', null);

      if (deletedUsers.error) {
        return serverError(deletedUsers.error);
      }

      for (const deletedUser of deletedUsers.data as Row[]) {
        const retirementError = await retireUserAuth(
          admin,
          deletedUser.id as string,
        );

        if (retirementError) return retirementError;
      }

      const created = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
      });

      if (created.error || !created.data.user) {
        console.error('Failed to create Auth user:', created.error);

        if (
          created.error?.message
            ?.toLowerCase()
            .includes('already registered')
        ) {
          return json(409, { error: 'username_taken' });
        }

        return serverError(created.error);
      }

      const userId = created.data.user.id;

      // Create the public user using the EXACT same UUID as auth.users.
      const inserted = await admin
        .from('users')
        .insert({
          id: userId,
          game_id: gameId,
          uname: username,
          is_admin: false,
        });

      if (inserted.error) {
        console.error('Failed to create public.users row:', inserted.error);

        // Roll back the Auth account if the application row fails.
        const deleted = await admin.auth.admin.deleteUser(userId);

        if (deleted.error) {
          console.error(
            'Failed to roll back Auth user:',
            deleted.error,
          );
        }

        return serverError(inserted.error);
      }

      return json(201, {
        id: userId,
      });
    }

    // -----------------------------------------------------------------------
    // RESET PASSWORD
    // -----------------------------------------------------------------------

    if (action === 'reset_password') {
      if (
        typeof body.user_id !== 'string' ||
        typeof body.password !== 'string'
      ) {
        return json(400, { error: 'invalid_input' });
      }

      const userId = body.user_id;
      const password = body.password;

      if (password.length === 0) {
        return json(400, { error: 'invalid_input' });
      }

      const target = await admin
        .from('users')
        .select('id, game_id, is_admin')
        .eq('id', userId)
        .is('deleted_at', null)
        .maybeSingle();

      if (target.error) {
        return serverError(target.error);
      }

      if (!target.data || target.data.game_id !== gameId) {
        return json(404, { error: 'not_found' });
      }

      // Admin accounts cannot be managed through the participant controls.
      if (target.data.is_admin === true) {
        return json(403, { error: 'forbidden' });
      }

      const updated = await admin.auth.admin.updateUserById(userId, {
        password,
      });

      if (updated.error) {
        return serverError(updated.error);
      }

      return json(200, { ok: true });
    }

    // -----------------------------------------------------------------------
    // SET SUBSECTIONS
    // -----------------------------------------------------------------------

    if (action === 'set_subsections') {
      if (
        typeof body.user_id !== 'string' ||
        !Array.isArray(body.subsection_ids)
      ) {
        return json(400, { error: 'invalid_input' });
      }

      const userId = body.user_id;
      const subsectionIds = body.subsection_ids;

      if (
        !subsectionIds.every(
          (id) => typeof id === 'string',
        )
      ) {
        return json(400, { error: 'invalid_input' });
      }

      const target = await admin
        .from('users')
        .select('id, game_id, is_admin')
        .eq('id', userId)
        .is('deleted_at', null)
        .maybeSingle();

      if (target.error) {
        return serverError(target.error);
      }

      if (!target.data || target.data.game_id !== gameId) {
        return json(404, { error: 'not_found' });
      }

      // Admins already have access to every subsection.
      if (target.data.is_admin === true) {
        return json(403, { error: 'forbidden' });
      }

      // Make sure every supplied subsection belongs to this game.
      if (subsectionIds.length > 0) {
        const validSubsections = await admin
          .from('subsections')
          .select('id')
          .eq('game_id', gameId)
          .is('deleted_at', null)
          .in('id', subsectionIds);

        if (validSubsections.error) {
          return serverError(validSubsections.error);
        }

        const validIds = new Set(
          (validSubsections.data as Row[]).map(
            (row) => row.id as string,
          ),
        );

        if (
          subsectionIds.some(
            (id) => !validIds.has(id),
          )
        ) {
          return json(400, { error: 'invalid_input' });
        }
      }

      // Remove existing grants.
      const removed = await admin
        .from('subsection_admins')
        .delete()
        .eq('user_id', userId);

      if (removed.error) {
        return serverError(removed.error);
      }

      // Add the new grants.
      if (subsectionIds.length > 0) {
        const rows = subsectionIds.map((subsectionId) => ({
          user_id: userId,
          subsection_id: subsectionId,
        }));

        const inserted = await admin
          .from('subsection_admins')
          .insert(rows);

        if (inserted.error) {
          return serverError(inserted.error);
        }
      }

      // Derived from the grants so the flag can't drift from them.
      const flagged = await admin
          .from('users')
          .update({ is_subsection_admin: subsectionIds.length > 0 })
          .eq('id', userId)
          .eq('game_id', gameId);

      if (flagged.error) {
          return serverError(flagged.error);
      }

      return json(200, { ok: true });
    }

    // -----------------------------------------------------------------------
    // REMOVE USER
    // -----------------------------------------------------------------------

    if (action === 'remove') {
      if (typeof body.user_id !== 'string') {
        return json(400, { error: 'invalid_input' });
      }

      const userId = body.user_id;

      const target = await admin
        .from('users')
        .select('id, game_id, is_admin')
        .eq('id', userId)
        .maybeSingle();

      if (target.error) {
        return serverError(target.error);
      }

      if (!target.data || target.data.game_id !== gameId) {
        return json(404, { error: 'not_found' });
      }

      // Never allow an admin to be removed by this endpoint.
      if (target.data.is_admin === true) {
        return json(403, { error: 'forbidden' });
      }

      // Soft-delete the public user.
      const removed = await admin
        .from('users')
        .update({
          deleted_at: new Date().toISOString(),
        })
        .eq('id', userId)
        .eq('game_id', gameId)
        .is('deleted_at', null);

      if (removed.error) {
        return serverError(removed.error);
      }

      // Remove subsection permissions.
      const grantsRemoved = await admin
        .from('subsection_admins')
        .delete()
        .eq('user_id', userId);

      if (grantsRemoved.error) {
        return serverError(grantsRemoved.error);
      }

      // Preserve the Auth row because deleting it cascades through answer
      // history, but revoke its refresh sessions and free its old email.
      const retirementError = await retireUserAuth(admin, userId);
      if (retirementError) return retirementError;

      return json(200, { ok: true });
    }

    return json(400, { error: 'invalid_input' });
  } catch (error) {
    return serverError(error);
  }
});
