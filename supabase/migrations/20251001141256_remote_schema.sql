SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";

CREATE SCHEMA IF NOT EXISTS "expense_tracker";

ALTER SCHEMA "expense_tracker" OWNER TO "postgres";

CREATE EXTENSION IF NOT EXISTS "pgsodium";

COMMENT ON SCHEMA "public" IS 'standard public schema';

CREATE SCHEMA IF NOT EXISTS "tests";

ALTER SCHEMA "tests" OWNER TO "postgres";

CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgtap" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

CREATE TYPE "expense_tracker"."decimal_point_enum" AS ENUM (
    'NONE',
    'ONE',
    'TWO',
    'THREE',
    'FOUR',
    'FIVE'
);

ALTER TYPE "expense_tracker"."decimal_point_enum" OWNER TO "postgres";

CREATE TYPE "expense_tracker"."flow_type_enum" AS ENUM (
    'EXPENSE',
    'INCOME'
);

ALTER TYPE "expense_tracker"."flow_type_enum" OWNER TO "postgres";

CREATE TYPE "expense_tracker"."invoice_status_enum" AS ENUM (
    'UNCATEGORIZED',
    'CATEGORIZED'
);

ALTER TYPE "expense_tracker"."invoice_status_enum" OWNER TO "postgres";

CREATE TYPE "expense_tracker"."repeat_interval_enum" AS ENUM (
    'DAILY',
    'WEEKLY',
    'MONTHLY',
    'YEARLY'
);

ALTER TYPE "expense_tracker"."repeat_interval_enum" OWNER TO "postgres";

CREATE TYPE "expense_tracker"."unit_position_enum" AS ENUM (
    'LEFT',
    'RIGHT'
);

ALTER TYPE "expense_tracker"."unit_position_enum" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "expense_tracker"."cascade_soft_delete_category"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'expense_tracker', 'public'
    AS $$
BEGIN
    -- If this is a soft delete operation on a parent category
    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL AND OLD.parent_id IS NULL THEN
        -- Update all child categories to also be soft deleted
        UPDATE expense_tracker.category
        SET deleted_at = NEW.deleted_at
        WHERE parent_id = OLD.id
        AND deleted_at IS NULL;
    END IF;
    
    RETURN NEW;
END;
$$;

ALTER FUNCTION "expense_tracker"."cascade_soft_delete_category"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "expense_tracker"."create_invoice_with_items"("invoice_data" "jsonb", "invoice_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'expense_tracker', 'public'
    AS $$
DECLARE
  new_invoice_id uuid;
  item_count     integer;
  err_state      text;
  err_txt        text;
BEGIN
  -- 1) Basic null check on invoice_data
  IF invoice_data IS NULL THEN
    RAISE EXCEPTION 'invoice_data cannot be null';
  END IF;

  -- 2) Insert the invoice row
  INSERT INTO expense_tracker.invoice (
    invoice_number, invoice_url, journal, total_amount,
    invoice_type, transaction_type, counter_extension,
    transaction_type_counter, counter_total, requested_by,
    signed_by, pft_time, is_valid, note, user_id,
    company_id, currency_code
  )
  SELECT
    d.invoice_number,
    d.invoice_url,
    d.journal,
    d.total_amount::numeric,
    d.invoice_type::integer,
    d.transaction_type::integer,
    d.counter_extension,
    d.transaction_type_counter::integer,
    d.counter_total::integer,
    d.requested_by,
    d.signed_by,
    d.pft_time::timestamptz,
    COALESCE(d.is_valid::boolean, true),
    d.note,
    auth.uid()::uuid,
    d.company_id::uuid,
    d.currency_code
  FROM (
    SELECT
      invoice_data->>'invoice_number'           AS invoice_number,
      invoice_data->>'invoice_url'              AS invoice_url,
      invoice_data->>'journal'                  AS journal,
      invoice_data->>'total_amount'             AS total_amount,
      invoice_data->>'invoice_type'             AS invoice_type,
      invoice_data->>'transaction_type'         AS transaction_type,
      invoice_data->>'counter_extension'        AS counter_extension,
      invoice_data->>'transaction_type_counter' AS transaction_type_counter,
      invoice_data->>'counter_total'            AS counter_total,
      invoice_data->>'requested_by'             AS requested_by,
      invoice_data->>'signed_by'                AS signed_by,
      invoice_data->>'pft_time'                 AS pft_time,
      invoice_data->>'is_valid'                 AS is_valid,
      invoice_data->>'note'                     AS note,
      invoice_data->>'company_id'               AS company_id,
      invoice_data->>'currency_code'            AS currency_code
  ) AS d
  RETURNING id
  INTO new_invoice_id;

  -- 3) Bulk-insert the items and count how many went in
  -- Only if there are items to insert
  IF invoice_items IS NOT NULL AND jsonb_typeof(invoice_items) = 'array' THEN
    WITH parsed AS (
      SELECT *
      FROM jsonb_to_recordset(invoice_items) AS t(
        item_order      integer,
        name            text,
        unit_price      numeric,
        quantity        numeric,
        total           numeric,
        tax_base_amount numeric,
        vat_amount      numeric,
        description     text,
        label_id        uuid,
        category_id     uuid
      )
    ),
    ins AS (
      INSERT INTO expense_tracker.invoice_item (
        invoice_id, item_order, name,
        unit_price, quantity, total,
        tax_base_amount, vat_amount,
        description, label_id, category_id
      )
      SELECT
        new_invoice_id,
        p.item_order, p.name,
        p.unit_price, p.quantity, p.total,
        p.tax_base_amount, p.vat_amount,
        p.description, p.label_id, p.category_id
      FROM parsed AS p
      RETURNING 1
    )
    SELECT COUNT(*) INTO item_count FROM ins;
  ELSE
    item_count := 0;
  END IF;

  -- 4) Return success JSON
  RETURN jsonb_build_object(
    'success',    true,
    'invoice_id', new_invoice_id,
    'item_count', item_count
  );

EXCEPTION
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS 
      err_state = RETURNED_SQLSTATE,
      err_txt = MESSAGE_TEXT;
      
    -- Re-raise certain critical errors (optional)
    IF err_state IN ('23505', '23503') THEN -- Unique violation, FK violation
      RAISE;
    END IF;
    
    RETURN jsonb_build_object(
      'success',       false,
      'error_message', err_txt,
      'error_code',    err_state
    );
END;
$$;


ALTER FUNCTION "expense_tracker"."create_invoice_with_items"("invoice_data" "jsonb", "invoice_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "expense_tracker"."finance_record_insert_summary"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'expense_tracker', 'public'
    AS $$
DECLARE
  v_flow_type expense_tracker.flow_type_enum;
  v_month     smallint;
  v_year      integer;
BEGIN
  -- 1) load the flow_type from the category
  SELECT flow_type
    INTO v_flow_type
    FROM expense_tracker.category
   WHERE id = NEW.category_id;

  -- 2) extract month and year from transferred_at
  v_month := EXTRACT(MONTH FROM NEW.transferred_at)::smallint;
  v_year  := EXTRACT(YEAR  FROM NEW.transferred_at)::integer;

  -- 3) upsert into user_details: add to income or expense
  INSERT INTO expense_tracker.user_details
    (user_id, month, year, income, expense)
  VALUES
    (
      NEW.user_id,
      v_month,
      v_year,
      CASE WHEN v_flow_type = 'INCOME' THEN NEW.amount ELSE 0 END,
      CASE WHEN v_flow_type = 'EXPENSE' THEN NEW.amount ELSE 0 END
    )
  ON CONFLICT (user_id, month, year) DO UPDATE
    SET
      income  = user_details.income  + EXCLUDED.income,
      expense = user_details.expense + EXCLUDED.expense;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "expense_tracker"."finance_record_insert_summary"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "expense_tracker"."finance_record_update_summary"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'expense_tracker', 'public'
    AS $$
