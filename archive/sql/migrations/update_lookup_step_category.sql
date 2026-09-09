-- The step vocabulary, in production order. Existing sequences keep their
-- value (they live in historical log rows); the new steps slot in between.
-- Mirror: json/lookup/relation/lookup_step_category.json
UPDATE relation.lookup
SET lookup_json = $steps$[
  { "step": "impose",   "order": 0,  "sequence": 500, "internal_status_code": "imposed" },
  { "step": "rip",      "order": 1,  "sequence": 600, "internal_status_code": "ripped" },
  { "step": "print",    "order": 2,  "sequence": 700, "internal_status_code": "printed" },
  { "step": "coat",     "order": 3,  "sequence": 790, "internal_status_code": "coated" },
  { "step": "laminate", "order": 4,  "sequence": 795, "internal_status_code": "laminated" },
  { "step": "route",    "order": 5,  "sequence": 798, "internal_status_code": "routed" },
  { "step": "cut",      "order": 6,  "sequence": 801, "internal_status_code": "cut" },
  { "step": "assemble", "order": 7,  "sequence": 810, "internal_status_code": "assembled" },
  { "step": "finish",   "order": 8,  "sequence": 820, "internal_status_code": "finished" },
  { "step": "bin",      "order": 9,  "sequence": 830, "internal_status_code": "binned" },
  { "step": "package",  "order": 10, "sequence": 840, "internal_status_code": "packaged" }
]$steps$::jsonb
WHERE lookup = 'lookup_step_category';
