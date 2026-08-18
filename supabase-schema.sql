-- Testing/Demo POS — Supabase database schema.
--
-- This runs INSIDE THE SAME Supabase project as Hafiz Dairy (no new project,
-- no extra cost). Every table/function/trigger/index for this client is
-- suffixed "_td" so it lives completely separate from Hafiz's "_"-less
-- tables in the same database — different rows, different RPC functions,
-- zero overlap. Paste this whole file into the SAME project's SQL Editor
-- and click Run; it only creates new "_td" objects, it does not touch any
-- existing Hafiz Dairy table.
--
-- Design: every table is locked down with Row Level Security (RLS) and NO
-- direct table access is granted to anyone. The only way in or out is
-- through the SECURITY DEFINER functions below, which run with elevated
-- privileges but only do exactly what they're written to do. This means
-- even someone who gets the anon key can only call these functions — they
-- can't run arbitrary queries against your tables.
--
-- Every add/edit/delete in the app saves to the database instantly:
-- sync_append_sale_td/sync_append_refund_td insert one record at a time (so
-- sales_td history never has to be resent in full), while sync_replace_*_td
-- functions wipe-and-rewrite just their own table (items_td, categories_td,
-- suppliers_td, purchases_td, cashiers_td, held_sales_td, shifts_td,
-- settings_td) whenever that specific thing changes. sync_push_td/sync_pull_td
-- remain as a full-dataset replace/read, used only for restoring a backup file.

-- ============== TABLES ==============

create table if not exists items_td (
  id text primary key,
  name text not null,
  barcode text default '',
  category text default '',
  price numeric default 0,
  cost numeric default 0, -- buying price per unit, so Financials' Money Out is accurate
  stock numeric default 0,
  unit text default '',
  low_stock numeric default 0,
  expiry text default ''
);

-- Safe to re-run — no-op if the column already exists.
alter table items_td add column if not exists cost numeric default 0;
alter table items_td add column if not exists expiry text default '';

-- A master reference catalog — items_td here are NOT live inventory (no stock
-- tracking, don't show up in Billing/Purchases) until explicitly copied into
-- the `items_td` table via "Add to Inventory". Lets a store owner import a huge
-- premade product list without it looking like they stock everything in it.
create table if not exists item_catalog_td (
  id text primary key,
  name text not null,
  barcode text default '',
  category text default '',
  brand text default '',
  price numeric default 0,
  cost numeric default 0, -- suggested buying price, pre-fills Inventory's Buying Price on Add to Inventory
  unit text default '',
  low_stock numeric default 0
);

-- Safe to re-run — no-op if the column already exists.
alter table item_catalog_td add column if not exists brand text default '';
alter table item_catalog_td add column if not exists cost numeric default 0;

create table if not exists categories_td (
  name text primary key
);

create table if not exists suppliers_td (
  id text primary key,
  name text not null,
  contact text default '',
  address text default ''
);

create table if not exists cashiers_td (
  id text primary key,
  name text not null,
  pin text default ''
);

create table if not exists purchases_td (
  id text primary key,
  date date,
  supplier_id text,
  supplier_name text,
  item_id text,
  item_name text,
  qty numeric,
  cost numeric,
  total numeric,
  notes text default '',
  proof_data_url text,
  proof_name text
);

-- General business expenses_td (rent, utilities, salaries, misc) — "money out"
-- that ISN'T buying inventory stock (that's what `purchases_td` already tracks).
-- Powers the Financials tab's Money In vs Money Out view.
create table if not exists expenses_td (
  id text primary key,
  date date, -- when it was actually entered/paid
  period text default '', -- e.g. '2026-07' — which month this expense is FOR, may differ from date
  category text default '',
  amount numeric default 0,
  notes text default ''
);

-- Safe to re-run — no-op if the column already exists.
alter table expenses_td add column if not exists period text default '';

-- Udhaar/credit accounts — a regular customer buys now, pays later.
-- `balance` is a running counter (like items_td.stock), updated directly by the
-- app on every credit sale (+) and logged payment (-), not recomputed from
-- sales_td history — keeps this consistent with how stock is already tracked.
create table if not exists customers_td (
  id text primary key,
  name text not null,
  phone text default '',
  notes text default '',
  balance numeric default 0
);

-- Ledger of payments customers_td make against their credit balance — kept
-- separate from `customers_td` itself so there's a printable/auditable history.
create table if not exists customer_payments_td (
  id text primary key,
  customer_id text,
  customer_name text default '',
  amount numeric default 0,
  date date,
  notes text default ''
);

create table if not exists sales_td (
  id text primary key,
  receipt_no integer,
  date timestamptz,
  customer text,
  cashier text,
  payment text,
  cash numeric,
  subtotal numeric,
  discount_pct numeric,
  discount_amt numeric,
  tax_pct numeric,
  tax_amt numeric,
  grand numeric
);

create table if not exists sale_lines_td (
  sale_id text,
  item_id text,
  item_name text,
  barcode text,
  price numeric,
  qty numeric,
  unit text,
  subtotal numeric
);

create table if not exists refunds_td (
  id text primary key,
  sale_id text,
  receipt_no integer,
  date timestamptz,
  total numeric,
  reason text,
  cashier text
);

create table if not exists refund_lines_td (
  refund_id text,
  item_id text,
  item_name text,
  qty numeric,
  price numeric,
  refund_amount numeric
);

create table if not exists held_sales_td (
  id text primary key,
  date timestamptz,
  customer text,
  discount numeric,
  tax numeric,
  cashier text
);

create table if not exists held_sales_cart_td (
  held_id text,
  item_id text,
  qty numeric
);

create table if not exists shifts_td (
  id text primary key,
  cashier_name text,
  start timestamptz,
  "end" timestamptz,
  opening_cash numeric,
  cash_sales numeric,
  card_sales numeric,
  wallet_sales numeric,
  cash_refunds numeric,
  txn_count integer,
  expected_cash numeric,
  actual_cash numeric,
  difference numeric,
  notes text
);

