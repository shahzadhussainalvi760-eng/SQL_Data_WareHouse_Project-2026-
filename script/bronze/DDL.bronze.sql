/*
======================================================================
Create Database and Schemas
======================================================================

Script Purpose:
    This script creates a new database named 'DataWarehouse' after checking if it already exists.
    If the database exists, it is dropped and recreated. Additionally, the script sets up three schemas
    within the database: 'bronze', 'silver', and 'gold'.

WARNING:
    Running this script will drop the entire 'DataWarehouse' database if it exists.
    All data in the database will be permanently deleted. Proceed with caution
    and ensure you have proper backups before running this script.
*/
USE master;
GO
--Drop and recreate the 'DataWareHouse' database
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DataWarehouse')
BEGIN
    ALTER DATABASE DataWarehouse SET SINGLE_USER ROLLBACK IMMEDIATE;
    DROP DATABASE DataWarehouse;
END;
GO
--Create Database 'DataWarehouse'
CREATE DATABASE DataWarehouse;
GO

USE DataWarehouse;
GO
-- Create SCHEMA
CREATE SCHEMA bronze;
GO
CREATE SCHEMA silver;
GO
CREATE SCHEMA gold;

-- create tabel
IF OBJECT_ID('bronze.crm_cust_info','U') IS NOT NULL
DROP TABLE bronze.crm_cust_info ;
CREATE TABLE bronze.crm_cust_info(
      cst_id INT,
      cst_key NVARCHAR(50),
      cst_firstname NVARCHAR(50),
      cst_lastname NVARCHAR(50),
      cst_material_status NVARCHAR(50),
      cst_gndr NVARCHAR(50),
      cst_create_date DATE
    );
---
IF OBJECT_ID('bronze.crm_prd_info','U') IS NOT NULL
DROP TABLE bronze.crm_prd_info ;
CREATE TABLE bronze.crm_prd_info(
prd_id	INT ,
prd_key	 NVARCHAR(50),
prd_nm	 NVARCHAR(50),
prd_cost	INT,
prd_line	NVARCHAR(50),
prd_start_dt DATETIME,
prd_end_dt   DATETIME

);
--
IF OBJECT_ID('bronze.crm_sales_details','U') IS NOT NULL
DROP TABLE bronze.crm_sales_details;

CREATE TABLE bronze.crm_sales_details(
    sls_prd_key NVARCHAR(50),
    sls_cust_id   NVARCHAR(50),
    sls_order_dt   INT,
    sls_ship_dt	   INT,
    sls_due_dt	    INT,
    sls_sales	    INT,
    sls_quantity    INT,
    sls_price       NVARCHAR(50)

);
---
IF OBJECT_ID('bronze.erp_cust_az12','U') IS NOT NULL
DROP TABLE bronze.erp_cust_az12;
CREATE TABLE bronze.erp_cust_az12(
CID	 NVARCHAR(50),
BDATE   DATE,
GEN VARCHAR(50)

);

---
IF OBJECT_ID('bronze.erp_loc_a101','U') IS NOT NULL
DROP TABLE bronze.erp_loc_a101;
CREATE TABLE bronze.erp_loc_a101(
CID	  NVARCHAR(50),
CNTRY  NVARCHAR(50)

);

--
IF OBJECT_ID('bronze.erp_px_cat_g1v2','U') IS NOT NULL
DROP TABLE bronze.erp_px_cat_g1v2;
CREATE TABLE bronze.erp_px_cat_g1v2(
ID	 NVARCHAR(50),
CAT	 NVARCHAR(50),
SUBCAT	NVARCHAR(50),
MAINTENANCE NVARCHAR(50)

);
--------------------------------------------------------------------------------