DECLARE
  v_old_flow expense_tracker.flow_type_enum;
  v_old_m    smallint;
  v_old_y    integer;
  v_new_flow expense_tracker.flow_type_enum;
  v_new_m    smallint;
  v_new_y    integer;
BEGIN
  /* === subtract OLD if it was active before === */
  IF OLD.deleted_at IS NULL THEN
    SELECT flow_type
      INTO v_old_flow
      FROM expense_tracker.category
     WHERE id = OLD.category_id;
    v_old_m := EXTRACT(MONTH FROM OLD.transferred_at)::smallint;
    v_old_y := EXTRACT(YEAR  FROM OLD.transferred_at)::integer;

    UPDATE expense_tracker.user_details
       SET income      = income - CASE WHEN v_old_flow = 'INCOME' THEN OLD.amount ELSE 0 END,
           expense     = expense - CASE WHEN v_old_flow = 'EXPENSE' THEN OLD.amount ELSE 0 END,
           modified_at = now()
     WHERE user_id = OLD.user_id
       AND month   = v_old_m
       AND year    = v_old_y;
  END IF;

  /* === add NEW if it is active after === */
  IF NEW.deleted_at IS NULL THEN
    SELECT flow_type
      INTO v_new_flow
      FROM expense_tracker.category
     WHERE id = NEW.category_id;
    v_new_m := EXTRACT(MONTH FROM NEW.transferred_at)::smallint;
    v_new_y := EXTRACT(YEAR  FROM NEW.transferred_at)::integer;

    INSERT INTO expense_tracker.user_details
      (user_id, month, year, income, expense, modified_at)
    VALUES
      (
        NEW.user_id,
        v_new_m,
        v_new_y,
        CASE WHEN v_new_flow = 'INCOME'  THEN NEW.amount ELSE 0 END,
        CASE WHEN v_new_flow = 'EXPENSE' THEN NEW.amount ELSE 0 END,
        now()
      )
    ON CONFLICT (user_id, month, year) DO UPDATE
      SET income      = user_details.income  + EXCLUDED.income,
          expense     = user_details.expense + EXCLUDED.expense,
          modified_at = now();
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "expense_tracker"."finance_record_update_summary"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "expense_tracker"."prevent_invoice_id_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'expense_tracker', 'public'
    AS $$
BEGIN
    -- Check if the invoice_id is being changed in an UPDATE operation
    -- OLD refers to the row data *before* the update
    -- NEW refers to the row data *after* the update (as proposed)
    IF OLD.invoice_id IS DISTINCT FROM NEW.invoice_id THEN
        RAISE EXCEPTION 'Changing the invoice_id of an invoice_item is not allowed.';
    END IF;

    -- If the invoice_id is not changing, allow the update to proceed
    RETURN NEW;
END;
$$;


ALTER FUNCTION "expense_tracker"."prevent_invoice_id_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "expense_tracker"."seed_categories_for_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'expense_tracker', 'public'
    AS $$
declare
  temp_rec record;
  -- a mapping from template_id → real category_id
  id_map     jsonb := '{}';
  real_id    uuid;
begin
  -- 1) insert top‐level templates
  for temp_rec in
    select template_id, name, color, list_order, flow_type
    from expense_tracker.default_category_template
    where parent_template_id is null
    order by list_order
  loop
    insert into expense_tracker.category
      (id, name, color, list_order, flow_type, user_id)
    values
      (expense_tracker.uuid_generate_v7(),
       temp_rec.name,
       temp_rec.color,
       temp_rec.list_order,
       temp_rec.flow_type,
       new.id)
    returning id into real_id;

    id_map := id_map || jsonb_build_object(
      temp_rec.template_id::text, real_id::text
    );
  end loop;

  -- 2) insert second-level (and deeper) if any
  for temp_rec in
    select template_id, name, color, list_order,
           flow_type, parent_template_id
    from expense_tracker.default_category_template
    where parent_template_id is not null
    order by parent_template_id, list_order
  loop
    insert into expense_tracker.category
      (id, name, color, list_order, flow_type,
       user_id, parent_id)
    values
      (expense_tracker.uuid_generate_v7(),
       temp_rec.name,
       temp_rec.color,
       temp_rec.list_order,
       temp_rec.flow_type,
       new.id,
       (id_map ->> temp_rec.parent_template_id::text)::uuid)
    returning id into real_id;

    id_map := id_map || jsonb_build_object(
      temp_rec.template_id::text, real_id::text
    );
  end loop;

  return new;
end;
$$;


ALTER FUNCTION "expense_tracker"."seed_categories_for_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "expense_tracker"."set_modified_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'expense_tracker', 'public'
    AS $$
begin
  IF row(NEW.*) IS DISTINCT FROM row(OLD.*) THEN
    NEW.modified_at = now();
  END IF;
  RETURN NEW;
end;
$$;


ALTER FUNCTION "expense_tracker"."set_modified_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "expense_tracker"."uuid_generate_v7"() RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'expense_tracker', 'public'
    AS $$
BEGIN
  RETURN encode(
          set_bit(
            set_bit(
              overlay(uuid_send(gen_random_uuid())
                      placing substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3)
                      from 1 for 6
              ),
              52, 1
            ),
            53, 1
          ),
          'hex'
      )::uuid;
END;
$$;


ALTER FUNCTION "expense_tracker"."uuid_generate_v7"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "tests"."test_cascade_soft_delete_category"() RETURNS SETOF "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'extensions', 'expense_tracker', 'auth'
    AS $$
declare
  -- test user
  _user constant uuid := 'f42966f9-37bc-4d53-937a-e19b2d57f77b';

  parent_x uuid; child_x1 uuid; child_x2 uuid;
  parent_y uuid; child_y1 uuid;

  ts timestamptz := now();
begin
  -- Make auth.uid() = _user under role `authenticated` (works with RLS)
  perform set_config('role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', _user::text, 'role','authenticated')::text,
    true
  );

  return query select plan(7);

  return query select ok(
    exists (
      select 1
      from pg_trigger
      where tgrelid = 'expense_tracker.category'::regclass
        and tgname  = 'cascade_soft_delete_category'
        and not tgisinternal
    ), 
    'Trigger exists on expense_tracker.category'
  );

  -- Create parent X
  insert into category (name, list_order, user_id)
  values ('parentX', 1, _user)
  returning id into parent_x;

  -- Create X children with parent_id set immediately
  insert into category (name, list_order, user_id, parent_id)
  values ('childX1', 2, _user, parent_x)
  returning id into child_x1;

  insert into category (name, list_order, user_id, parent_id)
  values ('childX2', 3, _user, parent_x)
  returning id into child_x2;

  -- Create an unrelated parent Y and child Y1
  insert into category (name, list_order, user_id)
  values ('parentY', 4, _user)
  returning id into parent_y;

  insert into category (name, list_order, user_id, parent_id)
  values ('childY1', 5, _user, parent_y)
  returning id into child_y1;

  -- --- Preconditions -------------------------------------------------------
  return query select is(
    (select count(*) from category where parent_id = parent_x and deleted_at is null),
    2::bigint,
    'Two active children under parentX'
  );

  return query select is(
    (select count(*) from category where parent_id = parent_y and deleted_at is null),
    1::bigint,
    'One active child under parentY'
  );

  -- --- Fire the trigger ----------------------------------------------------
  update category
     set deleted_at = ts
   where id = parent_x;

  -- --- Postconditions ------------------------------------------------------
  return query select ok(
    (select deleted_at is not null from category where id = parent_x),
    'parentX was soft-deleted'
  );

  return query select is(
    (select count(*) from category where parent_id = parent_x and deleted_at is not null),
    2::bigint,
    'childX1 and childX2 were soft-deleted'
  );

  return query select is(
    (select count(*) from category where parent_id = parent_y and deleted_at is null),
    1::bigint,
    'childY1 under parentY was not touched'
  );

  return query select is(
    (select count(*) from category where id in (child_x1, child_x2) and deleted_at = ts),
    2::bigint,
    'childX1/childX2 deleted_at equals parentX deleted_at'
  );

  return query select * from finish();
