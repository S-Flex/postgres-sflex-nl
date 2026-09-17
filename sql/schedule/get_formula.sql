-- The version of each schedule.formula code that applies at p_at: the newest
-- active or archived row created at or before that moment (the rule of
-- catalog.get_formula, on the schedule twin). Draft and pending-approval never
-- apply. One row per code, none when no version applied yet. First reader:
-- schedule.get_schedule_lane_items, for the lag formula of a view code
-- (formula_code 'lag-<view_code>', docs/schedule-base.md §1).
drop function if exists schedule.get_formula(text[], timestamp with time zone);

create function schedule.get_formula(p_formula_codes text[], p_at timestamp with time zone DEFAULT now())
    returns TABLE(formula_code text, formula_id integer, version integer, version_status text, created_at timestamp with time zone, formula_json jsonb, formula_level integer)
    stable
    language sql
as $$
    WITH applying AS (
        SELECT DISTINCT ON (f.formula_code)
               f.formula_code, f.formula_id, f.version, f.version_status,
               f.created_at, f.formula_json, f.formula_level
        FROM schedule.formula f
        WHERE f.formula_code = ANY (p_formula_codes)
          AND f.version_status IN ('active', 'archived')
          AND f.created_at <= p_at
        ORDER BY f.formula_code, f.created_at DESC, f.version DESC
    )
    SELECT a.formula_code, a.formula_id, a.version, a.version_status,
           a.created_at, a.formula_json, a.formula_level
    FROM applying a
    ORDER BY a.formula_level, a.formula_code;
$$;

alter function schedule.get_formula(text[], timestamp with time zone) owner to xfw3;