create table if not exists active_shift_td (
  id text primary key,
  cashier_id text,
  cashier_name text,
  start timestamptz,
  opening_cash numeric
);

create table if not exists settings_td (
  key text primary key,
  value text
);

create table if not exists meta_td (
  key text primary key,
  value text
);

-- Running totals, kept up to date by triggers below (not recomputed on
-- read). "All Time" stats/top-items_td come from these instead of scanning the
-- full sales_td/sale_lines_td tables — the live scan approach that used to time
-- out once sales_td history got into the tens of thousands. Any bounded range
-- (Today/This Week/This Month/Custom) still scans live, since an indexed
-- date filter keeps that fast regardless of total table size.

create table if not exists item_sales_totals_td (
  item_name text primary key,
  qty numeric default 0,
  revenue numeric default 0
);

create table if not exists sales_overall_totals_td (
  key text primary key,
  count integer default 0,
  revenue numeric default 0
);
insert into sales_overall_totals_td (key, count, revenue) values ('all', 0, 0)
on conflict (key) do nothing;

-- ============== LOCK EVERYTHING DOWN ==============
-- RLS enabled, no policies granted = nobody can touch these tables directly,
-- not even with the anon key. Only the SECURITY DEFINER functions below can.

alter table items_td enable row level security;
alter table item_catalog_td enable row level security;
alter table categories_td enable row level security;
alter table suppliers_td enable row level security;
alter table cashiers_td enable row level security;
alter table purchases_td enable row level security;
alter table expenses_td enable row level security;
alter table sales_td enable row level security;
alter table sale_lines_td enable row level security;
alter table refunds_td enable row level security;
alter table refund_lines_td enable row level security;
alter table held_sales_td enable row level security;
alter table held_sales_cart_td enable row level security;
alter table shifts_td enable row level security;
alter table active_shift_td enable row level security;
alter table settings_td enable row level security;
alter table meta_td enable row level security;
alter table item_sales_totals_td enable row level security;
alter table sales_overall_totals_td enable row level security;
alter table customers_td enable row level security;
alter table customer_payments_td enable row level security;

-- ============== triggers: keep running totals in sync ==============
-- Fire on every insert/update/delete to sales_td/sale_lines_td, regardless of
-- which function touched them (single append, batch append, full replace,
-- or clear) — so the totals never need a separate maintenance step.

create or replace function trg_sale_lines_totals_td()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    insert into item_sales_totals_td (item_name, qty, revenue)
    values (NEW.item_name, NEW.qty, NEW.subtotal)
    on conflict (item_name) do update set
      qty = item_sales_totals_td.qty + NEW.qty,
      revenue = item_sales_totals_td.revenue + NEW.subtotal;
    return NEW;
  elsif TG_OP = 'DELETE' then
    update item_sales_totals_td set qty = qty - OLD.qty, revenue = revenue - OLD.subtotal
    where item_name = OLD.item_name;
    return OLD;
  end if;
  return null;
end;
$$;

drop trigger if exists sale_lines_totals_trigger_td on sale_lines_td;
create trigger sale_lines_totals_trigger_td
after insert or delete on sale_lines_td
for each row execute function trg_sale_lines_totals_td();

create or replace function trg_sales_totals_td()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    update sales_overall_totals_td set count = count + 1, revenue = revenue + NEW.grand where key = 'all';
    return NEW;
  elsif TG_OP = 'DELETE' then
    update sales_overall_totals_td set count = count - 1, revenue = revenue - OLD.grand where key = 'all';
    return OLD;
  elsif TG_OP = 'UPDATE' then
    update sales_overall_totals_td set revenue = revenue - OLD.grand + NEW.grand where key = 'all';
    return NEW;
  end if;
  return null;
end;
$$;

drop trigger if exists sales_totals_trigger_td on sales_td;
create trigger sales_totals_trigger_td
after insert or update or delete on sales_td
for each row execute function trg_sales_totals_td();

-- One-time (and safely re-runnable) backfill, so totals stay correct even
-- for rows that existed before these triggers did. Only touches the summary
-- tables, so it's cheap regardless of when it runs.
insert into item_sales_totals_td (item_name, qty, revenue)
select item_name, sum(qty), sum(subtotal) from sale_lines_td group by item_name
on conflict (item_name) do update set qty = excluded.qty, revenue = excluded.revenue;

update sales_overall_totals_td
set count = (select count(*) from sales_td), revenue = (select coalesce(sum(grand), 0) from sales_td)
where key = 'all';

-- ============== sync_push_td: atomic full-replace write ==============

