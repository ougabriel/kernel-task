###Proposed Logical schema

-- metadata for attributes
CREATE TABLE attr_type (
  attribute_id    integer PRIMARY KEY,   -- small int or int
  name            text UNIQUE NOT NULL,
  data_type       text NOT NULL,         -- 'number' | 'text' | 'ts' | 'bool' | 'json'
  created_at      timestamptz DEFAULT now()
);

-- entities
CREATE TABLE entity (
  entity_id   bigint PRIMARY KEY,  -- large id (200M+)
  entity_type text,
  created_at  timestamptz DEFAULT now()
);

-- the EAV storage (narrow, typed)
CREATE TABLE entity_attribute (
  attribute_id   integer    NOT NULL REFERENCES attr_type(attribute_id),
  entity_id      bigint     NOT NULL REFERENCES entity(entity_id),
  value_number   double precision NULL,
  value_text     text           NULL,
  value_ts       timestamptz    NULL,
  value_bool     boolean        NULL,
  value_jsonb    jsonb          NULL,     -- complex/structured values
  created_at     timestamptz    DEFAULT now(),

  PRIMARY KEY (attribute_id, entity_id)  -- narrow PK useful for partitions & lookups
) PARTITION BY HASH (attribute_id);

