SET local check_function_bodies = off;

CREATE ROLE "powersync_role" WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN REPLICATION BYPASSRLS;

CREATE TABLE "public"."activities" (
  "id"                          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "game_id"                     uuid                     NOT NULL,
  "subsection_id"               uuid,
  "name"                        text                     NOT NULL,
  "answer_schema"               jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "can_resubmit"                boolean                  NOT NULL DEFAULT false,
  "release_time_offset_minutes" integer                  NOT NULL DEFAULT 0,
  "activity_order"              integer                  NOT NULL,
  "points"                      integer,
  "updated_at"                  timestamp with time zone NOT NULL DEFAULT now(),
  "deleted_at"                  timestamp with time zone,
  "desc"                        text,
  "solution"                    jsonb,
  CONSTRAINT "activities_pkey" PRIMARY KEY (id),
  CONSTRAINT "activities_points_check" CHECK (((points IS NULL) OR (points >= 0))),
  CONSTRAINT "activities_release_time_offset_minutes_check" CHECK ((release_time_offset_minutes >= 0))
);

ALTER TABLE "public"."activities"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."answers" (
  "id"                   uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "activity_id"          uuid                     NOT NULL,
  "user_id"              uuid                     NOT NULL,
  "answer"               jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "points"               integer,
  "automatically_graded" boolean                  NOT NULL DEFAULT false,
  "created_at"           timestamp with time zone NOT NULL DEFAULT now(),
  "submitted_by"         uuid                     NOT NULL,
  "graded_by"            uuid,
  "graded_at"            timestamp with time zone,
  "updated_at"           timestamp with time zone NOT NULL DEFAULT now(),
  "deleted_at"           timestamp with time zone,
  CONSTRAINT "answers_pkey" PRIMARY KEY (id),
  CONSTRAINT "answers_points_check" CHECK (((points IS NULL) OR (points >= 0)))
);

ALTER TABLE "public"."answers"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."games" (
  "id"           uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "game_code"    text                     NOT NULL,
  "name"         text                     NOT NULL,
  "starts_at"    timestamp with time zone,
  "game_options" jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "updated_at"   timestamp with time zone NOT NULL DEFAULT now(),
  "deleted_at"   timestamp with time zone,
  CONSTRAINT "games_game_code_key" UNIQUE (game_code),
  CONSTRAINT "games_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."games"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."public_endpoint_rate_limits" (
  "scope"             text                     NOT NULL,
  "identifier_hash"   text                     NOT NULL,
  "window_started_at" timestamp with time zone NOT NULL,
  "request_count"     integer                  NOT NULL,
  "expires_at"        timestamp with time zone NOT NULL,
  CONSTRAINT "public_endpoint_rate_limits_identifier_hash_check" CHECK ((identifier_hash ~ '^[0-9a-f]{64}$'::text)),
  CONSTRAINT "public_endpoint_rate_limits_pkey" PRIMARY KEY (scope, identifier_hash),
  CONSTRAINT "public_endpoint_rate_limits_request_count_check" CHECK ((request_count > 0)),
  CONSTRAINT "public_endpoint_rate_limits_scope_check" CHECK ((scope = ANY (ARRAY['create-game'::text, 'join-game'::text])))
);

ALTER TABLE "public"."public_endpoint_rate_limits"
  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE "public"."public_endpoint_rate_limits" FROM "anon", "authenticated";

CREATE TABLE "public"."subsection_admins" (
  "user_id"       uuid                     NOT NULL,
  "subsection_id" uuid                     NOT NULL,
  "updated_at"    timestamp with time zone NOT NULL DEFAULT now(),
  "deleted_at"    timestamp with time zone,
  CONSTRAINT "activity_admins_pkey" PRIMARY KEY (user_id, subsection_id)
);

ALTER TABLE "public"."subsection_admins"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."subsections" (
  "id"               uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "game_id"          uuid                     NOT NULL,
  "name"             text                     NOT NULL,
  "subsection_order" integer                  NOT NULL,
  "updated_at"       timestamp with time zone NOT NULL DEFAULT now(),
  "deleted_at"       timestamp with time zone,
  "desc"             jsonb,
  CONSTRAINT "subsections_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."subsections"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."user_activity_notes" (
  "id"           uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"      uuid                     NOT NULL,
  "activity_id"  uuid                     NOT NULL,
  "tags"         jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "lat"          double precision,
  "lng"          double precision,
  "updated_at"   timestamp with time zone NOT NULL DEFAULT now(),
  "deleteted_at" timestamp with time zone,
  "suburb"       text,
  "suburb_lat"   double precision,
  "suburb_lng"   double precision,
  CONSTRAINT "user_activity_notes_one_per_activity" UNIQUE (user_id, activity_id),
  CONSTRAINT "user_activity_notes_pin_valid" CHECK ((((lat IS NULL) AND (lng IS NULL)) OR ((lat IS NOT NULL) AND (lng IS
    NOT NULL) AND ((lat >= ('-90'::integer)::double precision) AND (lat <= (90)::double precision)) AND
    ((lng >= ('-180'::integer)::double precision) AND (lng <= (180)::double precision))))),
  CONSTRAINT "user_activity_notes_pkey" PRIMARY KEY (id),
  CONSTRAINT "user_activity_notes_suburb_point_valid" CHECK ((((suburb_lat IS NULL) AND (suburb_lng IS NULL)) OR ((suburb_lat IS NOT NULL) AND (suburb_lng IS
    NOT NULL) AND ((suburb_lat >= ('-90'::integer)::double precision) AND (suburb_lat <= (90)::double precision)) AND
    ((suburb_lng >= ('-180'::integer)::double precision) AND (suburb_lng <= (180)::double precision))))),
  CONSTRAINT "user_activity_notes_suburb_valid" CHECK (((suburb IS NULL) OR ((char_length(suburb) >= 1) AND (char_length(suburb) <= 100))))
);

