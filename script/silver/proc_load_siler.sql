
/* ============================================================================
   Stored Procedure : silver.load_silver
   Schema           : silver
   Database         : DataWarehouse
   ============================================================================
   Purpose:
       Orchestrates the full ETL load from the bronze (raw/landing) layer into
       the silver (cleansed/conformed) layer.  Each table section performs:
         1. TRUNCATE  – full-refresh strategy; idempotent by design.
         2. INSERT    – row-by-row transformation inline with SELECT.

    This stored procedure performs the ETL (Extract, Transform, Load) process to
    populate the 'silver' schema tables from the 'bronze' schema.


       Transformations applied per domain:
         CRM  → Deduplication, TRIM, gender/marital-status normalisation,
                product key decomposition, date casting, sales/qty/price
                consistency enforcement.
         ERP  → Customer-ID prefix stripping, future-date nullification,
                gender harmonisation, country code expansion.

   Data Flow:
       bronze.crm_cust_info      →  silver.crm_cust_info
       bronze.crm_prd_info       →  silver.crm_prd_info
       bronze.crm_sales_details  →  silver.crm_sales_details
       bronze.erp_cust_az12      →  silver.erp_cust_az12
       bronze.erp_loc_a101       →  silver.erp_loc_a101
       bronze.erp_px_cat_g1v2    →  silver.erp_px_cat_g1v2

   Load Strategy : Full Refresh (TRUNCATE + INSERT)
   Error Handling : TRY / CATCH with structured error surfacing
   Idempotency    : Yes – safe to re-execute at any time

   Parameters : None
   Returns    : None  (PRINT-based audit log to the message stream)

   Usage:
       EXEC silver.load_silver;

   Change Log:
   --------------------------------------------------------------------------
   Date        Author            Description
   ----------  ----------------  --------------------------------------------
   2025-01-01  <your_name>       Initial creation
   ============================================================================ */

