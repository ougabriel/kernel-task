# Kernel — Senior Platform Engineer (take-home) — Design Note

## Context & assumptions (short)
- AtlasCo stores ~200M assets (entities); attributes are sparse (most assets have << 10k attributes).
- Multi-tenant system; tenants vary in size. We assume small/medium tenants are the common case; a few large tenants may require dedicated isolation.
- Requirements: ~10k inserts/sec sustained, immediate read-after-write for some actions, ad-hoc filtering across thousands of attribute types, and eventual replication to OLAP.

## Logical schema (core)
1. `assets` (one row per entity, denormalized snapshot for hot attributes)
   - `asset_id BIGINT PK, tenant_id INT, created_at, updated_at, snapshot JSONB`
   - Snapshot contains frequently-read attributes (hot set) for immediate reads.
2. `attribute_types` (metadata)
   - `attribute_id SERIAL PK, tenant_id INT, name TEXT, data_type TEXT, is_hot BOOLEAN`
3. `eav_values` (EAV store for attributes)
   - `tenant_id, asset_id, attribute_id, value_text, value_num, value_bool, value_jsonb, updated_at`
   - Partitioned (HASH) on `asset_id` for even distribution / parallelism.
4. `hot_attribute_index` (inverted index for frequently filtered attributes)
   - `tenant_id, attribute_id, value_text, value_num, asset_id` — single table with composite indexes (attribute_id, value) — used only for the hot subset.

## Partitioning & sharding strategy
- **Tenant isolation**: three levels depending on tenant size:
  1. **Schema-per-tenant** for very large tenants (hot path isolation).
  2. **Row-level tenant_id** for typical tenants.
  3. **Dedicated DB** for extraordinarily large customers (operational decision).
- **Partitioning**:
  - `eav_values` partitioned by `HASH(asset_id)` into N partitions (N tuned per cluster size; start with 16–64).
  - This provides even write distribution, smaller indexes per partition, and parallel vacuum.
- **Data lifecycle**:
  - Hot attributes promoted to `hot_attribute_index` (and to `assets.snapshot`) for immediate reads and fast filtering.
  - Cold attributes kept in `eav_values` with a global `GIN` index on `value_jsonb` for ad-hoc existence/contains queries.
- **Scaling**:
  - Scale writes with connection pooling (PgBouncer), batched writes, and WAL tuning.
  - Use multiple writer processes with partition-aware batching.

## Example SQL — operational (multi-attribute filter)
(Option A — fast path when filters are from hot set / snapshot)
```sql
SELECT asset_id, snapshot
FROM assets
WHERE tenant_id = 42
  AND snapshot->>'firmware_version' = '1.2.3'
  AND snapshot->>'status' = 'active'
LIMIT 100;

