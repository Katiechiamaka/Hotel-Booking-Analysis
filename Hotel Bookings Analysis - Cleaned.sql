-- ============================================================
--  HOTEL BOOKINGS — DATA CLEANING SCRIPT
--  Source: hotel_bookings.csv  |  119,390 rows  |  32 columns

--  Issues found:
--    1. 31,994 duplicate rows
--    2. NULLs  — country (488), agent (16,340), company (112,593), children (4)
--    3. "Undefined" sentinel values in meal, market_segment, distribution_channel
--    4. 180 bookings with 0 guests (adults + children + babies = 0)
--    5. 403 bookings with 0 adults
--    6. 1 negative ADR value
--    7. Extreme ADR outlier (max = 5,400)
--    8. arrival_date_month stored as text, not sortable
--    9. reservation_status_date stored as VARCHAR, not DATE
--   10. agent & company stored as FLOAT instead of INTEGER
-- ============================================================


-- ------------------------------------------------------------
-- STEP 0 — Load raw data into a staging table
-- ------------------------------------------------------------

CREATE TABLE hotel_bookings_raw (
    hotel                           VARCHAR(50),
    is_canceled                     INT,
    lead_time                       INT,
    arrival_date_year               INT,
    arrival_date_month              VARCHAR(15),
    arrival_date_week_number        INT,
    arrival_date_day_of_month       INT,
    stays_in_weekend_nights         INT,
    stays_in_week_nights            INT,
    adults                          INT,
    children                        FLOAT,       -- has 4 NULLs; FLOAT from source
    babies                          INT,
    meal                            VARCHAR(20),
    country                         VARCHAR(10),
    market_segment                  VARCHAR(30),
    distribution_channel            VARCHAR(30),
    is_repeated_guest               INT,
    previous_cancellations          INT,
    previous_bookings_not_canceled  INT,
    reserved_room_type              VARCHAR(5),
    assigned_room_type              VARCHAR(5),
    booking_changes                 INT,
    deposit_type                    VARCHAR(20),
    agent                           FLOAT,       -- has 16,340 NULLs; FLOAT from source
    company                         FLOAT,       -- has 112,593 NULLs; FLOAT from source
    days_in_waiting_list            INT,
    customer_type                   VARCHAR(30),
    adr                             FLOAT,
    required_car_parking_spaces     INT,
    total_of_special_requests       INT,
    reservation_status              VARCHAR(20),
    reservation_status_date         VARCHAR(20)  -- stored as text, needs casting
);

-- Import CSV 
-- Verifying the imported datasets

SELECT COUNT(*)
FROM hotel_bookings_raw;

SELECT *
FROM hotel_bookings_raw;

-- ============================================================
-- STEP 1 — Remove exact duplicate rows
-- ============================================================
-- Keep one occurrence of each fully-duplicated row.
-- 31,994 duplicates were identified across all 32 columns.

CREATE TABLE hotel_bookings_cleaned LIKE hotel_bookings_raw;

INSERT INTO hotel_bookings_cleaned
SELECT 
    hotel, is_canceled, lead_time,
    arrival_date_year, arrival_date_month,
    arrival_date_week_number, arrival_date_day_of_month,
    stays_in_weekend_nights, stays_in_week_nights,
    adults, children, babies, meal, country,
    market_segment, distribution_channel,
    is_repeated_guest, previous_cancellations,
    previous_bookings_not_canceled,
    reserved_room_type, assigned_room_type,
    booking_changes, deposit_type,
    agent, company, days_in_waiting_list,
    customer_type, adr,
    required_car_parking_spaces, total_of_special_requests,
    reservation_status, reservation_status_date
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY
                   hotel, is_canceled, lead_time,
                   arrival_date_year, arrival_date_month,
                   arrival_date_week_number, arrival_date_day_of_month,
                   stays_in_weekend_nights, stays_in_week_nights,
                   adults, children, babies, meal, country,
                   market_segment, distribution_channel,
                   is_repeated_guest, previous_cancellations,
                   previous_bookings_not_canceled,
                   reserved_room_type, assigned_room_type,
                   booking_changes, deposit_type, agent, company,
                   days_in_waiting_list, customer_type, adr,
                   required_car_parking_spaces, total_of_special_requests,
                   reservation_status, reservation_status_date
               ORDER BY (SELECT NULL)
           ) AS rn
    FROM hotel_bookings_raw
) ranked
WHERE rn = 1;
-- Result: 87,392 rows retained due to duplicated rows affected