end;
$$;


ALTER FUNCTION "tests"."test_cascade_soft_delete_category"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "tests"."test_category_rls_policies"() RETURNS SETOF "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'extensions', 'expense_tracker', 'auth'
    AS $$
declare
  -- two test users
  user_a constant uuid := 'f42966f9-37bc-4d53-937a-e19b2d57f77b';
  user_b constant uuid := '5e0da9b5-18ea-4ae7-9b08-d0634ed71593';

  cat_a uuid;
  cat_b uuid;

  threw boolean;
  updated_rows int;
begin
  -- act as authenticated role (so RLS applies) and impersonate user A
  perform set_config('role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', user_a::text, 'role','authenticated')::text,
    true
  );

  return query select plan(16);

  return query select ok(
    (select relrowsecurity from pg_class where oid = 'category'::regclass),
    'RLS is enabled on category'
  );

  return query select ok(
    exists (select 1 from pg_policies
            where schemaname = 'expense_tracker'
              and tablename  = 'category'
              and policyname = 'Users can only create their own categories'),
    'Create policy exists'
  );

  return query select ok(
    exists (select 1 from pg_policies
            where schemaname = 'expense_tracker'
              and tablename  = 'category'
              and policyname = 'Users can read their own categories'),
    'Read policy exists'
  );

  return query select ok(
    exists (select 1 from pg_policies
            where schemaname = 'expense_tracker'
              and tablename  = 'category'
              and policyname = 'Users can update their own categories'),
    'Update policy exists'
  );

  insert into category (name, list_order, user_id)
  values ('cat_A', 1, user_a)
  returning id into cat_a;

  return query select ok(cat_a is not null, 'User A inserted their own category');

  threw := false;
  begin
    insert into category (name, list_order, user_id)
    values ('should_fail_A_for_B', 2, user_b);
  exception when others then
    threw := true;
  end;
  return query select ok(threw, 'User A cannot insert a row for user B');

  -- switch to user B
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', user_b::text, 'role','authenticated')::text,
    true
  );

  insert into category (name, list_order, user_id)
  values ('cat_B', 1, user_b)
  returning id into cat_b;

  return query select ok(cat_b is not null, 'User B inserted their own category');

  return query select is(
    (select count(*) from category where id = cat_b),
    1::bigint,
    'User B can read their own category'
  );

  return query select is(
    (select count(*) from category where id = cat_a),
    0::bigint,
    'User B cannot read User A category'
  );

  -- switch back to user A
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', user_a::text, 'role','authenticated')::text,
    true
  );

  return query select is(
    (select count(*) from category where id = cat_a),
    1::bigint,
    'User A can read their own category'
  );

  return query select is(
    (select count(*) from category where id = cat_b),
    0::bigint,
    'User A cannot read User B category'
  );

  update category
     set name = 'cat_A_updated'
   where id = cat_a;

  return query select is(
    (select name from category where id = cat_a),
    'cat_A_updated',
    'User A updated their own category'
  );

  update category
     set name = 'should_not_update'
   where id = cat_b;

  GET DIAGNOSTICS updated_rows = ROW_COUNT;
  
  return query select is(
    updated_rows::bigint, 0::bigint,   
    'User A cannot update User B category'
  );

  threw := false;
  begin
    update category
       set user_id = user_b
     where id = cat_a;
  exception when others then
    threw := true;
  end;
  return query select ok(threw, 'User A cannot reassign their category to User B');

  threw := false;
  begin
    update category
       set name = 'attempt_also_reassign', user_id = user_b
     where id = cat_a;
  exception when others then
    threw := true;
  end;
  return query select ok(threw, 'WITH CHECK enforced when changing user_id alongside other fields');

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', user_b::text, 'role','authenticated')::text,
    true
  );

  return query select is(
    (select count(*) from category where id = cat_a),
    0::bigint,
    'After all operations, User B still cannot see User A category'
  );

  return query select * from finish();
end;
$$;


ALTER FUNCTION "tests"."test_category_rls_policies"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "tests"."test_create_invoice_with_items"() RETURNS SETOF "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'extensions', 'expense_tracker', 'auth', 'public'
    AS $_$
DECLARE
  test_user  uuid := 'f42966f9-37bc-4d53-937a-e19b2d57f77b';
  company_id uuid;
  label_id   uuid;

  -- results
  result jsonb;
  new_invoice_id uuid;
  second_invoice_id uuid;
