-- Quick check after update_data_group_inline.sql: does the table carry the
-- new keys? Read-only. Expect fields_class_name > 0 and class_name next to
-- field_config = 0 everywhere; the last three rows show the boards touched.
select t.data_group_id, t.data_group,
       -- the new key and the old spot, counted over the whole json
       (select count(*) from jsonb_path_query(t.data_group_json, 'strict $.**.fields_class_name'))                          as fields_class_name,
       (select count(*) from jsonb_path_query(t.data_group_json, 'strict $.** ? (exists(@.field_config) && exists(@.class_name))')) as old_class_name,
       -- the three boards of this round
       t.data_group_json #>> '{0,timeline_config,is_pinned_field}'                                                       as is_pinned_field,
       t.data_group_json #> '{0,field_config,part_status_json,ui,control}'                                               as bar_control,
       t.data_group_json #> '{0,timeline_config,label_options,field_config,fixed_group}'                              as label_fixed_group
from site.data_group t
where t.data_group in ('nest_schedule', 'nest_resource_schedule', 'print_schedule')
   or exists (select 1 from jsonb_path_query(t.data_group_json, 'strict $.** ? (exists(@.field_config) && exists(@.class_name))'))
order by t.data_group_id;
