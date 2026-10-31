CREATE OR REPLACE FUNCTION public.revealed_activity_locations()
    RETURNS TABLE (
        activity_id uuid,
        lat         double precision,
        lng         double precision
    )
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path TO ''
    AS $function$
        SELECT
            a.id,
            (a.solution #>> '{geo,lat}')::double precision,
            (a.solution #>> '{geo,lng}')::double precision
        FROM public.activities a
        JOIN public.games g ON g.id = a.game_id
        WHERE a.game_id = public.current_user_game_id()
            AND a.deleted_at IS NULL
            AND g.deleted_at IS NULL
            AND (a.solution -> 'geo') IS NOT NULL
            -- Compared as jsonb so a malformed value reads as off, not an error.
            AND COALESCE(
                (g.game_options -> 'reveal_locations') = 'true'::jsonb,
                false
            );
    $function$;

COMMENT ON FUNCTION public.revealed_activity_locations() IS
    'Location answer keys of the caller''s game, only while the game option reveal_locations is true. Never returns the scoring distance.';

REVOKE ALL ON FUNCTION public.revealed_activity_locations()
    FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.revealed_activity_locations()
    TO authenticated;