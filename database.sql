-- =========================================================
-- ACC VAULT — SUPABASE DATABASE SCHEMA (DATA-ONLY VERSION)
-- Chạy toàn bộ file này trong Supabase SQL Editor (1 lần).
-- An toàn để chạy lại nhiều lần (idempotent).
-- Toàn bộ logic nghiệp vụ (tạo mã thuê, kiểm tra acc, countdown,
-- đồng bộ trạng thái, xác nhận thanh toán, gia hạn...) xử lý ở
-- JavaScript trong index.html thông qua Supabase JS Client API
-- (select / insert / update / delete trực tiếp).
-- Database CHỈ lưu dữ liệu: bảng, khóa, index, RLS.
-- =========================================================

create extension if not exists pgcrypto;

-- =========================================================
-- 1. BẢNG accounts — danh sách acc cho thuê
-- =========================================================
create table if not exists public.accounts (
  id           text primary key,
  name         text not null,
  status       text not null default 'available'
               check (status in ('available','rented','maintenance')),
  prices       jsonb not null default '{}'::jsonb,
  sort_order   int not null default 0,
  updated_at   timestamptz not null default now()
);

-- =========================================================
-- 2. BẢNG orders — đơn thuê
-- =========================================================
create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  code           text unique,
  account_id     text not null references public.accounts(id) on delete restrict,
  account_name   text not null,
  package_hours  int not null,
  amount         numeric not null,
  status         text not null default 'holding'
                 check (status in ('holding','unconfirmed','confirmed','rejected','expired')),
  created_at     timestamptz not null default now(),
  expires_at     timestamptz,
  confirmed_at   timestamptz
);
create index if not exists idx_orders_account on public.orders(account_id);
create index if not exists idx_orders_status  on public.orders(status);
create index if not exists idx_orders_code    on public.orders(code);

-- =========================================================
-- 3. BẢNG payments — lịch sử xác nhận thanh toán của từng đơn
-- =========================================================
create table if not exists public.payments (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  amount      numeric not null,
  method      text not null default 'bank_transfer',
  status      text not null default 'claimed'
              check (status in ('claimed','confirmed','rejected')),
  created_at  timestamptz not null default now()
);
create index if not exists idx_payments_order on public.payments(order_id);

-- =========================================================
-- 4. BẢNG rentals — phiên thuê thực tế
-- =========================================================
create table if not exists public.rentals (
  id           uuid primary key default gen_random_uuid(),
  account_id   text not null references public.accounts(id) on delete restrict,
  order_id     uuid not null references public.orders(id) on delete cascade,
  start_time   timestamptz not null default now(),
  end_time     timestamptz not null,
  status       text not null default 'active'
               check (status in ('active','completed','cancelled')),
  created_at   timestamptz not null default now()
);
create unique index if not exists one_active_rental_per_account
  on public.rentals(account_id) where status = 'active';
create index if not exists idx_rentals_order on public.rentals(order_id);

-- =========================================================
-- 5. BẢNG settings — cấu hình ngân hàng / zalo / logo / QR
-- =========================================================
create table if not exists public.settings (
  id                   text primary key default 'default',
  bank_name            text,
  bank_account_name    text,
  bank_account_number  text,
  zalo_number          text,
  qr_url               text,
  logo_url             text,
  updated_at           timestamptz not null default now()
);
insert into public.settings (id) values ('default')
  on conflict (id) do nothing;

-- =========================================================
-- 6. BẢNG notifications — thông báo cho Admin
-- =========================================================
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  type        text not null,
  message     text not null,
  order_id    uuid references public.orders(id) on delete set null,
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists idx_notifications_read on public.notifications(is_read);

-- =========================================================
-- 7. BẢNG admin_logs — nhật ký thao tác quản trị
-- =========================================================
create table if not exists public.admin_logs (
  id          uuid primary key default gen_random_uuid(),
  action      text not null,
  detail      jsonb,
  created_at  timestamptz not null default now()
);