-- checking the cleaned dataset
SELECT *
FROM hotel_bookings_cleaned;


-- ============================================================
-- STEP 2 — Fixing NULL values
-- ============================================================

-- 2a. children: 4 NULLs - default to 0 (most likely no children)
UPDATE hotel_bookings_cleaned
SET children = 0
WHERE children IS NULL;

-- 2b. country: 452 NULLs - replace with 'Unknown'
UPDATE hotel_bookings_cleaned
SET country = 'Unknown'
WHERE country IS NULL OR company = '';

-- 2c. Agent: 12,191 NULLs - replace with 0 (no agent used)
-- Also cast to INT now that NULLs are resolved
UPDATE hotel_bookings_cleaned
SET agent = 0
WHERE agent IS NULL OR agent = '';

-- 2d. company: 82,133 NULLs - replace with 0 (no company affiliation)
UPDATE hotel_bookings_cleaned
SET company = 0
WHERE company IS NULL OR company = '';


-- ============================================================
-- STEP 3 — Replace 'Undefined' sentinel strings
-- ============================================================

-- 3a. meal: 'Undefined' - 'SC' (Self Catering / no meal plan)
-- BB=Bed & Breakfast, HB=Half Board, FB=Full Board, SC=No Meal
UPDATE hotel_bookings_cleaned
SET meal = 'SC'
WHERE meal = 'Undefined';

-- 3b. market_segment: 'Undefined' - 'Other'
UPDATE hotel_bookings_cleaned
SET market_segment = 'Other'
WHERE market_segment = 'Undefined';

-- 3c. distribution_channel: 'Undefined' → 'Other'
UPDATE hotel_bookings_cleaned
SET distribution_channel = 'Other'
WHERE distribution_channel = 'Undefined';


-- ============================================================
-- STEP 4 — Remove invalid guest records
-- ============================================================
-- 166 bookings have 0 adults AND 0 children AND 0 babies.
-- A hotel booking with no guests is logically impossible.

-- 4a. Checking if  "invalid guest" bookings exist 
SELECT COUNT(*) 
FROM hotel_bookings_cleaned
WHERE adults = 0 AND children = 0 AND babies = 0;

-- 4b. Deleting invalid records
DELETE FROM hotel_bookings_cleaned
WHERE adults = 0
  AND COALESCE(children, 0) = 0
  AND babies = 0;
-- 166 rows removed

-- 4c. checking for invalid hotel bookings
SELECT *
FROM hotel_bookings_cleaned
WHERE adults = 0 AND children = 0 AND babies = 0;

-- ============================================================
-- STEP 5 — Fix invalid ADR (Average Daily Rate)
-- ============================================================

-- 5a. 1 negative ADR - set to 0 (may be a data entry error)
UPDATE hotel_bookings_cleaned
SET adr = 0
WHERE adr < 0;

-- 5b. Flag extreme ADR outlier (max = 5,400 vs mean ~102, std ~51)
--  Values > 3 std deviations above mean (~255) are suspicious.
--  We flag rather than delete to preserve the record.
ALTER TABLE hotel_bookings_cleaned
ADD COLUMN adr_outlier_flag INT 
DEFAULT 0;

UPDATE hotel_bookings_cleaned
SET adr_outlier_flag = 1
WHERE adr > (
    SELECT avg_adr + (3 * std_adr)
    FROM (
        SELECT AVG(adr) AS avg_adr, STD(adr) AS std_adr
        FROM hotel_bookings_cleaned
    ) AS stats
);

-- ============================================================
-- STEP 6 — Fix data types
-- ============================================================