BEGIN

  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', test_user::text, 'role', 'authenticated')::text,
    true
  );

  RETURN QUERY SELECT plan(15);

  SELECT id INTO label_id
  FROM label
  LIMIT 1;

  INSERT INTO company (
    tax_id, business_name, location_name, city, administrative_unit, address
  )
  VALUES ('123', 'Biz d.o.o.', 'Loc', 'City', 'AU', 'Addr')
  RETURNING id INTO company_id;

  RETURN QUERY SELECT ok(
    EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'invoice_user_id_invoice_number_key'
    ),
    'Unique (user_id, invoice_number) exists on invoice'
  );

  SELECT create_invoice_with_items(NULL, '[]'::jsonb) INTO result;

  RETURN QUERY SELECT is(
    (result->>'success')::boolean,
    false,
    'NULL invoice_data: function returns success=false (caught by EXCEPTION block)'
  );

  RETURN QUERY SELECT is(
    coalesce(result->>'error_message','')::text,
    'invoice_data cannot be null'::text,
    'NULL invoice_data: error_message mentions the null guard'::text
  );

  SELECT create_invoice_with_items(
    invoice_data := jsonb_build_object(
      'invoice_number','INV-1001',
      'invoice_url','https://example.com/inv/1001',
      'journal','XJOURNAL',
      'total_amount', 1000,
      'invoice_type', 1,
      'transaction_type', 2,
      'counter_extension','A',
      'transaction_type_counter', 1,
      'counter_total', 10,
      'requested_by','Me',
      'signed_by','Signer',
      'pft_time','2025-01-01T12:00:00Z',
      'is_valid', true,
      'note', NULL,
      'company_id', company_id::text,
      'currency_code','RSD'
    ),
    invoice_items := jsonb_build_array(
      jsonb_build_object(
        'item_order', 1, 'name','Item 1', 'unit_price', 100, 'quantity', 2,
        'total', 200, 'tax_base_amount', 166.67, 'vat_amount', 33.33,
        'description', NULL, 'label_id', label_id, 'category_id', NULL
      ),
      jsonb_build_object(
        'item_order', 2, 'name','Item 2', 'unit_price', 400, 'quantity', 2,
        'total', 800, 'tax_base_amount', 666.67, 'vat_amount', 133.33,
        'description', NULL, 'label_id', label_id, 'category_id', NULL
      )
    )
  ) INTO result;

  RETURN QUERY SELECT ok( (result->>'success')::boolean, 'RPC returns success=true' );

  SELECT (result->>'invoice_id')::uuid INTO new_invoice_id;

  RETURN QUERY SELECT ok( new_invoice_id IS NOT NULL, 'RPC returned non-null invoice_id' );
  RETURN QUERY SELECT is( (result->>'item_count')::int, 2, 'RPC reports item_count = 2' );

  RETURN QUERY SELECT is(
    (SELECT user_id FROM invoice WHERE id = new_invoice_id),
    test_user,
    'Inserted invoice.user_id = auth.uid() (test_user)'
  );

  RETURN QUERY SELECT is(
    (SELECT total_amount::numeric FROM invoice WHERE id = new_invoice_id),
    1000::numeric,
    'Inserted invoice.total_amount = 1000.00'
  );

  RETURN QUERY SELECT is(
    (SELECT COUNT(*) FROM invoice_item WHERE invoice_id = new_invoice_id),
    2::bigint,
    'Two invoice_item rows inserted'
  );

  RETURN QUERY SELECT is(
    (SELECT SUM(total)::numeric FROM invoice_item WHERE invoice_id = new_invoice_id),
    1000::numeric,
    'Sum(items.total) = 1000.00'
  );

  RETURN QUERY SELECT throws_ok(
    format(
      $sql$
        SELECT create_invoice_with_items(
          invoice_data := jsonb_build_object(
            'invoice_number','INV-1001', -- duplicate
            'invoice_url','https://example.com/dup',
            'journal','XJOURNAL',
            'total_amount', 999,
            'invoice_type', 1,
            'transaction_type', 2,
            'counter_extension','A',
            'transaction_type_counter', 1,
            'counter_total', 10,
            'requested_by','Me',
            'signed_by','Signer',
            'pft_time','2025-01-02T12:00:00Z',
            'is_valid', true,
            'note', NULL,
            'company_id', %L,
            'currency_code','RSD'
          ),
          invoice_items := '[]'::jsonb
        )
      $sql$,
      company_id::text
    ),
    '23505',
    'duplicate key value violates unique constraint "invoice_user_id_invoice_number_key"'
  );

  RETURN QUERY SELECT throws_ok(
    $sql$
    SELECT create_invoice_with_items(
      invoice_data := jsonb_build_object(
        'invoice_number','INV-BOGUS',
        'invoice_url','https://example.com/bogus',
        'journal','J',
        'total_amount', 10,
        'invoice_type', 1, 'transaction_type', 1,
        'counter_extension','X', 'transaction_type_counter', 1, 'counter_total', 1,
        'requested_by','R', 'signed_by','S',
        'pft_time','2025-02-01T10:00:00Z',
        'is_valid', true,
        'note', NULL,
        'company_id', '00000000-0000-0000-0000-000000000000', -- non-existing
        'currency_code','RSD'
      ),
      invoice_items := '[]'::jsonb
    )$sql$,
    '23503', -- foreign key violation
    'Non-existing company_id raises FK violation (23503)'
  );

  INSERT INTO invoice (
    id, invoice_number, invoice_url, journal, total_amount,
    invoice_type, transaction_type, counter_extension,
    transaction_type_counter, counter_total, requested_by, signed_by,
    pft_time, is_valid, note, user_id, company_id, currency_code
  )
  VALUES (
    gen_random_uuid(), 'INV-2002', 'https://example.com/inv/2002', 'J',
    10, 1, 1, 'B', 1, 1, 'Req', 'Sig', now(), true, NULL, test_user, company_id, 'RSD'
  )
  RETURNING id INTO second_invoice_id;

  RETURN QUERY SELECT throws_like(
    format(
      $sql$UPDATE expense_tracker.invoice_item
           SET invoice_id = '%s'
         WHERE invoice_id = '%s' AND item_order = 1$sql$,
      second_invoice_id, new_invoice_id
    ),
    '%Changing the invoice_id of an invoice_item is not allowed.%',
    'Trigger prevents changing invoice_item.invoice_id'
  );

  UPDATE invoice_item
     SET name = 'Item 1 (edited)'
   WHERE invoice_id = new_invoice_id AND item_order = 1;

  RETURN QUERY SELECT is(
    (SELECT name FROM invoice_item WHERE invoice_id = new_invoice_id AND item_order = 1),
    'Item 1 (edited)',
    'Update allowed when invoice_id unchanged'
  );

  UPDATE invoice
     SET note = 'note x'
   WHERE id = new_invoice_id;

  RETURN QUERY SELECT ok(
    (SELECT modified_at IS NOT NULL FROM invoice WHERE id = new_invoice_id),
    'Invoice.modified_at set by update trigger'
  );

  RETURN QUERY SELECT * FROM finish();
END;
$_$;


ALTER FUNCTION "tests"."test_create_invoice_with_items"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "tests"."test_finance_record_summary_triggers"() RETURNS SETOF "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'extensions', 'expense_tracker', 'auth'
    AS $$
declare
  -- test user 
  test_user constant uuid := 'f42966f9-37bc-4d53-937a-e19b2d57f77b';

  -- categories
  cat_income uuid;
  cat_expense uuid;

  -- finance records
  fr_income_mar uuid;
  fr_expense_mar uuid;

  -- months/years
  m_mar smallint := 3;
  m_apr smallint := 4;
  y_2025 int := 2025;

  -- convenience for now()
  ts timestamptz := now();
