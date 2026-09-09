-- The constants of a setting_json: its numeric keys. That is what a board
-- evaluates with — evaluate_many_nas rejects strings, so the formula, the
-- names and whatever else the setting carries stay out.
create or replace function production.get_setting_numbers(p_setting_json jsonb) returns jsonb
    immutable
    language sql
as $$
    SELECT coalesce(jsonb_object_agg(e.key, e.value)
                    FILTER (WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
    FROM jsonb_each(coalesce(p_setting_json, '{}'::jsonb)) e
$$;

alter function production.get_setting_numbers(jsonb) owner to xfw3;