create or replace function sync_push_td(payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if payload ? 'items' then
    delete from items_td where true;
    insert into items_td (id, name, barcode, category, price, cost, stock, unit, low_stock, expiry)
    select x->>'id', x->>'name', coalesce(x->>'barcode',''), coalesce(x->>'category',''),
           coalesce((x->>'price')::numeric,0), coalesce((x->>'cost')::numeric,0), coalesce((x->>'stock')::numeric,0),
           coalesce(x->>'unit',''), coalesce((x->>'lowStock')::numeric,0), coalesce(x->>'expiry','')
    from jsonb_array_elements(payload->'items') x;
  end if;

  if payload ? 'itemCatalog' then
    delete from item_catalog_td where true;
    insert into item_catalog_td (id, name, barcode, category, brand, price, cost, unit, low_stock)
    select x->>'id', x->>'name', coalesce(x->>'barcode',''), coalesce(x->>'category',''), coalesce(x->>'brand',''),
           coalesce((x->>'price')::numeric,0), coalesce((x->>'cost')::numeric,0), coalesce(x->>'unit',''), coalesce((x->>'lowStock')::numeric,0)
    from jsonb_array_elements(payload->'itemCatalog') x;
  end if;

  if payload ? 'categories' then
    delete from categories_td where true;
    insert into categories_td (name)
    select jsonb_array_elements_text(payload->'categories');
  end if;

  if payload ? 'suppliers' then
    delete from suppliers_td where true;
    insert into suppliers_td (id, name, contact, address)
    select x->>'id', x->>'name', coalesce(x->>'contact',''), coalesce(x->>'address','')
    from jsonb_array_elements(payload->'suppliers') x;
  end if;

  if payload ? 'cashiers' then
    delete from cashiers_td where true;
    insert into cashiers_td (id, name, pin)
    select x->>'id', x->>'name', coalesce(x->>'pin','')
    from jsonb_array_elements(payload->'cashiers') x;
  end if;

  if payload ? 'purchases' then
    delete from purchases_td where true;
    insert into purchases_td (id, date, supplier_id, supplier_name, item_id, item_name, qty, cost, total, notes, proof_data_url, proof_name)
    select x->>'id',
           nullif(x->>'date','')::date,
           x->>'supplierId', x->>'supplierName', x->>'itemId', x->>'itemName',
           (x->>'qty')::numeric, (x->>'cost')::numeric, (x->>'total')::numeric, coalesce(x->>'notes',''),
           x->>'proof', x->>'proofName'
    from jsonb_array_elements(payload->'purchases') x;
  end if;

  if payload ? 'expenses' then
    delete from expenses_td where true;
    insert into expenses_td (id, date, period, category, amount, notes)
    select x->>'id', nullif(x->>'date','')::date, coalesce(x->>'period',''), coalesce(x->>'category',''),
           coalesce((x->>'amount')::numeric,0), coalesce(x->>'notes','')
    from jsonb_array_elements(payload->'expenses') x;
  end if;

  if payload ? 'customers' then
    delete from customers_td where true;
    insert into customers_td (id, name, phone, notes, balance)
    select x->>'id', x->>'name', coalesce(x->>'phone',''), coalesce(x->>'notes',''), coalesce((x->>'balance')::numeric,0)
    from jsonb_array_elements(payload->'customers') x;
  end if;

  if payload ? 'customerPayments' then
    delete from customer_payments_td where true;
    insert into customer_payments_td (id, customer_id, customer_name, amount, date, notes)
    select x->>'id', x->>'customerId', coalesce(x->>'customerName',''), coalesce((x->>'amount')::numeric,0),
           nullif(x->>'date','')::date, coalesce(x->>'notes','')
    from jsonb_array_elements(payload->'customerPayments') x;
  end if;

  if payload ? 'sales' then
    -- TRUNCATE (not DELETE) so this doesn't fire the per-row totals triggers
    -- thousands of times over on a full replace — reset the summary tables
    -- directly instead, then let the inserts below rebuild them correctly.
    truncate sale_lines_td;
    truncate sales_td;
    truncate item_sales_totals_td;
    update sales_overall_totals_td set count = 0, revenue = 0 where key = 'all';

    insert into sales_td (id, receipt_no, date, customer, cashier, payment, cash, subtotal, discount_pct, discount_amt, tax_pct, tax_amt, grand)
    select x->>'id', (x->>'receiptNo')::integer, (x->>'date')::timestamptz, x->>'customer', x->>'cashier', x->>'payment',
           (x->>'cash')::numeric, (x->>'subtotal')::numeric, (x->>'discountPct')::numeric, (x->>'discountAmt')::numeric,
           (x->>'taxPct')::numeric, (x->>'taxAmt')::numeric, (x->>'grand')::numeric
    from jsonb_array_elements(payload->'sales') x;

    insert into sale_lines_td (sale_id, item_id, item_name, barcode, price, qty, unit, subtotal)
    select s->>'id', l->>'itemId', l->>'name', coalesce(l->>'barcode',''), (l->>'price')::numeric,
           (l->>'qty')::numeric, coalesce(l->>'unit',''), (l->>'subtotal')::numeric
    from jsonb_array_elements(payload->'sales') s,
         jsonb_array_elements(coalesce(s->'lines','[]'::jsonb)) l;
  end if;

  if payload ? 'refunds' then
    delete from refund_lines_td where true;
    delete from refunds_td where true;
    insert into refunds_td (id, sale_id, receipt_no, date, total, reason, cashier)
    select x->>'id', x->>'saleId', (x->>'receiptNo')::integer, (x->>'date')::timestamptz,
           (x->>'total')::numeric, coalesce(x->>'reason',''), x->>'cashier'
    from jsonb_array_elements(payload->'refunds') x;

    insert into refund_lines_td (refund_id, item_id, item_name, qty, price, refund_amount)
    select r->>'id', l->>'itemId', l->>'name', (l->>'qty')::numeric, (l->>'price')::numeric, (l->>'refundAmount')::numeric
    from jsonb_array_elements(payload->'refunds') r,
         jsonb_array_elements(coalesce(r->'lines','[]'::jsonb)) l;
  end if;

  if payload ? 'heldSales' then
    delete from held_sales_cart_td where true;
    delete from held_sales_td where true;
    insert into held_sales_td (id, date, customer, discount, tax, cashier)
    select x->>'id', (x->>'date')::timestamptz, x->>'customer', (x->>'discount')::numeric, (x->>'tax')::numeric, x->>'cashier'
    from jsonb_array_elements(payload->'heldSales') x;

    insert into held_sales_cart_td (held_id, item_id, qty)
    select h->>'id', c->>'itemId', (c->>'qty')::numeric
    from jsonb_array_elements(payload->'heldSales') h,
         jsonb_array_elements(coalesce(h->'cart','[]'::jsonb)) c;
  end if;

  if payload ? 'shifts' then
    delete from shifts_td where true;
    insert into shifts_td (id, cashier_name, start, "end", opening_cash, cash_sales, card_sales, wallet_sales, cash_refunds, txn_count, expected_cash, actual_cash, difference, notes)
    select x->>'id', x->>'cashierName', (x->>'start')::timestamptz, (x->>'end')::timestamptz,
           (x->>'openingCash')::numeric, (x->>'cashSales')::numeric, (x->>'cardSales')::numeric, (x->>'walletSales')::numeric,
           (x->>'cashRefunds')::numeric, (x->>'txnCount')::integer, (x->>'expectedCash')::numeric,
           (x->>'actualCash')::numeric, (x->>'difference')::numeric, coalesce(x->>'notes','')
    from jsonb_array_elements(payload->'shifts') x;
  end if;

  if payload ? 'activeShift' then
    delete from active_shift_td where true;
    if payload->'activeShift' is not null and payload->'activeShift' != 'null'::jsonb then
      insert into active_shift_td (id, cashier_id, cashier_name, start, opening_cash)
      values (
        payload->'activeShift'->>'id',
        payload->'activeShift'->>'cashierId',
        payload->'activeShift'->>'cashierName',
        (payload->'activeShift'->>'start')::timestamptz,
        (payload->'activeShift'->>'openingCash')::numeric
      );
    end if;
  end if;

  if payload ? 'settings' then
    delete from settings_td where true;
    insert into settings_td (key, value)
    select k, v
    from jsonb_each_text(payload->'settings') as t(k, v);
  end if;

  if payload ? 'receiptCounter' then
    insert into meta_td (key, value) values ('receiptCounter', (payload->>'receiptCounter'))
    on conflict (key) do update set value = excluded.value;
  end if;
end;
$$;

-- ============== sync_pull_td: read everything EXCEPT sales_td/refunds_td ==============
-- Sales and refunds_td are deliberately left out here — that history can grow
-- without bound, and building/sending all of it on every app load is what
-- broke this at high volume. Sales/refunds_td are fetched separately, scoped to
-- whatever date range the user has selected, by sync_pull_sales_range_td below.

create or replace function sync_pull_td()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'barcode', barcode, 'category', category,
      'price', price, 'cost', cost, 'stock', stock, 'unit', unit, 'lowStock', low_stock, 'expiry', expiry
    )) from items_td), '[]'::jsonb),

    'itemCatalog', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'barcode', barcode, 'category', category, 'brand', brand,
      'price', price, 'cost', cost, 'unit', unit, 'lowStock', low_stock
    )) from item_catalog_td), '[]'::jsonb),

    'categories', coalesce((select jsonb_agg(name) from categories_td), '[]'::jsonb),

    'suppliers', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'contact', contact, 'address', address
    )) from suppliers_td), '[]'::jsonb),

    'cashiers', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'pin', pin
    )) from cashiers_td), '[]'::jsonb),

    'purchases', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'date', date, 'supplierId', supplier_id, 'supplierName', supplier_name,
      'itemId', item_id, 'itemName', item_name, 'qty', qty, 'cost', cost, 'total', total,
      'notes', notes, 'proof', proof_data_url, 'proofName', proof_name
    )) from purchases_td), '[]'::jsonb),

    'expenses', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'date', date, 'period', period, 'category', category, 'amount', amount, 'notes', notes
    )) from expenses_td), '[]'::jsonb),

    'customers', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'phone', phone, 'notes', notes, 'balance', balance
    )) from customers_td), '[]'::jsonb),

    'customerPayments', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'customerId', customer_id, 'customerName', customer_name, 'amount', amount, 'date', date, 'notes', notes
    )) from customer_payments_td), '[]'::jsonb),

    'heldSales', coalesce((select jsonb_agg(
      jsonb_build_object(
        'id', h.id, 'date', h.date, 'customer', h.customer, 'discount', h.discount,
        'tax', h.tax, 'cashier', h.cashier,
        'cart', coalesce((select jsonb_agg(jsonb_build_object(
          'itemId', hc.item_id, 'qty', hc.qty
        )) from held_sales_cart_td hc where hc.held_id = h.id), '[]'::jsonb)
      )
    ) from held_sales_td h), '[]'::jsonb),

    'shifts', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'cashierName', cashier_name, 'start', start, 'end', "end",
      'openingCash', opening_cash, 'cashSales', cash_sales, 'cardSales', card_sales,
      'walletSales', wallet_sales, 'cashRefunds', cash_refunds, 'txnCount', txn_count,
      'expectedCash', expected_cash, 'actualCash', actual_cash, 'difference', difference, 'notes', notes
    )) from shifts_td), '[]'::jsonb),

    'activeShift', (select jsonb_build_object(
      'id', id, 'cashierId', cashier_id, 'cashierName', cashier_name, 'start', start, 'openingCash', opening_cash
    ) from active_shift_td limit 1),

    'settings', coalesce((select jsonb_object_agg(key, value) from settings_td), '{}'::jsonb),

    'receiptCounter', (select (value)::integer from meta_td where key = 'receiptCounter')
  ) into result;
  return result;