CREATE OR ALTER PROCEDURE silver.load_silver
AS
BEGIN
    /* -----------------------------------------------------------------------
       Batch & section timing variables.
       @batch_*  : wall-clock duration for the entire procedure call.
       @start_*  : wall-clock duration for each individual table load.
    ----------------------------------------------------------------------- */
    DECLARE
        @start_time        DATETIME,
        @end_time          DATETIME,
        @batch_start_time  DATETIME,
        @batch_end_time    DATETIME;

    BEGIN TRY

        SET @batch_start_time = GETDATE();

        PRINT '========================================================================';
        PRINT 'silver Layer Load  –  START';
        PRINT '========================================================================';

        /* ====================================================================
           SECTION 1 : CRM TABLES
           Source system : CRM (Customer Relationship Management)
        ==================================================================== */
        PRINT '------------------------------------------------------------------------';
        PRINT 'Loading CRM Tables';
        PRINT '------------------------------------------------------------------------';

        /* --------------------------------------------------------------------
           Table : silver.crm_cust_info
           Rule  : Keep only the most-recent record per customer (last-write
                   wins deduplication via ROW_NUMBER on cst_create_date DESC).
           Transforms:
             - TRIM leading/trailing whitespace from name fields.
             - Expand single-character gender codes → readable labels.
             - Expand single-character marital-status codes → readable labels.
             - Exclude rows where cst_id IS NULL (orphaned / corrupt records).
        -------------------------------------------------------------------- */
        SET @start_time = GETDATE();
        PRINT '>> Truncating : silver.crm_cust_info';
        TRUNCATE TABLE silver.crm_cust_info;

        PRINT '>> Inserting  : silver.crm_cust_info';
        INSERT INTO silver.crm_cust_info (
            cst_id,
            cst_key,
            cst_firstname,
            cst_lastname,
            cst_gndr,
            cst_material_status,
            cst_create_date
        )
        SELECT
            t.cst_id,
            t.cst_key,

            -- Remove accidental leading/trailing whitespace from free-text name fields
            TRIM(t.cst_firstname)  AS cst_firstname,
            TRIM(t.cst_lastname)   AS cst_lastname,

            /* Normalise gender code to a human-readable label.
               Any value outside the known domain falls back to 'n/a'
               rather than propagating a raw code downstream. */
            CASE UPPER(TRIM(t.cst_gndr))
                WHEN 'M' THEN 'Male'
                WHEN 'F' THEN 'Female'
                ELSE          'n/a'
            END AS cst_gndr,

            /* Normalise marital-status code using the same defensive pattern. */
            CASE UPPER(TRIM(t.cst_material_status))
                WHEN 'S' THEN 'Single'
                WHEN 'M' THEN 'Married'
                ELSE          'n/a'
            END AS cst_material_status,

            t.cst_create_date

        FROM (
            /* Deduplication sub-query: assign rank 1 to the latest version
               of each customer record.  Duplicate cst_ids arise from
               change-capture re-sends in the source CRM system. */
            SELECT
                *,
                ROW_NUMBER() OVER (
                    PARTITION BY cst_id
                    ORDER BY     cst_create_date DESC
                ) AS flag_last
            FROM  bronze.crm_cust_info
            WHERE cst_id IS NOT NULL   -- exclude structurally invalid rows
        ) t
        WHERE t.flag_last = 1;         -- retain only the most-recent snapshot

        SET @end_time = GETDATE();
        PRINT '>> Load Duration : ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' second(s)';
        PRINT '------------------------------------------------------------------------';

        /* --------------------------------------------------------------------
           Table : silver.crm_prd_info
           Transforms:
             - Decompose composite prd_key into a normalised cat_id prefix
               (chars 1–5, hyphens replaced with underscores) and a clean
               prd_key suffix (chars 7 onward).
             - Default NULL cost to 0 (unknown cost ≠ free; flag for review).
             - Expand product-line codes to descriptive labels.
             - Cast prd_start_dt to DATE (strip time component).
             - Derive prd_end_dt as one day before the next version's
               start date using LEAD(), creating a non-overlapping SCD2
               date range.
        -------------------------------------------------------------------- */
        SET @start_time = GETDATE();
        PRINT '>> Truncating : silver.crm_prd_info';
        TRUNCATE TABLE silver.crm_prd_info;

        PRINT '>> Inserting  : silver.crm_prd_info';
        INSERT INTO silver.crm_prd_info (
            prd_id,
            cat_id,
            prd_key,
            prd_nm,
            prd_cost,
            prd_line,
            prd_start_dt,
            prd_end_dt
        )
        SELECT
            c.prd_id,

            /* Extract category identifier from the first 5 chars of the
               composite key; replace hyphens with underscores to match
               the erp_px_cat_g1v2 ID format used in the gold join. */
            REPLACE(SUBSTRING(c.prd_key, 1, 5), '-', '_') AS cat_id,

            /* Strip the category prefix to isolate the product-level key. */
            SUBSTRING(c.prd_key, 7, LEN(c.prd_key))       AS prd_key,

            c.prd_nm,

            /* Treat NULL cost as 0; negative/NULL cost has no business meaning
               for standard product pricing. Flag for upstream data-quality fix. */
            ISNULL(c.prd_cost, 0)                          AS prd_cost,

            /* Expand single-char product-line codes to descriptive labels. */
            CASE UPPER(TRIM(c.prd_line))
                WHEN 'M' THEN 'Mountain'
                WHEN 'S' THEN 'Other Sales'
                WHEN 'R' THEN 'Road'
                WHEN 'T' THEN 'Touring'
                ELSE          'n/a'
            END                                            AS prd_line,

            CAST(c.prd_start_dt AS DATE)                   AS prd_start_dt,

            /* Derive end date as (next version's start date − 1 day).
               This produces a closed, non-overlapping SCD Type 2 date range.
               NULL end date indicates the currently active record. */
            CAST(
                LEAD(c.prd_start_dt) OVER (
                    PARTITION BY c.prd_key
                    ORDER BY     c.prd_start_dt
                ) - 1
            AS DATE)                                       AS prd_end_dt

        FROM bronze.crm_prd_info c;

        SET @end_time = GETDATE();
        PRINT '>> Load Duration : ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' second(s)';
        PRINT '------------------------------------------------------------------------';

        /* --------------------------------------------------------------------
           Table : silver.crm_sales_details
           Transforms:
             - Date columns stored as integers (YYYYMMDD); cast to DATE after
               validating length = 8 and value ≠ 0.  Invalid values → NULL.
             - Enforce the business invariant: sls_sales = sls_quantity × sls_price.
               When the stored value violates this rule (or is NULL / non-positive),
               recompute from the other two components.
             - ABS() applied to all three metrics to eliminate sign errors
               introduced by the source system's credit-note encoding.
             - NULLIF used as a zero-division guard on price and quantity.
        -------------------------------------------------------------------- */
        SET @start_time = GETDATE();
        PRINT '>> Truncating : silver.crm_sales_details';
        TRUNCATE TABLE silver.crm_sales_details;

        PRINT '>> Inserting  : silver.crm_sales_details';
        INSERT INTO silver.crm_sales_details (
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            sls_order_dt,
            sls_ship_dt,
            sls_due_dt,
            sls_sales,
            sls_quantity,
            sls_price
        )
        SELECT
            s.sls_ord_num,
            s.sls_prd_key,
            s.sls_cust_id,

            /* ── Date Columns ─────────────────────────────────────────────
               Source stores dates as INTEGER in YYYYMMDD format.
               Guard conditions: value = 0 or string length ≠ 8 → NULL.   */
            CASE
                WHEN s.sls_order_dt = 0 OR LEN(s.sls_order_dt) != 8 THEN NULL
                ELSE CAST(CAST(s.sls_order_dt AS VARCHAR) AS DATE)
            END AS sls_order_dt,

            CASE
                WHEN s.sls_ship_dt  = 0 OR LEN(s.sls_ship_dt)  != 8 THEN NULL
                ELSE CAST(CAST(s.sls_ship_dt  AS VARCHAR) AS DATE)
            END AS sls_ship_dt,

            CASE
                WHEN s.sls_due_dt   = 0 OR LEN(s.sls_due_dt)   != 8 THEN NULL
                ELSE CAST(CAST(s.sls_due_dt   AS VARCHAR) AS DATE)
            END AS sls_due_dt,

            /* ── Sales Amount ─────────────────────────────────────────────
               Recompute from qty × price when:
                 (a) sls_sales is NULL,
                 (b) sls_sales ≤ 0 (invalid),
                 (c) sls_sales ≠ sls_quantity × sls_price (internal inconsistency).
               ABS() eliminates negative values caused by credit-note sign conventions. */
            CASE
                WHEN s.sls_sales IS NULL
                  OR s.sls_sales <= 0
                  OR s.sls_sales <> s.sls_quantity * s.sls_price
                THEN ABS(ISNULL(s.sls_quantity, 0) * ISNULL(s.sls_price, 0))
                ELSE ABS(s.sls_sales)
            END AS sls_sales,

            /* ── Quantity ─────────────────────────────────────────────────
               Recompute from sales ÷ price when stored quantity is invalid
               or inconsistent with the sales/price relationship.
               NULLIF prevents divide-by-zero when price = 0. */
            CASE
                WHEN s.sls_quantity <= 0
                  OR s.sls_quantity <> s.sls_sales / NULLIF(s.sls_price, 0)
                THEN s.sls_sales / NULLIF(s.sls_price, 0)
                ELSE ABS(s.sls_quantity)
            END AS sls_quantity,

            /* ── Unit Price ───────────────────────────────────────────────
               Recompute from sales ÷ quantity when stored price is invalid
               or inconsistent with the sales/quantity relationship. */
            CASE
                WHEN s.sls_price <= 0
                  OR s.sls_price <> s.sls_sales / NULLIF(ABS(s.sls_quantity), 0)
                THEN s.sls_sales / NULLIF(ABS(s.sls_quantity), 0)
                ELSE ABS(s.sls_price)
            END AS sls_price

        FROM bronze.crm_sales_details s;

        SET @end_time = GETDATE();
        PRINT '>> Load Duration : ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' second(s)';
        PRINT '------------------------------------------------------------------------';

        /* ====================================================================
           SECTION 2 : ERP TABLES
           Source system : ERP (Enterprise Resource Planning)
        ==================================================================== */
        PRINT '------------------------------------------------------------------------';
        PRINT 'Loading ERP Tables';
        PRINT '------------------------------------------------------------------------';

        /* --------------------------------------------------------------------
           Table : silver.erp_cust_az12
           Transforms:
             - Strip the 'NAS' prefix from CID values where present;
               this prefix is an ERP system artefact with no business meaning.
             - Nullify future birth dates (data-entry errors; a person cannot
               be born after today).
             - Harmonise gender free-text variants ('F', 'FEMALE', 'M', 'MALE')
               to the CRM-aligned canonical labels 'Female' / 'Male'.
        -------------------------------------------------------------------- */
        SET @start_time = GETDATE();
        PRINT '>> Truncating : silver.erp_cust_az12';
        TRUNCATE TABLE silver.erp_cust_az12;

        PRINT '>> Inserting  : silver.erp_cust_az12';
        INSERT INTO silver.erp_cust_az12 (
            CID,
            BDATE,
            GEN
        )
        SELECT
            /* Remove ERP-specific 'NAS' prefix so CID aligns with
               the CRM cst_key used in downstream gold-layer joins. */
            CASE
                WHEN CID LIKE 'NAS%' THEN SUBSTRING(CID, 4, LEN(CID))
                ELSE CID
            END AS CID,

            /* Future birth dates are logically impossible; set to NULL
               and surface for upstream data-quality remediation. */
            CASE
                WHEN BDATE > GETDATE() THEN NULL
                ELSE BDATE
            END AS BDATE,

            /* Harmonise multi-variant gender strings to a single canonical
               label set, matching the CRM gender dimension. */
            CASE UPPER(TRIM(GEN))
                WHEN 'F'      THEN 'Female'
                WHEN 'FEMALE' THEN 'Female'
                WHEN 'M'      THEN 'Male'
                WHEN 'MALE'   THEN 'Male'
                ELSE GEN   -- preserve unrecognised values for audit review
            END AS GEN

        FROM bronze.erp_cust_az12;

        SET @end_time = GETDATE();
        PRINT '>> Load Duration : ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' second(s)';
        PRINT '------------------------------------------------------------------------';

        /* --------------------------------------------------------------------
           Table : silver.erp_loc_a101
           Transforms:
             - Strip hyphens from CID to align with the CRM/ERP key format.
             - Expand ISO-2 country codes to full country names.
             - Coalesce empty strings and NULLs to 'n/a' sentinel.
           !! DATA-QUALITY NOTE !!
               'US' / 'USA' currently maps to 'United Kingdom'.
               Verify with the source-system owner whether this is intentional
               (e.g., a regional-sales remapping) or a defect.
               If a defect, change the target value to 'United States'.
        -------------------------------------------------------------------- */
        SET @start_time = GETDATE();
        PRINT '>> Truncating : silver.erp_loc_a101';
        TRUNCATE TABLE silver.erp_loc_a101;

        PRINT '>> Inserting  : silver.erp_loc_a101';
        INSERT INTO silver.erp_loc_a101 (
            CID,
            CNTRY
        )
        SELECT
            /* Remove hyphens from customer ID to produce a uniform key
               that joins cleanly to crm_cust_info.cst_key. */
            REPLACE(CID, '-', '') AS CID,

            /* Expand country codes to full names; guard against both
               NULL and empty-string representations of missing data. */
            CASE
                WHEN TRIM(CNTRY) = 'DE'               THEN 'Germany'
                WHEN TRIM(CNTRY) IN ('US', 'USA')     THEN 'United States'  -- !! verify mapping above
                WHEN TRIM(CNTRY) = '' OR CNTRY IS NULL THEN 'n/a'
                ELSE TRIM(CNTRY)
            END AS CNTRY

        FROM bronze.erp_loc_a101;

        SET @end_time = GETDATE();
        PRINT '>> Load Duration : ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' second(s)';
        PRINT '------------------------------------------------------------------------';

        /* --------------------------------------------------------------------
           Table : silver.erp_px_cat_g1v2
           Transforms:
             - Pass-through load; no cleansing rules identified for this
               reference/lookup table at current data-quality assessment.
             - Revisit if upstream category governance introduces code changes.
        -------------------------------------------------------------------- */
        SET @start_time = GETDATE();
        PRINT '>> Truncating : silver.erp_px_cat_g1v2';
        TRUNCATE TABLE silver.erp_px_cat_g1v2;

        PRINT '>> Inserting  : silver.erp_px_cat_g1v2';
        INSERT INTO silver.erp_px_cat_g1v2 (
            ID,
            CAT,
            SUBCAT,
            MAINTENANCE
        )
        SELECT
            ID,
            CAT,
            SUBCAT,
            MAINTENANCE
        FROM bronze.erp_px_cat_g1v2;

        SET @end_time = GETDATE();
        PRINT '>> Load Duration : ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' second(s)';
        PRINT '------------------------------------------------------------------------';

        /* ====================================================================
           BATCH SUMMARY
        ==================================================================== */
        SET @batch_end_time = GETDATE();
        PRINT '========================================================================';
        PRINT 'silver Layer Load  –  COMPLETE';
        PRINT '>> Total Batch Duration : '
              + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR)
              + ' second(s)';
        PRINT '========================================================================';

    END TRY

    /* ------------------------------------------------------------------------
       Structured error handler.
       Surfaces error metadata to the calling process / monitoring agent.
       Re-raise or log to an audit table as required by your ops framework.
    ------------------------------------------------------------------------ */
    BEGIN CATCH
        PRINT '========================================================================';
        PRINT 'silver Layer Load  –  FAILED';
        PRINT '  Error Message : ' + ERROR_MESSAGE();
        PRINT '  Error Number  : ' + CAST(ERROR_NUMBER()  AS NVARCHAR);
        PRINT '  Error State   : ' + CAST(ERROR_STATE()   AS NVARCHAR);
        PRINT '  Error Line    : ' + CAST(ERROR_LINE()    AS NVARCHAR);  -- added for faster debugging
        PRINT '========================================================================';
    END CATCH

END;

/* ============================================================================
   Execution
   Run manually or invoke from the orchestration layer (e.g., ADF pipeline,
   SQL Agent job, dbt pre-hook).
============================================================================ */
EXEC silver.load_silver;