-- 6a. children — convert from FLOAT to INT
ALTER TABLE hotel_bookings_cleaned 
MODIFY COLUMN children INT;

-- 6b. agent — convert from FLOAT to INT
ALTER TABLE hotel_bookings_cleaned 
MODIFY COLUMN agent INT;

-- 6c. company — convert from FLOAT to INT
ALTER TABLE hotel_bookings_cleaned
MODIFY COLUMN company INT;

-- 6d. reservation_status_date — convert from VARCHAR to DATE
ALTER TABLE hotel_bookings_cleaned 
MODIFY COLUMN reservation_status_date DATE;

-- ============================================================
-- STEP 7 — Add a sortable arrival_date column
-- ============================================================
-- arrival_date_month is a full month name (e.g. 'July'), not sortable.
-- Build a proper DATE column from the three separate parts.

-- 7a. Add arrival_date column
ALTER TABLE hotel_bookings_cleaned 
ADD COLUMN arrival_date DATE;

UPDATE hotel_bookings_cleaned
SET arrival_date = STR_TO_DATE(
    CONCAT(
        arrival_date_year, '-',
        CASE arrival_date_month
            WHEN 'January'   THEN '1' 
            WHEN 'February'  THEN '2'
            WHEN 'March'     THEN '3' 
            WHEN 'April'     THEN '4'
            WHEN 'May'       THEN '5' 
            WHEN 'June'      THEN '6'
            WHEN 'July'      THEN '7'
            WHEN 'August'    THEN '8'
            WHEN 'September' THEN '9'
            WHEN 'October'   THEN '10'
            WHEN 'November'  THEN '11' 
            WHEN 'December'  THEN '12'
        END, '-',
        LPAD(arrival_date_day_of_month, 2, '0')
    ), '%Y-%m-%d'
);


-- ============================================================
-- STEP 8 — Add a total_guests derived column
-- ============================================================
ALTER TABLE hotel_bookings_cleaned
    ADD COLUMN total_guests INT
    GENERATED ALWAYS AS (adults + COALESCE(children, 0) + babies) STORED;


-- ============================================================
-- STEP 9 — Add a total_nights derived column
-- ============================================================
ALTER TABLE hotel_bookings_cleaned
    ADD COLUMN total_nights INT
    GENERATED ALWAYS AS (stays_in_weekend_nights + stays_in_week_nights) STORED;

-- ============================================================
-- STEP 10. Adding additional columns
-- ============================================================
-- 10a. creating a revenue column
ALTER TABLE hotel_bookings_cleaned
ADD COLUMN revenue DECIMAL(10,2);

UPDATE hotel_bookings_cleaned
SET revenue = adr * (stays_in_week_nights + stays_in_weekend_nights)
WHERE is_canceled = 0;

-- 10b. calculating the length of stay
ALTER TABLE hotel_bookings_cleaned 
ADD COLUMN length_of_stay INT;

UPDATE hotel_bookings_cleaned
SET length_of_stay = stays_in_week_nights + stays_in_weekend_nights;

-- 10c. create new column for rooms changed
ALTER TABLE hotel_bookings_cleaned
ADD COLUMN room_changed VARCHAR(3);

UPDATE hotel_bookings_cleaned
SET room_changed = 
    CASE 
        WHEN reserved_room_type <> assigned_room_type THEN 'Yes'
        ELSE 'No'
    END;
    
-- 10d. creating a category for guest_type
ALTER TABLE hotel_bookings_cleaned
ADD COLUMN guest_type VARCHAR(20);

UPDATE hotel_bookings_cleaned
SET guest_type =
    CASE
        WHEN customer_type = 'Transient' AND is_repeated_guest = 1 THEN 'Returning Guest'
        WHEN customer_type = 'Transient' AND is_repeated_guest = 0 THEN 'New Guest'
        WHEN customer_type = 'Transient-Party' AND is_repeated_guest = 1 THEN 'Returning Group'
        WHEN customer_type = 'Transient-Party' AND is_repeated_guest = 0 THEN 'New Group'
        WHEN customer_type = 'Contract' THEN 'Contract Guest'
        WHEN customer_type = 'Group' THEN 'Group Guest'
        ELSE 'Other'
    END;
