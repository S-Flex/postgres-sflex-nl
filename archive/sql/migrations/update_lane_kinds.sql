-- ============================================================
-- Stap 3 van docs/plan-lane-model.md: twee soorten lanes.
-- action.lane keeps lane_id and lane_date; the kind sits in exactly one
-- subtype row: resource_lane (machine-day, resource_path) or
-- imposition_group_lane (group-day, imposition_group_id = material_id alias).
-- Migration: 1.029 lanes with a resource_path -> resource_lane; 780 group
-- lanes -> imposition_group_lane through the group of their item; then
-- lane.resource_path and its indexes go. Every reader and writer of the lane
-- kind follows: generate_production_plan, crud_object, get_plan_lanes,
-- get_production_plan, generate_plan, crud_lane_item, crud_nest.
-- Baseline of every board read taken 2026-09-05T11:33:35.375Z (row counts and md5 over
-- the rows) for the checks below.
-- ============================================================

BEGIN;

-- 1. the subtype tables
-- The machine-day kind of lane (docs/plan-lane-model.md, stap 3): the lane
-- plans this machine, wherever it physically stands — a foil plan can carry a
-- printer standing in the sheet hall (plan_lane hangs the lane under both
-- boards). Snapshot at planning time (docs/resource-path.md). One lane per
-- machine per day: the creators (mock.generate_production_plan,
-- action.crud_object) look the lane up on (lane_date, resource_path) before
-- they make one.
create table action.resource_lane
(
	lane_id bigint
		primary key
		references action.lane
			on delete cascade,
	resource_path ltree not null
);

comment on table action.resource_lane is 'The machine of a lane (relation.resource.resource_path), recorded at planning time. A lane has this row or an imposition_group_lane row, never both.';

alter table action.resource_lane owner to xfw3;

create index idx_resource_lane_resource_path
	on action.resource_lane (resource_path);

create index idx_resource_lane_resource_path_gist
	on action.resource_lane using gist (resource_path);

-- The group-day kind of lane (docs/plan-lane-model.md, stap 3): the lane of
-- one imposition group on the print schedule (75) and the impose plan (76).
-- imposition_group_id is for now an alias of material_id (the groups were
-- seeded 1:1 from the materials); the real groups from the xbom follow later.
create table action.imposition_group_lane
(
	lane_id bigint
		primary key
		references action.lane
			on delete cascade,
	imposition_group_id integer not null
);

comment on table action.imposition_group_lane is 'The imposition group of a lane. A lane has this row or a resource_lane row, never both.';

alter table action.imposition_group_lane owner to xfw3;

create index idx_imposition_group_lane_group
	on action.imposition_group_lane (imposition_group_id);

-- 2. the migration
insert into action.resource_lane (lane_id, resource_path)
select l.lane_id, l.resource_path
from action.lane l
where l.resource_path is not null;

insert into action.imposition_group_lane (lane_id, imposition_group_id)
select l.lane_id, min(g.imposition_group_id)
from action.lane l
join action.lane_item li on li.lane_id = l.lane_id
join action.imposition_group_lane_item g on g.lane_item_id = li.lane_item_id
where l.resource_path is null
group by l.lane_id;

-- every lane has exactly one kind, or the transaction stops here
do $$
declare
    v_lanes integer; v_kinds integer; v_both integer;
begin
    select count(*) into v_lanes from action.lane;
    select count(*) into v_kinds from (select lane_id from action.resource_lane union all select lane_id from action.imposition_group_lane) k;
    select count(*) into v_both from action.resource_lane r join action.imposition_group_lane g using (lane_id);
    if v_lanes <> v_kinds or v_both <> 0 then
        raise exception 'lane kinds do not add up: % lanes, % kind rows, % lanes with both kinds', v_lanes, v_kinds, v_both;
    end if;
    raise notice 'lane kinds ok: % lanes, % resource_lane + % imposition_group_lane', v_lanes,
        (select count(*) from action.resource_lane), (select count(*) from action.imposition_group_lane);
end $$;

drop index action.uq_lane_date_resource_path;
drop index action.idx_lane_resource_path_gist;
alter table action.lane drop column resource_path;
comment on table action.lane is 'One strip of time on one day. What the strip is for says exactly one of the two subtype rows: resource_lane (a machine-day) or imposition_group_lane (a material / imposition group). Which plans show the lane, and in what order, says plan_lane.';
comment on column action.lane.lane_date is 'The day of this strip of time. A lane is one machine-day (resource_lane) or one group-day (imposition_group_lane); which plans show it says plan_lane.';

-- 3. the readers and writers
drop function if exists mock.generate_production_plan(date, text, text);
create function mock.generate_production_plan(p_date date, p_step text DEFAULT 'print'::text, p_line_type text DEFAULT 'sheet'::text) returns TABLE(plan_id bigint, lane_id bigint, sort_order numeric)
	language plpgsql
as $$
#variable_conflict use_column
declare
    v_plan_id bigint;
begin
    -- A production plan for one day and one step. Lanes are machine-days:
    -- created once per machine per day, then hung under this plan; a lane
    -- another plan already made is reused (docs/plan-production-schedule.md).
    insert into action.plan (plan_date, steps, type, line_type)
    values (p_date, array[p_step], 'production-plan', p_line_type)
    returning plan_id into v_plan_id;

    -- ensure the machine-day lane of every active resource of the step: the
    -- lane and its resource_lane row, ids drawn up front so the two inserts
    -- pair without a temp table
    with missing as (
        select r.resource_path,
               nextval(pg_get_serial_sequence('action.lane', 'lane_id')) as lane_id
        from relation.resource r
        join relation.production_line pl on pl.line_id = r.line_id
        where r.active and r.resource_path is not null
          and r.step = p_step and pl.line_type = p_line_type
          and not exists (select 1
                          from action.lane l
                          join action.resource_lane rl on rl.lane_id = l.lane_id
                          where l.lane_date = p_date and rl.resource_path = r.resource_path)
    ),
    new_lane as (
        insert into action.lane (lane_id, lane_date)
        overriding system value
        select m.lane_id, p_date from missing m
        returning lane_id
    )
    insert into action.resource_lane (lane_id, resource_path)
    select m.lane_id, m.resource_path from missing m;

    -- hang them under the plan, in the order the resources carry
    return query
    insert into action.plan_lane (plan_id, lane_id, sort_order)
    select v_plan_id, l.lane_id,
           row_number() over (order by (r.resource_json ->> 'pv2_order')::numeric nulls last, r.resource_name)::numeric
    from relation.resource r
    join relation.production_line pl on pl.line_id = r.line_id
    join action.resource_lane rl on rl.resource_path = r.resource_path
    join action.lane l on l.lane_id = rl.lane_id and l.lane_date = p_date
    where r.active and r.resource_path is not null
      and r.step = p_step and pl.line_type = p_line_type
    returning plan_id, lane_id, sort_order;
end;
$$;

alter function mock.generate_production_plan(date, text, text) owner to xfw3;

drop function if exists action.crud_object(jsonb, boolean);
create or replace function action.crud_object(p_param_json jsonb, p_no_results boolean DEFAULT false) returns jsonb
	language plpgsql
as $$
DECLARE
    result          jsonb;
    last_updated_at timestamp;
