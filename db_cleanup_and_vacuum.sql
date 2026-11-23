DO $$
DECLARE
    tbl RECORD;
    batch_size INT := 5000;          -- Rows per batch (adjust based on server capacity)
    deleted_count BIGINT;
    total_deleted BIGINT;
    batch_num INT;
    start_time TIMESTAMPTZ;
    loop_start TIMESTAMPTZ;
    batch_ms NUMERIC;
BEGIN
    FOR tbl IN
        SELECT table_schema, table_name
        FROM information_schema.columns
        WHERE column_name IN ('isActive', 'isDelete')
          AND table_schema = 'public'
        GROUP BY table_schema, table_name
        HAVING COUNT(DISTINCT column_name) = 2
    LOOP
        total_deleted := 0;
        batch_num := 0;
        start_time := clock_timestamp();

        RAISE NOTICE '==================================================';
        RAISE NOTICE '=== Starting cleanup on: %.% ===', tbl.table_schema, tbl.table_name;
        RAISE NOTICE '==================================================';

        -- ============ BATCH DELETE LOOP ============
        LOOP
            loop_start := clock_timestamp();
            batch_num := batch_num + 1;

            EXECUTE format(
                'DELETE FROM %I.%I
                 WHERE ctid IN (
                     SELECT ctid FROM %I.%I
                     WHERE "isActive" = FALSE AND "isDelete" = TRUE
                     LIMIT $1
                 )',
                tbl.table_schema, tbl.table_name,
                tbl.table_schema, tbl.table_name
            ) USING batch_size;

            GET DIAGNOSTICS deleted_count = ROW_COUNT;
            total_deleted := total_deleted + deleted_count;

             COMMIT;

            EXIT WHEN deleted_count = 0;

            batch_ms := ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - loop_start)) * 1000);

            -- Small pause after each batch → I/O breathing room
            PERFORM pg_sleep(0.05);

            -- Log progress every 10 batches
            IF batch_num % 10 = 0 THEN
                RAISE NOTICE '  [%.%] Batch #% | Total deleted: % | Last batch: % ms',
                    tbl.table_schema, tbl.table_name,
                    batch_num, total_deleted, batch_ms;
            END IF;
        END LOOP;

        RAISE NOTICE '=== Delete done: %.% — % rows in % seconds ===',
            tbl.table_schema, tbl.table_name,
            total_deleted,
            ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - start_time)));
    END LOOP;

    RAISE NOTICE '##################################################';
    RAISE NOTICE '### ALL TABLES PROCESSED SUCCESSFULLY ###';
    RAISE NOTICE '##################################################';
END $$;


-- ============================================================================
-- Dynamic VACUUM (ANALYZE) 
-- ============================================================================
VACUUM (ANALYZE);