end;
$$;

-- ============== indexes for range-scoped sales_td/refunds_td lookups ==============

create index if not exists idx_sales_date_td on sales_td(date);
create index if not exists idx_refunds_date_td on refunds_td(date);
create index if not exists idx_sale_lines_sale_id_td on sale_lines_td(sale_id);
create index if not exists idx_refund_lines_refund_id_td on refund_lines_td(refund_id);

-- ============== sync_pull_sales_range_td: one page of sales_td/refunds_td for a date range ==============
-- Called whenever the user picks Today/This Week/This Month/Custom Range (or
-- All Time) in the Dashboard or Sales History, and again for each "Next
-- page"/"Previous page" click — never on app load, never for the whole
-- history at once. Returns:
--   - sales_td/refunds_td: one page (page_size rows, newest-first) — pass
--     cursor_date/cursor_id (the last row's date/id from the previous page)
--     to get the NEXT page; leave both null for the first page. Uses a
--     LATERAL join so only the selected page's line items_td get aggregated,
--     never the whole sale_lines_td table, however large it's grown.
--   - hasMore: true if there's another page after this one.
--   - totalCount/totalRevenue/topItems: exact for the whole range regardless
--     of paging — for a BOUNDED range these come from a live indexed scan
--     (fast no matter how much total history exists); for true "All Time"
--     (both bounds null) they come from the running-totals tables instead,
--     since aggregating the entire table live is exactly what timed out
--     once sales_td history got into the tens of thousands.
-- Pass null for range_start/range_end for an unbounded (All Time) range.

create or replace function sync_pull_sales_range_td(
  range_start timestamptz, range_end timestamptz,
  page_size integer default 30,
  cursor_date timestamptz default null, cursor_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  is_all_time boolean := (range_start is null and range_end is null);
  v_total_count integer;
  v_total_revenue numeric;
  v_top_items jsonb;
  v_sales jsonb;
  v_has_more boolean;
begin
  if is_all_time then
    select count, revenue into v_total_count, v_total_revenue from sales_overall_totals_td where key = 'all';
    select coalesce(jsonb_agg(jsonb_build_object('name', item_name, 'qty', qty, 'revenue', revenue) order by qty desc), '[]'::jsonb)
    into v_top_items
    from (select * from item_sales_totals_td order by qty desc limit 20) t;
  else
    select count(*) into v_total_count from sales_td
    where (range_start is null or date >= range_start) and (range_end is null or date <= range_end);

    select coalesce(sum(grand), 0) into v_total_revenue from sales_td
    where (range_start is null or date >= range_start) and (range_end is null or date <= range_end);

    select coalesce(jsonb_agg(t order by (t->>'qty')::numeric desc), '[]'::jsonb) into v_top_items
    from (
      select jsonb_build_object('name', sl.item_name, 'qty', sum(sl.qty), 'revenue', sum(sl.subtotal)) as t
      from sale_lines_td sl
      join sales_td s on s.id = sl.sale_id
      where (range_start is null or s.date >= range_start) and (range_end is null or s.date <= range_end)
      group by sl.item_name
      limit 20
    ) t;
  end if;

  -- Page: pick the next page_size+1 sale ROWS first (index-friendly — narrows
  -- by range, then by the keyset cursor, then LIMIT), fetch the +1 extra only
  -- to know if there's a next page, THEN lateral-join each selected sale's
  -- own lines. This is what actually fixes the timeout: the old version
  -- pre-aggregated the ENTIRE sale_lines_td table before the join happened, so
  -- the row limit never helped — Postgres had already done the expensive part.
  with page as (
    select *
    from sales_td s
    where (range_start is null or s.date >= range_start)
      and (range_end is null or s.date <= range_end)
      and (cursor_date is null or (s.date, s.id) < (cursor_date, cursor_id))
    order by s.date desc, s.id desc
    limit page_size + 1
  ),
  trimmed as (
    select * from page order by date desc, id desc limit page_size
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', t.id, 'receiptNo', t.receipt_no, 'date', t.date, 'customer', t.customer,
        'cashier', t.cashier, 'payment', t.payment, 'cash', t.cash, 'subtotal', t.subtotal,
        'discountPct', t.discount_pct, 'discountAmt', t.discount_amt, 'taxPct', t.tax_pct,
        'taxAmt', t.tax_amt, 'grand', t.grand,
        'lines', coalesce(sl.lines, '[]'::jsonb)
      ) order by t.date desc
    ), '[]'::jsonb),
    (select count(*) from page) > page_size
  into v_sales, v_has_more
  from trimmed t
  left join lateral (
    select jsonb_agg(jsonb_build_object(
      'itemId', item_id, 'name', item_name, 'barcode', barcode,
      'price', price, 'qty', qty, 'unit', unit, 'subtotal', subtotal
    )) as lines
    from sale_lines_td where sale_id = t.id
  ) sl on true;

  select jsonb_build_object(
    'sales', v_sales,
    'hasMore', coalesce(v_has_more, false),

    'refunds', coalesce((
      select jsonb_agg(x order by x->>'date' desc) from (
        select jsonb_build_object(
          'id', r.id, 'saleId', r.sale_id, 'receiptNo', r.receipt_no, 'date', r.date,
          'total', r.total, 'reason', r.reason, 'cashier', r.cashier,
          'lines', coalesce(rl.lines, '[]'::jsonb)
        ) as x
        from refunds_td r
        left join lateral (
          select jsonb_agg(jsonb_build_object(
            'itemId', item_id, 'name', item_name, 'qty', qty,
            'price', price, 'refundAmount', refund_amount
          )) as lines
          from refund_lines_td where refund_id = r.id
        ) rl on true
        where (range_start is null or r.date >= range_start)
          and (range_end is null or r.date <= range_end)
        order by r.date desc
        limit page_size
      ) x
    ), '[]'::jsonb),

    'totalCount', v_total_count,
    'totalRevenue', v_total_revenue,
    'topItems', v_top_items
  ) into result;
  return result;