BEGIN
    -- ============================================================
    -- normalize every payload element into one set. resource_uid is
    -- never sent directly by the caller — only the pv2 resource_id is —
    -- so it is resolved here via relation.resource.pv2_id.
    -- ============================================================
    CREATE TEMP TABLE param_table ON COMMIT DROP AS
    SELECT
        (el ->> 'plannable_item_id')::integer                          AS plannable_item_id,
        el ->> 'crud'                                                   AS crud,
        (el ->> 'domain_id')::integer                                   AS domain_id,
        (el ->> 'company_id')::integer                                  AS company_id,
        (el ->> 'contact_id')::integer                                  AS contact_id,
        (el ->> 'team_id')::bigint                                      AS team_id,
        (el ->> 'section_id')::integer                                  AS section_id,
        (el ->> 'batch_id')::integer                                    AS batch_id,
        el ->> 'machine_type'                                            AS machine_type,
        res.resource_uid,
        COALESCE((el ->> 'is_fixed_offset')::boolean, false)             AS is_fixed_offset,
        (el ->> 'deleted_at') IS NOT NULL                                AS is_delete,
        jsonb_set(el, '{data}', (el ->> 'data')::jsonb, true)            AS action_json,
        (el ->> 'updated_at')::timestamp AT TIME ZONE 'Europe/Amsterdam' AS updated_at
    FROM jsonb_array_elements(p_param_json) AS el
    LEFT JOIN relation.resource res
           ON res.resource_json ->> 'pv2_id' = el ->> 'resource_id';

    -- ============================================================
    -- deletes: rows flagged with deleted_at
    -- ============================================================
    DELETE FROM action.object o
    USING param_table pt
    WHERE pt.crud = 'merge'
      AND pt.is_delete
      AND (o.action_json ->> 'plannable_item_id')::integer = pt.plannable_item_id;

    -- ============================================================
    -- upserts: rank continues from the existing count per
    -- resource_uid + day, then increments per row in updated_at order —
    -- same convention as generate_planning_objects. IS NOT DISTINCT FROM
    -- (instead of =) so rows without a resource_uid are grouped and
    -- ranked correctly instead of each restarting at 0.
    -- offset_in_seconds is always computed from start_at relative to
    -- 06:00 Amsterdam of that day — the canonical planning time field —
    -- never taken from the payload. Everything written through crud_object
    -- is atomic by definition, so is_atomic is hardcoded true.
    -- ============================================================
    WITH existing_rank AS (
        SELECT
            o.resource_uid,
            (o.start_at AT TIME ZONE 'Europe/Amsterdam')::date AS day,
            count(*)                                            AS cnt
        FROM action.object o
        WHERE o.parent_action_id IS NULL
        GROUP BY 1, 2
    ),
    batch_rows AS (
        SELECT
            pt.*,
            (pt.action_json ->> 'start_date')::timestamp AT TIME ZONE 'Europe/Amsterdam' AS start_at_local,
            ((pt.action_json ->> 'start_date')::timestamp AT TIME ZONE 'Europe/Amsterdam')::date AS day
        FROM param_table pt
        WHERE pt.crud = 'merge' AND NOT pt.is_delete
    ),
    ranked AS (
        SELECT
            br.*,
            EXTRACT(EPOCH FROM (br.start_at_local - (br.day + time '06:00')))::integer AS offset_in_seconds,
            row_number() OVER (
                PARTITION BY br.resource_uid, br.day
                ORDER BY br.updated_at NULLS FIRST
            ) AS batch_seq
        FROM batch_rows br
    )
    INSERT INTO action.object (
        domain_id, company_id, contact_id, team_id, section_id,
        action_json, start_at, end_at, batch_id,
        resource_uid, resource_plan_rank, is_fixed_offset, offset_in_seconds, is_atomic
    )
    SELECT
        r.domain_id, r.company_id, r.contact_id, r.team_id, r.section_id,
        r.action_json,
        r.start_at_local,
        (r.action_json ->> 'end_date')::timestamp AT TIME ZONE 'Europe/Amsterdam',
        r.batch_id,
        r.resource_uid,
        (COALESCE(er.cnt, 0) + r.batch_seq) * 1000,
        r.is_fixed_offset,
        r.offset_in_seconds,
        true
    FROM ranked r
    LEFT JOIN existing_rank er
           ON er.resource_uid IS NOT DISTINCT FROM r.resource_uid
          AND er.day          IS NOT DISTINCT FROM r.day
    ON CONFLICT (((action_json->>'plannable_item_id')::integer))
    DO UPDATE SET
        action_json        = EXCLUDED.action_json,
        start_at           = EXCLUDED.start_at,
        end_at             = EXCLUDED.end_at,
        batch_id           = EXCLUDED.batch_id,
        resource_uid       = EXCLUDED.resource_uid,
        resource_plan_rank = EXCLUDED.resource_plan_rank,
        is_fixed_offset    = EXCLUDED.is_fixed_offset,
        offset_in_seconds  = EXCLUDED.offset_in_seconds,
        is_atomic          = true;

    -- ============================================================
    -- resolve parent_action_id now that every row in this batch
    -- (parents included, regardless of arrival order) exists.
    -- chain: printer is root; coater/laminator is child of printer;
    -- cutter is child of coater/laminator if one exists for the batch,
    -- else child of printer
    -- ============================================================
    UPDATE action.object o
    SET parent_action_id = parent.action_id
    FROM param_table pt
    CROSS JOIN LATERAL (
        SELECT p.action_id
        FROM action.object p
        WHERE p.batch_id = pt.batch_id
          AND (
              (pt.machine_type IN ('coater', 'laminator') AND (p.action_json ->> 'machine_type') = 'printer')
              OR (pt.machine_type = 'cutter' AND (p.action_json ->> 'machine_type') IN ('coater', 'laminator'))
          )
        ORDER BY p.action_id DESC
        LIMIT 1
    ) parent
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND pt.batch_id IS NOT NULL
      AND pt.machine_type IN ('coater', 'laminator', 'cutter')
      AND (o.action_json ->> 'plannable_item_id')::integer = pt.plannable_item_id;

    -- cutter fallback: no coater/laminator sibling found for this batch,
    -- so fall back to the printer directly
    UPDATE action.object o
    SET parent_action_id = printer.action_id
    FROM param_table pt
    CROSS JOIN LATERAL (
        SELECT p.action_id
        FROM action.object p
        WHERE p.batch_id = pt.batch_id
          AND (p.action_json ->> 'machine_type') = 'printer'
        ORDER BY p.action_id DESC
        LIMIT 1
    ) printer
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND pt.batch_id IS NOT NULL
      AND pt.machine_type = 'cutter'
      AND o.parent_action_id IS NULL
      AND (o.action_json ->> 'plannable_item_id')::integer = pt.plannable_item_id;

    -- ============================================================
    -- the new plan model: the same items as action.plan -> lane ->
    -- lane_item (level 0), with their nests and dependencies. One
    -- production plan per day and line type covering every step in the
    -- payload; one lane per resource (its resource_path); one lane_item
    -- per plannable item, found again on the next payload through
    -- (source 'pv2', source_ref plannable_item_id). Only type 'batch'
    -- items are planning items; batch-reserved / batch-initiated are not.
    -- Items whose resource has no resource_path yet cannot get a lane and
    -- are skipped until it has one.
    -- ============================================================
    CREATE TEMP TABLE new_item ON COMMIT DROP AS
    SELECT pt.plannable_item_id,
           pt.plannable_item_id::text                                              AS source_ref,
           pt.batch_id,
           pt.machine_type,
           r.resource_path,
           r.step,
           -- the plan's line type is the ORDER's, from the batch; a machine can
           -- physically stand in another department (a foil order on a printer
           -- in the sheet hall still belongs to the foil plan)
           coalesce(bpl.line_type, pl.line_type) as line_type,
           pl.line_type                              as physical_line_type,
           ((pt.action_json ->> 'start_date')::timestamp AT TIME ZONE 'Europe/Amsterdam')                     AS start_at,
           -- start_date is Amsterdam local time; its date IS the plan date.
           -- No AT TIME ZONE here: the date cast would run in the session
           -- timezone (GMT) and shift items starting just after midnight
           -- to the previous day, blowing the 0..86399 offset check.
           ((pt.action_json ->> 'start_date')::timestamp)::date                                                AS plan_date,
           (pt.action_json ->> 'start_date')::timestamp                                                        AS start_local,
           (pt.action_json ->> 'end_date')::timestamp                                                          AS end_local,
           pt.is_fixed_offset,
           pt.action_json -> 'data' -> 'batched_amounts'                                                       AS batched_amounts
    FROM param_table pt
    JOIN relation.resource r          ON r.resource_uid = pt.resource_uid
    JOIN relation.production_line pl  ON pl.line_id = r.line_id
    LEFT JOIN legacy.batch b          ON b.batch_id = pt.batch_id
    LEFT JOIN relation.production_line bpl ON bpl.line_id = (b.batch_json ->> 'production_line_id')::integer
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND COALESCE(pt.action_json ->> 'type', 'batch') = 'batch'
      AND r.resource_path IS NOT NULL
      AND (pt.action_json ->> 'start_date') IS NOT NULL;

    -- deletes: the item, its nests and its edges (edges cascade)
    DELETE FROM action.imposition_lane_item nli
    USING action.lane_item li, param_table pt
    WHERE nli.lane_item_id = li.lane_item_id
      AND li.source = 'pv2' AND li.source_ref = pt.plannable_item_id::text
      AND pt.crud = 'merge' AND pt.is_delete;

    DELETE FROM action.lane_item li
    USING param_table pt
    WHERE li.source = 'pv2' AND li.source_ref = pt.plannable_item_id::text
      AND pt.crud = 'merge' AND pt.is_delete;

    -- the day's production plan per line type: the newest one, or a new one
    -- (the material-resource-plan is calendar-driven and created in
    -- site.refresh_derived_data, ahead of the plannable items)
    INSERT INTO action.plan (plan_date, steps, type, line_type)
    SELECT d.plan_date, array_agg(DISTINCT d.step ORDER BY d.step), 'production-plan', d.line_type
    FROM (SELECT ni.plan_date, ni.step, ni.line_type FROM new_item ni
          UNION ALL
          SELECT ni.plan_date, ni.step, ni.physical_line_type FROM new_item ni
          WHERE ni.physical_line_type IS DISTINCT FROM ni.line_type) d
    WHERE NOT EXISTS (SELECT 1 FROM action.plan p
                      WHERE p.plan_date = d.plan_date AND p.type = 'production-plan'
                        AND p.line_type IS NOT DISTINCT FROM d.line_type)
    GROUP BY d.plan_date, d.line_type;

    -- and every step of the payload in the plan's steps
    UPDATE action.plan p
    SET steps = (SELECT array_agg(DISTINCT s ORDER BY s)
                 FROM unnest(p.steps || x.steps) AS s)
    FROM (SELECT d.plan_date, d.line_type, array_agg(DISTINCT d.step) AS steps
          FROM (SELECT ni.plan_date, ni.step, ni.line_type FROM new_item ni
                UNION ALL
                SELECT ni.plan_date, ni.step, ni.physical_line_type FROM new_item ni
                WHERE ni.physical_line_type IS DISTINCT FROM ni.line_type) d
          GROUP BY d.plan_date, d.line_type) x
    WHERE p.plan_id = (SELECT p2.plan_id FROM action.plan p2
                       WHERE p2.plan_date = x.plan_date AND p2.type = 'production-plan'
                         AND p2.line_type IS NOT DISTINCT FROM x.line_type
                       ORDER BY p2.plan_id DESC LIMIT 1)
      AND NOT (p.steps @> x.steps);

    -- the plan of every item, resolved once
    CREATE TEMP TABLE item_plan ON COMMIT DROP AS
    SELECT d.*,
           (SELECT p.plan_id FROM action.plan p
            WHERE p.plan_date = d.plan_date AND p.type = 'production-plan'
              AND p.line_type IS NOT DISTINCT FROM d.line_type
            ORDER BY p.plan_id DESC LIMIT 1) AS plan_id,
           CASE WHEN d.physical_line_type IS DISTINCT FROM d.line_type THEN
           (SELECT p.plan_id FROM action.plan p
            WHERE p.plan_date = d.plan_date AND p.type = 'production-plan'
              AND p.line_type IS NOT DISTINCT FROM d.physical_line_type
            ORDER BY p.plan_id DESC LIMIT 1) END AS physical_plan_id
    FROM new_item d;

    -- the machine-day lane of every item, created once, then hung under
    -- the order's plan AND the physical department's plan, so both boards
    -- see the machine's full occupation
    WITH missing AS (
        SELECT DISTINCT ip.plan_date, ip.resource_path
        FROM item_plan ip
        WHERE NOT EXISTS (SELECT 1
                          FROM action.lane l
                          JOIN action.resource_lane rl ON rl.lane_id = l.lane_id
                          WHERE l.lane_date = ip.plan_date AND rl.resource_path = ip.resource_path)
    ),
    with_id AS (
        SELECT m.plan_date, m.resource_path,
               nextval(pg_get_serial_sequence('action.lane', 'lane_id')) AS lane_id
        FROM missing m
    ),
    new_lane AS (
        INSERT INTO action.lane (lane_id, lane_date)
        OVERRIDING SYSTEM VALUE
        SELECT w.lane_id, w.plan_date FROM with_id w
        RETURNING lane_id
    )
    INSERT INTO action.resource_lane (lane_id, resource_path)
    SELECT w.lane_id, w.resource_path FROM with_id w;

    INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
    SELECT x.plan_id, x.lane_id,
           COALESCE((SELECT max(pl2.sort_order) FROM action.plan_lane pl2 WHERE pl2.plan_id = x.plan_id), 0)
             + row_number() OVER (PARTITION BY x.plan_id ORDER BY x.lane_id)
    FROM (SELECT DISTINCT pp.plan_id, l.lane_id
          FROM (SELECT ip.plan_id, ip.plan_date, ip.resource_path FROM item_plan ip
                UNION
                SELECT ip.physical_plan_id, ip.plan_date, ip.resource_path FROM item_plan ip
                WHERE ip.physical_plan_id IS NOT NULL) pp
          JOIN action.resource_lane rl ON rl.resource_path = pp.resource_path
          JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = pp.plan_date) x
    WHERE NOT EXISTS (SELECT 1 FROM action.plan_lane pl3
                      WHERE pl3.plan_id = x.plan_id AND pl3.lane_id = x.lane_id);

    -- the items: offset in seconds since the plan date's local midnight,
    -- duration from the pv2 end, pinned when pv2 fixes the offset, never
    -- split. sort_order is a placeholder here; the lanes are renumbered
    -- below (it is unique per lane).
    INSERT INTO action.lane_item AS li
        (lane_id, sort_order, start_offset_in_seconds, duration_in_seconds,
         is_pinned, no_split, level, source, source_ref)
    SELECT l.lane_id,
           -1 * ip.plannable_item_id,
           EXTRACT(EPOCH FROM (ip.start_local - ip.plan_date::timestamp))::integer,
           GREATEST(COALESCE(EXTRACT(EPOCH FROM (ip.end_local - ip.start_local))::integer, 0), 0),
           ip.is_fixed_offset, true, 0, 'pv2', ip.source_ref
    FROM item_plan ip
    JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date
    ON CONFLICT (source, source_ref) DO UPDATE SET
        lane_id                 = EXCLUDED.lane_id,
        sort_order              = EXCLUDED.sort_order,
        start_offset_in_seconds = EXCLUDED.start_offset_in_seconds,
        duration_in_seconds     = EXCLUDED.duration_in_seconds,
        is_pinned               = EXCLUDED.is_pinned;

    -- renumber every touched lane by start, in two steps so the unique
    -- (lane_id, sort_order) never collides on the way
    UPDATE action.lane_item li
    SET sort_order = -1 * li.lane_item_id
    WHERE li.level = 0
      AND li.lane_id IN (SELECT DISTINCT l.lane_id FROM item_plan ip
                         JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date);

    UPDATE action.lane_item li
    SET sort_order = x.rank * 1000
    FROM (SELECT li2.lane_item_id,
                 row_number() OVER (PARTITION BY li2.lane_id
                                    ORDER BY li2.start_offset_in_seconds, li2.lane_item_id) AS rank
          FROM action.lane_item li2
          WHERE li2.level = 0
            AND li2.lane_id IN (SELECT DISTINCT l.lane_id FROM item_plan ip
                                JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date)) x
    WHERE li.lane_item_id = x.lane_item_id;

    -- the nests of the items: replaced as a set
    DELETE FROM action.imposition_lane_item nli
    USING action.lane_item li, item_plan ip
    WHERE nli.lane_item_id = li.lane_item_id
      AND li.source = 'pv2' AND li.source_ref = ip.source_ref;

    INSERT INTO action.imposition_lane_item (imposition_id, lane_item_id, sort_order)
    SELECT DISTINCT ON ((ba.value ->> 'nest_id')::bigint, li.lane_item_id)
           (ba.value ->> 'nest_id')::bigint, li.lane_item_id, (ba.value ->> 'sequence')::numeric
    FROM item_plan ip
    JOIN action.lane_item li ON li.source = 'pv2' AND li.source_ref = ip.source_ref
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(ip.batched_amounts, '[]'::jsonb)) AS ba(value)
    WHERE (ba.value ->> 'nest_id') IS NOT NULL
    ORDER BY (ba.value ->> 'nest_id')::bigint, li.lane_item_id, (ba.value ->> 'sequence')::numeric;

    -- the chain: coater/laminator after the printer of the batch, cutter
    -- after the coater/laminator of the batch, else after the printer.
    -- Edges of the items are replaced as a set.
    DELETE FROM action.lane_item_dependency d
    USING action.lane_item li, item_plan ip
    WHERE d.to_lane_item_id = li.lane_item_id
      AND li.source = 'pv2' AND li.source_ref = ip.source_ref;

    INSERT INTO action.lane_item_dependency (from_lane_item_id, to_lane_item_id)
    SELECT parent.lane_item_id, child.lane_item_id
    FROM item_plan ip
    JOIN action.lane_item child ON child.source = 'pv2' AND child.source_ref = ip.source_ref
    CROSS JOIN LATERAL (
        SELECT p.lane_item_id
        FROM action.object o
        JOIN action.lane_item p ON p.source = 'pv2' AND p.source_ref = (o.action_json ->> 'plannable_item_id')
        WHERE o.batch_id = ip.batch_id
          AND (   (ip.machine_type IN ('coater', 'laminator') AND o.action_json ->> 'machine_type' = 'printer')
               OR (ip.machine_type = 'cutter' AND o.action_json ->> 'machine_type' IN ('coater', 'laminator', 'printer')))
        ORDER BY CASE WHEN o.action_json ->> 'machine_type' IN ('coater', 'laminator') THEN 0 ELSE 1 END,
                 o.action_id DESC
        LIMIT 1
    ) parent
    WHERE ip.batch_id IS NOT NULL
      AND ip.machine_type IN ('coater', 'laminator', 'cutter')
    ON CONFLICT DO NOTHING;

    -- ============================================================
    -- fill print_production_unit_id in legacy.batch if it is still null
    -- ============================================================
    UPDATE legacy.batch b
    SET batch_json = jsonb_set(
        b.batch_json,
        '{print_production_unit_id}',
        to_jsonb((pt.action_json ->> 'resource_id')::int)
    )
    FROM param_table pt
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND (pt.action_json ->> 'machine_type') = 'printer'
      AND (pt.action_json ->> 'resource_id') IS NOT NULL
      AND pt.batch_id IS NOT NULL
      AND b.batch_id = pt.batch_id
      AND (b.batch_json ->> 'print_production_unit_id') IS NULL;

    SELECT MAX(pt.updated_at) INTO last_updated_at
    FROM param_table pt;

    IF last_updated_at IS NOT NULL THEN
        UPDATE mapping.persistent_vars
        SET value = last_updated_at - INTERVAL '2 minutes'
        WHERE key = 'last_plannable_item_updated_at';
    END IF;

    IF p_no_results THEN
        RETURN '[]'::jsonb;
    END IF;

    SELECT jsonb_agg(to_jsonb(pt.*))
    INTO result
    FROM param_table pt;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