-- =========================================================
-- SEED DATA — 6 acc mặc định
-- =========================================================
insert into public.accounts (id, name, status, prices, sort_order) values
  ('acc1','Acc 1','available','{"1":30000,"2":50000,"3":60000,"4":80000}',1),
  ('acc2','Acc 2','available','{"1":35000,"2":60000,"3":70000,"4":90000}',2),
  ('acc3','Acc 3','available','{"1":30000,"2":50000,"3":60000,"4":80000}',3),
  ('acc4','Acc 4','available','{"1":25000,"2":40000,"3":50000,"4":70000}',4),
  ('acc5','Acc 5','available','{"1":30000,"2":50000,"3":60000,"4":80000}',5),
  ('acc6','Acc 6','available','{"1":20000,"2":40000,"3":50000,"4":60000}',6)
on conflict (id) do nothing;

update public.settings set
  bank_name = 'BIDV — PGD',
  bank_account_name = 'MAI ĐẶNG PHƯỚC THỊNH',
  bank_account_number = '8865743051',
  zalo_number = '0818105658'
where id = 'default'
  and bank_name is null;

-- =========================================================
-- updated_at TRIGGER — chỉ dùng trigger tối thiểu này (không có
-- trigger/function nghiệp vụ nào khác trong file)
-- =========================================================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_accounts_updated_at on public.accounts;
create trigger trg_accounts_updated_at
  before update on public.accounts
  for each row execute function public.set_updated_at();

drop trigger if exists trg_settings_updated_at on public.settings;
create trigger trg_settings_updated_at
  before update on public.settings
  for each row execute function public.set_updated_at();

-- =========================================================
-- ROW LEVEL SECURITY
-- anon/authenticated được đọc và ghi trực tiếp (insert/update/delete)
-- vì toàn bộ logic kiểm tra nằm ở JavaScript trong index.html.
-- =========================================================
alter table public.accounts      enable row level security;
alter table public.orders        enable row level security;
alter table public.payments      enable row level security;
alter table public.rentals       enable row level security;
alter table public.settings      enable row level security;
alter table public.notifications enable row level security;
alter table public.admin_logs    enable row level security;

drop policy if exists accounts_select_all on public.accounts;
create policy accounts_select_all on public.accounts for select using (true);
drop policy if exists accounts_write_all on public.accounts;
create policy accounts_write_all on public.accounts for all using (true) with check (true);

drop policy if exists orders_select_all on public.orders;
create policy orders_select_all on public.orders for select using (true);
drop policy if exists orders_write_all on public.orders;
create policy orders_write_all on public.orders for all using (true) with check (true);

drop policy if exists payments_select_all on public.payments;
create policy payments_select_all on public.payments for select using (true);
drop policy if exists payments_write_all on public.payments;
create policy payments_write_all on public.payments for all using (true) with check (true);

drop policy if exists rentals_select_all on public.rentals;
create policy rentals_select_all on public.rentals for select using (true);
drop policy if exists rentals_write_all on public.rentals;
create policy rentals_write_all on public.rentals for all using (true) with check (true);

drop policy if exists settings_select_all on public.settings;
create policy settings_select_all on public.settings for select using (true);
drop policy if exists settings_write_all on public.settings;
create policy settings_write_all on public.settings for all using (true) with check (true);

drop policy if exists notifications_select_all on public.notifications;
create policy notifications_select_all on public.notifications for select using (true);
drop policy if exists notifications_write_all on public.notifications;
create policy notifications_write_all on public.notifications for all using (true) with check (true);

drop policy if exists admin_logs_select_all on public.admin_logs;
create policy admin_logs_select_all on public.admin_logs for select using (true);
drop policy if exists admin_logs_write_all on public.admin_logs;
create policy admin_logs_write_all on public.admin_logs for all using (true) with check (true);

-- =========================================================
-- REALTIME — bật replication cho các bảng cần đồng bộ tức thời
-- =========================================================
do $$
begin
  begin
    alter publication supabase_realtime add table public.accounts;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.orders;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.notifications;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.rentals;
  exception when duplicate_object then null;
  end;
end $$;

-- =========================================================
-- HẾT — Sau khi chạy file này, vào Database > Replication trong Supabase
-- và đảm bảo 4 bảng accounts, orders, notifications, rentals đã bật Realtime.
-- =========================================================
