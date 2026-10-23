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

    -- Keep the answer for manual grading until a solution is configured.
    if solution_geo is null then
        return new;
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