end;
$$;

-- ============== sync_append_sale_td: instant single-sale insert ==============
-- Used right after checkout, on every device, so a sale reaches the database
-- immediately without resending the entire sales_td history each time. Safe to
-- retry (e.g. after a dropped connection) since it upserts on the sale's id.

create or replace function sync_append_sale_td(sale jsonb, receipt_counter integer default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into sales_td (id, receipt_no, date, customer, cashier, payment, cash, subtotal, discount_pct, discount_amt, tax_pct, tax_amt, grand)
  values (
    sale->>'id', (sale->>'receiptNo')::integer, (sale->>'date')::timestamptz, sale->>'customer', sale->>'cashier', sale->>'payment',
    (sale->>'cash')::numeric, (sale->>'subtotal')::numeric, (sale->>'discountPct')::numeric, (sale->>'discountAmt')::numeric,
    (sale->>'taxPct')::numeric, (sale->>'taxAmt')::numeric, (sale->>'grand')::numeric
  )
  on conflict (id) do update set
    receipt_no = excluded.receipt_no, date = excluded.date, customer = excluded.customer,
    cashier = excluded.cashier, payment = excluded.payment, cash = excluded.cash,
    subtotal = excluded.subtotal, discount_pct = excluded.discount_pct, discount_amt = excluded.discount_amt,
    tax_pct = excluded.tax_pct, tax_amt = excluded.tax_amt, grand = excluded.grand;

  delete from sale_lines_td where sale_id = sale->>'id';
  insert into sale_lines_td (sale_id, item_id, item_name, barcode, price, qty, unit, subtotal)
  select sale->>'id', l->>'itemId', l->>'name', coalesce(l->>'barcode',''), (l->>'price')::numeric,
         (l->>'qty')::numeric, coalesce(l->>'unit',''), (l->>'subtotal')::numeric
  from jsonb_array_elements(coalesce(sale->'lines', '[]'::jsonb)) l;

  if receipt_counter is not null then
    insert into meta_td (key, value) values ('receiptCounter', receipt_counter::text)
    on conflict (key) do update set value = excluded.value;
  end if;
end;
$$;

-- ============== sync_append_sales_batch_td: bulk append, no wipe ==============
-- Set-based insert for many sales_td at once (e.g. bulk-loading historical data)
-- without ever deleting the existing table first, unlike sync_push_td. Callers
-- should chunk large loads (a few thousand sales_td per call) to stay under
-- Supabase's statement timeout — this function itself has no size limit,
-- the timeout is on how much work fits in one call.

drop function if exists sync_append_sales_batch_td(jsonb);
create or replace function sync_append_sales_batch_td(sales jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into sales_td (id, receipt_no, date, customer, cashier, payment, cash, subtotal, discount_pct, discount_amt, tax_pct, tax_amt, grand)
  select x->>'id', (x->>'receiptNo')::integer, (x->>'date')::timestamptz, x->>'customer', x->>'cashier', x->>'payment',
         (x->>'cash')::numeric, (x->>'subtotal')::numeric, (x->>'discountPct')::numeric, (x->>'discountAmt')::numeric,
         (x->>'taxPct')::numeric, (x->>'taxAmt')::numeric, (x->>'grand')::numeric
  from jsonb_array_elements(sales) x
  on conflict (id) do nothing;

  insert into sale_lines_td (sale_id, item_id, item_name, barcode, price, qty, unit, subtotal)
  select s->>'id', l->>'itemId', l->>'name', coalesce(l->>'barcode',''), (l->>'price')::numeric,
         (l->>'qty')::numeric, coalesce(l->>'unit',''), (l->>'subtotal')::numeric
  from jsonb_array_elements(sales) s,
       jsonb_array_elements(coalesce(s->'lines','[]'::jsonb)) l;
end;
$$;

-- ============== sync_append_refund_td: instant single-refund insert ==============

create or replace function sync_append_refund_td(refund jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into refunds_td (id, sale_id, receipt_no, date, total, reason, cashier)
  values (
    refund->>'id', refund->>'saleId', (refund->>'receiptNo')::integer, (refund->>'date')::timestamptz,
    (refund->>'total')::numeric, coalesce(refund->>'reason',''), refund->>'cashier'
  )
  on conflict (id) do update set
    sale_id = excluded.sale_id, receipt_no = excluded.receipt_no, date = excluded.date,
    total = excluded.total, reason = excluded.reason, cashier = excluded.cashier;

  delete from refund_lines_td where refund_id = refund->>'id';
  insert into refund_lines_td (refund_id, item_id, item_name, qty, price, refund_amount)
  select refund->>'id', l->>'itemId', l->>'name', (l->>'qty')::numeric, (l->>'price')::numeric, (l->>'refundAmount')::numeric
  from jsonb_array_elements(coalesce(refund->'lines', '[]'::jsonb)) l;
end;
$$;

-- ============== sync_clear_sales_td: wipes sales_td/sale_lines_td only ==============
-- Used by "Clear all sales_td history" — a deliberate one-off admin action,
-- not something that happens per checkout.

create or replace function sync_clear_sales_td()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- TRUNCATE, not DELETE, so wiping a large history doesn't fire the
  -- per-row totals triggers thousands of times over — reset the summary
  -- tables directly instead, since there's nothing left to total.
  truncate sale_lines_td;
  truncate sales_td;
  truncate item_sales_totals_td;
  update sales_overall_totals_td set count = 0, revenue = 0 where key = 'all';
end;
$$;

-- ============== per-domain instant replace functions ==============
-- Every button that adds/edits/deletes items_td, categories_td, suppliers_td,
-- purchases_td, cashiers_td, held sales_td, shifts_td, or settings_td calls one of these
-- immediately — each only touches its own table, so editing inventory never
-- has to resend sales_td history (and vice versa).

drop function if exists sync_replace_items_td(jsonb);
create or replace function sync_replace_items_td(items jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from items_td where true;
  insert into items_td (id, name, barcode, category, price, cost, stock, unit, low_stock, expiry)
  select x->>'id', x->>'name', coalesce(x->>'barcode',''), coalesce(x->>'category',''),
         coalesce((x->>'price')::numeric,0), coalesce((x->>'cost')::numeric,0), coalesce((x->>'stock')::numeric,0),
         coalesce(x->>'unit',''), coalesce((x->>'lowStock')::numeric,0), coalesce(x->>'expiry','')
  from jsonb_array_elements(items) x;
end;
$$;

create or replace function sync_replace_item_catalog_td("itemCatalog" jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from item_catalog_td where true;
  insert into item_catalog_td (id, name, barcode, category, brand, price, cost, unit, low_stock)
  select x->>'id', x->>'name', coalesce(x->>'barcode',''), coalesce(x->>'category',''), coalesce(x->>'brand',''),
         coalesce((x->>'price')::numeric,0), coalesce((x->>'cost')::numeric,0), coalesce(x->>'unit',''), coalesce((x->>'lowStock')::numeric,0)
  from jsonb_array_elements("itemCatalog") x;
end;
$$;

drop function if exists sync_replace_categories_td(jsonb);
create or replace function sync_replace_categories_td(categories jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from categories_td where true;
  insert into categories_td (name)
  select jsonb_array_elements_text(categories);
end;
$$;

drop function if exists sync_replace_suppliers_td(jsonb);
create or replace function sync_replace_suppliers_td(suppliers jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from suppliers_td where true;
  insert into suppliers_td (id, name, contact, address)
  select x->>'id', x->>'name', coalesce(x->>'contact',''), coalesce(x->>'address','')
  from jsonb_array_elements(suppliers) x;
end;
$$;

drop function if exists sync_replace_cashiers_td(jsonb);
create or replace function sync_replace_cashiers_td(cashiers jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from cashiers_td where true;
  insert into cashiers_td (id, name, pin)
  select x->>'id', x->>'name', coalesce(x->>'pin','')
  from jsonb_array_elements(cashiers) x;
end;
$$;

drop function if exists sync_replace_purchases_td(jsonb);
create or replace function sync_replace_purchases_td(purchases jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from purchases_td where true;
  insert into purchases_td (id, date, supplier_id, supplier_name, item_id, item_name, qty, cost, total, notes, proof_data_url, proof_name)
  select x->>'id',
         nullif(x->>'date','')::date,
         x->>'supplierId', x->>'supplierName', x->>'itemId', x->>'itemName',
         (x->>'qty')::numeric, (x->>'cost')::numeric, (x->>'total')::numeric, coalesce(x->>'notes',''),
         x->>'proof', x->>'proofName'
  from jsonb_array_elements(purchases) x;
end;
$$;

drop function if exists sync_replace_expenses_td(jsonb);
create or replace function sync_replace_expenses_td(expenses jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from expenses_td where true;
  insert into expenses_td (id, date, period, category, amount, notes)
  select x->>'id', nullif(x->>'date','')::date, coalesce(x->>'period',''), coalesce(x->>'category',''),
         coalesce((x->>'amount')::numeric,0), coalesce(x->>'notes','')
  from jsonb_array_elements(expenses) x;
end;
$$;

drop function if exists sync_replace_customers_td(jsonb);
create or replace function sync_replace_customers_td(customers jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from customers_td where true;
  insert into customers_td (id, name, phone, notes, balance)
  select x->>'id', x->>'name', coalesce(x->>'phone',''), coalesce(x->>'notes',''), coalesce((x->>'balance')::numeric,0)
  from jsonb_array_elements(customers) x;
end;
$$;

create or replace function sync_replace_customer_payments_td("customerPayments" jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from customer_payments_td where true;
  insert into customer_payments_td (id, customer_id, customer_name, amount, date, notes)
  select x->>'id', x->>'customerId', coalesce(x->>'customerName',''), coalesce((x->>'amount')::numeric,0),
         nullif(x->>'date','')::date, coalesce(x->>'notes','')
  from jsonb_array_elements("customerPayments") x;
end;
$$;

drop function if exists sync_replace_held_sales_td(jsonb);
create or replace function sync_replace_held_sales_td("heldSales" jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from held_sales_cart_td where true;
  delete from held_sales_td where true;
  insert into held_sales_td (id, date, customer, discount, tax, cashier)
  select x->>'id', (x->>'date')::timestamptz, x->>'customer', (x->>'discount')::numeric, (x->>'tax')::numeric, x->>'cashier'
  from jsonb_array_elements("heldSales") x;

  insert into held_sales_cart_td (held_id, item_id, qty)
  select h->>'id', c->>'itemId', (c->>'qty')::numeric
  from jsonb_array_elements("heldSales") h,
       jsonb_array_elements(coalesce(h->'cart','[]'::jsonb)) c;
end;
$$;

drop function if exists sync_replace_shifts_td(jsonb);
create or replace function sync_replace_shifts_td(shifts jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from shifts_td where true;
  insert into shifts_td (id, cashier_name, start, "end", opening_cash, cash_sales, card_sales, wallet_sales, cash_refunds, txn_count, expected_cash, actual_cash, difference, notes)
  select x->>'id', x->>'cashierName', (x->>'start')::timestamptz, (x->>'end')::timestamptz,
         (x->>'openingCash')::numeric, (x->>'cashSales')::numeric, (x->>'cardSales')::numeric, (x->>'walletSales')::numeric,
         (x->>'cashRefunds')::numeric, (x->>'txnCount')::integer, (x->>'expectedCash')::numeric,
         (x->>'actualCash')::numeric, (x->>'difference')::numeric, coalesce(x->>'notes','')
  from jsonb_array_elements(shifts) x;
end;
$$;

drop function if exists sync_replace_active_shift_td(jsonb);
create or replace function sync_replace_active_shift_td("activeShift" jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from active_shift_td where true;
  if "activeShift" is not null and "activeShift" != 'null'::jsonb then
    insert into active_shift_td (id, cashier_id, cashier_name, start, opening_cash)
    values (
      "activeShift"->>'id',
      "activeShift"->>'cashierId',
      "activeShift"->>'cashierName',
      ("activeShift"->>'start')::timestamptz,
      ("activeShift"->>'openingCash')::numeric
    );
  end if;
end;
$$;

drop function if exists sync_replace_settings_td(jsonb);
create or replace function sync_replace_settings_td(settings jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from settings_td where true;
  insert into settings_td (key, value)
  select k, v
  from jsonb_each_text(settings) as t(k, v);
end;
$$;

-- ============== grant access ONLY to the functions above ==============

grant execute on function sync_push_td(jsonb) to anon;
grant execute on function sync_pull_sales_range_td(timestamptz, timestamptz, integer, timestamptz, text) to anon;
-- The old 3-arg signature may still be cached from before — drop it so
-- PostgREST doesn't get confused between overloads with the same name.
drop function if exists sync_pull_sales_range_td(timestamptz, timestamptz, integer);
grant execute on function sync_pull_td() to anon;
grant execute on function sync_append_sale_td(jsonb, integer) to anon;
grant execute on function sync_append_sales_batch_td(jsonb) to anon;
grant execute on function sync_append_refund_td(jsonb) to anon;
grant execute on function sync_clear_sales_td() to anon;
grant execute on function sync_replace_items_td(jsonb) to anon;
grant execute on function sync_replace_item_catalog_td(jsonb) to anon;
grant execute on function sync_replace_categories_td(jsonb) to anon;
grant execute on function sync_replace_suppliers_td(jsonb) to anon;
grant execute on function sync_replace_cashiers_td(jsonb) to anon;
grant execute on function sync_replace_purchases_td(jsonb) to anon;
grant execute on function sync_replace_expenses_td(jsonb) to anon;
grant execute on function sync_replace_customers_td(jsonb) to anon;
grant execute on function sync_replace_customer_payments_td(jsonb) to anon;
grant execute on function sync_replace_held_sales_td(jsonb) to anon;
grant execute on function sync_replace_shifts_td(jsonb) to anon;
grant execute on function sync_replace_active_shift_td(jsonb) to anon;
grant execute on function sync_replace_settings_td(jsonb) to anon;

-- ============== APP LOGIN (real username + password) ==============

-- ============== APP LOGIN (real username + password) ==============
-- Replaces the old hardcoded-in-JavaScript password with a real
-- server-side check: the actual password is never present in the app's
-- source code anymore, only a one-way bcrypt hash sits in the database,
-- and the app just asks Postgres "does this match?" and gets true/false
-- back. This is shared by BOTH apps (POS and Client Manager) since they
-- live in the same Supabase project — each app passes its own app_name
-- ('pos-testing-demo' or 'client-manager') so their credentials are
-- independent even though the mechanism is identical.
--
-- Honest limits: this gates the app's UI, not the data functions below —
-- someone who already has your anon key can still call sync_pull_crm()
-- etc. directly (same as before). What's genuinely new is that reading
-- the page's source no longer reveals the password, and you can change
-- it any time from Settings without needing to touch code or re-run SQL.

-- Supabase installs pgcrypto into the "extensions" schema by default, not
-- "public" — every call below is schema-qualified (extensions.crypt(...))
-- instead of relying on search_path, so this works regardless of which
-- schema it lands in.
create extension if not exists pgcrypto with schema extensions;

create table if not exists app_logins (
  app_name text not null,
  username text not null,
  password_hash text not null,
  primary key (app_name, username)
);
alter table app_logins enable row level security;

create or replace function verify_app_login(p_app text, p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
begin
  select password_hash into v_hash from app_logins where app_name = p_app and username = p_username;
  if v_hash is null then
    return false;
  end if;
  return v_hash = extensions.crypt(p_password, v_hash);
end;
$$;

-- Lets a logged-in user change their own app's username/password from
-- Settings. Requires the CURRENT password to succeed — you can't change
-- credentials without already knowing the existing ones.
create or replace function set_app_login(p_app text, p_username text, p_current_password text, p_new_username text, p_new_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not verify_app_login(p_app, p_username, p_current_password) then
    return false;
  end if;
  delete from app_logins where app_name = p_app and username = p_username;
  insert into app_logins (app_name, username, password_hash)
  values (p_app, p_new_username, extensions.crypt(p_new_password, extensions.gen_salt('bf')));
  return true;
end;
$$;

grant execute on function verify_app_login(text, text, text) to anon;
grant execute on function set_app_login(text, text, text, text, text) to anon;

-- Seed the initial login — CHANGE THIS from the app's Settings panel right
-- after setup, since these starting credentials are visible in this file.
-- Checks for ANY existing login on that app_name (not just this exact
-- username), so re-running this file after you've changed the username
-- never silently re-adds the old default alongside your real one.
insert into app_logins (app_name, username, password_hash)
select 'pos-testing-demo', 'admin', extensions.crypt('changeme123', extensions.gen_salt('bf'))
where not exists (select 1 from app_logins where app_name = 'pos-testing-demo');

-- ============== ADMIN SETTINGS GATE (owner-only, single password) ==============
-- A SECOND, separate lock inside Settings — even after someone unlocks the
-- app itself (the shared login everyone uses to open the till), the Cloud
-- Sync credentials and the app login's own Change Login form stay hidden
-- behind this extra password, which only you need to know. Same bcrypt
-- approach as app_logins, just a single password with no username, and its
-- own table so changing one never affects the other.

create table if not exists admin_settings_passwords (
  app_name text primary key,
  password_hash text not null
);
alter table admin_settings_passwords enable row level security;

create or replace function verify_admin_settings_password(p_app text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
begin
  select password_hash into v_hash from admin_settings_passwords where app_name = p_app;
  if v_hash is null then
    return false;
  end if;
  return v_hash = extensions.crypt(p_password, v_hash);
end;
$$;

create or replace function set_admin_settings_password(p_app text, p_current_password text, p_new_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if exists (select 1 from admin_settings_passwords where app_name = p_app) then
    if not verify_admin_settings_password(p_app, p_current_password) then
      return false;
    end if;
  end if;
  delete from admin_settings_passwords where app_name = p_app;
  insert into admin_settings_passwords (app_name, password_hash)
  values (p_app, extensions.crypt(p_new_password, extensions.gen_salt('bf')));
  return true;
end;
$$;

grant execute on function verify_admin_settings_password(text, text) to anon;
grant execute on function set_admin_settings_password(text, text, text) to anon;

-- Seed a starting password — CHANGE THIS from the newly-unlocked admin panel
-- right after setup, since it's visible here in this file.
insert into admin_settings_passwords (app_name, password_hash)
select 'pos-testing-demo', extensions.crypt('changeme456', extensions.gen_salt('bf'))
where not exists (select 1 from admin_settings_passwords where app_name = 'pos-testing-demo');