begin

  perform set_config('role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', test_user::text, 'role','authenticated')::text,
    true
  );

  return query select plan(21);

  return query select ok(
    exists (
      select 1 from pg_trigger
      where tgrelid = 'finance_record'::regclass
        and tgname  = 'finance_record_insert_summary'
        and not tgisinternal
    ),
    'Trigger finance_record_insert_summary exists'
  );

  return query select ok(
    exists (
      select 1 from pg_trigger
      where tgrelid = 'finance_record'::regclass
        and tgname  = 'finance_record_update_summary'
        and not tgisinternal
    ),
    'Trigger finance_record_update_summary exists'
  );

  insert into category (name, list_order, user_id, flow_type)
  values ('cat_income', 1, test_user, 'INCOME'::flow_type_enum)
  returning id into cat_income;

  insert into category (name, list_order, user_id, flow_type)
  values ('cat_expense', 2, test_user, 'EXPENSE'::flow_type_enum)
  returning id into cat_expense;

  delete from user_details
   where user_id = test_user and year = y_2025 and month in (m_mar, m_apr);

  -- ========== INSERT TRIGGER TESTS ==========

  -- Insert INCOME 100 in March -> income=100, expense=0
  insert into finance_record
    (name, amount, description, user_id, category_id, currency_code, transferred_at)
  values
    ('income_mar_100', 100.00, 'ins income 100', test_user, cat_income, 'EUR', make_timestamptz(y_2025, m_mar, 10, 12, 0, 0))
  returning id into fr_income_mar;

  return query select is(
    (select income from user_details where user_id=test_user and month=m_mar and year=y_2025),
    100.00::numeric,
    'After first income insert: income(Mar 2025) = 100.00'
  );

  return query select is(
    (select coalesce(expense,0) from user_details where user_id=test_user and month=m_mar and year=y_2025),
    0.00::numeric,
    'After first income insert: expense(Mar 2025) = 0.00'
  );

  -- Insert another INCOME 50 in March -> income=150 expense=0
  insert into finance_record
    (name, amount, description, user_id, category_id, currency_code, transferred_at)
  values
    ('income_mar_50', 50.00, 'ins income 50', test_user, cat_income, 'EUR', make_timestamptz(y_2025, m_mar, 15, 13, 0, 0));

  return query select is(
    (select income from user_details where user_id=test_user and month=m_mar and year=y_2025),
    150.00::numeric,
    'After second income insert: income(Mar 2025) = 150.00'
  );

  -- Insert EXPENSE 20 in March -> income=150 expense=20
  insert into finance_record
    (name, amount, description, user_id, category_id, currency_code, transferred_at)
  values
    ('expense_mar_20', 20.00, 'ins expense 20', test_user, cat_expense, 'EUR', make_timestamptz(y_2025, m_mar, 18, 9, 30, 0))
  returning id into fr_expense_mar;

  return query select is(
    (select expense from user_details where user_id=test_user and month=m_mar and year=y_2025),
    20.00::numeric,
    'After first expense insert: expense(Mar 2025) = 20.00'
  );

  -- Insert EXPENSE 30 in April -> income=0 expense = 30, March -> income=150 expense=20
  insert into finance_record
    (name, amount, description, user_id, category_id, currency_code, transferred_at)
  values
    ('expense_apr_30', 30.00, 'ins expense 30', test_user, cat_expense, 'EUR', make_timestamptz(y_2025, m_apr, 2, 8, 0, 0));

  return query select is(
    (select expense from user_details where user_id=test_user and month=m_apr and year=y_2025),
    30.00::numeric,
    'After April expense insert: expense(Apr 2025) = 30.00'
  );

  -- ========== UPDATE TRIGGER TESTS ==========

  -- Change amount of the March expense: 20 -> 35
  update finance_record
     set amount = 35.00
   where id = fr_expense_mar;

  return query select is(
    (select expense from user_details where user_id=test_user and month=m_mar and year=y_2025),
    35.00::numeric,
    'Update amount: expense(Mar 2025) adjusted to 35.00'
  );

  return query select ok(
    (select modified_at is not null from user_details where user_id=test_user and month=m_mar and year=y_2025),
    'modified_at set on user_details (Mar 2025) after amount update'
  );

  -- Move that expense from March to April -> Mar -35, Apr +35 (Apr already had 30 -> now 65)
  update finance_record
     set transferred_at = make_timestamptz(y_2025, m_apr, 5, 10, 0, 0)
   where id = fr_expense_mar;

  return query select is(
    (select coalesce(expense,0) from user_details where user_id=test_user and month=m_mar and year=y_2025),
    0.00::numeric,
    'Move month: expense(Mar 2025) back to 0.00'
  );

  return query select is(
    (select expense from user_details where user_id=test_user and month=m_apr and year=y_2025),
    65.00::numeric,  -- previous 30 + moved 35
    'Move month: expense(Apr 2025) increased to 65.00'
  );

  return query select ok(
    (select modified_at is not null from user_details where user_id=test_user and month=m_apr and year=y_2025),
    'modified_at set on user_details (Apr 2025) after month move'
  );

  -- Switch flow type by changing category: expense(Apr 35) -> income(Apr 35)
  update finance_record
     set category_id = cat_income
   where id = fr_expense_mar;

  return query select is(
    (select expense from user_details where user_id=test_user and month=m_apr and year=y_2025),
    30.00::numeric,
    'Switch category to INCOME: expense(Apr 2025) reduced to 30.00'
  );

  return query select is(
    (select coalesce(income,0) from user_details where user_id=test_user and month=m_apr and year=y_2025),
    35.00::numeric,
    'Switch category to INCOME: income(Apr 2025) increased to 35.00'
  );

  -- Delete record
  update finance_record
     set deleted_at = ts
   where id = fr_expense_mar;

  return query select is(
    (select coalesce(income,0) from user_details where user_id=test_user and month=m_apr and year=y_2025),
    0.00::numeric,
    'Delete removes contribution from Apr income'
  );

  -- Undelete (deleted_at back to null)
  update finance_record
     set deleted_at = null
   where id = fr_expense_mar;

  return query select is(
    (select income from user_details where user_id=test_user and month=m_apr and year=y_2025),
    35.00::numeric,
    'Undelete adds contribution back to Apr income (35.00)'
  );

  -- Sanity: March totals (income 150, expense 0)
  return query select is(
    (select income from user_details where user_id=test_user and month=m_mar and year=y_2025),
    150.00::numeric,
    'Sanity: income(Mar 2025) remains 150.00'
  );

  return query select is(
    (select coalesce(expense,0) from user_details where user_id=test_user and month=m_mar and year=y_2025),
    0.00::numeric,
    'Sanity: expense(Mar 2025) is 0.00 after moves'
  );

  return query select ok(
    (select (income >= 0)::boolean from user_details where user_id=test_user and month=m_mar and year=y_2025),
    'Non-negative guard: income(Mar 2025) >= 0'
  );

  return query select ok(
    (select (expense >= 0)::boolean from user_details where user_id=test_user and month=m_apr and year=y_2025),
    'Non-negative guard: expense(Apr 2025) >= 0'
  );

  -- only two rows exist for Mar & Apr 2025
  return query select is(
    (select count(*) from user_details where user_id=test_user and year=y_2025 and month in (m_mar, m_apr)),
    2::bigint,
    'Exactly two user_details rows for Mar and Apr 2025'
  );

  return query select * from finish();
end;
$$;


ALTER FUNCTION "tests"."test_finance_record_summary_triggers"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "expense_tracker"."category" (
    "id" "uuid" DEFAULT "expense_tracker"."uuid_generate_v7"() NOT NULL,
    "name" character varying(128) NOT NULL,
    "color" character varying(32),
    "list_order" integer NOT NULL,
    "flow_type" "expense_tracker"."flow_type_enum" DEFAULT 'EXPENSE'::"expense_tracker"."flow_type_enum" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "user_id" "uuid" NOT NULL,
    "parent_id" "uuid",
    CONSTRAINT "category_name_check" CHECK (("length"(TRIM(BOTH FROM "name")) > 0))
);


ALTER TABLE "expense_tracker"."category" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."company" (
    "id" "uuid" DEFAULT "expense_tracker"."uuid_generate_v7"() NOT NULL,
    "tax_id" character varying(32) NOT NULL,
    "business_name" character varying(256) NOT NULL,
    "location_name" character varying(256) NOT NULL,
    "city" character varying(128) NOT NULL,
    "administrative_unit" character varying(128) NOT NULL,
    "address" character varying(128) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "company_tax_id_check" CHECK (("length"(TRIM(BOTH FROM "tax_id")) > 0))
);


ALTER TABLE "expense_tracker"."company" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."currency" (
    "code" character varying(4) NOT NULL,
    "name" character varying(128) NOT NULL,
    "symbol" character varying(16) NOT NULL,
    CONSTRAINT "currency_code_check" CHECK (("length"(TRIM(BOTH FROM "code")) > 0)),
    CONSTRAINT "currency_name_check" CHECK (("length"(TRIM(BOTH FROM "name")) > 0)),
    CONSTRAINT "currency_symbol_check" CHECK (("length"(TRIM(BOTH FROM "symbol")) > 0))
);