ALTER TABLE "public"."user_activity_notes"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."users" (
  "id"                  uuid                     NOT NULL,
  "uname"               text                     NOT NULL,
  "game_id"             uuid,
  "is_admin"            boolean                  NOT NULL DEFAULT false,
  "is_subsection_admin" boolean                  NOT NULL DEFAULT false,
  "updated_at"          timestamp with time zone NOT NULL DEFAULT now(),
  "deleted_at"          timestamp with time zone,
  CONSTRAINT "users_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."users"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.activities_before_write()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
    geo_config jsonb;
begin
    -- Reads are limited to game admins by the view below, writes by this check.
    if auth.uid() is not null and not public.is_game_admin() then
        if tg_op = 'INSERT' then
            if new.solution is not null then
                raise exception 'Only game admins can set a solution'
                    using errcode = '42501';
            end if;
        elsif new.solution is distinct from old.solution then
            raise exception 'Only game admins can change a solution'
                using errcode = '42501';
        end if;
    end if;
    if jsonb_typeof(new.answer_schema) = 'string' then
        begin
            new.answer_schema := (new.answer_schema #>> '{}')::jsonb;
        exception when invalid_text_representation then
            return new;
        end;
    end if;
    if jsonb_typeof(new.answer_schema) is distinct from 'object' then
        return new;
    end if;
    if not coalesce((new.answer_schema -> 'types') @> '"geo"'::jsonb, false) then
        new.answer_schema := new.answer_schema - 'geo';
        return new;
    end if;
    geo_config := coalesce(new.answer_schema -> 'geo', '{}'::jsonb);
    if jsonb_typeof(geo_config) is distinct from 'object' then
        geo_config := '{}'::jsonb;
    end if;
    new.answer_schema := new.answer_schema || jsonb_build_object(
        'geo',
        geo_config || jsonb_build_object(
            'ready',
            (new.solution -> 'geo') is not null
        )
    );
    return new;
end;
$function$;

REVOKE ALL ON FUNCTION "public"."activities_before_write"() FROM PUBLIC, "anon", "authenticated";

CREATE OR REPLACE FUNCTION public.answers_before_insert()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
    actor uuid := auth.uid();
    act record;
    part jsonb;
    solution_geo jsonb;
    max_distance numeric;
    distance double precision;
begin
    if actor is null then
        return new;
    end if;

    if jsonb_typeof(new.answer) = 'string' then
        begin
            new.answer := (new.answer #>> '{}')::jsonb;
        exception when invalid_text_representation then
            raise exception 'Answer is not valid JSON' using errcode = '22023';
        end;
    end if;

    -- Capped rather than replaced, so offline submissions keep their time.
    new.submitted_by := actor;
    new.created_at := least(coalesce(new.created_at, now()), now());
    new.points := null;
    new.automatically_graded := false;
    new.graded_by := null;
    new.graded_at := null;
    new.deleted_at := null;

    select a.answer_schema, a.solution, a.points
    into act
    from public.activities a
    where a.id = new.activity_id and a.deleted_at is null;
    if not found then
        return new;
    end if;

    part := new.answer #> '{parts,geo}';
    if not coalesce((act.answer_schema -> 'types') @> '"geo"'::jsonb, false) then
        if part is not null then
            raise exception 'This activity does not take a location'
                using errcode = '22023';
        end if;
        return new;
    end if;

    solution_geo := act.solution -> 'geo';
    if solution_geo is null then
        if part is not null then
            raise exception 'This activity is not ready for locations'
                using errcode = '22023';
        end if;
        return new;
    end if;
    if part is null then
        raise exception 'A location is required' using errcode = '22023';
    end if;

    if jsonb_typeof(part) is distinct from 'object'
        or jsonb_typeof(part -> 'lat') is distinct from 'number'
        or jsonb_typeof(part -> 'lng') is distinct from 'number' then
        raise exception 'Invalid location' using errcode = '22023';
    end if;
    if (part ->> 'lat')::numeric not between -90 and 90
        or (part ->> 'lng')::numeric not between -180 and 180 then
        raise exception 'Invalid location' using errcode = '22023';
    end if;
    if (part ->> 'source') is not null
        and (part ->> 'source') not in ('device', 'photo', 'map') then
        raise exception 'Invalid location source' using errcode = '22023';
    end if;

    max_distance := (solution_geo ->> 'max_distance_m')::numeric;
    if max_distance is null or act.points is null then
        return new;
    end if;
    -- Other parts (photo, text) still need a person, so only an activity that
    -- asks for a location alone is graded automatically.
    if (act.answer_schema -> 'types') is distinct from '["geo"]'::jsonb then
        return new;
    end if;

    distance := public.geo_distance_m(
        (part ->> 'lat')::double precision,
        (part ->> 'lng')::double precision,
        (solution_geo ->> 'lat')::double precision,
        (solution_geo ->> 'lng')::double precision
    );
    new.points := case when distance <= max_distance then act.points else 0 end;
    new.automatically_graded := true;
    new.graded_at := now();
    return new;
end;
$function$;

REVOKE ALL ON FUNCTION "public"."answers_before_insert"() FROM PUBLIC, "anon", "authenticated";

CREATE OR REPLACE FUNCTION public.bulk_set_scores (
  p_scores jsonb
)
  RETURNS integer
  LANGUAGE plpgsql
  SET search_path TO 'public'
  AS $function$
declare
    v_score record;
    v_answer_id uuid;
    v_count integer := 0;
begin
    if not public.is_game_admin() then
        raise exception 'Only game admins can enter scores in bulk'
            using errcode = '42501';
    end if;

    for v_score in
        select *
        from jsonb_to_recordset(p_scores)
            as s(activity_id uuid, user_id uuid, points integer)
    loop
        select id into v_answer_id
        from answers
        where activity_id = v_score.activity_id
            and user_id = v_score.user_id
            and deleted_at is null
        order by created_at desc
        limit 1;

        if v_answer_id is null then
            v_answer_id := gen_random_uuid();
            -- ASSUMPTION: the trigger accepts this body. It probably rejects
            -- it for image and location activities, which need a real path
            -- or coordinates, so it may need an admin-entered bypass.
            insert into answers (id, activity_id, user_id, answer, submitted_by)
            values (
                v_answer_id,
                v_score.activity_id,
                v_score.user_id,
                '{"parts": {}}',
                auth.uid()
            );
        end if;

        -- Range, permission and "newer answer" checks stay in one place.
        perform public.grade_answer(v_answer_id, v_score.points);
        v_count := v_count + 1;
    end loop;

    return v_count;
end;
$function$;

REVOKE ALL ON FUNCTION "public"."bulk_set_scores"(jsonb) FROM PUBLIC, "anon";

CREATE OR REPLACE FUNCTION public.can_admin_activity (
  target_activity_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$select
    (
        public.is_game_admin()
        and exists (
            select 1
            from public.activities a
            where a.id = target_activity_id
                and a.game_id = public.current_user_game_id()
        )
    )
    or public.is_activity_admin(target_activity_id);$function$;

CREATE OR REPLACE FUNCTION public.can_grade_activity (
  p_activity_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$select exists (
    select 1 from public.activities a
    where a.id = p_activity_id
      and a.deleted_at is null
      and (
        public.can_admin_activity(a.id)
        or exists (
          select 1 from public.subsection_admins sa
          where sa.user_id = (select auth.uid())
            and sa.subsection_id = a.subsection_id
            and sa.deleted_at is null
        )
      )
  );$function$;

REVOKE ALL ON FUNCTION "public"."can_grade_activity"(uuid) FROM PUBLIC, "anon";

CREATE OR REPLACE FUNCTION public.can_view_submission (
  p_path text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select exists (
    select 1 from public.answers a
    where a.deleted_at is null
      and strpos(a.answer::text, p_path) > 0
      and (a.answer::jsonb #>> '{parts,image,path}') = p_path
      and public.can_grade_activity(a.activity_id)
  );
$function$;

REVOKE ALL ON FUNCTION "public"."can_view_submission"(text) FROM PUBLIC, "anon";

CREATE OR REPLACE FUNCTION public.consume_public_endpoint_rate_limit (
  p_scope           text,
  p_identifier_hash text,
  p_max_requests    integer,
  p_window_seconds  integer
)
  RETURNS TABLE (
    allowed             boolean,
    retry_after_seconds integer
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_window_start timestamptz;
  v_window_end timestamptz;
  v_request_count integer;
begin
  if p_scope is null or p_scope not in ('create-game', 'join-game')
    or p_identifier_hash is null
    or p_identifier_hash !~ '^[0-9a-f]{64}$'
    or p_max_requests is null or p_max_requests not between 1 and 100
    or p_window_seconds is null or p_window_seconds not between 60 and 3600
  then
    raise exception 'invalid rate limit parameters' using errcode = '22023';
  end if;

  v_window_start := pg_catalog.date_bin(
    pg_catalog.make_interval(secs => p_window_seconds),
    v_now,
    'epoch'::timestamptz
  );
  v_window_end := v_window_start + pg_catalog.make_interval(secs => p_window_seconds);

  -- Remove expired entries in small batches so rotating client IPs cannot
  -- grow the limiter table indefinitely.
  delete from public.public_endpoint_rate_limits
  where ctid in (
    select ctid
    from public.public_endpoint_rate_limits
    where expires_at <= v_now
    order by expires_at
    limit 100
  );

  insert into public.public_endpoint_rate_limits as current_limit (
    scope,
    identifier_hash,
    window_started_at,
    request_count,
    expires_at
  ) values (
    p_scope,
    p_identifier_hash,
    v_window_start,
    1,
    v_window_end
  )
  on conflict (scope, identifier_hash) do update
  set
    window_started_at = case
      when current_limit.window_started_at < excluded.window_started_at
        then excluded.window_started_at
      else current_limit.window_started_at
    end,
    request_count = case
      when current_limit.window_started_at < excluded.window_started_at then 1
      else current_limit.request_count + 1
    end,
    expires_at = excluded.expires_at
  returning current_limit.request_count into v_request_count;

  allowed := v_request_count <= p_max_requests;
  retry_after_seconds := greatest(
    1,
    pg_catalog.ceil(pg_catalog.date_part('epoch', v_window_end - v_now))::integer
  );
  return next;
end;
$function$;

REVOKE ALL ON FUNCTION "public"."consume_public_endpoint_rate_limit"(text, text, integer, integer) FROM PUBLIC, "anon", "authenticated";

CREATE OR REPLACE FUNCTION public."create-game" (
  p_game_code    text,
  p_name         text,
  p_game_options jsonb                    DEFAULT '{}'::jsonb,
  p_starts_at    timestamp with time zone DEFAULT NULL::timestamp WITH time zone,
  p_ends_at      timestamp with time zone DEFAULT NULL::timestamp WITH time zone,
  p_uname        text                     DEFAULT 'Admin'::text
)
  RETURNS public.games
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$declare
    new_game public.games;
    current_user_id uuid;
begin
    current_user_id := auth.uid();

    -- The authenticated user must not already have a public.users account.
    if exists (
        select 1
        from public.users
        where id = current_user_id
    ) then
        raise exception 'User already has an account';
    end if;

    -- Create the game.
    insert into public.games (
        game_code,
        name,
        game_options,
        starts_at,
        ends_at
    )
    values (
        p_game_code,
        p_name,
        coalesce(p_game_options, '{}'::jsonb),
        p_starts_at,
        p_ends_at
    )
    returning * into new_game;

    -- Create the user as the game's administrator.
    insert into public.users (
        id,
        uname,
        game_id,
        is_super_admin,
        is_game_admin
    )
    values (
        current_user_id,
        p_uname,
        new_game.id,
        true,
        true
    );

    return new_game;
end;$function$;

CREATE OR REPLACE FUNCTION public.create_game_with_admin (
  p_user_id   uuid,
  p_uname     text,
  p_game_code text,
  p_name      text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  v_game_id uuid;
begin
  if p_user_id is null then
    raise exception 'p_user_id is required';
  end if;

  if exists (select 1 from public.users where id = p_user_id) then
    raise exception 'user already has an account';
  end if;

  -- A duplicate game code raises 23505 (unique violation) and rolls back.
  insert into public.games (game_code, name)
  values (p_game_code, p_name)
  returning id into v_game_id;

  insert into public.users (id, uname, game_id, is_admin)
  values (p_user_id, p_uname, v_game_id, true);

  return v_game_id;
end;
$function$;

REVOKE ALL ON FUNCTION "public"."create_game_with_admin"(uuid, text, text, text) FROM PUBLIC, "anon", "authenticated";

CREATE OR REPLACE FUNCTION public.current_user_game_id()
  RETURNS uuid
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
    select game_id
    from public.users
    where id = (select auth.uid());
$function$;

CREATE OR REPLACE FUNCTION public.debug_auth_context()
  RETURNS jsonb
  LANGUAGE sql
  AS $function$select jsonb_build_object(
    'uid', auth.uid(),
    'role', auth.role(),
    'is_super_admin', is_game_admin(),
    'is_subsection_admin', is_subsection_admin(),
    'current_game_id', current_user_game_id()
  );$function$;

CREATE OR REPLACE FUNCTION public.geo_distance_m (
  p_lat1 double precision,
  p_lng1 double precision,
  p_lat2 double precision,
  p_lng2 double precision
)
  RETURNS double precision
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
    select 2 * 6371008.8 * asin(least(1, sqrt(
        power(sin(radians(p_lat2 - p_lat1) / 2), 2)
        + cos(radians(p_lat1)) * cos(radians(p_lat2))
        * power(sin(radians(p_lng2 - p_lng1) / 2), 2)
    )));
$function$;

CREATE OR REPLACE FUNCTION public.grade_answer (
  p_answer_id uuid,
  p_points    integer
)
  RETURNS public.answers
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$declare
    target_answer public.answers;
    max_points integer;
    updated_answer public.answers;
begin
    if (select auth.uid()) is null then
        raise exception 'You must be authenticated';
    end if;

    -- Find the answer.
    select *
    into target_answer
    from public.answers
    where id = p_answer_id;

    if not found then
        raise exception 'Answer not found';
    end if;

    -- Check administrator permission.
    if not public.can_admin_activity(target_answer.activity_id) then
        raise exception 'You do not have permission to grade this answer';
    end if;

    -- Get the maximum points for the activity.
    select points
    into max_points
    from public.activities
    where id = target_answer.activity_id;

    -- Apply manual grade.
    update public.answers
    set
        points = p_points,
        graded_by = (select auth.uid()),
        graded_at = now()
    where id = p_answer_id
    returning *
    into updated_answer;

    return updated_answer;
end;$function$;

CREATE OR REPLACE FUNCTION public.grading_queue (
  p_include_graded boolean DEFAULT false,
  p_limit          integer DEFAULT 100
)
  RETURNS TABLE (
    answer_id            uuid,
    activity_id          uuid,
    activity_name        text,
    activity_description text,
    max_points           integer,
    subsection_name      text,
    user_id              uuid,
    username             text,
    answer               text,
    points               integer,
    created_at           timestamp with time zone,
    solution             jsonb,
    distance_m           double precision
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
    with scoped as (
        select a.* from public.answers a
        where a.deleted_at is null
            and public.can_grade_activity(a.activity_id)
    ),
    latest as (
        select distinct on (activity_id, user_id) *
        from scoped
        order by activity_id, user_id, created_at desc
    )
    select
        l.id,
        act.id,
        act.name,
        act."desc",
        act.points,
        s.name,
        l.user_id,
        u.uname,
        l.answer::text,
        l.points,
        l.created_at,
        act.solution,
        case
            when (act.solution -> 'geo') is not null
                and jsonb_typeof(l.answer #> '{parts,geo,lat}') = 'number'
                and jsonb_typeof(l.answer #> '{parts,geo,lng}') = 'number'
            then public.geo_distance_m(
                (l.answer #>> '{parts,geo,lat}')::double precision,
                (l.answer #>> '{parts,geo,lng}')::double precision,
                (act.solution #>> '{geo,lat}')::double precision,
                (act.solution #>> '{geo,lng}')::double precision
            )
        end
    from latest l
    join public.activities act on act.id = l.activity_id and act.deleted_at is null
    left join public.subsections s on s.id = act.subsection_id
    join public.users u on u.id = l.user_id
    where p_include_graded or l.points is null
    order by l.created_at
    limit least(greatest(p_limit, 1), 200);
$function$;

REVOKE ALL ON FUNCTION "public"."grading_queue"(boolean, integer) FROM PUBLIC, "anon";

CREATE OR REPLACE FUNCTION public.is_activity_admin (
  target_activity_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$SELECT EXISTS (
    SELECT 1
    FROM public.subsection_admins aa
    WHERE aa.user_id = auth.uid()
      AND aa.subsection_id = (
          SELECT a.subsection_id
          FROM public.activities a
          WHERE a.id = target_activity_id
      )
);$function$;

CREATE OR REPLACE FUNCTION public.is_game_admin()
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$select coalesce(
        (
            select is_admin
            from public.users
            where id = (select auth.uid())
        ),
        false
    );$function$;

CREATE OR REPLACE FUNCTION public.is_game_viewable_by_users (
  game_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  AS $function$SELECT
        public.is_game_admin()
        OR COALESCE(
            (g.game_options->>'starts_at')::timestamptz >= now(),
            true
        )
    FROM public.games g
    WHERE g.id = game_id;$function$;

CREATE OR REPLACE FUNCTION public.is_member_of_game (
  p_game_id uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select exists (
    select 1 from public.users u
    where u.id = (select auth.uid())
      and u.game_id = p_game_id
      and u.deleted_at is null
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_subsection_admin()
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$select coalesce(
        (
            select is_subsection_admin
            from public.users
            where id = (select auth.uid())
        ),
        false
    );$function$;

CREATE OR REPLACE FUNCTION public.scoreboard()
  RETURNS TABLE (
    place        bigint,
    user_id      uuid,
    username     text,
    total_points bigint,
    graded_count bigint
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$#variable_conflict use_column
declare
  v_caller uuid := (select auth.uid());
  v_game uuid;
  v_is_admin boolean;
  v_enabled boolean;
begin
  if v_caller is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  select u.game_id, (
    u.is_admin
    or u.is_subsection_admin
    or exists (
        select 1 from public.subsection_admins sa
        where sa.user_id = u.id and sa.deleted_at is null
    )
  )
  into v_game, v_is_admin
  from public.users u
  where u.id = v_caller and u.deleted_at is null;
  if v_game is null then
    raise exception 'not in a game' using errcode = '42501';
  end if;

  select coalesce((g.game_options::jsonb ->> 'scoreboard_enabled')::boolean, true)
    into v_enabled
  from public.games g
  where g.id = v_game and g.deleted_at is null;

  -- 55000 lets the app tell "turned off" apart from "not allowed".
  if not v_is_admin and not coalesce(v_enabled, true) then
    raise exception 'the scoreboard is turned off' using errcode = '55000';
  end if;

  return query
  with latest as (
    select distinct on (a.activity_id, a.user_id)
      a.activity_id, a.user_id, a.points
    from public.answers a
    join public.activities act
      on act.id = a.activity_id and act.game_id = v_game and act.deleted_at is null
    where a.deleted_at is null
    order by a.activity_id, a.user_id, a.created_at desc
  ),
  totals as (
    select l.user_id,
           coalesce(sum(l.points), 0)::bigint as total_points,
           count(l.points)::bigint as graded_count
    from latest l
    group by l.user_id
  )
  select
    rank() over (order by coalesce(t.total_points, 0) desc),
    u.id,
    u.uname,
    coalesce(t.total_points, 0),
    coalesce(t.graded_count, 0)
  from public.users u
  left join totals t on t.user_id = u.id
  where u.game_id = v_game
    and u.deleted_at is null
    and not (
      u.is_admin
      or u.is_subsection_admin
      or exists (
        select 1 from public.subsection_admins sa
        where sa.user_id = u.id and sa.deleted_at is null
      )
    )
  order by coalesce(t.total_points, 0) desc, u.uname;
end;$function$;

REVOKE ALL ON FUNCTION "public"."scoreboard"() FROM PUBLIC, "anon";

CREATE OR REPLACE FUNCTION public.update_game_settings (
  p_name         text,
  p_game_options jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$declare
  v_caller uuid := (select auth.uid());
  v_game uuid;
begin
  if v_caller is null then
    raise exception 'not signed in'
      using errcode = '42501';
  end if;

  select u.game_id
  into v_game
  from public.users u
  where u.id = v_caller
    and u.deleted_at is null
    and public.is_game_admin();

  if v_game is null then
    raise exception 'only game admins can change settings'
      using errcode = '42501';
  end if;

  if p_name is null
     or char_length(btrim(p_name)) not between 1 and 100 then
    raise exception 'invalid name'
      using errcode = '22023';
  end if;

  if p_game_options is null
     or jsonb_typeof(p_game_options) <> 'object' then
    raise exception 'invalid game options'
      using errcode = '22023';
  end if;

  update public.games
  set name = btrim(p_name),
      game_options = coalesce(game_options, '{}'::jsonb) || p_game_options,
      updated_at = now()
  where id = v_game;
end;$function$;

REVOKE ALL ON FUNCTION "public"."update_game_settings"(text, jsonb) FROM PUBLIC, "anon";

CREATE OR REPLACE FUNCTION public.user_activity_notes_before_write()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
    if jsonb_typeof(new.tags) = 'string' then
        new.tags := (new.tags #>> '{}')::jsonb;
    end if;
    return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.valid_activity_solution (
  p_solution jsonb
)
  RETURNS boolean
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
declare
    geo jsonb;
begin
    if jsonb_typeof(p_solution) is distinct from 'object' then
        return false;
    end if;
    if exists (
        select 1 from jsonb_object_keys(p_solution) as k where k <> 'geo'
    ) then
        return false;
    end if;
    geo := p_solution -> 'geo';
    if geo is null then
        return true;
    end if;
    if jsonb_typeof(geo) is distinct from 'object'
        or jsonb_typeof(geo -> 'lat') is distinct from 'number'
        or jsonb_typeof(geo -> 'lng') is distinct from 'number' then
        return false;
    end if;
    if (geo ->> 'lat')::numeric not between -90 and 90
        or (geo ->> 'lng')::numeric not between -180 and 180 then
        return false;
    end if;
    if geo -> 'max_distance_m' is null then
        return true;
    end if;
    if jsonb_typeof(geo -> 'max_distance_m') is distinct from 'number' then
        return false;
    end if;
    return (geo ->> 'max_distance_m')::numeric > 0;
end;
$function$;

CREATE OR REPLACE FUNCTION public.valid_activity_tags (
  tags jsonb
)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
    select case
        when jsonb_typeof(tags) <> 'object' then false
        else
            (select count(*) from jsonb_object_keys(tags)) <= 5
            and not exists (
                select 1
                from jsonb_each(tags) as t(k, v)
                where char_length(t.k) not between 1 and 30
                    or jsonb_typeof(t.v) <> 'string'
                    or (t.v #>> '{}') !~ '^#[0-9A-Fa-f]{6}$'
            )
    end;
$function$;

ALTER TABLE "public"."answers"
  ADD CONSTRAINT "answers_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE CASCADE;

ALTER TABLE "public"."activities"
  ADD CONSTRAINT "activities_game_id_fkey" FOREIGN KEY (game_id) REFERENCES public.games(id) ON DELETE CASCADE;

ALTER TABLE "public"."subsections"
  ADD CONSTRAINT "subsections_game_id_fkey" FOREIGN KEY (game_id) REFERENCES public.games(id) ON DELETE CASCADE;

ALTER TABLE "public"."activities"
  ADD CONSTRAINT "activities_subsection_id_fkey" FOREIGN KEY (subsection_id) REFERENCES public.subsections(id) ON DELETE SET NULL;

ALTER TABLE "public"."subsection_admins"
  ADD CONSTRAINT "activity_admins_subsection_id_fkey" FOREIGN KEY (subsection_id) REFERENCES public.subsections(id);

ALTER TABLE "public"."user_activity_notes"
  ADD CONSTRAINT "user_activity_notes_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE CASCADE;

ALTER TABLE "public"."users"
  ADD CONSTRAINT "users_game_id_fkey" FOREIGN KEY (game_id) REFERENCES public.games(id) ON DELETE SET NULL;

ALTER TABLE "public"."users"
  ADD CONSTRAINT "users_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."answers"
  ADD CONSTRAINT "answers_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."subsection_admins"
  ADD CONSTRAINT "activity_admins_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."user_activity_notes"
  ADD CONSTRAINT "user_activity_notes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

CREATE VIEW "public"."activities_public" WITH (security_invoker=true) AS  SELECT id,
    game_id,
    subsection_id,
    name,
    answer_schema,
    can_resubmit,
    release_time_offset_minutes,
    activity_order,
    points
   FROM public.activities;

CREATE VIEW "public"."activity_solutions" AS  SELECT id AS activity_id,
    solution
   FROM public.activities a
  WHERE ((solution IS NOT NULL) AND public.is_game_admin() AND (game_id = public.current_user_game_id()));

REVOKE ALL ON TABLE "public"."activity_solutions" FROM "anon";

CREATE INDEX activities_game_id_idx ON public.activities USING btree (game_id);

CREATE UNIQUE INDEX activities_game_id_subsection_id_activity_order_key ON public.activities USING btree (game_id, subsection_id, activity_order)
  WHERE (deleted_at IS NULL);

CREATE INDEX activities_subsection_id_idx ON public.activities USING btree (subsection_id);

CREATE INDEX activity_admins_activity_id_idx ON public.subsection_admins USING btree (subsection_id);

CREATE INDEX answers_activity_id_idx ON public.answers USING btree (activity_id);

CREATE INDEX answers_user_activity_idx ON public.answers USING btree (user_id, activity_id);

CREATE INDEX answers_user_id_idx ON public.answers USING btree (user_id);

CREATE INDEX public_endpoint_rate_limits_expires_at_idx ON public.public_endpoint_rate_limits USING btree (expires_at);

CREATE INDEX subsections_game_id_idx ON public.subsections USING btree (game_id);

CREATE UNIQUE INDEX subsections_game_id_subsection_order_key ON public.subsections USING btree (game_id, subsection_order)
  WHERE (deleted_at IS NULL);

CREATE INDEX users_game_id_idx ON public.users USING btree (game_id);

CREATE TRIGGER activities_before_write
  BEFORE INSERT OR UPDATE OF answer_schema, solution ON public.activities
  FOR EACH ROW
  EXECUTE FUNCTION public.activities_before_write();

CREATE TRIGGER answers_before_insert
  BEFORE INSERT ON public.answers
  FOR EACH ROW
  EXECUTE FUNCTION public.answers_before_insert();

CREATE TRIGGER user_activity_notes_before_write
  BEFORE INSERT OR UPDATE ON public.user_activity_notes
  FOR EACH ROW
  EXECUTE FUNCTION public.user_activity_notes_before_write();

CREATE POLICY "activity admins can delete activities" ON "public"."activities"
  FOR DELETE
  TO "authenticated"
  USING (public.can_admin_activity(id));

CREATE POLICY "activity admins can update activities" ON "public"."activities"
  FOR UPDATE
  TO "authenticated"
  USING (((public.is_game_admin() AND (game_id = public.current_user_game_id())) OR public.is_activity_admin(id)))
  WITH CHECK (((public.is_game_admin() AND (game_id = public.current_user_game_id())) OR public.is_activity_admin(id)));

CREATE POLICY "game admins can insert activities" ON "public"."activities"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((public.is_game_admin() AND (game_id = public.current_user_game_id()) AND ((subsection_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM public.subsections s
  WHERE ((s.id = activities.subsection_id) AND (s.game_id = activities.game_id)))))));

CREATE POLICY "users can view available game activities" ON "public"."activities"
  FOR SELECT
  TO "authenticated"
  USING
    (((game_id = public.current_user_game_id()) AND (public.is_subsection_admin() OR public.is_game_admin() OR public.is_activity_admin(id) OR
    public.is_game_viewable_by_users(game_id))));

CREATE POLICY "activity admins can view activity answers" ON "public"."answers"
  FOR SELECT
  TO "authenticated"
  USING (public.can_admin_activity(activity_id));

CREATE POLICY "admins can submit activities for users" ON "public"."answers"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (public.can_admin_activity(activity_id));

CREATE POLICY "users can submit their own answers" ON "public"."answers"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM public.activities a
  WHERE ((a.id = answers.activity_id) AND (a.game_id = public.current_user_game_id()))))));

CREATE POLICY "users can view their own answers" ON "public"."answers"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "game admins can update their game" ON "public"."games"
  FOR UPDATE
  TO "authenticated"
  USING ((public.is_game_admin() AND (id = public.current_user_game_id())))
  WITH CHECK ((public.is_game_admin() AND (id = public.current_user_game_id())));

CREATE POLICY "users can view their game" ON "public"."games"
  FOR SELECT
  TO "authenticated"
  USING ((id = public.current_user_game_id()));

CREATE POLICY "games_select_member" ON "public"."games"
  FOR SELECT
  TO "authenticated"
  USING (public.is_member_of_game(id));

CREATE POLICY "game super admins can create activity admin assignments" ON "public"."subsection_admins"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((public.is_subsection_admin() AND (EXISTS ( SELECT 1
   FROM public.activities a
  WHERE ((a.id = subsection_admins.subsection_id) AND (a.game_id = public.current_user_game_id())))) AND (EXISTS ( SELECT 1
   FROM public.users u
  WHERE ((u.id = subsection_admins.user_id) AND (u.game_id = public.current_user_game_id()))))));

CREATE POLICY "game super admins can delete activity admin assignments" ON "public"."subsection_admins"
  FOR DELETE
  TO "authenticated"
  USING ((public.is_subsection_admin() AND (EXISTS ( SELECT 1
   FROM public.activities a
  WHERE ((a.id = subsection_admins.subsection_id) AND (a.game_id = public.current_user_game_id()))))));

CREATE POLICY "users can view their activity admin assignments" ON "public"."subsection_admins"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "game admins can delete subsections" ON "public"."subsections"
  FOR DELETE
  TO "authenticated"
  USING ((public.is_game_admin() AND (game_id = public.current_user_game_id())));

CREATE POLICY "game admins can insert subsections" ON "public"."subsections"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((public.is_game_admin() AND (game_id = public.current_user_game_id())));

CREATE POLICY "game admins can update subsections" ON "public"."subsections"
  FOR UPDATE
  TO "authenticated"
  USING ((public.is_game_admin() AND (game_id = public.current_user_game_id())))
  WITH CHECK ((public.is_game_admin() AND (game_id = public.current_user_game_id())));

CREATE POLICY "users can view game subsections" ON "public"."subsections"
  FOR SELECT
  TO "authenticated"
  USING ((game_id = public.current_user_game_id()));

CREATE POLICY "Owner adds own notes" ON "public"."user_activity_notes"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM public.activities a
  WHERE (a.id = user_activity_notes.activity_id)))));

CREATE POLICY "Owner deletes own notes" ON "public"."user_activity_notes"
  FOR DELETE
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Owner reads own notes" ON "public"."user_activity_notes"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "Owner updates own notes" ON "public"."user_activity_notes"
  FOR UPDATE
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)))
  WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "game admins can view game users" ON "public"."users"
  FOR SELECT
  TO "authenticated"
  USING (((public.is_subsection_admin() OR public.is_game_admin()) AND (game_id = public.current_user_game_id())));

CREATE POLICY "users can view themselves" ON "public"."users"
  FOR SELECT
  TO "authenticated"
  USING ((id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "game members can receive game broadcasts" ON "realtime"."messages"
  FOR SELECT
  TO "authenticated"
  USING (((EXTENSION = 'broadcast'::text) AND (EXISTS ( SELECT 1
   FROM public.users u
  WHERE ((u.id = ( SELECT auth.uid() AS uid)) AND (u.game_id = (split_part(realtime.topic(), ':'::text, 2))::uuid))))));

CREATE POLICY "submissions_insert" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH
    CHECK
    (((bucket_id = 'submissions'::text) AND ((storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text) AND
    ((storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text) AND
    (public.can_admin_activity(((storage.foldername(name))[1])::uuid) OR (((storage.foldername(name))[2] = (( SELECT auth.uid() AS uid))::text) AND
    public.is_member_of_game(((storage.foldername(name))[1])::uuid)))));

CREATE POLICY "submissions_select" ON "storage"."objects"
  FOR SELECT
  TO "authenticated"
  USING
    (((bucket_id = 'submissions'::text) AND (public.can_view_submission(name) OR ((storage.foldername(name))[2] = (( SELECT auth.uid() AS uid))::text) OR (public.is_game_admin()
    AND ((storage.foldername(name))[1] = (public.current_user_game_id())::text)))));

CREATE PUBLICATION "powersync" FOR ALL TABLES WITH (publish = 'insert, update, delete, truncate');

REVOKE ALL ON FUNCTION "public"."activities_before_write"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."activities_before_write"() TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."activities_before_write"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."answers_before_insert"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."answers_before_insert"() TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."answers_before_insert"() TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."bulk_set_scores"(jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."bulk_set_scores"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."bulk_set_scores"(jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."bulk_set_scores"(jsonb) TO "service_role";

REVOKE ALL ON FUNCTION "public"."can_admin_activity"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."can_admin_activity"(uuid) TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."can_admin_activity"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."can_admin_activity"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."can_admin_activity"(uuid) TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."can_grade_activity"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."can_grade_activity"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."can_grade_activity"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."can_grade_activity"(uuid) TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."can_view_submission"(text) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."can_view_submission"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."can_view_submission"(text) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."can_view_submission"(text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."consume_public_endpoint_rate_limit"(text, text, integer, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."consume_public_endpoint_rate_limit"(text, text, integer, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."consume_public_endpoint_rate_limit"(text, text, integer, integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."create-game"(text, text, jsonb, timestamp WITH time zone, timestamp WITH time zone, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."create-game"(text, text, jsonb, timestamp WITH time zone, timestamp WITH time zone, text) TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."create-game"(text, text, jsonb, timestamp WITH time zone, timestamp WITH time zone, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."create-game"(text, text, jsonb, timestamp WITH time zone, timestamp WITH time zone, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."create-game"(text, text, jsonb, timestamp WITH time zone, timestamp WITH time zone, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_game_with_admin"(uuid, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."create_game_with_admin"(uuid, text, text, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."create_game_with_admin"(uuid, text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "public"."current_user_game_id"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."current_user_game_id"() TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."current_user_game_id"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."current_user_game_id"() TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."current_user_game_id"() TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."debug_auth_context"() TO PUBLIC, "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."debug_auth_context"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."debug_auth_context"() TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."debug_auth_context"() TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."geo_distance_m"(double precision, double precision, double precision, double precision) TO PUBLIC, "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."geo_distance_m"(double precision, double precision, double precision, double precision) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."geo_distance_m"(double precision, double precision, double precision, double precision) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."geo_distance_m"(double precision, double precision, double precision, double precision) TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."grade_answer"(uuid, integer) TO PUBLIC, "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."grade_answer"(uuid, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."grade_answer"(uuid, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."grade_answer"(uuid, integer) TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."grading_queue"(boolean, integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."grading_queue"(boolean, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."grading_queue"(boolean, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."grading_queue"(boolean, integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."is_activity_admin"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."is_activity_admin"(uuid) TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."is_activity_admin"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_activity_admin"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_activity_admin"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "public"."is_game_admin"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."is_game_admin"() TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."is_game_admin"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_game_admin"() TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_game_admin"() TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."is_game_viewable_by_users"(uuid) TO PUBLIC, "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."is_game_viewable_by_users"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_game_viewable_by_users"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_game_viewable_by_users"(uuid) TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."is_member_of_game"(uuid) TO PUBLIC, "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."is_member_of_game"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_member_of_game"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_member_of_game"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "public"."is_subsection_admin"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."is_subsection_admin"() TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."is_subsection_admin"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_subsection_admin"() TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."is_subsection_admin"() TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."scoreboard"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."scoreboard"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."scoreboard"() TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."scoreboard"() TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."update_game_settings"(text, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."update_game_settings"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."update_game_settings"(text, jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."update_game_settings"(text, jsonb) TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."user_activity_notes_before_write"() TO PUBLIC, "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."user_activity_notes_before_write"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."user_activity_notes_before_write"() TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."user_activity_notes_before_write"() TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."valid_activity_solution"(jsonb) TO PUBLIC, "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."valid_activity_solution"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."valid_activity_solution"(jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."valid_activity_solution"(jsonb) TO "service_role";

GRANT EXECUTE ON FUNCTION "public"."valid_activity_tags"(jsonb) TO PUBLIC, "anon", "authenticated";

REVOKE ALL ON FUNCTION "public"."valid_activity_tags"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "public"."valid_activity_tags"(jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "public"."valid_activity_tags"(jsonb) TO "service_role";

REVOKE ALL ON TABLE "public"."activities" FROM "anon";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."activities" TO "anon";

REVOKE ALL ON TABLE "public"."activities" FROM "authenticated";

REVOKE ALL ("activity_order") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("activity_order") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("answer_schema") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("answer_schema") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("can_resubmit") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("can_resubmit") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("deleted_at") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("deleted_at") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("desc") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("desc") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("game_id") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("game_id") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("id") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("id") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("name") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("name") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("points") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("points") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("release_time_offset_minutes") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("release_time_offset_minutes") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("subsection_id") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("subsection_id") ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ("updated_at") ON TABLE "public"."activities" FROM "authenticated";

GRANT SELECT ("updated_at") ON TABLE "public"."activities" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."activities" TO "authenticated";

REVOKE ALL ON TABLE "public"."activities" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."activities" TO "postgres";

GRANT SELECT ON TABLE "public"."activities" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."activities" TO "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."answers" TO "anon", "authenticated";

REVOKE ALL ON TABLE "public"."answers" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."answers" TO "postgres";

GRANT SELECT ON TABLE "public"."answers" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."answers" TO "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."games" TO "anon";

REVOKE ALL ON TABLE "public"."games" FROM "authenticated";

GRANT DELETE, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."games" TO "authenticated";

REVOKE ALL ON TABLE "public"."games" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."games" TO "postgres";

GRANT SELECT ON TABLE "public"."games" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."games" TO "service_role";

REVOKE ALL ON TABLE "public"."public_endpoint_rate_limits" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."public_endpoint_rate_limits" TO "postgres";

GRANT SELECT ON TABLE "public"."public_endpoint_rate_limits" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."public_endpoint_rate_limits" TO "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."subsection_admins" TO "anon", "authenticated";

REVOKE ALL ON TABLE "public"."subsection_admins" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."subsection_admins" TO "postgres";

GRANT SELECT ON TABLE "public"."subsection_admins" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."subsection_admins" TO "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."subsections" TO "anon", "authenticated";

REVOKE ALL ON TABLE "public"."subsections" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."subsections" TO "postgres";

GRANT SELECT ON TABLE "public"."subsections" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."subsections" TO "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."user_activity_notes" TO "anon", "authenticated";

REVOKE ALL ON TABLE "public"."user_activity_notes" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."user_activity_notes" TO "postgres";

GRANT SELECT ON TABLE "public"."user_activity_notes" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."user_activity_notes" TO "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."users" TO "anon", "authenticated";

REVOKE ALL ON TABLE "public"."users" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."users" TO "postgres";

GRANT SELECT ON TABLE "public"."users" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."users" TO "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."activities_public" TO "anon", "authenticated";

REVOKE ALL ON TABLE "public"."activities_public" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."activities_public" TO "postgres";

GRANT SELECT ON TABLE "public"."activities_public" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."activities_public" TO "service_role";

REVOKE ALL ON TABLE "public"."activity_solutions" FROM "authenticated";

GRANT SELECT ON TABLE "public"."activity_solutions" TO "authenticated";

REVOKE ALL ON TABLE "public"."activity_solutions" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."activity_solutions" TO "postgres";

GRANT SELECT ON TABLE "public"."activity_solutions" TO "powersync_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."activity_solutions" TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT ON TABLES TO "powersync_role";

ALTER TABLE "public"."activities"
  ADD CONSTRAINT "activities_solution_valid" CHECK (((solution IS NULL) OR public.valid_activity_solution(solution)));

ALTER TABLE "public"."user_activity_notes"
  ADD CONSTRAINT "user_activity_notes_tags_valid" CHECK (public.valid_activity_tags(tags));