alter function action.crud_object(jsonb, boolean) owner to xfw3;

drop function if exists action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text, text[]);
-- One read for the lanes (labels) of every plan board: print_schedule,
-- impose_plan, impose_resource_plan, production_resource_plan and whatever
-- follows. Moved from mock to action: the lane model lives here.
--
-- Two modes, switched by p_steps:
--   * p_steps null — material lanes: one row per planned moment of the
--     newest plan of the day (p_plan_type), reached through
--     lane_item.source_ref (<material_impose_plan_id>:<date>), plus the
--     tenant noop windows. Feeds print_schedule and impose_plan
--     (imposition_group_id is the material_id alias until the xbom groups
--     arrive).
--   * p_steps set — resource lanes: one row per resource whose step is in
--     the list, line via path position 1, tenant via path position 0 (the
--     site abb). For a 'production-plan' the day's plan is the source: only
--     resources with a lane in that plan, lane_id and plan_lane.sort_order
--     ride along. For other plan types (impose: the material plan has no
--     resource lanes) every resource of the steps is a lane, lane_id null.
--
-- The offset rule: only a fixed group (coalesce(item, class moment from
-- lookup_nest_moments)) or a pinned item (its own offset) carries
-- start_offset_in_seconds. Every other item is a filler and serves null —
-- the client chains fillers itself (chain_scope), a moved-but-unpinned item
-- springs back on refresh.
--
-- Duration is not computed here. The row carries the formula of its resource
-- and the variables, and the board evaluates — otherwise a drag to another
-- resource could not change the duration. The chaining offset
-- (next_start_offset_in_seconds) belongs to the resource:
-- resource_json.next_start_lag_in_seconds; the connector mechanism replaces
-- this column later.

create function action.get_plan_lanes(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT false, p_plan_type text DEFAULT 'material-resource-plan'::text, p_steps text[] DEFAULT NULL::text[]) returns TABLE(imposition_group_id integer, material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, resource_path ltree, resource_uid text, resource_name text, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, is_fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, lane_item_id bigint, lane_id bigint)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_date  date;
    v_fixed jsonb;