ALTER TABLE "expense_tracker"."currency" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."currency_pair" (
    "from_currency_code" character varying(4) NOT NULL,
    "to_currency_code" character varying(4) NOT NULL,
    "exchange_rate" numeric(12,6) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    CONSTRAINT "currency_pair_exchange_rate_check" CHECK (("exchange_rate" > (0)::numeric))
);


ALTER TABLE "expense_tracker"."currency_pair" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."default_category_template" (
    "template_id" "uuid" DEFAULT "expense_tracker"."uuid_generate_v7"() NOT NULL,
    "name" character varying(128) NOT NULL,
    "color" character varying(32),
    "list_order" integer NOT NULL,
    "flow_type" "expense_tracker"."flow_type_enum" DEFAULT 'EXPENSE'::"expense_tracker"."flow_type_enum" NOT NULL,
    "parent_template_id" "uuid"
);


ALTER TABLE "expense_tracker"."default_category_template" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."displayed_name" (
    "user_id" "uuid" NOT NULL,
    "original_name" character varying(256) NOT NULL,
    "displayed_name" character varying(256) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "expense_tracker"."displayed_name" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."feedback_form" (
    "id" integer NOT NULL,
    "message" "text" NOT NULL,
    "is_bug" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "solved_at" timestamp with time zone,
    "user_id" "uuid"
);


ALTER TABLE "expense_tracker"."feedback_form" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "expense_tracker"."feedback_form_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "expense_tracker"."feedback_form_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "expense_tracker"."feedback_form_id_seq" OWNED BY "expense_tracker"."feedback_form"."id";



ALTER TABLE "expense_tracker"."feedback_form" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "expense_tracker"."feedback_form_id_seq1"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "expense_tracker"."finance_record" (
    "id" "uuid" DEFAULT "expense_tracker"."uuid_generate_v7"() NOT NULL,
    "name" character varying(128) NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "description" character varying(512),
    "repeat_interval" "expense_tracker"."repeat_interval_enum",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "user_id" "uuid" NOT NULL,
    "category_id" "uuid" NOT NULL,
    "currency_code" character varying(4) NOT NULL,
    "transferred_at" timestamp with time zone NOT NULL,
    CONSTRAINT "finance_record_amount_check" CHECK (("amount" >= (0)::numeric)),
    CONSTRAINT "finance_record_name_check" CHECK (("length"(TRIM(BOTH FROM "name")) > 0))
);


ALTER TABLE "expense_tracker"."finance_record" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."invoice" (
    "id" "uuid" DEFAULT "expense_tracker"."uuid_generate_v7"() NOT NULL,
    "invoice_number" character varying(64) NOT NULL,
    "invoice_url" "text" NOT NULL,
    "journal" "text" NOT NULL,
    "total_amount" numeric(12,2) NOT NULL,
    "invoice_type" integer NOT NULL,
    "transaction_type" integer NOT NULL,
    "counter_extension" character varying(4) NOT NULL,
    "transaction_type_counter" integer NOT NULL,
    "counter_total" integer NOT NULL,
    "requested_by" character varying(32) NOT NULL,
    "signed_by" character varying(32) NOT NULL,
    "pft_time" timestamp with time zone NOT NULL,
    "is_valid" boolean NOT NULL,
    "note" character varying(512),
    "status" "expense_tracker"."invoice_status_enum" DEFAULT 'UNCATEGORIZED'::"expense_tracker"."invoice_status_enum" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "user_id" "uuid" NOT NULL,
    "company_id" "uuid" NOT NULL,
    "currency_code" character varying(4) NOT NULL
);


ALTER TABLE "expense_tracker"."invoice" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."invoice_item" (
    "invoice_id" "uuid" NOT NULL,
    "item_order" integer NOT NULL,
    "name" character varying(256) NOT NULL,
    "unit_price" numeric(12,2) NOT NULL,
    "quantity" numeric(12,2) NOT NULL,
    "total" numeric(12,2) NOT NULL,
    "tax_base_amount" numeric(12,2) NOT NULL,
    "vat_amount" numeric(12,2) NOT NULL,
    "description" character varying(512),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "label_id" "uuid" NOT NULL,
    "category_id" "uuid"
);


ALTER TABLE "expense_tracker"."invoice_item" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."label" (
    "id" "uuid" DEFAULT "expense_tracker"."uuid_generate_v7"() NOT NULL,
    "label" character(1) NOT NULL,
    "rate" numeric(4,2) NOT NULL
);


ALTER TABLE "expense_tracker"."label" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."main_currency" (
    "user_id" "uuid" NOT NULL,
    "currency_code" character varying(4) NOT NULL,
    "decimal_point" "expense_tracker"."decimal_point_enum" NOT NULL,
    "unit_position" "expense_tracker"."unit_position_enum" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "expense_tracker"."main_currency" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."secondary_currency" (
    "user_id" "uuid" NOT NULL,
    "currency_code" character varying(4) NOT NULL,
    "decimal_point" "expense_tracker"."decimal_point_enum" NOT NULL,
    "unit_position" "expense_tracker"."unit_position_enum" NOT NULL,
    "list_order" integer NOT NULL,
    "exchange_rate" numeric(12,6) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "secondary_currency_exchange_rate_check" CHECK (("exchange_rate" > (0)::numeric))
);


ALTER TABLE "expense_tracker"."secondary_currency" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."user_details" (
    "user_id" "uuid" NOT NULL,
    "month" smallint NOT NULL,
    "year" integer NOT NULL,
    "income" numeric(12,2) NOT NULL,
    "expense" numeric(12,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "user_details_expense_check" CHECK (("expense" >= (0)::numeric)),
    CONSTRAINT "user_details_income_check" CHECK (("income" >= (0)::numeric)),
    CONSTRAINT "user_details_month_check" CHECK ((("month" >= 1) AND ("month" <= 12))),
    CONSTRAINT "user_details_year_check" CHECK ((("year" >= 2000) AND ("year" <= 2100)))
);


ALTER TABLE "expense_tracker"."user_details" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."user_settings" (
    "id" "uuid" DEFAULT "expense_tracker"."uuid_generate_v7"() NOT NULL,
    "settings" "jsonb" NOT NULL,
    "ui_theme" character varying(64) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "user_id" "uuid" NOT NULL
);


ALTER TABLE "expense_tracker"."user_settings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "expense_tracker"."vw_finance_record" WITH ("security_invoker"='on') AS
 SELECT "fr"."id",
    "fr"."name" AS "record_name",
    "fr"."amount",
    "fr"."description",
    "fr"."repeat_interval",
    "fr"."transferred_at",
    "c"."id" AS "category_id",
    "c"."name" AS "category_name",
    "c"."color" AS "category_color",
    "c"."flow_type" AS "category_flow_type",
    "pc"."id" AS "parent_category_id",
    "pc"."name" AS "parent_category_name",
    "pc"."color" AS "parent_category_color",
    "curr"."code" AS "currency_code",
    "curr"."symbol" AS "currency_symbol",
    "curr"."name" AS "currency_name",
    "fr"."user_id"
   FROM ((("expense_tracker"."finance_record" "fr"
     JOIN "expense_tracker"."category" "c" ON (("fr"."category_id" = "c"."id")))
     LEFT JOIN "expense_tracker"."category" "pc" ON (("c"."parent_id" = "pc"."id")))
     JOIN "expense_tracker"."currency" "curr" ON ((("fr"."currency_code")::"text" = ("curr"."code")::"text")))
  WHERE ("fr"."deleted_at" IS NULL);


ALTER TABLE "expense_tracker"."vw_finance_record" OWNER TO "postgres";


CREATE OR REPLACE VIEW "expense_tracker"."vw_invoice_details" WITH ("security_invoker"='true') AS
 SELECT "inv"."id" AS "invoice_id",
    "inv"."invoice_number",
    "inv"."invoice_url",
    "inv"."journal",
    "inv"."total_amount",
    "inv"."invoice_type",
    "inv"."transaction_type",
    "inv"."counter_extension",
    "inv"."transaction_type_counter",
    "inv"."counter_total",
    "inv"."requested_by",
    "inv"."signed_by",
    "inv"."pft_time",
    "inv"."is_valid",
    "inv"."note",
    "inv"."status",
    "inv"."created_at" AS "invoice_created_at",
    "inv"."modified_at" AS "invoice_modified_at",
    "inv"."deleted_at" AS "invoice_deleted_at",
    "inv"."user_id",
    "inv"."company_id",
    "inv"."currency_code",
    "cur"."name" AS "currency_name",
    "cur"."symbol" AS "currency_symbol",
    "cmp"."tax_id" AS "company_tax_id",
    "cmp"."business_name" AS "company_business_name",
    "cmp"."location_name" AS "company_location_name",
    "cmp"."city" AS "company_city",
    "cmp"."administrative_unit" AS "company_administrative_unit",
    "cmp"."address" AS "company_address"
   FROM (("expense_tracker"."invoice" "inv"
     JOIN "expense_tracker"."company" "cmp" ON (("inv"."company_id" = "cmp"."id")))
     JOIN "expense_tracker"."currency" "cur" ON ((("inv"."currency_code")::"text" = ("cur"."code")::"text")));


ALTER TABLE "expense_tracker"."vw_invoice_details" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "expense_tracker"."warranty" (
    "id" "uuid" DEFAULT "expense_tracker"."uuid_generate_v7"() NOT NULL,
    "name" character varying(128) NOT NULL,
    "note" character varying(512) NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "img_path" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "user_id" "uuid" NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    CONSTRAINT "warranty_check" CHECK (("end_date" > "start_date"))
);


ALTER TABLE "expense_tracker"."warranty" OWNER TO "postgres";


ALTER TABLE ONLY "expense_tracker"."category"
    ADD CONSTRAINT "category_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "expense_tracker"."company"
    ADD CONSTRAINT "company_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "expense_tracker"."currency_pair"
    ADD CONSTRAINT "currency_pair_pkey" PRIMARY KEY ("from_currency_code", "to_currency_code");



ALTER TABLE ONLY "expense_tracker"."currency"
    ADD CONSTRAINT "currency_pkey" PRIMARY KEY ("code");



ALTER TABLE ONLY "expense_tracker"."displayed_name"
    ADD CONSTRAINT "displayed_name_pkey" PRIMARY KEY ("user_id", "original_name");



ALTER TABLE ONLY "expense_tracker"."feedback_form"
    ADD CONSTRAINT "feedback_form_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "expense_tracker"."finance_record"
    ADD CONSTRAINT "finance_record_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "expense_tracker"."invoice_item"
    ADD CONSTRAINT "invoice_item_pkey" PRIMARY KEY ("invoice_id", "item_order");



ALTER TABLE ONLY "expense_tracker"."invoice"
    ADD CONSTRAINT "invoice_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "expense_tracker"."invoice"
    ADD CONSTRAINT "invoice_user_id_invoice_number_key" UNIQUE ("user_id", "invoice_number");



ALTER TABLE ONLY "expense_tracker"."label"
    ADD CONSTRAINT "label_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "expense_tracker"."main_currency"
    ADD CONSTRAINT "main_currency_pkey" PRIMARY KEY ("user_id", "currency_code");



ALTER TABLE ONLY "expense_tracker"."default_category_template"
    ADD CONSTRAINT "pk_default_cat_temp" PRIMARY KEY ("template_id");



ALTER TABLE ONLY "expense_tracker"."secondary_currency"
    ADD CONSTRAINT "secondary_currency_pkey" PRIMARY KEY ("user_id", "currency_code");



ALTER TABLE ONLY "expense_tracker"."user_details"
    ADD CONSTRAINT "user_details_pkey" PRIMARY KEY ("user_id", "month", "year");



ALTER TABLE ONLY "expense_tracker"."user_settings"
    ADD CONSTRAINT "user_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "expense_tracker"."warranty"
    ADD CONSTRAINT "warranty_img_path_key" UNIQUE ("img_path");



ALTER TABLE ONLY "expense_tracker"."warranty"
    ADD CONSTRAINT "warranty_pkey" PRIMARY KEY ("id");



CREATE OR REPLACE TRIGGER "cascade_soft_delete_category" BEFORE UPDATE ON "expense_tracker"."category" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."cascade_soft_delete_category"();



CREATE OR REPLACE TRIGGER "check_invoice_id_update_immutable" BEFORE UPDATE ON "expense_tracker"."invoice_item" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."prevent_invoice_id_update"();



CREATE OR REPLACE TRIGGER "finance_record_insert_summary" AFTER INSERT ON "expense_tracker"."finance_record" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."finance_record_insert_summary"();



CREATE OR REPLACE TRIGGER "finance_record_update_summary" AFTER UPDATE ON "expense_tracker"."finance_record" FOR EACH ROW WHEN ((("old"."deleted_at" IS DISTINCT FROM "new"."deleted_at") OR ("old"."amount" IS DISTINCT FROM "new"."amount") OR ("old"."category_id" IS DISTINCT FROM "new"."category_id") OR ("old"."transferred_at" IS DISTINCT FROM "new"."transferred_at") OR ("old"."user_id" IS DISTINCT FROM "new"."user_id"))) EXECUTE FUNCTION "expense_tracker"."finance_record_update_summary"();



CREATE OR REPLACE TRIGGER "trg_category_set_modified_at" BEFORE UPDATE ON "expense_tracker"."category" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_company_set_modified_at" BEFORE UPDATE ON "expense_tracker"."company" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_currency_pair_set_modified_at" BEFORE UPDATE ON "expense_tracker"."currency_pair" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_displayed_name_set_modified_at" BEFORE UPDATE ON "expense_tracker"."displayed_name" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_finance_record_set_modified_at" BEFORE UPDATE ON "expense_tracker"."finance_record" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_invoice_item_set_modified_at" BEFORE UPDATE ON "expense_tracker"."invoice_item" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_invoice_set_modified_at" BEFORE UPDATE ON "expense_tracker"."invoice" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_main_currency_set_modified_at" BEFORE UPDATE ON "expense_tracker"."main_currency" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_secondary_currency_set_modified_at" BEFORE UPDATE ON "expense_tracker"."secondary_currency" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_user_details_set_modified_at" BEFORE UPDATE ON "expense_tracker"."user_details" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_user_settings_set_modified_at" BEFORE UPDATE ON "expense_tracker"."user_settings" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



CREATE OR REPLACE TRIGGER "trg_warranty_set_modified_at" BEFORE UPDATE ON "expense_tracker"."warranty" FOR EACH ROW EXECUTE FUNCTION "expense_tracker"."set_modified_at"();



ALTER TABLE ONLY "expense_tracker"."category"
    ADD CONSTRAINT "category_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "expense_tracker"."category"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."category"
    ADD CONSTRAINT "category_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."currency_pair"
    ADD CONSTRAINT "currency_pair_from_currency_code_fkey" FOREIGN KEY ("from_currency_code") REFERENCES "expense_tracker"."currency"("code") ON DELETE RESTRICT;



ALTER TABLE ONLY "expense_tracker"."currency_pair"
    ADD CONSTRAINT "currency_pair_to_currency_code_fkey" FOREIGN KEY ("to_currency_code") REFERENCES "expense_tracker"."currency"("code") ON DELETE RESTRICT;



ALTER TABLE ONLY "expense_tracker"."displayed_name"
    ADD CONSTRAINT "displayed_name_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."feedback_form"
    ADD CONSTRAINT "feedback_form_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "expense_tracker"."finance_record"
    ADD CONSTRAINT "finance_record_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "expense_tracker"."category"("id");



ALTER TABLE ONLY "expense_tracker"."finance_record"
    ADD CONSTRAINT "finance_record_currency_code_fkey" FOREIGN KEY ("currency_code") REFERENCES "expense_tracker"."currency"("code");



ALTER TABLE ONLY "expense_tracker"."finance_record"
    ADD CONSTRAINT "finance_record_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."default_category_template"
    ADD CONSTRAINT "fk_parent_template" FOREIGN KEY ("parent_template_id") REFERENCES "expense_tracker"."default_category_template"("template_id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."invoice"
    ADD CONSTRAINT "invoice_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "expense_tracker"."company"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "expense_tracker"."invoice"
    ADD CONSTRAINT "invoice_currency_code_fkey" FOREIGN KEY ("currency_code") REFERENCES "expense_tracker"."currency"("code") ON DELETE RESTRICT;



ALTER TABLE ONLY "expense_tracker"."invoice_item"
    ADD CONSTRAINT "invoice_item_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "expense_tracker"."category"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "expense_tracker"."invoice_item"
    ADD CONSTRAINT "invoice_item_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "expense_tracker"."invoice"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."invoice_item"
    ADD CONSTRAINT "invoice_item_label_id_fkey" FOREIGN KEY ("label_id") REFERENCES "expense_tracker"."label"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "expense_tracker"."invoice"
    ADD CONSTRAINT "invoice_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."main_currency"
    ADD CONSTRAINT "main_currency_currency_code_fkey" FOREIGN KEY ("currency_code") REFERENCES "expense_tracker"."currency"("code");



ALTER TABLE ONLY "expense_tracker"."main_currency"
    ADD CONSTRAINT "main_currency_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."secondary_currency"
    ADD CONSTRAINT "secondary_currency_currency_code_fkey" FOREIGN KEY ("currency_code") REFERENCES "expense_tracker"."currency"("code");



ALTER TABLE ONLY "expense_tracker"."secondary_currency"
    ADD CONSTRAINT "secondary_currency_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."user_details"
    ADD CONSTRAINT "user_details_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."user_settings"
    ADD CONSTRAINT "user_settings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "expense_tracker"."warranty"
    ADD CONSTRAINT "warranty_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "expense_tracker"."invoice"("id");



ALTER TABLE ONLY "expense_tracker"."warranty"
    ADD CONSTRAINT "warranty_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Authenticated users can add feedback" ON "expense_tracker"."feedback_form" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated users can create companies" ON "expense_tracker"."company" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can create only his invoice items" ON "expense_tracker"."invoice_item" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "expense_tracker"."invoice" "inv"
  WHERE (("inv"."id" = "invoice_item"."invoice_id") AND ("inv"."user_id" = "auth"."uid"())))));



CREATE POLICY "Authenticated users can create their own invoices" ON "expense_tracker"."invoice" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated users can create their own user details" ON "expense_tracker"."user_details" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated users can read company" ON "expense_tracker"."company" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can read labels" ON "expense_tracker"."label" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read only his invoice items" ON "expense_tracker"."invoice_item" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "expense_tracker"."invoice" "inv"
  WHERE (("inv"."id" = "invoice_item"."invoice_id") AND ("inv"."user_id" = "auth"."uid"())))));



