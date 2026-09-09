# plan: one date set and one moment instead of from/until/look_back/look_ahead

Status: proposal, not started. Touches the whole legacy planning chain
(`docs/legacy-planning-chain.md`), so it goes in one step per layer, not per
function.

## why

Today four parameters describe the same two things in different clothes:

| parameter | means | where |
|---|---|---|
| `p_from` | the viewed moment; also the anchor day of the window | mapping detail, aggregate, board aggregate, graph |
| `p_until` | the viewed moment; the plan date | mock nest/print boards |
| `p_look_back_days`, `p_look_ahead_days` | how many *in-scope* days around that anchor | detail, aggregate, board aggregate |
| `p_include_weekend`, `p_include_mandatory_dates` | which days count as in scope | detail, aggregate |
| `p_date` | a day | manifest |

Two concepts are folded into one: **which days** the board shows, and **at what
moment** it is looked at (the reference for `plan-alert`, `state-delayed`,
"today" sub-cells). Every function re-derives the day set on `action.dates`
(`get_date_window`), each in its own way, and a board can only ask for a
contiguous run of days around one anchor.

## proposal — two parameters

```
p_dates  datemultirange   -- the days the board shows; NULL = no day filter
p_at     timestamp with time zone   -- the moment it is looked at; DEFAULT now()
```

- `p_dates` is a set of half-open day ranges, e.g. `{[2026-08-04,2026-08-09),[2026-08-11,2026-08-16)}`
  (two working weeks, weekend out). Contiguous days merge by themselves; a
  single day is `{[2026-08-14,2026-08-15)}`. Non-contiguous picks ("today
  and Friday") come for free.
- `p_at` is the only time in the interface. Class names, alert windows and
  "is today" compare with it, never with `now()`. Its Amsterdam date is *not*
  automatically part of `p_dates` — the caller decides both.

Names considered and dropped: `p_days` (reads like a count),
`p_date_range` (it is a *multi*range), `p_moment` / `p_now` (`p_now` lies
when a past board is opened). `p_at` reads naturally at the call site
(`p_at => now()`, `p_at => '2026-08-11 10:00+02'`) and matches how the
column already used for it in the detail is named (`v_at`). If two letters
are too short, `p_viewed_at` is the runner-up.

## how the chain uses them

**detail** — one filter per date type instead of the four-branch `v_from`/`v_until`:

```sql
and (p_dates is null
     or case p_date_type
            when 'logistics'  then cs.logistics_date::date
            when 'production' then cs.production_date::date
            when 'shipment'   then cs.shipment_date::date
            when 'nest'       then (cs.nest_date at time zone v_zone)::date
        end <@ p_dates)
```

`v_day := (p_at at time zone v_zone)::date`, `v_at := p_at at time zone v_zone`
— everything that compares stays as it is. `p_look_back_days`,
`p_look_ahead_days`, `p_include_weekend`, `p_include_mandatory_dates` and
`action.get_date_window` disappear from the detail.

Index note: `date <@ datemultirange` is not a btree condition by itself. The
board window uses `ix_component_specs_board` (domain, is_open, line, status)
and filters the date afterwards, so nothing changes there. Where a date range
scan is needed, the join form is index-friendly:
`join unnest(p_dates) r on cs.logistics_date >= lower(r) and cs.logistics_date < upper(r)`.
Decide per query on the plan, not upfront.

**aggregate, board aggregate, graph** — pass `p_dates` and `p_at` through; the
forecast in the aggregate reads `log.production_forecast_material` with
`f.date <@ p_dates` (nest/batch scope: `p_dates` null → the day of `p_at`,
as today).

**mock boards (`get_nest_schedule`, `get_print_schedule_materials`,
`get_print_schedule`)** — `p_until` becomes `p_at`; the plan date is
`(p_at at time zone ...)::date` as now. `get_nest_schedule` gets `p_dates`
for the orderline window (default: the plan date only) and hands it to the
aggregate.

**manifest** — `p_date` stays a day (the queue is a day), but internally it
builds `p_dates` = the working days from `p_date` for `look_ahead` days and
`p_at` = start of `p_date`. `p_look_ahead_days = -1` stays.

## the bridge: building the set from the old inputs

One helper replaces `action.get_date_window` and keeps the old boards working
until the frontend sends a multirange itself:

```sql
create function action.get_dates(
    p_at                      timestamp with time zone default now(),
    p_look_back_days          integer default 0,
    p_look_ahead_days         integer default 0,
    p_include_weekend         boolean default true,
    p_include_mandatory_dates boolean default true)
returns datemultirange
    stable language sql
as $$
    -- Every day in scope as its own [d, d+1) range; the multirange merges
    -- neighbours, so a plain window is one range and a workday window with
    -- the weekend cut out is several. Same counting as get_date_window: N
    -- days that are in scope, not N calendar days.
    select coalesce(range_agg(daterange(d.date, d.date + 1)), '{}'::datemultirange)
    from (
        (select d.date from action.dates d
          where d.date <= (p_at at time zone 'Europe/Amsterdam')::date
            and (p_include_weekend or not d.is_weekend)
            and (p_include_mandatory_dates or d.tenants_mandatory_day_off = '{}')
          order by d.date desc limit p_look_back_days + 1)
        union
        (select d.date from action.dates d
          where d.date >= (p_at at time zone 'Europe/Amsterdam')::date
            and (p_include_weekend or not d.is_weekend)
            and (p_include_mandatory_dates or d.tenants_mandatory_day_off = '{}')
          order by d.date limit p_look_ahead_days + 1)
    ) d;
$$;
```

(`range_agg` on `daterange` returns a `datemultirange`; PostgreSQL 14+.)

Callers that still receive `look_back`/`look_ahead` from a data group call
`action.get_dates(...)` once and pass the result on. The day counting stays
identical to today, so results do not change during the migration.

## frontend contract

A data group passes `dates` as the text form of a datemultirange —
`'{[2026-08-04,2026-08-20)}'` — and `at` as a timestamp. Until the client
can compose the multirange (a date picker with multiple ranges, or "workdays
between"), the params `look_back_days` / `look_ahead_days` stay on the data
group and the SQL bridge does the conversion. That is a control-room question
to settle before step 4 below; put it in `archive/docs/handoff-control-room.md` when
it lands.

## steps

1. `action.get_dates` (new) — no callers yet; verify against
   `get_date_window` on a few inputs (same first/last day, weekend gap).
2. detail: `p_dates` + `p_at` in, the four window params out; body as above.
   Same step: aggregate, board aggregate, graph, `get_nest_schedule`,
   manifest — every caller builds `p_dates` with `action.get_dates` from what
   it receives today. Data groups unchanged. Measure with the queries in
   `legacy-planning-chain.md` §6; numbers must not move.
3. `action.get_date_window` dropped.
4. Data groups: `from`/`until` → `at`, `look_back_days`/`look_ahead_days` →
   `dates` where the client can produce it; the mock boards' `p_until` →
   `p_at`. This is the only step the client sees.
5. Later: `p_dates` on the boards that today can only show a contiguous run —
   the production board with weekends collapsed, the nest board over "the
   next three working days".

## open before starting

- Can the client send a `datemultirange` literal, and does it want to (a
  multi-range picker), or does the bridge stay the long-term interface for
  the timeline boards?
- `p_at` default `now()` on the mapping functions: keep, or force the caller
  to pass it (a board that forgets it silently becomes "today")? I would
  keep the default on the mapping layer and pass it explicitly from every
  board.