-- ============================================================
-- STEP 11 — Final validation checks
-- ============================================================

-- 11a. Checking for any remaining NULLs in critical columns
SELECT
    SUM(CASE WHEN hotel                  IS NULL THEN 1 ELSE 0 END) AS null_hotel,
    SUM(CASE WHEN children               IS NULL THEN 1 ELSE 0 END) AS null_children,
    SUM(CASE WHEN country                IS NULL THEN 1 ELSE 0 END) AS null_country,
    SUM(CASE WHEN agent                  IS NULL THEN 1 ELSE 0 END) AS null_agent,
    SUM(CASE WHEN company                IS NULL THEN 1 ELSE 0 END) AS null_company,
    SUM(CASE WHEN arrival_date           IS NULL THEN 1 ELSE 0 END) AS null_arrival_date,
    SUM(CASE WHEN reservation_status_date IS NULL THEN 1 ELSE 0 END) AS null_res_date
FROM hotel_bookings_cleaned;

-- 11b. Checking no zero-guest bookings remain
SELECT COUNT(*) AS zero_guest_bookings
FROM hotel_bookings_cleaned
WHERE total_guests = 0;

-- 11c. Checking no negative ADR
SELECT COUNT(*) AS negative_adr
FROM hotel_bookings_cleaned
WHERE adr < 0;

-- 11d. Checking no 'Undefined' strings remain
SELECT COUNT(*) AS undefined_remaining
FROM hotel_bookings_cleaned
WHERE meal = 'Undefined'
   OR market_segment = 'Undefined'
   OR distribution_channel = 'Undefined';

-- 11e. Checking duplicate count should be 0
SELECT COUNT(*) - COUNT(DISTINCT
    CONCAT(hotel, is_canceled, lead_time, arrival_date, adults,
           children, babies, adr, reservation_status)
) AS approx_duplicates
FROM hotel_bookings_cleaned;


-- 11ei. checking the rows with reoccurrences
SELECT 
    hotel, is_canceled, lead_time,
    arrival_date_year, arrival_date_month,
    arrival_date_day_of_month, adults, 
    children, babies, adr,
    reservation_status, country, agent,
    COUNT(*) AS occurrences
FROM hotel_bookings_cleaned
GROUP BY 
    hotel, is_canceled, lead_time,
    arrival_date_year, arrival_date_month,
    arrival_date_day_of_month, adults,
    children, babies, adr,
    reservation_status, country, agent
HAVING COUNT(*) > 1
ORDER BY occurrences DESC
LIMIT 20;

-- 11eii. Verifying the records for genuie reoccurrences
SELECT *
FROM hotel_bookings_cleaned
WHERE arrival_date_year = 2017
  AND arrival_date_month = 'January'
  AND arrival_date_day_of_month = 16
  AND adults = 1
  AND adr = 55
  AND reservation_status = 'Check-Out'
  AND country = 'PRT'
  AND agent = 0
LIMIT 20;

-- Check: row count summary
SELECT
    (SELECT COUNT(*) FROM hotel_bookings_raw)      AS raw_rows,
    (SELECT COUNT(*) FROM hotel_bookings_cleaned)  AS clean_rows,
    (SELECT COUNT(*) FROM hotel_bookings_raw)
     - (SELECT COUNT(*) FROM hotel_bookings_cleaned) AS rows_removed;


-- ============================================================
-- STEP 12 — Creating final clean table
-- ============================================================

ALTER TABLE hotel_bookings_cleaned RENAME TO hotel_bookings;

-- Optional: drop the original month/year/day columns now that
-- arrival_date consolidates them
-- ALTER TABLE hotel_bookings_clean
--     DROP COLUMN arrival_date_year,
--     DROP COLUMN arrival_date_month,
--     DROP COLUMN arrival_date_week_number,
--     DROP COLUMN arrival_date_day_of_month;