CREATE POLICY "Authenticated users can read their own data" ON "expense_tracker"."user_details" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated users can read their own invoices" ON "expense_tracker"."invoice" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated users can update only their own invoice items" ON "expense_tracker"."invoice_item" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "expense_tracker"."invoice" "inv"
  WHERE (("inv"."id" = "invoice_item"."invoice_id") AND ("inv"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "expense_tracker"."invoice" "inv"
  WHERE (("inv"."id" = "invoice_item"."invoice_id") AND ("inv"."user_id" = "auth"."uid"())))));



CREATE POLICY "Authenticated users can update their own details" ON "expense_tracker"."user_details" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated users can update their own invoices" ON "expense_tracker"."invoice" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Global access to currency data" ON "expense_tracker"."currency" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Global access to currency pair data" ON "expense_tracker"."currency_pair" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Users can add their own finance records" ON "expense_tracker"."finance_record" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can edit their own finance records" ON "expense_tracker"."finance_record" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can only create their own categories" ON "expense_tracker"."category" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can read their own categories" ON "expense_tracker"."category" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can read their own finance records" ON "expense_tracker"."finance_record" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own categories" ON "expense_tracker"."category" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "expense_tracker"."category" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."company" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."currency" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."currency_pair" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."default_category_template" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."displayed_name" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."feedback_form" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."finance_record" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."invoice" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."invoice_item" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."label" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."main_currency" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."secondary_currency" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."user_details" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."user_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "expense_tracker"."warranty" ENABLE ROW LEVEL SECURITY;

ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";

