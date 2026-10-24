-- A public location shown to players. Kept apart from `solution`, which is the
-- answer key and must stay hidden from players.
ALTER TABLE public.activities
    ADD COLUMN location_lat double precision,
    ADD COLUMN location_lng double precision,
    ADD CONSTRAINT activities_location_valid CHECK (
        (location_lat IS NULL AND location_lng IS NULL)
        OR (
            location_lat IS NOT NULL
            AND location_lng IS NOT NULL
            AND location_lat BETWEEN -90 AND 90
            AND location_lng BETWEEN -180 AND 180
        )
    );

-- Reads on this table are granted per column, so new columns need their own.
GRANT SELECT (location_lat, location_lng)
    ON public.activities TO authenticated;