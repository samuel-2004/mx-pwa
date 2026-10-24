CREATE OR REPLACE FUNCTION public.revoke_user_sessions(p_user_id uuid)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
    DELETE FROM auth.sessions
    WHERE user_id = p_user_id;
  $function$;

COMMENT ON FUNCTION public.revoke_user_sessions(uuid) IS
  'Revokes all Auth sessions for p_user_id while preserving the Auth user row. Returns void. May throw if the session deletion fails.';

REVOKE ALL ON FUNCTION public.revoke_user_sessions(uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.revoke_user_sessions(uuid)
  TO service_role;