BEGIN
    v_date := (p_until AT TIME ZONE current_setting('TimeZone'))::date;

    -- resource mode: one lane per resource of the steps
    IF p_steps IS NOT NULL THEN
        RETURN QUERY
        WITH tenant AS (
            SELECT (v.value ->> 'tenant_id')::integer AS tenant_id,
                   v.value ->> 'name'                 AS tenant_name,
                   v.value ->> 'abb'                  AS abb
            FROM relation.lookup lk
            CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS v(value)
            WHERE lk.lookup = 'lookup_tenants'
        ),
        the_plan AS (
            -- the newest plan of this date, step, type and line type wins
            SELECT plan_id
            FROM action.plan
            WHERE plan_date = v_date AND p_step = ANY (steps)
              AND type = p_plan_type
              AND (p_line_type IS NULL OR line_type = p_line_type)
            ORDER BY plan_id DESC
            LIMIT 1
        ),
        plan_lane AS (
            -- the machine-day lanes of the plan; a group lane has no row here
            SELECT rl.lane_id, pl.sort_order, rl.resource_path
            FROM the_plan tp
            JOIN action.plan_lane pl USING (plan_id)
            JOIN action.resource_lane rl ON rl.lane_id = pl.lane_id
        )
        SELECT NULL::integer, NULL::integer, NULL::text, NULL::integer,
               t.tenant_id, t.tenant_name,
               r.resource_path, r.resource_uid, r.resource_name,
               NULL::integer, NULL::integer,
               pl.sort_order,
               -- the resource constants the board evaluates with; numbers
               -- only — evaluate_many_nas rejects strings
               coalesce((SELECT jsonb_object_agg(e.key, e.value)
                         FROM jsonb_each(rs.setting_json) e
                         WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb),
               coalesce(rs.setting_json -> 'formula', '[]'::jsonb),
               '{}'::jsonb,
               NULL::text, false,
               -- a lane has no time of its own; the items bring the times
               NULL::integer,
               (r.resource_json ->> 'next_start_lag_in_seconds')::integer,
               NULL::bigint, pl.lane_id
        FROM relation.resource r
        LEFT JOIN plan_lane pl ON pl.resource_path = r.resource_path
        LEFT JOIN LATERAL (
            SELECT s.setting_json FROM production.resource_setting s
            WHERE r.resource_path <@ s.resource_path
            ORDER BY nlevel(s.resource_path) DESC, s.moved_at DESC LIMIT 1
        ) rs ON true
        LEFT JOIN tenant t ON t.abb = ltree2text(subpath(r.resource_path, 0, 1))
        WHERE r.step = ANY (p_steps)
          AND (p_line_type IS NULL OR ltree2text(subpath(r.resource_path, 1, 1)) = p_line_type)
          -- a production plan names its lanes; other plan types have no
          -- resource lanes, so every resource of the steps is a lane
          AND (p_plan_type <> 'production-plan' OR pl.lane_id IS NOT NULL)
          AND (p_tenant_ids IS NULL OR t.tenant_id = ANY (p_tenant_ids))
        ORDER BY t.tenant_id, pl.sort_order NULLS LAST, r.resource_path;
        RETURN;
    END IF;

    -- The default schedule per delivery class: the group label and the moment
    -- the class starts at. A schedule is a template, so this is where a lane
    -- item gets its first time; once the planner moves the item, the item
    -- wins (see the coalesce below).
    SELECT coalesce(jsonb_object_agg(
               v.value ->> 'code',
               jsonb_build_object(
                   'group',  v.value ->> 'is_fixed_group',
                   'offset', v.value #> '{nest_moments,0,nest_time,start_offset_in_seconds}')),
           '{}'::jsonb)
    INTO v_fixed
    FROM production.lookup l
    CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_nest_moments'
      AND (v.value ->> 'is_fixed_group' IS NOT NULL
           OR v.value #>> '{nest_moments,0,nest_time,start_offset_in_seconds}' IS NOT NULL);

    RETURN QUERY
    WITH the_plan AS (
        -- the newest plan of this date, step, type and line type wins
        SELECT plan_id
        FROM action.plan
        WHERE plan_date = v_date AND p_step = ANY (steps)
          AND type = p_plan_type
          AND (p_line_type IS NULL OR line_type = p_line_type)
        ORDER BY plan_id DESC
        LIMIT 1
    ),
    tenant AS (
        SELECT (v.value ->> 'tenant_id')::integer AS tenant_id,
               v.value ->> 'name'                 AS tenant_name
        FROM relation.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS v(value)
        WHERE lk.lookup = 'lookup_tenants'
    ),
    item AS (
        -- one row per planned moment; an extra moment is simply another item
        SELECT l.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
               li.start_offset_in_seconds,
               igli.imposition_group_id,
               -- the pattern row the item was stamped from: source_ref is
               -- <material_impose_plan_id>:<date>, which replaces the old
               -- material_impose_plan_lane detour
               nullif(split_part(li.source_ref, ':', 1), '')::bigint AS material_impose_plan_id
        FROM the_plan tp
        JOIN action.plan_lane l USING (plan_id)
        JOIN action.lane_item li ON li.lane_id = l.lane_id AND li.level = 0
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
        WHERE li.source = 'material-plan'
    ),
    -- one interval check per distinct (start, days) pair of the plan's own
    -- materials instead of one per row: a check costs ~7 ms in
    -- get_interval_dates, so per row it was hundreds of milliseconds. The
    -- extra (null, 1) pair covers materials without a schedule row.
    --
    -- p_tenant_ids goes into get_interval_dates as well, not only into the
    -- anchor below: without it the day-off test there falls back to
    -- coalesce(null, tenants_mandatory_day_off) <@ tenants_mandatory_day_off,
    -- which is always true, so one tenant's day off dropped a working day for
    -- every tenant and shifted the interval for all of them.
    -- MATERIALIZED: referenced once, so the planner would inline it into the
    -- EXISTS below and run the interval check per material row (65 x 4000
    -- buffers) instead of once per pair (16 x)
    allowed_interval AS MATERIALIZED (
        SELECT s.interval_start_date, s.interval_days
        FROM (SELECT DISTINCT mps.interval_start_date,
                     coalesce(nullif(mps.interval_days, 0), 1) AS interval_days
              FROM item i
              JOIN mock.material_impose_plan m ON m.material_impose_plan_id = i.material_impose_plan_id
              JOIN mock.material_print_schedule mps
                   ON mps.material_id = m.material_id
                  AND mps.production_line_id = m.production_line_id
                  AND mps.tenant_id = m.tenant_id
              UNION
              SELECT NULL::date, 1) s
        WHERE NOT p_only_starting_today
           OR EXISTS (
                  SELECT 1
                  FROM action.get_interval_dates(
                           (SELECT min(d.date)
                            FROM action.dates d
                            WHERE d.date >= coalesce(s.interval_start_date, v_date)
                              AND d.is_weekend = false
                              AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')),
                           v_date, s.interval_days, 1, false, false, 0,
                           p_tenant_ids) AS i(interval_date)
                  WHERE i.interval_date = v_date)
    ),
    material_row AS (
        SELECT i.imposition_group_id,
               -- alias: the group id is the material id until the xbom groups arrive
               coalesce(m.material_id, i.imposition_group_id) AS material_id,
               mps.material_name, m.production_line_id,
               m.tenant_id, t.tenant_name,
               m.resource_path, r.resource_uid, r.resource_name,
               mps.delivery_hours, mps.min_delivery_hours, i.sort_order,
               -- the variables the board evaluates with: the resource
               -- constants, the format of the group, and the work itself.
               -- Numbers only — evaluate_many_nas rejects strings.
               coalesce((SELECT jsonb_object_agg(e.key, e.value)
                         FROM jsonb_each(rs.setting_json) e
                         WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
               || coalesce(w.format_json, '{}'::jsonb)
               || jsonb_build_object('specs', coalesce(mpl.line_json -> 'specs', '[]'::jsonb))
                                                       AS param_json,
               coalesce(rs.setting_json -> 'formula', '[]'::jsonb) AS formula,
               -- every impose resource the item may be dragged to, with its
               -- own constants, so the duration follows the gesture
               jsonb_build_object('valid_resources', coalesce((
                   SELECT jsonb_agg(jsonb_build_object('resource_path', vr.resource_path::text,
                                                       'resource_name', vr.resource_name)
                                    || coalesce((SELECT jsonb_object_agg(e.key, e.value)
                                                 FROM jsonb_each(vrs.setting_json) e
                                                 WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
                                    ORDER BY vr.resource_path)
                   FROM relation.resource vr
                   LEFT JOIN LATERAL (
                       SELECT s.setting_json FROM production.resource_setting s
                       WHERE vr.resource_path <@ s.resource_path
                       ORDER BY nlevel(s.resource_path) DESC, s.moved_at DESC LIMIT 1
                   ) vrs ON true
                   WHERE vr.resource_path ~ '*.impose.*'
                     AND subpath(vr.resource_path, 0, 2) = subpath(m.resource_path, 0, 2)
               ), '[]'::jsonb))                        AS data,
               v_fixed -> mps.delivery_hours::text ->> 'group' AS is_fixed_group,
               -- the mutable truth lives on the lane item
               i.is_pinned,
               -- only a fixed group (class moment as default) or a pinned
               -- item has a time of its own; every other item is a filler
               -- and serves null — the client chains fillers itself
               CASE WHEN v_fixed -> mps.delivery_hours::text ->> 'group' IS NOT NULL
                    THEN coalesce(i.start_offset_in_seconds,
                                  (v_fixed -> mps.delivery_hours::text ->> 'offset')::integer)
                    WHEN i.is_pinned THEN i.start_offset_in_seconds
               END                                     AS start_offset_in_seconds,
               -- the chaining offset belongs to the resource; the connector
               -- mechanism replaces this column later
               (r.resource_json ->> 'next_start_lag_in_seconds')::integer
                                                       AS next_start_offset_in_seconds,
               i.lane_item_id, i.lane_id
        FROM item i
        LEFT JOIN mock.material_impose_plan m ON m.material_impose_plan_id = i.material_impose_plan_id
        LEFT JOIN relation.resource r ON r.resource_path = m.resource_path
        -- the speed setting of that resource for that group
        LEFT JOIN LATERAL (
            SELECT s.setting_json FROM production.resource_setting s
            WHERE m.resource_path <@ s.resource_path
              AND (s.imposition_group_id IS NULL OR s.imposition_group_id = i.imposition_group_id)
            ORDER BY nlevel(s.resource_path) DESC,
                     (s.imposition_group_id IS NOT NULL) DESC,
                     s.moved_at DESC
            LIMIT 1
        ) rs ON true
        -- the format of the group: waste and imposition size, first entry that
        -- matches the material width of the resource path
        LEFT JOIN LATERAL (
            SELECT jsonb_build_object(
                       'waste_factor',   (f.value ->> 'waste_factor')::numeric,
                       'imposition_sqm', (f.value ->> 'imposition_sqm')::numeric) AS format_json
            FROM catalog.imposition_group g
            CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.imposition_group_json -> 'waste', '[]'::jsonb)) f
            WHERE g.imposition_group_id = i.imposition_group_id
            ORDER BY (f.value ->> 'width')::numeric DESC
            LIMIT 1
        ) w ON true
        LEFT JOIN mock.material_print_schedule mps
               ON mps.material_id = m.material_id
              AND mps.production_line_id = m.production_line_id
              AND mps.tenant_id = m.tenant_id
        LEFT JOIN mapping.material_production_line mpl
               ON mpl.material_id = m.material_id
              AND mpl.production_line_id = m.production_line_id
        LEFT JOIN tenant t ON t.tenant_id = m.tenant_id
        WHERE (p_tenant_ids IS NULL OR m.tenant_id = ANY (p_tenant_ids))
          -- only materials whose interval says the plan date is a production day
          AND (NOT p_only_starting_today OR EXISTS (
                   SELECT 1 FROM allowed_interval ai
                   WHERE ai.interval_start_date IS NOT DISTINCT FROM mps.interval_start_date
                     AND ai.interval_days = coalesce(nullif(mps.interval_days, 0), 1)))
    )
    SELECT * FROM material_row
    UNION ALL
    -- one row per tenant noop window, newest per slot; removed time the client
    -- lays the timeline around (column names and types come from the first branch)
    SELECT NULL, NULL, NULL, NULL, s.tenant_id, t.tenant_name, NULL, NULL, NULL, NULL, NULL, NULL,
           -- a noop has no formula, so its duration is already in param_json:
           -- the board reads param_json.duration_in_seconds for every row
           jsonb_build_object('specs', '[]'::jsonb,
                              'duration_in_seconds', s.duration_in_seconds),
           '[]'::jsonb, '{}'::jsonb, 'noop', false,
           s.start_offset_in_seconds, s.duration_in_seconds, NULL::bigint, NULL::bigint
    FROM (
        SELECT DISTINCT ON (n.rule_path, n.weekday, n.start_offset_in_seconds)
               n.rule_path::integer AS tenant_id,
               n.start_offset_in_seconds, n.duration_in_seconds
        FROM action.non_working_times n
        WHERE n.type = 'noop'
          AND n.rule_path NOT LIKE '%.%'
          AND n.rule_path IN (SELECT DISTINCT mr.tenant_id::text FROM material_row mr)
          AND (n.weekday IS NULL OR n.weekday = extract(dow FROM v_date)::smallint + 1)
        ORDER BY n.rule_path, n.weekday, n.start_offset_in_seconds,
                 n.non_working_time_id DESC
    ) s
    LEFT JOIN tenant t ON t.tenant_id = s.tenant_id
    WHERE s.duration_in_seconds > 0
    ORDER BY tenant_id, sort_order;
END;
$$;

alter function action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text, text[]) owner to xfw3;

-- Stap 0 of docs/plan-lane-model.md: this mirror was a draft
-- (get_production_schedule on a table nest_lane_item that never existed); it
-- is now the live definition, with one change (stap 2): the impositions of an
-- item come from action.get_lane_item_impositions (current set, inherited or
-- own) instead of a direct read of action.imposition_lane_item.
CREATE OR REPLACE FUNCTION mock.get_production_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_domain_id integer DEFAULT 1)
 RETURNS TABLE(tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, lane_id bigint, step text, level integer, lane_item_id bigint, sort_order numeric, is_pinned boolean, no_split boolean, is_fixed_group text, start_offset_in_seconds integer, duration_in_seconds integer, start_at timestamp with time zone, end_at timestamp with time zone, nest_ids bigint[], nest_count integer, batch_id integer, batch_name text, material_id integer, material_name text, impact_json jsonb, sqm numeric, gross_sqm numeric, part_status_json jsonb, state_json jsonb, group_state_json jsonb, class_names text[], param_json jsonb)
 LANGUAGE plpgsql
 STABLE
 SET jit TO 'off'
AS $function$
#variable_conflict use_column
declare
    v_zone constant text := 'Europe/Amsterdam';
    -- the plan date is the day of the viewed moment; the axis of the board is
    -- that day's local midnight, offsets are seconds since then
    v_date       date := (p_until at time zone 'Europe/Amsterdam')::date;
    v_day_start  timestamp with time zone;
    v_day_end    timestamp with time zone;
    -- the open steps the plan side counts; a lookup later
    v_status_sequences constant integer[] := array[225, 290, 300, 350, 400, 450];
    -- print seconds per gross sqm at standard speed, and the shortest item; a lookup later
    v_standard_seconds_per_sqm constant numeric := 45;
    v_min_duration_in_seconds  constant integer := 900;
    -- legacy.nest width/height are in cm; a lookup later
    v_nest_size_per_sqm        constant numeric := 10000;
    v_state_lookup             jsonb;
begin
    select lk.lookup_json into v_state_lookup
    from relation.lookup lk where lk.lookup = 'lookup_resource_state';

    v_day_start := v_date::timestamp at time zone v_zone;
    v_day_end   := (v_date + 1)::timestamp at time zone v_zone;

    return query
    with the_plan as (
        -- the newest production plan of the day that covers the step
        select p.plan_id
        from action.plan p
        where p.plan_date = v_date
          and p.type = 'production-plan'
          and p_step = any (p.steps)
          and (p_line_type is null or p.line_type = p_line_type)
        order by p.plan_id desc
        limit 1
    ),
    tenant as (
        select (v.value ->> 'tenant_id')::integer             as tenant_id,
               v.value ->> 'name'                             as tenant_name,
               v.value ->> 'abb'                              as abb,
               (v.value ->> 'production_company_id')::integer as production_company_id
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as v(value)
        where lk.lookup = 'lookup_tenants'
    ),
    -- one lane = one machine's day; the live resource is found on its
    -- path, the tenant through its production line. Which machines a plan
    -- shows says plan_lane (a foil plan can carry a printer from the sheet
    -- hall; both boards share the lane and see its full occupation).
    lane as (
        select l.lane_id, pl_l.sort_order, rl.resource_path,
               r.resource_uid, r.resource_name, r.step,
               t.tenant_id, t.tenant_name, t.production_company_id
        from the_plan tp
        join action.plan_lane pl_l on pl_l.plan_id = tp.plan_id
        join action.lane l on l.lane_id = pl_l.lane_id
        join action.resource_lane rl on rl.lane_id = l.lane_id
        join relation.resource r on r.resource_path = rl.resource_path
        -- the site is the first label of the path: the tenant's abb (dk, bh)
        left join tenant t on t.abb = ltree2text(subpath(rl.resource_path, 0, 1))
        where (p_tenant_ids is null or t.tenant_id = any (p_tenant_ids))
    ),
    -- planned items with the nests hung on them
    item as (
        select li.lane_item_id, li.lane_id, li.sort_order, li.is_pinned, li.no_split,
               li.is_fixed_group, li.start_offset_in_seconds, li.duration_in_seconds, li.level,
               (select array_agg(distinct x.imposition_id)
                from action.get_lane_item_impositions(li.lane_item_id) x) as nest_ids
        from action.lane_item li
        join lane on lane.lane_id = li.lane_id
        where li.level = 0
    ),
    -- what the nests of an item say: the batch, the run (amount x area) and
    -- the least advanced status, which names the item's state
    item_nest as (
        select i.lane_item_id,
               min(n.batch_id)                                                          as batch_id,
               min(b.batch_name)                                                        as batch_name,
               sum(coalesce(n.amount, 1) * coalesce(n.width, 0) * coalesce(n.height, 0)) / v_nest_size_per_sqm as run_sqm,
               (array_agg(n.nest_json ->> 'internal_status_code' order by ist.sequence nulls last))[1] as internal_status_code
        from item i
        cross join lateral action.get_lane_item_impositions(i.lane_item_id) nli
        join legacy.nest n on n.nest_id = nli.imposition_id
        left join legacy.batch b on b.batch_id = n.batch_id
        left join mapping.internal_status ist on ist.code = n.nest_json ->> 'internal_status_code' and ist.domain_id = p_domain_id
        group by i.lane_item_id
    ),
    -- one aggregate call per distinct nest set (rows per material of the set)
    agg_rows as materialized (
        -- the aggregate has a nest_ids column of its own, so the set the call
        -- was made for gets its own name
        select ns.nest_ids as lane_nest_ids, a.*
        from (select distinct i.nest_ids from item i where i.nest_ids is not null) ns
        cross join lateral mapping.get_production_orderline_aggregate(
                 p_from             => p_until,
                 p_date_type        => 'nest',
                 p_nest_ids         => ns.nest_ids,
                 p_status_sequences => v_status_sequences,
                 p_is_open          => true,
                 p_domain_id        => p_domain_id) a
    ),
    -- summed over the materials of the set; the material is named when the
    -- set has one, else null
    item_agg as (
        select r.lane_nest_ids as nest_ids,
               sum(r.orderline_count)::integer as orderline_count,
               sum(r.sqm)                      as sqm,
               sum(r.gross_sqm)                as gross_sqm,
               jsonb_build_object(
                   'count',         sum((r.impact_json ->> 'count')::integer),
                   'amount',        sum((r.impact_json ->> 'amount')::numeric),
                   'sqm',           round(sum((r.impact_json ->> 'sqm')::numeric), 2),
                   'rework_count',  sum((r.impact_json ->> 'rework_count')::integer),
                   'rework_amount', sum((r.impact_json ->> 'rework_amount')::numeric),
                   'rework_sqm',    round(sum((r.impact_json ->> 'rework_sqm')::numeric), 2)) as impact_json,
               case when count(distinct r.material_id) = 1 then min(r.material_id) end   as material_id,
               case when count(distinct r.material_id) = 1 then min(r.material_name) end as material_name,
               -- the part statuses of the whole set, summed per status
               (select jsonb_agg(jsonb_build_object(
                           'sequence', x.sequence, 'internal_status_code', x.internal_status_code,
                           'class_names', x.class_names, 'i18n', x.i18n, 'amount', x.amount)
                        order by x.sequence)
                from (select (e.value ->> 'sequence')::integer   as sequence,
                             e.value ->> 'internal_status_code'  as internal_status_code,
                             e.value -> 'class_names'            as class_names,
                             e.value -> 'i18n'                   as i18n,
                             sum((e.value ->> 'amount')::numeric) as amount
                      from agg_rows b
                      cross join lateral jsonb_array_elements(b.part_status_json) as e(value)
                      where b.lane_nest_ids = r.lane_nest_ids
                      group by 1, 2, 3, 4) x)                                          as part_status_json,
               (select array_agg(distinct c order by c)
                from agg_rows b cross join lateral unnest(b.class_names) as c
                where b.lane_nest_ids = r.lane_nest_ids)                                as class_names
        from agg_rows r
        group by r.lane_nest_ids
    ),
    -- realized: the state blocks and the produced items of the lanes'
    -- resources, up to the viewed moment (the log functions clip to now())
    realized_state as (
        select s.resource_uid, s.state, s.group_state, s.start_at,
               s.duration_seconds, s.data, s.nest_name
        from log.get_resource_state(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) s
    ),
    realized_produced as (
        select r.resource_uid, r.state, r.group_state, r.start_at,
               r.duration_seconds, r.data, r.nest_name
        from log.get_resource_produced(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) r
    )
    -- planned rows: the lane's primary resource names the row
    select l.tenant_id, l.tenant_name, l.production_company_id,
           l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
           i.level, i.lane_item_id, i.sort_order, i.is_pinned, i.no_split, i.is_fixed_group,
           i.start_offset_in_seconds,
           -- pv2's duration when it sent one, else the print time of the run
           -- (nest area x amount) at the resource's speed, never shorter
           -- than the minimum
           case when i.duration_in_seconds > 0 then i.duration_in_seconds
                else greatest(ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm
                                   / coalesce(nullif(mock.get_resource_speed_factor(ag.material_id, l.resource_uid), 0), 1))::integer,
                              v_min_duration_in_seconds) end,
           v_day_start + make_interval(secs => i.start_offset_in_seconds),
           null::timestamp with time zone,
           coalesce(i.nest_ids, '{}'::bigint[]),
           coalesce(cardinality(i.nest_ids), 0),
           nf.batch_id, nf.batch_name,
           ag.material_id, ag.material_name,
           ag.impact_json, ag.sqm, ag.gross_sqm,
           coalesce(ag.part_status_json, '[]'::jsonb),
           -- the state of a planned item is the least advanced status of its
           -- nests, from the same lookup the realized rows use
           (select st.value from jsonb_array_elements(v_state_lookup) as ss(value)
                                 cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
             where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1),
           (select ss.value - 'states' from jsonb_array_elements(v_state_lookup) as ss(value)
                                       cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
             where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1),
           coalesce(ag.class_names, '{}'::text[]),
           jsonb_build_object(
               'standard_production_impact_in_seconds', ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm)::integer,
               'run_sqm',                                round(coalesce(nf.run_sqm, 0), 2),
               'speed_factor',                           mock.get_resource_speed_factor(ag.material_id, l.resource_uid),
               'orderline_count',                        ag.orderline_count)
    from item i
    join lane l on l.lane_id = i.lane_id
    left join item_nest nf on nf.lane_item_id = i.lane_item_id
    left join item_agg ag on ag.nest_ids = i.nest_ids

    union all
    -- realized: state blocks, named by the resource that ran
    select l.tenant_id, l.tenant_name, l.production_company_id,
           l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
           1, null::bigint, null::numeric, false, false, null::text,
           extract(epoch from (rs.start_at - v_day_start))::integer,
           rs.duration_seconds::integer,
           rs.start_at,
           rs.start_at + make_interval(secs => rs.duration_seconds),
           '{}'::bigint[], 0,
           null::integer, null::text,
           null::integer, null::text,
           null::jsonb, null::numeric, null::numeric,
           '[]'::jsonb,
           rs.state, rs.group_state,
           array_remove(array[rs.state ->> 'class_name'], null),
           coalesce(rs.data, '{}'::jsonb)
    from realized_state rs
    join lane l on l.resource_uid = rs.resource_uid

    union all
    -- realized: produced items, named by the resource that ran
    select l.tenant_id, l.tenant_name, l.production_company_id,
           l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
           1, null::bigint, null::numeric, false, false, null::text,
           extract(epoch from (rp.start_at - v_day_start))::integer,
           rp.duration_seconds::integer,
           rp.start_at,
           rp.start_at + make_interval(secs => coalesce(rp.duration_seconds, 0)),
           case when (rp.data ->> 'nest_id') is not null then array[(rp.data ->> 'nest_id')::bigint] else '{}'::bigint[] end,
           case when (rp.data ->> 'nest_id') is not null then 1 else 0 end,
           (rp.data ->> 'batch_id')::integer, null::text,
           null::integer, null::text,
           null::jsonb, null::numeric, null::numeric,
           '[]'::jsonb,
           rp.state, rp.group_state,
           array_remove(array[rp.state ->> 'class_name', 'realized-produced'], null),
           coalesce(rp.data, '{}'::jsonb) || jsonb_build_object('nest_name', rp.nest_name)
    from realized_produced rp
    join lane l on l.resource_uid = rp.resource_uid

    order by tenant_id, resource_path, level, start_offset_in_seconds, sort_order;
end;
$function$

alter function mock.get_production_plan(timestamp with time zone, text, text, integer[], integer) owner to xfw3;

drop function if exists mock.generate_plan(date, text, text);
-- the output column follows the renamed table, so the old signature goes first

create function mock.generate_plan(p_date date, p_step text, p_line_type text) returns TABLE(plan_id bigint, lane_id bigint, material_impose_plan_id bigint)
	language sql
as $$
    WITH pattern AS (
        SELECT DISTINCT ON (m.sort_order)
               m.material_impose_plan_id, m.sort_order, m.material_id,
               m.start_offset_in_seconds, m.is_pinned
        FROM mock.material_impose_plan m
        WHERE m.weekday = extract(dow FROM p_date)::smallint + 1
          AND m.step = p_step
          AND m.production_line_id IN (
                SELECT DISTINCT production_line_id
                FROM mock.material_print_schedule
                WHERE line = p_line_type)
        ORDER BY m.sort_order, m.moved_at DESC, m.material_impose_plan_id DESC
    ),
    numbered_pattern AS (
        SELECT p.*, row_number() OVER (ORDER BY p.sort_order) AS rn FROM pattern p
    ),
    new_plan AS (
        -- tenant_ids: the tenants that run this line_type
        INSERT INTO action.plan (plan_date, steps, type, line_type, tenant_ids)
        SELECT p_date, array[p_step], 'material-resource-plan', p_line_type,
               (SELECT array_agg(DISTINCT pl.tenant_id ORDER BY pl.tenant_id)
                       FILTER (WHERE pl.tenant_id IS NOT NULL)
                FROM relation.production_line pl
                WHERE pl.line_type = p_line_type)
        RETURNING plan_id
    ),
    -- group lanes: one fresh lane per pattern row, with the imposition group
    -- of the row on it (imposition_group_lane); the group ids were seeded 1:1
    -- from the material ids
    new_lane AS (
        INSERT INTO action.lane (lane_date)
        SELECT p_date FROM pattern
        RETURNING lane_id
    ),
    numbered_lane AS (
        SELECT nl.lane_id, row_number() OVER (ORDER BY nl.lane_id) AS rn FROM new_lane nl
    ),
    new_group_lane AS (
        INSERT INTO action.imposition_group_lane (lane_id, imposition_group_id)
        SELECT nl.lane_id, p.material_id
        FROM numbered_lane nl
        JOIN numbered_pattern p USING (rn)
        WHERE p.material_id IS NOT NULL
        RETURNING lane_id
    ),
    new_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT np.plan_id, nl.lane_id, p.sort_order
        FROM numbered_lane nl
        JOIN numbered_pattern p USING (rn)
        CROSS JOIN new_plan np
        RETURNING plan_id, lane_id, sort_order
    ),
    -- one slot per lane, stamped from the pattern row: the planned moment
    -- the client moves, pins and copies. The pattern stays the template.
    new_lane_item AS (
        INSERT INTO action.lane_item
            (lane_id, sort_order, start_offset_in_seconds, is_pinned,
             no_split, level, source, source_ref)
        SELECT nl.lane_id, p.sort_order, p.start_offset_in_seconds,
               coalesce(p.is_pinned, false), true, 0,
               'material-plan', p.material_impose_plan_id || ':' || p_date
        FROM numbered_lane nl
        JOIN numbered_pattern p USING (rn)
        RETURNING lane_item_id, lane_id
    ),
    -- the imposition group of the slot, on the item (the group ids were
    -- seeded 1:1 from the material ids)
    new_imposition_group_lane_item AS (
        INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
        SELECT p.material_id, nli.lane_item_id
        FROM new_lane_item nli
        JOIN numbered_lane nl ON nl.lane_id = nli.lane_id
        JOIN numbered_pattern p USING (rn)
        WHERE p.material_id IS NOT NULL
        RETURNING lane_item_id
    )
    -- No lane-to-pattern table any more: action.lane_item.source_ref carries
    -- <material_impose_plan_id>:<date>, so the link is on the item itself.
    -- The inserts above still run — a data-modifying CTE always executes,
    -- referenced or not.
    SELECT (SELECT plan_id FROM new_plan), npl.lane_id, p.material_impose_plan_id
    FROM new_plan_lane npl
    JOIN numbered_pattern p ON p.sort_order = npl.sort_order;
$$;

alter function mock.generate_plan(date, text, text) owner to xfw3;

drop function if exists action.crud_lane_item(jsonb, boolean);
create function action.crud_lane_item(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, lane_item_id bigint, lane_id bigint, material_impose_plan_id bigint)
	language sql
as $$
    -- The client mutations of the planning boards, on lane_item level. Every
    -- mutation writes through to mock.material_impose_plan, so re-stamping a
    -- plan reproduces what the planner did:
    --   update — move/pin/sort: the item and its pattern row
    --   create — an extra moment: a new pattern row with the next instance,
    --            plus the lane and the item it stamps to
    --   delete — the moment, its impositions and its pattern row
    --
    -- Set-based throughout: ids are drawn from the sequences up front, so a
    -- created row can be paired back to its payload row without a temp table.
    WITH payload AS (
        SELECT row_number() OVER ()::integer AS param_id,
               coalesce(te.track_by, 0)      AS track_by,
               te.crud, te.lane_item_id, te.lane_id, te.plan_id,
               te.start_offset_in_seconds, te.sort_order, te.is_pinned,
               te.imposition_group_id
        FROM jsonb_array_elements(p_param_json) AS t(element)
        CROSS JOIN LATERAL jsonb_to_record(t.element) AS te(
            track_by integer, crud text, lane_item_id bigint, lane_id bigint,
            plan_id bigint, start_offset_in_seconds integer, sort_order numeric,
            is_pinned boolean, imposition_group_id integer)
    ),
    -- what an update or a copy starts from: the item, its lane and the
    -- pattern row it was stamped from (source_ref is <mrp_id>:<date>)
    source AS (
        SELECT p.param_id,
               li.lane_item_id, li.lane_id, li.sort_order, li.start_offset_in_seconds,
               li.is_pinned, li.duration_in_seconds,
               l.lane_date,
               nullif(split_part(li.source_ref, ':', 1), '')::bigint AS material_impose_plan_id,
               igli.imposition_group_id
        FROM payload p
        JOIN action.lane_item li ON li.lane_item_id = p.lane_item_id
        JOIN action.lane l       ON l.lane_id = li.lane_id
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
    ),
    -- ── update ────────────────────────────────────────────────────────────
    updated_item AS (
        UPDATE action.lane_item li
        SET sort_order              = coalesce(p.sort_order, li.sort_order),
            start_offset_in_seconds = coalesce(p.start_offset_in_seconds, li.start_offset_in_seconds),
            is_pinned               = coalesce(p.is_pinned, li.is_pinned)
        FROM payload p
        WHERE p.crud = 'update' AND li.lane_item_id = p.lane_item_id
        RETURNING li.lane_item_id, li.lane_id
    ),
    updated_pattern AS (
        -- the write-through: the same move on the template
        UPDATE mock.material_impose_plan m
        SET sort_order              = coalesce(p.sort_order, m.sort_order),
            start_offset_in_seconds = coalesce(p.start_offset_in_seconds, m.start_offset_in_seconds),
            is_pinned               = coalesce(p.is_pinned, m.is_pinned),
            moved_at                = now()
        FROM payload p
        JOIN source s ON s.param_id = p.param_id
        WHERE p.crud = 'update' AND m.material_impose_plan_id = s.material_impose_plan_id
        RETURNING m.material_impose_plan_id
    ),
    -- ── create ────────────────────────────────────────────────────────────
    -- ids up front: the pattern row, the lane (only for a copy that needs its
    -- own lane) and the item itself
    new_id AS (
        SELECT p.param_id, p.track_by, p.plan_id, p.sort_order, p.is_pinned,
               p.start_offset_in_seconds, p.lane_id AS given_lane_id,
               coalesce(p.imposition_group_id, s.imposition_group_id) AS imposition_group_id,
               s.material_impose_plan_id AS from_pattern_id,
               s.lane_id                 AS from_lane_id,
               nextval('mock.material_resource_plan_material_resource_plan_id_seq') AS new_pattern_id,
               nextval('action.lane_item_lane_item_id_seq')                          AS new_lane_item_id,
               CASE WHEN p.lane_id IS NULL AND s.lane_id IS NULL
                    THEN nextval('action.lane_lane_id_seq') END                      AS new_lane_id
        FROM payload p
        LEFT JOIN source s ON s.param_id = p.param_id
        WHERE p.crud = 'create'
    ),
    target AS (
        SELECT n.*,
               coalesce(n.given_lane_id, n.from_lane_id, n.new_lane_id) AS lane_id,
               coalesce(pl.plan_date, l.lane_date)                      AS lane_date
        FROM new_id n
        LEFT JOIN action.plan pl ON pl.plan_id = n.plan_id
        LEFT JOIN action.lane l  ON l.lane_id = coalesce(n.given_lane_id, n.from_lane_id)
    ),
    new_lane AS (
        INSERT INTO action.lane (lane_id, lane_date)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_lane_id, t.lane_date
        FROM target t WHERE t.new_lane_id IS NOT NULL
        RETURNING lane_id
    ),
    -- a fresh lane on a material board is a group lane
    new_group_lane AS (
        INSERT INTO action.imposition_group_lane (lane_id, imposition_group_id)
        SELECT t.new_lane_id, t.imposition_group_id
        FROM target t WHERE t.new_lane_id IS NOT NULL AND t.imposition_group_id IS NOT NULL
        RETURNING lane_id
    ),
    new_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT t.plan_id, t.new_lane_id,
               coalesce(t.sort_order,
                        (SELECT coalesce(max(pl2.sort_order), 0) + 1000
                         FROM action.plan_lane pl2 WHERE pl2.plan_id = t.plan_id))
        FROM target t WHERE t.new_lane_id IS NOT NULL AND t.plan_id IS NOT NULL
        RETURNING lane_id
    ),
    -- the new pattern row: the copy of the source row with the next instance
    new_pattern AS (
        INSERT INTO mock.material_impose_plan
            (material_impose_plan_id, weekday, step, resource_path, sort_order,
             material_id, instance, production_line_id, tenant_id,
             start_offset_in_seconds, is_pinned)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_pattern_id, m.weekday, m.step, m.resource_path,
               coalesce(t.sort_order, m.sort_order), m.material_id,
               -- the next repeat of this moment in its own lane
               (SELECT coalesce(max(m2.instance), 0) + 1
                FROM mock.material_impose_plan m2
                WHERE m2.weekday = m.weekday AND m2.step = m.step
                  AND m2.resource_path IS NOT DISTINCT FROM m.resource_path
                  AND m2.material_id IS NOT DISTINCT FROM m.material_id),
               m.production_line_id, m.tenant_id,
               coalesce(t.start_offset_in_seconds, m.start_offset_in_seconds),
               coalesce(t.is_pinned, m.is_pinned)
        FROM target t
        JOIN mock.material_impose_plan m ON m.material_impose_plan_id = t.from_pattern_id
        RETURNING material_impose_plan_id
    ),
    new_item AS (
        INSERT INTO action.lane_item
            (lane_item_id, lane_id, sort_order, start_offset_in_seconds,
             duration_in_seconds, is_pinned, no_split, level, source, source_ref)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_lane_item_id, t.lane_id,
               -- no rank from the client: append behind the lane, spread so a
               -- batch never collides on the unique (lane_id, sort_order)
               coalesce(t.sort_order,
                        (SELECT coalesce(max(li2.sort_order), 0)
                         FROM action.lane_item li2 WHERE li2.lane_id = t.lane_id)
                        + 1000 * row_number() OVER (ORDER BY t.param_id)),
               coalesce(t.start_offset_in_seconds, 0), 0,
               coalesce(t.is_pinned, false), true, 0,
               'material-plan',
               -- same shape generate_plan stamps, so the item stays idempotent
               t.new_pattern_id || ':' || t.lane_date
        FROM target t
        WHERE t.lane_id IS NOT NULL
        RETURNING lane_item_id, lane_id
    ),
    new_group_link AS (
        INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
        SELECT t.imposition_group_id, t.new_lane_item_id
        FROM target t
        WHERE t.imposition_group_id IS NOT NULL AND t.lane_id IS NOT NULL
        ON CONFLICT DO NOTHING
        RETURNING lane_item_id
    ),
    -- ── delete ────────────────────────────────────────────────────────────
    deleted_link AS (
        DELETE FROM action.imposition_lane_item x
        USING payload p
        WHERE p.crud = 'delete' AND x.lane_item_id = p.lane_item_id
        RETURNING x.lane_item_id
    ),
    deleted_item AS (
        DELETE FROM action.lane_item li
        USING payload p
        WHERE p.crud = 'delete' AND li.lane_item_id = p.lane_item_id
        RETURNING li.lane_item_id
    ),
    deleted_pattern AS (
        -- without this the moment returns at the next stamp
        DELETE FROM mock.material_impose_plan m
        USING payload p
        JOIN source s ON s.param_id = p.param_id
        WHERE p.crud = 'delete' AND m.material_impose_plan_id = s.material_impose_plan_id
        RETURNING m.material_impose_plan_id
    )
    SELECT p.param_id, p.track_by, p.crud,
           coalesce(t.new_lane_item_id, p.lane_item_id),
           coalesce(t.lane_id, p.lane_id),
           coalesce(t.new_pattern_id, s.material_impose_plan_id)
    FROM payload p
    LEFT JOIN target t ON t.param_id = p.param_id
    LEFT JOIN source s ON s.param_id = p.param_id
    WHERE NOT p_no_results
    ORDER BY p.param_id;
$$;

alter function action.crud_lane_item(jsonb, boolean) owner to xfw3;

drop function if exists legacy.crud_nest(jsonb, boolean);
create function legacy.crud_nest(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, domain_id integer, batch_id bigint, nest_id bigint, nest_counter integer, reproduced_counter integer, nest_name text, amount integer, width numeric, height numeric, nest_json jsonb, sort_order integer, status jsonb, possible_states bigint, possible_multiple_states bigint)
	language plpgsql
as $$
DECLARE
    last_updated_at timestamp;
    rec             record;
    v_batch_uid     bigint;
BEGIN
    CREATE TEMP TABLE param_table ON COMMIT DROP AS
    SELECT
        row_number() OVER ()::integer     AS param_id,
        COALESCE(te.track_by, 0)          AS track_by,
        te.crud,
        te.domain_id,
        te.batch_id,
        te.nest_id,
        COALESCE(te.nest_counter, 1)      AS nest_counter,
        COALESCE(te.reproduced_counter, 0) AS reproduced_counter,
        te.nest_name,
        te.amount,
        te.width::numeric(10,1)           AS width,
        te.height::numeric(10,1)          AS height,
        t.element                         AS nest_json,
        te.sort_order,
        te.status,
        te.possible_states,
        te.possible_multiple_states,
        te.nest_date,
        te.updated_at
    FROM jsonb_array_elements(p_param_json) AS t(element)
    CROSS JOIN LATERAL jsonb_to_record(t.element) AS te(
        track_by                 integer,
        crud                     text,
        domain_id                integer,
        batch_id                 bigint,
        nest_id                  bigint,
        nest_counter             integer,
        reproduced_counter       integer,
        nest_name                text,
        amount                   integer,
        width                    numeric,
        height                   numeric,
        sort_order               integer,
        status                   jsonb,
        possible_states          bigint,
        possible_multiple_states bigint,
        nest_date                timestamptz,
        updated_at               timestamptz
    );

    FOR rec IN
        SELECT * FROM param_table pt ORDER BY pt.updated_at ASC NULLS FIRST
    LOOP
        SELECT b.batch_uid INTO v_batch_uid
        FROM legacy.batch b
        WHERE b.batch_id = rec.batch_id;

        IF rec.crud IN ('create','merge') THEN
            INSERT INTO legacy.nest (
                batch_uid, domain_id, nest_id, nest_counter, reproduced_counter,
                nest_name, amount, width, height, nest_json, sort_order,
                status_json, possible_states, possible_multiple_states, nested_at, updated_at
            ) VALUES (
                v_batch_uid, rec.domain_id, rec.nest_id, rec.nest_counter, rec.reproduced_counter,
                rec.nest_name, rec.amount, rec.width, rec.height,
                -- never insert a bare NULL into nest_json
                COALESCE(rec.nest_json, '{}'::jsonb),
                rec.sort_order,
                rec.status, rec.possible_states, rec.possible_multiple_states, rec.nest_date, rec.updated_at
            )
            ON CONFLICT ON CONSTRAINT uq_nest_id DO UPDATE
                SET batch_uid                = EXCLUDED.batch_uid,
                    nest_name                = EXCLUDED.nest_name,
                    amount                   = EXCLUDED.amount,
                    width                    = EXCLUDED.width,
                    height                   = EXCLUDED.height,
                    -- merge instead of replace: keys not present in the incoming
                    -- payload (e.g. commercial_waste_percentage, which is
                    -- computed elsewhere and not part of this event) are kept.
                    -- Incoming keys still win over existing ones on conflict.
                    nest_json                = COALESCE(legacy.nest.nest_json, '{}'::jsonb)
                                                || COALESCE(EXCLUDED.nest_json, '{}'::jsonb),
                    sort_order               = EXCLUDED.sort_order,
                    status_json              = EXCLUDED.status_json,
                    possible_states          = EXCLUDED.possible_states,
                    possible_multiple_states = EXCLUDED.possible_multiple_states,
                    nested_at                = EXCLUDED.nested_at,
                    updated_at               = EXCLUDED.updated_at;

            -- insert into legacy.nest_log when a nest is created (initial 'ripped' entry, full amount)
            INSERT INTO legacy.nest_log
                (nest_id, from_status_sequence, to_status_sequence, amount, remaining_impact_delta, resource_uids, moved_at)
            SELECT
                n.nest_id,
                NULL,
                l.sequence,
                n.amount,
                NULL,
                '{}'::text[],
                now()
            FROM legacy.nest n,
                 relation.lookup rl,
                 jsonb_to_recordset(rl.lookup_json) AS l(step text, sequence int)
            WHERE n.nest_id = rec.nest_id
              AND rl.lookup = 'lookup_step_category'
              AND l.step = 'ripped';

        ELSIF rec.crud = 'update' THEN
            UPDATE legacy.nest n
            SET
                batch_uid                = v_batch_uid,
                -- merge instead of replace, same reasoning as the create/merge branch above
                nest_json                = COALESCE(n.nest_json, '{}'::jsonb)
                                            || COALESCE(rec.nest_json, '{}'::jsonb),
                sort_order               = rec.sort_order,
                status_json              = rec.status,
                possible_states          = rec.possible_states,
                possible_multiple_states = rec.possible_multiple_states,
                nested_at                = rec.nest_date,
                updated_at               = rec.updated_at
            WHERE n.nest_id = rec.nest_id;
        END IF;
    END LOOP;

    UPDATE legacy.nest n
    SET batch_uid = b.batch_uid
    FROM legacy.batch b
    WHERE n.batch_uid IS NULL
      AND b.batch_id = (n.nest_json ->> 'batch_id')::integer;

    -- ── nest → lane item (docs/nest-planning-lane-items.md §3) ─────────
    -- Every nest hangs on a lane item of the material-resource-plan of its
    -- day: plan → plan_lane → lane (the material lane) → lane_item. The
    -- item picked is the latest one starting at or before the nest moment
    -- (the stamped items are 0-duration moments, so a covering-window match
    -- would never hit), else the first of the day. Durations are never
    -- stored here: the boards derive them at read time — nests from
    -- width × height × sum(amount), the future from the aggregate and the
    -- material sizes in line_json.specs.
    CREATE TEMP TABLE nest_link ON COMMIT DROP AS
    WITH payload AS (
        SELECT pt.nest_id, pt.sort_order,
               (n.nest_json ->> 'material_id')::integer        AS material_id,
               (n.nest_json ->> 'production_line_id')::integer AS production_line_id,
               (COALESCE(pt.nest_date, n.nested_at) AT TIME ZONE 'Europe/Amsterdam')::date AS plan_date,
               extract(epoch FROM (COALESCE(pt.nest_date, n.nested_at) AT TIME ZONE 'Europe/Amsterdam')::time)::integer AS nest_seconds,
               lower(COALESCE(n.nest_json ->> 'status', '')) LIKE 'cancel%' AS is_cancelled
        FROM param_table pt
        JOIN legacy.nest n ON n.nest_id = pt.nest_id
        WHERE pt.crud IN ('create', 'merge', 'update')
    )
    SELECT p.nest_id, p.sort_order, p.nest_seconds, p.is_cancelled,
           lane.lane_id, item.lane_item_id
    FROM payload p
    LEFT JOIN relation.production_line prl ON prl.line_id = p.production_line_id
    LEFT JOIN LATERAL (
        SELECT ap.plan_id
        FROM action.plan ap
        WHERE ap.plan_date = p.plan_date
          AND ap.type = 'material-resource-plan'
          AND (prl.line_type IS NULL OR ap.line_type = prl.line_type)
        ORDER BY ap.plan_id DESC
        LIMIT 1
    ) tp ON true
    LEFT JOIN LATERAL (
        -- the lane of the nest material on that plan: the group lane.
        -- imposition_group_id acts as an alias of material_id for now (the
        -- groups were seeded 1:1 from the material ids); later the nests
        -- resolve their real imposition group here.
        -- The plan carries both tenants, so a material has one lane per
        -- production line; the line of the nest decides which one. The line
        -- of a lane sits on the pattern row its item was stamped from
        -- (source_ref = <material_impose_plan_id>:<date>). Before this, the
        -- first lane won and 1.338 nests of the other line landed on the
        -- wrong tenant's item (24 aug - 4 sep).
        SELECT igl.lane_id
        FROM action.plan_lane apl
        JOIN action.imposition_group_lane igl ON igl.lane_id = apl.lane_id
        JOIN action.lane_item li2 ON li2.lane_id = igl.lane_id AND li2.source = 'material-plan'
        JOIN mock.material_impose_plan mip
          ON mip.material_impose_plan_id = nullif(split_part(li2.source_ref, ':', 1), '')::bigint
        WHERE apl.plan_id = tp.plan_id
          AND igl.imposition_group_id = p.material_id
          AND mip.production_line_id = p.production_line_id
        ORDER BY apl.sort_order
        LIMIT 1
    ) lane ON true
    LEFT JOIN LATERAL (
        SELECT li.lane_item_id
        FROM action.lane_item li
        WHERE li.lane_id = lane.lane_id
          AND li.level = 0
        ORDER BY (COALESCE(li.start_offset_in_seconds, 0) <= p.nest_seconds) DESC,
                 CASE WHEN COALESCE(li.start_offset_in_seconds, 0) <= p.nest_seconds
                      THEN -COALESCE(li.start_offset_in_seconds, 0)
                      ELSE COALESCE(li.start_offset_in_seconds, 0) END
        LIMIT 1
    ) item ON true;

    -- lane found but no lane item at all: create one for this nest
    INSERT INTO action.lane_item
        (lane_id, sort_order, start_offset_in_seconds, no_split, level, source, source_ref)
    SELECT ns.lane_id, -1 * ns.nest_id, ns.nest_seconds, true, 0, 'nest', ns.nest_id::text
    FROM nest_link ns
    WHERE ns.lane_item_id IS NULL
      AND ns.lane_id IS NOT NULL
      AND NOT ns.is_cancelled
    ON CONFLICT ON CONSTRAINT lane_item_source_ref_uq DO NOTHING;

    -- The material-lane sets are append-only (docs/plan-lane-model.md stap
    -- 2): every item a payload nest leaves or joins gets its set written
    -- anew — the current set minus the payload nests, plus the payload nests
    -- that land on it. An item left without impositions gets the explicit
    -- empty set (one row, imposition_id null), so it does not fall back to
    -- inheriting. The pv2 machine links belong to action.crud_object and
    -- stay untouched. Cancelled nests only leave. No plan or lane for the
    -- day: no link, never an invented lane — the backfill catches it later.
    WITH target AS (
        SELECT ns.nest_id, ns.sort_order,
               COALESCE(ns.lane_item_id, own.lane_item_id) AS lane_item_id
        FROM nest_link ns
        LEFT JOIN action.lane_item own
               ON own.source = 'nest' AND own.source_ref = ns.nest_id::text
        WHERE NOT ns.is_cancelled
          AND COALESCE(ns.lane_item_id, own.lane_item_id) IS NOT NULL
    ),
    -- the material-lane items that hold a payload nest today, plus the
    -- items the payload lands on
    touched AS (
        SELECT DISTINCT i.lane_item_id
        FROM action.imposition_lane_item i
        JOIN action.lane_item li ON li.lane_item_id = i.lane_item_id
        WHERE li.source IN ('material-plan', 'nest')
          AND i.imposition_id IN (SELECT ns.nest_id FROM nest_link ns)
          AND i.moved_at = (SELECT max(x.moved_at) FROM action.imposition_lane_item x
                            WHERE x.lane_item_id = i.lane_item_id)
        UNION
        SELECT t.lane_item_id FROM target t
    ),
    -- the current set of those items, without the payload nests
    kept AS (
        SELECT i.lane_item_id, i.imposition_id, i.sort_order
        FROM action.imposition_lane_item i
        JOIN touched t ON t.lane_item_id = i.lane_item_id
        WHERE i.imposition_id IS NOT NULL
          AND i.imposition_id NOT IN (SELECT ns.nest_id FROM nest_link ns)
          AND i.moved_at = (SELECT max(x.moved_at) FROM action.imposition_lane_item x
                            WHERE x.lane_item_id = i.lane_item_id)
    ),
    new_set AS (
        SELECT lane_item_id, imposition_id, sort_order FROM kept
        UNION ALL
        SELECT t.lane_item_id, t.nest_id, t.sort_order FROM target t
    )
    INSERT INTO action.imposition_lane_item (lane_item_id, imposition_id, sort_order)
    SELECT n.lane_item_id, n.imposition_id, n.sort_order
    FROM new_set n
    UNION ALL
    SELECT t.lane_item_id, NULL, NULL
    FROM touched t
    WHERE NOT EXISTS (SELECT 1 FROM new_set n WHERE n.lane_item_id = t.lane_item_id);

    -- ── imposition → unit manifest ────────────────────────────────────
    -- What the imposition is made of, snapshotted from the orderline
    -- manifests it holds (legacy.single_product is the bridge). Rebuilt for
    -- every nest in this payload, so a re-nest or a merge refreshes it.
    -- Cancelled nests keep their manifest: it records what was imposed, not
    -- what is still planned — the lane link above is what disappears.
    PERFORM legacy.create_imposition_unit_manifest(
        array(SELECT DISTINCT pt.nest_id
              FROM param_table pt
              WHERE pt.crud IN ('create', 'merge', 'update')
                AND pt.nest_id IS NOT NULL));

    SELECT MAX(pt.updated_at) INTO last_updated_at
    FROM param_table pt;

    IF last_updated_at IS NOT NULL THEN
        UPDATE mapping.persistent_vars
        SET value = last_updated_at - INTERVAL '2 minutes'
        WHERE key = 'last_nest_updated_at';
    END IF;

    IF NOT p_no_results THEN
        RETURN QUERY
        SELECT pt.param_id, pt.track_by, pt.crud, pt.domain_id,
               pt.batch_id, pt.nest_id, pt.nest_counter, pt.reproduced_counter,
               pt.nest_name, pt.amount, pt.width, pt.height, pt.nest_json,
               pt.sort_order, pt.status, pt.possible_states, pt.possible_multiple_states
        FROM param_table pt
        ORDER BY pt.param_id;
    END IF;
END;
$$;

alter function legacy.crud_nest(jsonb, boolean) owner to xfw3;

COMMIT;

-- checks: every board read gives the same rows as before the change (counts
-- and md5 over the rows, baseline 2026-09-05T11:33:35.375Z). impose_76 and
-- production_81 carry a clock-relative column, so their md5 may differ on a
-- later day; the counts must match. Expected: unchanged = true everywhere
select 'labels_75' as read, count(*) = 67 as same_count, md5(string_agg(t::text, '|' order by t::text)) = '0fcfc3d8aa631a17a607210cf8a4df47' as same_rows from (select * from action.get_plan_lanes('2026-09-04 10:00+02', 'print', 'sheet', null, false, 'material-resource-plan', null)) t;
select 'labels_76' as read, count(*) = 48 as same_count, md5(string_agg(t::text, '|' order by t::text)) = '974be35c8a79d9a6bbe233a7d19f3080' as same_rows from (select * from action.get_plan_lanes('2026-09-04 10:00+02', 'print', 'sheet', null, true, 'material-resource-plan', null)) t;
select 'labels_78' as read, count(*) = 5 as same_count, md5(string_agg(t::text, '|' order by t::text)) = '448adc22efa30362bd62feee3e96277b' as same_rows from (select * from action.get_plan_lanes('2026-09-04 10:00+02', 'print', 'sheet', null, false, 'material-resource-plan', array['impose'])) t;
select 'labels_81' as read, count(*) = 15 as same_count, md5(string_agg(t::text, '|' order by t::text)) = '20964e1bab196764735409f72b8837ac' as same_rows from (select * from action.get_plan_lanes('2026-09-04 10:00+02', 'print', 'sheet', null, false, 'production-plan', array['print','coat','laminate','route','cut'])) t;
select 'labels_81_foil' as read, count(*) = 16 as same_count, md5(string_agg(t::text, '|' order by t::text)) = '97773f83d38a6e3f48dad4d9bbf59620' as same_rows from (select * from action.get_plan_lanes('2026-09-04 10:00+02', 'print', 'foil', null, false, 'production-plan', array['print','coat','laminate','route','cut'])) t;
select 'impose_76' as read, count(*) = 48 as same_count, md5(string_agg(t::text, '|' order by t::text)) = '11d1abf6acbaa91f7adb1405202ab859' as same_rows from (select * from mock.get_impose_plan('2026-09-04 10:00+02', 'print', 'sheet', null, 0, 0, 1)) t;
select 'production_81' as read, count(*) = 988 as same_count, md5(string_agg(t::text, '|' order by t::text)) = '33a5ff6a1c4285678765a6313f038daa' as same_rows from (select * from mock.get_production_plan('2026-09-04 10:00+02', 'print', 'sheet')) t;

-- a machine-day stays unique: expected 0
select count(*) as duplicate_machine_days
from (select l.lane_date, rl.resource_path from action.lane l join action.resource_lane rl using (lane_id)
      group by 1, 2 having count(*) > 1) d;
