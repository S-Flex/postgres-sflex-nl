-- The status history of a lane item (docs/schedule-base.md §9): the
-- planner releases an item to the nesting software, legacy.crud_nest marks
-- it nested when its first nest lands. Append-only: one row per change, the
-- latest row is the status; the vocabulary is action.lookup
-- lookup_lane_item_status (plan, released, nested). One element per event:
--   {"track_by": 1, "data": {"lane_item_id": 8842, "status": "released",
--                            "moved_by": 12, "moved_at": "2026-09-09T13:00:00+02:00"}}
-- moved_at defaults to now, moved_by (the contact) may be null. There is no
-- crud: an event is only ever added.
--
-- A released item without a time of its own takes the release moment as its
-- start_offset_in_seconds (seconds since the local midnight of its lane
-- date, kept inside the day), so it has a moment before its nests arrive:
-- a nest lands on the item released last before it was nested.
drop function if exists action.crud_lane_item_event(jsonb, boolean);

create function action.crud_lane_item_event(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, lane_item_event_id bigint, lane_item_id bigint, status text, moved_at timestamp with time zone)
	language sql
as $$
    WITH payload AS (
        SELECT row_number() OVER (ORDER BY coalesce((t.element ->> 'track_by')::integer, 0))::integer AS param_id,
               coalesce((t.element ->> 'track_by')::integer, 0) AS track_by,
               te.lane_item_id, te.status, te.moved_by,
               coalesce(te.moved_at, now()) AS moved_at
        FROM jsonb_array_elements(p_param_json) AS t(element)
        CROSS JOIN LATERAL jsonb_to_record(coalesce(t.element -> 'data', '{}'::jsonb)) AS te(
            lane_item_id bigint, status text, moved_by integer, moved_at timestamp with time zone)
    ),
    inserted AS (
        INSERT INTO action.lane_item_event (lane_item_id, status, moved_at, moved_by)
        SELECT p.lane_item_id, p.status, p.moved_at, p.moved_by
        FROM payload p
        ORDER BY p.param_id
        RETURNING lane_item_event_id, lane_item_id, status, moved_at
    ),
    -- the release moment becomes the time of an item without one
    timed AS (
        UPDATE action.lane_item li
        SET start_offset_in_seconds = least(86399, greatest(0,
                extract(epoch FROM (p.moved_at AT TIME ZONE 'Europe/Amsterdam') - l.lane_date::timestamp)::integer))
        FROM payload p, action.lane l
        WHERE p.status = 'released'
          AND li.lane_item_id = p.lane_item_id
          AND l.lane_id = li.lane_id
          AND li.start_offset_in_seconds IS NULL
        RETURNING li.lane_item_id
    )
    SELECT p.param_id, p.track_by, i.lane_item_event_id, i.lane_item_id, i.status, i.moved_at
    FROM payload p
    JOIN inserted i ON i.lane_item_id = p.lane_item_id AND i.status = p.status AND i.moved_at = p.moved_at
    WHERE NOT p_no_results
    ORDER BY p.param_id;
$$;

alter function action.crud_lane_item_event(jsonb, boolean) owner to xfw3;
