ALTER TABLE public.activities
  DROP CONSTRAINT activities_points_check;

ALTER TABLE public.answers
  DROP CONSTRAINT answers_points_check;

CREATE OR REPLACE FUNCTION public.grade_answer (
  p_answer_id uuid,
  p_points    integer
)
  RETURNS public.answers
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
declare
    target_answer public.answers;
    max_points integer;
    updated_answer public.answers;
begin
    if (select auth.uid()) is null then
        raise exception 'You must be authenticated';
    end if;

    select *
    into target_answer
    from public.answers
    where id = p_answer_id;

    if not found then
        raise exception 'Answer not found';
    end if;

    if not public.can_admin_activity(target_answer.activity_id) then
        raise exception 'You do not have permission to grade this answer';
    end if;

    select points
    into max_points
    from public.activities
    where id = target_answer.activity_id;

    if max_points is not null
        and (p_points < least(max_points, 0)
            or p_points > greatest(max_points, 0)) then
        raise exception 'Points outside activity range'
            using errcode = '22023';
    end if;

    update public.answers
    set
        points = p_points,
        graded_by = (select auth.uid()),
        graded_at = now()
    where id = p_answer_id
    returning *
    into updated_answer;

    return updated_answer;
end;
$function$;
