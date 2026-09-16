# Plan: shift employees per shift (sidebar shift)

Date: 2026-09-15. Status: built (archive/sql/migrations/update_shift_employees_log.sql), waiting to be run. The answers of Cees are in §5.

## 1. what is there

- `log.hr_shift_planning.shift_json` (one row per department resource and business date) carries
  since 1 Sep 2026 a `code` on every shift and on every employee (day, evening, night), the
  planned `employee_count` per shift (already without the absent), the `absence` per shift
  (`employee_count`, `duration_in_seconds`, `by_marking`), and per employee a `marking`
  (`sick`, `leave`, or empty). Rows before 1 Sep have no codes (1025 of 3125 rows have them).
- Markings in use since 1 Sep: empty, `leave`, `sick`; one employee without marking or code.
- Shift codes per department: many have day only, the production departments day and evening,
  eight of them day, evening and night (174 Plaat among them).
- `legacy.lookup` `lookup_shift`: `[{code, i18n}]` for day, evening, night (nl, en, de, fr, es; no
  uk), changed by Cees today: `i18n` directly under the code, no `block` any more.
- `log.lookup` exists (`lookup`, `lookup_json`) and holds `lookup_resource_state`.
- `legacy.get_resource_shift_employees(p_production_line_id, p_business_date)`: one row per
  employee in the planning of the line's department resources, the shift type from the clock
  data (`log.hr_data`), the title through `lookup_shift ... block -> i18n`. Data_table
  `get_resource_shift_employees` points at it, primary keys `resource_data_log_id, group_name`
  (stale: the read returns `shift_planning_id`).
- Readers of the lookup or the read: `legacy.get_resource_shift_employees`,
  `mapping.get_status_bar_teams` (the status bar teams), `log.get_oee_report` (the shift titles
  of the per-shift columns, still through `block -> i18n`, so those titles are null since today).
- Data_group 42 `resource_shift_employees`: `flow-grid` on `shift_type` (the clock shift), a
  `flow-container` per `group_name` with a count chip, `flow-cards` per employee (name, personnel
  number, contract type). Page `shift`, opened by the status bar teams and the OEE summary button
  with `production_line_id` and `business_date`.

## 2. the lookup moves to log

`log.lookup` `lookup_shift`, the content of `json/lookup/log/lookup_shift.json` (the moved file,
`[{code, i18n}]`, with `uk` added), removed from `legacy.lookup`. Every reader takes it from
`log.lookup` and `-> 'i18n'`: the shift employees read, the OEE report read. The status bar teams
only calls the read.

## 3. the read moves to log and reads the planning as it is

`log.get_resource_shift_employees(p_production_line_id integer, p_business_date date)`, the
legacy one dropped, the data_table on the new one with primary keys that match (§5.4). The
shift of an employee is the `code` in the planning, not the clock data. One row per employee
(§5.1) with:

| column | source |
|---|---|
| `shift`, `shift_order`, `i18n` | the employee's `code`, the order and title from the lookup |
| `group_name` | the group |
| `department_group_id`, `department_group_name`, `shift_planning_id` | the planning row |
| `employee_id`, `personnel_number`, `first_name`, `infix`, `last_name`, `contract_type`, `start_at`, `end_at`, `duration`, `break_minutes`, `remark` | the employee |
| `marking` | `sick`, `leave`, or null |
| `section`, `section_i18n`, `section_order` | the container of the board: the group of a working employee, or the absence (sick, leave) of an absent one; the board counts the rows per section |

`mapping.get_status_bar_teams` follows the move and counts the planned `employee_count` of the
current shift per group (§5.5).

## 4. data_group 42

- `flow-grid` `group_by [shift]`, `group_title_fields [i18n]`, `sort {shift_order, asc}`: a column
  per shift code present in the data (§5.2).
- `flow-container` `group_by [section]`, `sort {section_order}`, `colexp true`: the groups first,
  then sick, then leave, each with a count chip (`aggregate_fn count` on `employee_id`).
- `flow-cards` per employee as today, plus group, start, end and remark.
- params `production_line_id`, `business_date` unchanged.

## 5. decided (Cees, 15 Sep)

1. The employee cards stay under each group.
2. Grid columns: only the shift codes present in the planning of that day.
3. Sick and leave per shift: the absent employees are not in their group but in a section of
   their own per shift (`section` sick / leave, titles from `log.lookup` `lookup_absence`), a
   collapsible container with the count and the employees. Only sick and leave exist.
4. Data_table primary keys: `shift_planning_id, shift, group_name, employee_id`.
5. The status bar teams count the current shift only: the shift of the group that started last
   before now, before the first shift the first one; `shifts[].employee_count` (already without
   the absent).
6. Planning without codes (before 1 Sep) stays out of the sidebar.
7. The OEE report's shift titles are fixed in the same script (`log.lookup`, `-> i18n`).