GRANT USAGE ON SCHEMA "expense_tracker" TO "authenticated";

GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

GRANT ALL ON FUNCTION "expense_tracker"."uuid_generate_v7"() TO "anon";
GRANT ALL ON FUNCTION "expense_tracker"."uuid_generate_v7"() TO "authenticated";
GRANT ALL ON FUNCTION "expense_tracker"."uuid_generate_v7"() TO "service_role";

GRANT SELECT,INSERT,UPDATE ON TABLE "expense_tracker"."category" TO "authenticated";

GRANT SELECT,INSERT ON TABLE "expense_tracker"."company" TO "authenticated";

GRANT SELECT ON TABLE "expense_tracker"."currency" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."currency_pair" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."displayed_name" TO "authenticated";

GRANT INSERT ON TABLE "expense_tracker"."feedback_form" TO "authenticated";

GRANT USAGE ON SEQUENCE "expense_tracker"."feedback_form_id_seq" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."finance_record" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."invoice" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."invoice_item" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."label" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."main_currency" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."secondary_currency" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."user_details" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."user_settings" TO "authenticated";

GRANT SELECT ON TABLE "expense_tracker"."vw_finance_record" TO "authenticated";

GRANT SELECT ON TABLE "expense_tracker"."vw_invoice_details" TO "authenticated";

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "expense_tracker"."warranty" TO "authenticated";


ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "tests" GRANT ALL ON FUNCTIONS  TO "postgres";

RESET ALL;
CREATE TRIGGER seed_categories_after_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION expense_tracker.seed_categories_for_new_user();


  create policy "Give access to the user's file fuqmhd_0"
  on "storage"."objects"
  as permissive
  for insert
  to authenticated
with check ((((auth.uid())::text = (storage.foldername(name))[1]) AND (bucket_id = 'expense_tracker'::text)));



  create policy "Give access to the user's file fuqmhd_1"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using ((((auth.uid())::text = (storage.foldername(name))[1]) AND (bucket_id = 'expense_tracker'::text)));
