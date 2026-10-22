CREATE OR REPLACE FUNCTION public.is_game_viewable_by_users (
  game_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  AS $function$
    SELECT
      public.is_game_admin()
      OR (
        COALESCE((g.game_options->>'starts_at')::timestamptz <= now(), true)
        AND COALESCE((g.game_options->>'ends_at')::timestamptz >= now(), true)
      )
    FROM public.games g
    WHERE g.id = game_id;
  $function$;
